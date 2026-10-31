import Foundation

/// Reads, writes, and watches one drawing file.
///
/// Writes are atomic and coalesced. The file is watched so edits from other
/// programs, such as an agent writing the JSON directly, show up live. The
/// store ignores events caused by its own writes.
@MainActor
final class CanvasStore {
    let url: URL

    /// The drawing as the file holds it: what Nubb last read or wrote. This
    /// is the base of the three-way merge when the file changes.
    private(set) var base = CanvasDocument()

    /// Called on the main queue when another program changed the file, with
    /// the new contents and the previous `base`.
    var onExternalChange: ((_ remote: CanvasDocument, _ base: CanvasDocument) -> Void)?

    /// Called when a write fails.
    var onWriteError: ((Error) -> Void)?

    /// The bytes Nubb last read from or wrote to the file.
    private var knownData: Data?

    private var source: DispatchSourceFileSystemObject?
    private var directorySource: DispatchSourceFileSystemObject?
    private var pendingCheck: DispatchWorkItem?
    private var pendingWrite: DispatchWorkItem?
    private var pendingDocument: CanvasDocument?

    /// How long to wait after an edit before writing.
    var writeDelay: TimeInterval = 0.3

    /// How long to wait after a file event before reading, so a burst of
    /// events becomes one read.
    var readDelay: TimeInterval = 0.05

    init(url: URL) {
        self.url = url
    }

    deinit {
        source?.cancel()
        directorySource?.cancel()
    }

    // MARK: Reading

    /// Reads the file, creating it empty when missing.
    func read() throws -> CanvasDocument {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try CanvasDocument().encoded().write(to: url, options: .atomic)
        }
        let data = try Data(contentsOf: url)
        let document = try CanvasDocument.decode(data)
        knownData = data
        base = document
        return document
    }

    // MARK: Writing

    /// Writes `document` after a short delay, replacing any write still
    /// waiting.
    func scheduleWrite(_ document: CanvasDocument) {
        pendingDocument = document
        pendingWrite?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
        pendingWrite = work
        DispatchQueue.main.asyncAfter(deadline: .now() + writeDelay, execute: work)
    }

    var hasPendingWrite: Bool { pendingDocument != nil }

    /// Drops a write that hasn't happened yet.
    func cancelPendingWrite() {
        pendingWrite?.cancel()
        pendingWrite = nil
        pendingDocument = nil
    }

    /// Writes any waiting document now.
    func flush() {
        pendingWrite?.cancel()
        pendingWrite = nil
        guard let document = pendingDocument else { return }
        pendingDocument = nil
        let data = document.encoded()
        guard data != knownData else {
            base = document
            return
        }
        do {
            // Remember the bytes first: the write fires the watcher.
            knownData = data
            try data.write(to: url, options: .atomic)
            base = document
        } catch {
            Nubb.logger.error("canvas write failed path=\(self.url.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            onWriteError?(error)
        }
    }

    // MARK: Watching

    func startWatching() {
        stopWatching()
        watchFile()
        watchDirectory()
    }

    func stopWatching() {
        source?.cancel()
        source = nil
        directorySource?.cancel()
        directorySource = nil
        pendingCheck?.cancel()
        pendingCheck = nil
    }

    /// Watches the file itself for in-place writes.
    private func watchFile() {
        source?.cancel()
        source = nil
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .attrib],
            queue: .main)
        source.setEventHandler { [weak self, weak source] in
            let events = source?.data ?? []
            MainActor.assumeIsolated {
                guard let self else { return }
                // Atomic saves replace the file: watch the new one.
                if events.contains(.delete) || events.contains(.rename) {
                    self.watchFile()
                }
                self.scheduleCheck()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    /// Watches the folder, which changes when the file is replaced by a
    /// rename (how most programs save).
    private func watchDirectory() {
        let directory = url.deletingLastPathComponent()
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.watchFile()
                self.scheduleCheck()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        directorySource = source
    }

    private func scheduleCheck() {
        pendingCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.checkForChanges() }
        }
        pendingCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + readDelay, execute: work)
    }

    /// Reads the file and reports it when it differs from what Nubb knows.
    func checkForChanges() {
        guard let data = try? Data(contentsOf: url), data != knownData else { return }
        // A half-written file from a program that doesn't write atomically
        // fails to parse: wait for its next write.
        guard let remote = try? CanvasDocument.decode(data) else { return }
        knownData = data
        let previous = base
        base = remote
        onExternalChange?(remote, previous)
    }
}

// MARK: - Locations

enum CanvasFiles {
    /// Where new canvases go: `~/Library/Application Support/<bundle id>/Canvases`.
    static var defaultDirectory: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let bundle = Bundle.main.bundleIdentifier ?? "com.evancdev.nubb"
        return base.appendingPathComponent(bundle, isDirectory: true).appendingPathComponent("Canvases", isDirectory: true)
    }

    /// A file name in `directory` that isn't taken yet.
    static func newFileURL(in directory: URL = defaultDirectory, date: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let stem = "Canvas \(formatter.string(from: date))"
        var url = directory.appendingPathComponent(stem).appendingPathExtension(CanvasDocument.fileExtension)
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(stem) \(counter)").appendingPathExtension(CanvasDocument.fileExtension)
            counter += 1
        }
        return url
    }

    static func isCanvasFile(_ path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == CanvasDocument.fileExtension
    }
}
