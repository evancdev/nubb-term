import Foundation

/// Undo and redo for a drawing.
///
/// Each step stores only the elements it changed, before and after, so a
/// long history of a large drawing stays small. The z-order is stored only
/// when it changed. Changes merged in from the file (an agent or another
/// app editing it) are not steps: undo only reverts the user's own edits.
struct CanvasHistory {
    struct Entry: Equatable {
        /// Elements before the step, by id. `nil` means the element didn't exist.
        var before: [String: CanvasElement?]
        /// Elements after the step, by id. `nil` means the element was removed.
        var after: [String: CanvasElement?]
        var orderBefore: [String]?
        var orderAfter: [String]?
        var appStateBefore: [String: CanvasJSON]?
        var appStateAfter: [String: CanvasJSON]?
        var selectionBefore: Set<String>
        var selectionAfter: Set<String>
    }

    static let limit = 200

    private(set) var undoStack: [Entry] = []
    private(set) var redoStack: [Entry] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    mutating func record(_ entry: Entry, coalescing key: String? = nil, at time: Date = Date()) {
        defer {
            lastKey = key
            lastTime = time
        }
        if let key, key == lastKey, redoStack.isEmpty,
           time.timeIntervalSince(lastTime) < Self.coalescingWindow,
           let previous = undoStack.popLast() {
            undoStack.append(Self.combine(previous, entry))
            return
        }
        undoStack.append(entry)
        if undoStack.count > Self.limit {
            undoStack.removeFirst(undoStack.count - Self.limit)
        }
        redoStack.removeAll()
    }

    /// The key of the last recorded step, so repeated changes from one
    /// control, like dragging the opacity slider, become one step.
    private var lastKey: String?
    private var lastTime = Date.distantPast

    /// Changes with the same key further apart than this are separate steps.
    static let coalescingWindow: TimeInterval = 1

    /// Ends coalescing: the next step is recorded on its own.
    mutating func breakCoalescing() {
        lastKey = nil
    }

    /// One step doing `first` then `second`.
    static func combine(_ first: Entry, _ second: Entry) -> Entry {
        var result = first
        for (id, element) in second.before where result.before[id] == nil {
            result.before[id] = element
        }
        for (id, element) in second.after {
            result.after[id] = element
        }
        if result.orderBefore == nil { result.orderBefore = second.orderBefore }
        if second.orderAfter != nil { result.orderAfter = second.orderAfter }
        if result.appStateBefore == nil { result.appStateBefore = second.appStateBefore }
        if second.appStateAfter != nil { result.appStateAfter = second.appStateAfter }
        result.selectionAfter = second.selectionAfter
        return result
    }

    mutating func popUndo() -> Entry? {
        lastKey = nil
        guard let entry = undoStack.popLast() else { return nil }
        redoStack.append(entry)
        return entry
    }

    mutating func popRedo() -> Entry? {
        lastKey = nil
        guard let entry = redoStack.popLast() else { return nil }
        undoStack.append(entry)
        return entry
    }

    mutating func clear() {
        lastKey = nil
        undoStack.removeAll()
        redoStack.removeAll()
    }

    /// The step that turns `old` into `new`, or nil when nothing changed.
    static func diff(
        from old: CanvasDocument,
        to new: CanvasDocument,
        selectionBefore: Set<String>,
        selectionAfter: Set<String>
    ) -> Entry? {
        var oldByID: [String: CanvasElement] = [:]
        oldByID.reserveCapacity(old.elements.count)
        for element in old.elements { oldByID[element.id] = element }

        var before: [String: CanvasElement?] = [:]
        var after: [String: CanvasElement?] = [:]
        var seen = Set<String>()
        seen.reserveCapacity(new.elements.count)

        for element in new.elements {
            seen.insert(element.id)
            let previous = oldByID[element.id]
            if previous != element {
                before[element.id] = .some(previous)
                after[element.id] = .some(element)
            }
        }
        for element in old.elements where !seen.contains(element.id) {
            before[element.id] = .some(element)
            after[element.id] = .some(nil)
        }

        let oldOrder = old.elements.map(\.id)
        let newOrder = new.elements.map(\.id)
        let orderChanged = oldOrder != newOrder
        let appStateChanged = old.appState != new.appState

        guard !before.isEmpty || orderChanged || appStateChanged else { return nil }

        return Entry(
            before: before,
            after: after,
            orderBefore: orderChanged ? oldOrder : nil,
            orderAfter: orderChanged ? newOrder : nil,
            appStateBefore: appStateChanged ? old.appState : nil,
            appStateAfter: appStateChanged ? new.appState : nil,
            selectionBefore: selectionBefore,
            selectionAfter: selectionAfter)
    }

