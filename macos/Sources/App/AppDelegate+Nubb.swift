import AppKit

// MARK: Nubb Delegate

/// This implements the Nubb app delegate protocol which is used by the Nubb
/// APIs for app-global information.
extension AppDelegate: Nubb.Delegate {
    func nubbSurface(id: UUID) -> Nubb.SurfaceView? {
        for window in NSApp.windows {
            guard let controller = window.windowController as? BaseTerminalController else {
                continue
            }

            for surface in controller.surfaceTree where surface.id == id {
                return surface
            }
        }

        return nil
    }
}
