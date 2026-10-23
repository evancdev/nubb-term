import Foundation
import os

// This defines the minimal information required so all other files can do
// `extension Nubb` to add more to it. This purposely has minimal
// dependencies so things like our dock tile plugin can use it.
enum Nubb {
    // The primary logger used by the NubbKit libraries.
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: "nubb"
    )

    // All the notifications that will be emitted will be put here.
    struct Notification {}
}
