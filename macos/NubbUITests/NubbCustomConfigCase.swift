//
//  NubbCustomConfigCase.swift
//  Nubb
//
//  Created by luca on 16.10.2025.
//

import XCTest

class NubbCustomConfigCase: XCTestCase {
    /// We only want run these UI tests
    /// when testing manually with Xcode IDE
    ///
    /// So that we don't have to wait for each ci check
    /// to run these tedious tests
    override class var defaultTestSuite: XCTestSuite {
        // https://lldb.llvm.org/cpp_reference/PlatformDarwin_8cpp_source.html#:~:text==%20%22-,IDE_DISABLED_OS_ACTIVITY_DT_MODE

        if ProcessInfo.processInfo.environment["IDE_DISABLED_OS_ACTIVITY_DT_MODE"] != nil {
            return XCTestSuite(forTestCaseClass: Self.self)
        } else {
            return XCTestSuite(name: "Skipping \(className())")
        }
    }

    static let defaultsSuiteName: String = "NUBB_UI_TESTS"

    private let configFile: URL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("nubb")

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: configFile)
    }

    func updateConfig(_ newConfig: String) throws {
        try newConfig.write(to: configFile, atomically: true, encoding: .utf8)
    }

    func nubbApplication(defaultsSuite: String = NubbCustomConfigCase.defaultsSuiteName) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: ["-ApplePersistenceIgnoreState", "YES"])
        app.launchEnvironment["NUBB_CONFIG_PATH"] = configFile.path
        app.launchEnvironment["NUBB_USER_DEFAULTS_SUITE"] = defaultsSuite
        return app
    }
}
