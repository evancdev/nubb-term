# macOS Nubb Application

- The Xcode project, scheme, targets, and Swift module are named `Nubb`
  (`Nubb.xcodeproj`, scheme `Nubb`, test targets `NubbTests` and
  `NubbUITests`). The bundle id is `com.evancdev.nubb`.
- Use `swiftlint` for formatting and linting Swift code.
- If code outside of `macos/` directory is modified, use
  `zig build -Demit-macos-app=false` before building the macOS app to update
  the underlying library.
- Build and test with `xcodebuild` from `macos/`. `macos/build.nu` needs
  Nushell; prefer the `xcodebuild` commands below.
  - Build: `xcodebuild -scheme Nubb -configuration Debug SYMROOT=build build`
  - Output: `macos/build/<configuration>/Nubb.app`
  - Unit tests: `xcodebuild -scheme Nubb -skip-testing NubbUITests test`
    (UI tests need special permissions, so skip them.)
  - Run one suite with `-only-testing:NubbTests/<SuiteName>`.
  - Unit tests run in one test host process. Each host is a full copy of
    the app (Metal, fonts, libnubb), so parallel testing is off in the
    scheme and test plan. Never pass `-parallel-testing-enabled YES`.
  - Add `-test-timeouts-enabled YES -default-test-execution-time-allowance 60`
    so a hung test fails instead of leaving the host running. If a run is
    interrupted, check `ps -axo pid,command | grep DerivedData/Nubb-` for
    leftover hosts.
- Never run `xcodebuild clean` or delete `macos/build/` without first checking
  that no running terminal is launched from it.
