import Foundation
@testable import Nubb
@testable import NubbKit

/// Create a temporary config file and delete it when this is deallocated
class TemporaryConfig: Nubb.Config {
    enum Error: Swift.Error {
        case failedToLoad
    }

    let temporaryFile: URL

    init(_ configText: String, finalize: Bool = true) throws {
        let temporaryFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("nubb")
        try configText.write(to: temporaryFile, atomically: true, encoding: .utf8)
        self.temporaryFile = temporaryFile
        super.init(config: Self.loadConfig(at: temporaryFile.path(), finalize: finalize))
    }

    func reload(_ newConfigText: String?, finalize: Bool = true) throws {
        if let newConfigText {
            try newConfigText.write(to: temporaryFile, atomically: true, encoding: .utf8)
        }
        guard let cfg = Self.loadConfig(at: temporaryFile.path(), finalize: finalize) else {
            throw Error.failedToLoad
        }
        clone(config: cfg)
    }

    deinit {
        try? FileManager.default.removeItem(at: temporaryFile)
    }
}
