import Foundation

/// Keeps an editor and its file in sync: saves edits, merges changes other
/// programs make to the file, and holds those back while the user is in the
/// middle of a drag or typing.
@MainActor
final class CanvasSession {
    let editor: CanvasEditor
    let store: CanvasStore

    /// Whether the user is in the middle of something that a merge must not
    /// interrupt. Set by the view (text editing) on top of the editor's own
    /// interactions.
    var isBusy: () -> Bool = { false }

    /// Called after the file couldn't be read, or could be read again.
    var onLoadStateChange: (() -> Void)?

    /// File changes that arrived while busy, merged when it ends. Later
    /// changes replace earlier ones; the base stays the oldest.
    private var pendingRemote: (remote: CanvasDocument, base: CanvasDocument)?

    init(editor: CanvasEditor, store: CanvasStore) {
        self.editor = editor
        self.store = store
        editor.onCommit = { [weak self] document in self?.store.scheduleWrite(document) }
        editor.onInteractionEnd = { [weak self] in self?.applyPending() }
        store.onExternalChange = { [weak self] remote, base in self?.fileDidChange(remote: remote, base: base) }
        store.onWriteError = { [weak self] error in
            self?.editor.ui.set(\.loadError, "Couldn't save: \(error.localizedDescription)")
        }
    }

    /// Reads the file and starts watching it. A file that can't be read is
    /// left untouched and the drawing stays read-only until it's fixed.
    func open() {
        do {
            let document = try store.read()
            editor.isEditable = true
            editor.ui.set(\.loadError, nil)
            editor.load(document)
        } catch {
            editor.isEditable = false
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            editor.ui.set(\.loadError, "Can't read \(store.url.lastPathComponent): \(reason) Fix the file and it will reload.")
            editor.load(CanvasDocument())
        }
        store.startWatching()
        onLoadStateChange?()
    }

    func close() {
        store.flush()
        store.stopWatching()
    }

    /// Called when the user finishes something `isBusy` reported.
    func applyPending() {
        guard let pending = pendingRemote, !editor.isInteracting, !isBusy() else { return }
        pendingRemote = nil
        merge(remote: pending.remote, base: pending.base)
    }

    private func fileDidChange(remote: CanvasDocument, base: CanvasDocument) {
        if !editor.isEditable {
            // The file was broken and now parses: take it as is.
            editor.isEditable = true
            editor.ui.set(\.loadError, nil)
            editor.load(remote)
            onLoadStateChange?()
            return
        }
        if editor.isInteracting || isBusy() {
            pendingRemote = (remote, pendingRemote?.base ?? base)
            return
        }
        merge(remote: remote, base: base)
    }

    private func merge(remote: CanvasDocument, base: CanvasDocument) {
        let local = editor.document
        let merged = CanvasMerge.merge(base: base, local: local, remote: remote)
        if merged != local {
            editor.applyExternal(merged)
        }
        // A save still waiting holds the drawing from before the merge.
        // Replace it so it can't undo the other program's change, or drop it
        // when the file already has everything.
        if merged == remote {
            store.cancelPendingWrite()
        } else {
            store.scheduleWrite(merged)
        }
    }
}
