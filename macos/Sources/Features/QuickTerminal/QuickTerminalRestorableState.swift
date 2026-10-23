import Cocoa

struct QuickTerminalRestorableState: TerminalRestorable {
    static var version: Int { 1 }
    /// The name this type was archived under while the Swift module was named
    /// `Ghostty`. Never change it, or the quick terminal stops restoring.
    static var archivedClassName: String? { "_TtGC7Ghostty13CodableBridgeVS_28QuickTerminalRestorableState_" }

    var focusedSurface: String? {
        internalState.focusedSurface
    }

    var surfaceTree: SplitTree<Nubb.SurfaceView> {
        internalState.surfaceTree
    }

    var screenStateEntries: QuickTerminalScreenStateCache.Entries {
        internalState.screenStateEntries
    }

    private let internalState: InternalState<Nubb.SurfaceView>

    init(from controller: QuickTerminalController) {
        controller.saveScreenState(exitFullscreen: true)
        self.internalState = .init(from: controller)
    }

    init(copy other: QuickTerminalRestorableState) {
        self = other
    }

    var baseConfig: Nubb.SurfaceConfiguration? {
        var config = Nubb.SurfaceConfiguration()
        config.environmentVariables["NUBB_QUICK_TERMINAL"] = "1"
        return config
    }
}

extension QuickTerminalRestorableState {
    /// Internal State we use to perform unit tests
    ///
    /// Since we can't really change the type of `QuickTerminalRestorableState`
    /// due to `CodableBridge<QuickTerminalRestorableState>` supporting secure coding,
    /// we use an internal type to perform migration and tests
    struct InternalState<ViewType: NSView & Codable & Identifiable>: Codable {
        // MARK: - Version 1 (1.3.0)
        let focusedSurface: String?
        let surfaceTree: SplitTree<ViewType>
        let screenStateEntries: QuickTerminalScreenStateCache.Entries
    }
}

extension QuickTerminalRestorableState.InternalState where ViewType == Nubb.SurfaceView {
    init(from controller: QuickTerminalController) {
        self.init(
            focusedSurface: controller.focusedSurface?.id.uuidString,
            surfaceTree: controller.surfaceTree,
            screenStateEntries: controller.screenStateCache.stateByDisplay,
        )
    }
}
