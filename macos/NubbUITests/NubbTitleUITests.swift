//
//  NubbTitleUITests.swift
//  NubbUITests
//
//  Created by luca on 13.10.2025.
//

import XCTest

final class NubbTitleUITests: NubbCustomConfigCase {
    override func setUp() async throws {
        try await super.setUp()
        try updateConfig(#"title = "NubbUITestsLaunchTests""#)
    }

    @MainActor
    func testTitle() throws {
        let app = try nubbApplication()
        app.launch()

        XCTAssertEqual(app.windows.firstMatch.title, "NubbUITestsLaunchTests", "Oops, `title=` doesn't work!")
    }
}