    /// Applies one side of a step to `document`.
    static func apply(
        _ changes: [String: CanvasElement?],
        order: [String]?,
        appState: [String: CanvasJSON]?,
        to document: inout CanvasDocument
    ) {
        var byID: [String: CanvasElement] = [:]
        byID.reserveCapacity(document.elements.count)
        for element in document.elements { byID[element.id] = element }
        for (id, value) in changes {
            byID[id] = value
        }

        let baseOrder = order ?? document.elements.map(\.id)
        var result: [CanvasElement] = []
        result.reserveCapacity(byID.count)
        var placed = Set<String>()
        for id in baseOrder {
            if let element = byID[id], !placed.contains(id) {
                result.append(element)
                placed.insert(id)
            }
        }

        // Elements the order doesn't know: added by this step without an
        // order, or merged in from the file since the step was recorded.
        for element in document.elements where !placed.contains(element.id) {
            if let current = byID[element.id] {
                result.append(current)
                placed.insert(element.id)
            }
        }
        for id in changes.keys.sorted() where !placed.contains(id) {
            if let element = byID[id] {
                result.append(element)
                placed.insert(id)
            }
        }

        document.elements = result
        if let appState { document.appState = appState }
    }
}

// MARK: - Merge

/// A three-way merge of a drawing, used when the file changes on disk while
/// it is open. `base` is the file as Nubb last read or wrote it.
enum CanvasMerge {
    /// Merges `remote` (the file now) into `local` (the open drawing).
    ///
    /// An element changed on only one side takes that side. An element
    /// changed on both sides takes the one with the higher `version`, and
    /// the local one on a tie.
    static func merge(base: CanvasDocument, local: CanvasDocument, remote: CanvasDocument) -> CanvasDocument {
        let baseByID = dictionary(base.elements)
        let localByID = dictionary(local.elements)
        let remoteByID = dictionary(remote.elements)

        var merged: [String: CanvasElement] = [:]
        let allIDs = Set(baseByID.keys).union(localByID.keys).union(remoteByID.keys)
        for id in allIDs {
            let b = baseByID[id], l = localByID[id], r = remoteByID[id]
            if l == b {
                if let r { merged[id] = r }
            } else if r == b {
                if let l { merged[id] = l }
            } else {
                switch (l, r) {
                case let (l?, r?):
                    merged[id] = r.version > l.version ? r : l
                case let (l?, nil):
                    // Deleted remotely, edited locally: keep the edit.
                    merged[id] = l
                case let (nil, r?):
                    // Deleted locally, edited remotely: keep the edit.
                    merged[id] = r
                case (nil, nil):
                    break
                }
            }
        }

        var result = remote
        result.elements = mergedOrder(base: base, local: local, remote: remote, ids: Set(merged.keys))
            .compactMap { merged[$0] }
        result.appState = mergeMap(base: base.appState, local: local.appState, remote: remote.appState)
        result.files = mergeMap(base: base.files, local: local.files, remote: remote.files)
        result.extra = mergeMap(base: base.extra, local: local.extra, remote: remote.extra)
        return result
    }

    private static func dictionary(_ elements: [CanvasElement]) -> [String: CanvasElement] {
        var result: [String: CanvasElement] = [:]
        result.reserveCapacity(elements.count)
        for element in elements { result[element.id] = element }
        return result
    }

    /// The z-order of the merged drawing. A side that reordered wins over a
    /// side that didn't. New elements from the other side keep their place
    /// next to the element they were above.
    static func mergedOrder(base: CanvasDocument, local: CanvasDocument, remote: CanvasDocument, ids: Set<String>) -> [String] {
        let baseOrder = base.elements.map(\.id)
        let localOrder = local.elements.map(\.id)
        let remoteOrder = remote.elements.map(\.id)
        let baseIDs = Set(baseOrder)

        let remoteReordered = remoteOrder.filter(baseIDs.contains) != baseOrder.filter(Set(remoteOrder).contains)
        let primary = remoteReordered ? remoteOrder : localOrder
        let secondary = remoteReordered ? localOrder : remoteOrder

        var order = primary.filter(ids.contains)
        var placed = Set(order)
        for (index, id) in secondary.enumerated() where ids.contains(id) && !placed.contains(id) {
            // An element above everything the other side knows stays on top.
            let hasPlacedAbove = secondary[(index + 1)...].contains { placed.contains($0) }
            guard hasPlacedAbove else {
                order.append(id)
                placed.insert(id)
                continue
            }
            // Otherwise it goes right above the closest element below it.
            var insertAt = 0
            var probe = index - 1
            while probe >= 0 {
                if let position = order.firstIndex(of: secondary[probe]) {
                    insertAt = position + 1
                    break
                }
                probe -= 1
            }
            order.insert(id, at: insertAt)
            placed.insert(id)
        }
        return order
    }

    private static func mergeMap(base: [String: CanvasJSON], local: [String: CanvasJSON], remote: [String: CanvasJSON]) -> [String: CanvasJSON] {
        var result: [String: CanvasJSON] = [:]
        for key in Set(base.keys).union(local.keys).union(remote.keys) {
            let b = base[key], l = local[key], r = remote[key]
            let value = l == b ? r : (r == b ? l : r)
            if let value { result[key] = value }
        }
        return result
    }
}
