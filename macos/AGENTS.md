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
- Never run `xcodebuild clean` or delete `macos/build/` without first checking
  that no running terminal is launched from it.
