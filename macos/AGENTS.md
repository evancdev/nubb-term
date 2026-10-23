# macOS Nubb Application

- The Xcode project, scheme, and Swift module are still named `Ghostty`
  (`PRODUCT_MODULE_NAME` was kept). The product and bundle are `Nubb`
  (`com.evancdev.nubb`).
- Use `swiftlint` for formatting and linting Swift code.
- If code outside of `macos/` directory is modified, use
  `zig build -Demit-macos-app=false` before building the macOS app to update
  the underlying library.
- Build and test with `xcodebuild` from `macos/`. `macos/build.nu` needs
  Nushell; prefer the `xcodebuild` commands below.
  - Build: `xcodebuild -scheme Ghostty -configuration Debug SYMROOT=build build`
  - Output: `macos/build/<configuration>/Nubb.app`
  - Unit tests: `xcodebuild -scheme Ghostty -skip-testing GhosttyUITests test`
    (UI tests need special permissions, so skip them.)
- Never run `xcodebuild clean` or delete `macos/build/` without first checking
  that no running terminal is launched from it.
