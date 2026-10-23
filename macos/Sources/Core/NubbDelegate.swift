import Foundation

extension Nubb {
    /// This is a delegate that should be applied to your global app delegate for NubbKit
    /// to perform app-global operations.
    protocol Delegate {
        /// Look up a surface within the application by ID.
        func nubbSurface(id: UUID) -> SurfaceView?
    }
}
