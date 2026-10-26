# Removed from Ghostty

Nubb started from [ghostty-org/ghostty](https://github.com/ghostty-org/ghostty)
at commit `08a9518340e19487bd5fdf96963583fb32f0c41f` (2026-10-22). This file
lists everything Nubb removed from that tree, so any of it can be found or
brought back later. So far that is 1,038 files and about 247,000 lines of text.

Paths below are upstream paths at that commit. A path ending in `/` is a
whole directory. Renamed files (ghostty to nubb) are not listed.

To view or restore something:

```sh
git fetch https://github.com/ghostty-org/ghostty 08a9518340e19487bd5fdf96963583fb32f0c41f
git show FETCH_HEAD:<path>          # print one file
git checkout FETCH_HEAD -- <path>   # copy a file or directory back
```

To browse online, open
<https://github.com/ghostty-org/ghostty/tree/08a9518340e19487bd5fdf96963583fb32f0c41f>.

Every removal adds its entry here in the same commit.

## Dependencies removed

- Zig packages: fontconfig, harfbuzz, libxml2, gtk4-layer-shell, gobject,
  wayland, wayland-protocols, plasma-wayland-protocols, zig-wayland, opengl,
  libintl, sentry, breakpad, zig-js, android-ndk, iterm2_themes.
- Swift packages: Sparkle.

## Platforms and build

### libghostty-vt C library

The Mac app never linked the C library, but every build compiled it. The
`ghostty-vt` Zig module stays, because esctest and the fuzzer import it.
Build options removed: `-Demit-lib-vt`, `-Dlib-version-string`,
`-Dvt-features`, along with the lib-vt dist tarball and iOS target support.
Dependency builds still skip the app, xcframework, and docs.

- `.github/scripts/check-apple-libghostty-vt.nu`
- `CMakeLists.txt`, `Doxyfile`, `DoxygenLayout.xml`
- `dist/cmake/`, `dist/doxygen/`
- `example/`
- `include/ghostty/`
- `nix/libghostty-vt.nix`, `nix/test-src/`
- `src/build/GhosttyLibVt.zig`, `src/build/libghostty-vt.pc.in`,
  `src/build/wasm_patch_growable_table.zig`, `src/build/docker/lib-c-docs/`
- `src/lib/TinyIo.zig`, `src/lib/allocator.zig`, `src/lib/allocator/`,
  `src/lib/c_abi.zig`, `src/lib/tinyio/`, `src/lib/windows_dll.zig`
- `src/terminal/c/`
- `test/wasm-alloc.mjs`

### Windows and WebAssembly

Nubb only targets macOS.

- `dist/windows/`, `test/windows/`
- `src/apprt/browser.zig`, `src/main_wasm.zig`
- `src/config/Wasm.zig`, `src/datastruct/wasm_page_pool.zig`
- `src/font/face/web_canvas.zig`, `src/font/shaper/web_canvas.zig`
- `src/os/wasm.zig`, `src/os/wasm/`, `src/os/windows.zig`
- `src/terminal/kitty/windows.zig`

### Android NDK

Only Android targets used it, to find the NDK's libc and C++ headers for
highway and simdutf.

- `pkg/android-ndk/`

### Linux GTK app

Nubb only ships the Mac app. Config options removed: all `gtk-*` options,
`linux-cgroup`, `linux-cgroup-hard-fail`, `linux-cgroup-memory-limit`,
`linux-cgroup-processes-limit`, `x11-instance-name`, `app-notifications`,
`async-backend`, `quit-after-last-window-closed-delay`, `window-show-tab-bar`,
`window-subtitle`, `window-titlebar-background`, `window-titlebar-foreground`,
`quick-terminal-keyboard-interactivity`.

- `.github/workflows/flatpak.yml`, `.github/workflows/snap.yml`
- `dist/linux/`, `flatpak/`, `snap/`
- `images/gnome/`, `images/icons/`
- `nix/build-support/check-blueprints.sh`, `nix/package.nix`, `nix/tests.nix`,
  `nix/vm/`
- `pkg/gtk4-layer-shell/`
- `src/apprt/gtk.zig`, `src/apprt/gtk/`
- `src/build/docker/debian/`, `src/build/gtk.zig`
- `src/os/cgroup.zig`, `src/os/dbus.zig`, `src/os/flatpak.zig`,
  `src/os/kernel_info.zig`, `src/os/systemd.zig`

### OpenGL renderer

Nubb always renders with Metal.

- `Makefile`
- `pkg/opengl/`, `vendor/glad/`
- `src/renderer/Dmabuf.zig`, `src/renderer/OpenGL.zig`, `src/renderer/opengl/`,
  `src/renderer/shaders/glsl/`

### FreeType, HarfBuzz, and fontconfig font backends

Nubb always uses CoreText. Config option removed: `freetype-load-flags`.

- `pkg/fontconfig/`, `pkg/harfbuzz/`, `pkg/libxml2/`
- `src/font/face/freetype.zig`
- `src/font/shaper/harfbuzz.zig`, `src/font/shaper/noop.zig`
- `src/font/res/NotoColorEmoji.ttf`
- `src/stb/`

### Nix flake and dev shell

CI uses plain GitHub-hosted runners, and nothing builds Nubb with Nix.

- `.envrc`, `default.nix`, `shell.nix`, `flake.nix`, `flake.lock`
- `build.zig.zon.json`, `build.zig.zon.nix`, `build.zig.zon.txt`
- `nix/build-support/build-inputs.nix`, `nix/build-support/check-zig-cache.sh`,
  `nix/build-support/fetch-zig-cache.sh`,
  `nix/build-support/gi-typelib-path.nix`,
  `nix/build-support/ld-library-path.nix`, `nix/build-support/update-mirror.nu`
- `nix/devShell.nix`, `nix/patches/`, `nix/pkgs/`, `nix/zigCacheHash.nix`

### Valgrind

Valgrind does not run on macOS.

- `valgrind.supp`

### Upstream CI and repo automation

These workflows needed upstream's runners and secrets, or managed
ghostty-org's issues and contributors. Nubb has one workflow,
`.github/workflows/test.yml`.

- `.github/DISCUSSION_TEMPLATE/`, `.github/VOUCHED.td`,
  `.github/issue-unvouched-message`
- `.github/scripts/check-translations.sh`, `.github/scripts/ghostty-tip`
- `.github/workflows/clean-artifacts.yml`, `.github/workflows/milestone.yml`,
  `.github/workflows/nix.yml`, `.github/workflows/update-colorschemes.yml`
- `.github/workflows/vouch-check-issue.yml`,
  `.github/workflows/vouch-check-pr.yml`,
  `.github/workflows/vouch-manage-by-discussion.yml`,
  `.github/workflows/vouch-manage-by-issue.yml`,
  `.github/workflows/vouch-sync-codeowners.yml`

### Upstream contributor and packaging docs

These describe ghostty-org's process and distro packaging.

- `.mailmap`, `AI_POLICY.md`, `CODEOWNERS`, `CONTRIBUTING.md`, `HACKING.md`,
  `PACKAGING.md`

### Vim and Sublime syntax files

The build generated editor plugins for the config file and bundled them in
the app.

- `src/extra/sublime.zig`, `src/extra/vim.zig`

### Unused files

Nothing in the build, CI, or tests read these.

- `.gitmodules`, `passthrough.glsl`
- `src/font/res/JetBrainsMonoNerdFont-Bold.ttf`,
  `src/font/res/JetBrainsMonoNerdFont-BoldItalic.ttf`,
  `src/font/res/JetBrainsMonoNerdFont-Italic.ttf`, `src/font/res/Lilex-VF.ttf`
- `test/README.md`, `test/ucs-detect.sh` (ucs-detect needs a live terminal
  window, so it cannot run headless)

## macOS app

### Sparkle auto-updates

Nubb has no update feed and updates by rebuilding. This removed the Sparkle
Swift package and the update UI. Config options removed: `auto-update`,
`auto-update-channel`.

- `.github/workflows/publish-tag.yml`, `.github/workflows/release-tag.yml`,
  `.github/workflows/release-tip.yml`
- `dist/macos/`
- `macos/Ghostty.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/`
- `macos/Sources/Features/Update/`, `macos/Tests/Update/`

### Custom About window

Replaced by the standard AppKit About panel, which shows the name, version,
and icon from Info.plist.

- `macos/Sources/Features/About/`

### Settings view

Only its own preview used it.

- `macos/Sources/Features/Settings/SettingsView.swift`

### Finder services

"New Ghostty Tab/Window Here" in Finder's Services menu.

- `macos/Sources/Features/Services/`

### Make Default Terminal and Help menu items

The Help item opened ghostty.org. The Help menu stays so macOS still adds
menu search. No files were deleted. The items were removed from the menu and
AppDelegate.

### Global keybinds

`global:` keybinds used a CGEventTap and Accessibility permission to fire
while the app is in the background.

- `macos/Sources/Features/Global Keybinds/`

### AppleScript

Scripting of windows, tabs, and terminals through Apple Events. Config option
removed: `macos-applescript`.

- `macos/Ghostty.sdef`
- `macos/Sources/Features/AppleScript/`
- `macos/Tests/Features/`

### App Intents (Shortcuts)

Shortcuts and Spotlight actions to create terminals and send text or keys.
Config option removed: `macos-shortcuts`.

- `macos/Sources/Features/App Intents/`
- `macos/Sources/Helpers/PermissionRequest.swift`
- `macos/Tests/Ghostty/KeyEventSynthesizeTests.swift`

### Custom app icons and the dock tile plugin

Alternate Dock icons and the DockTilePlugin target. Config options removed:
`macos-icon`, `macos-icon-frame`, `macos-icon-ghost-color`,
`macos-icon-screen-color`, `macos-custom-icon`.

- `macos/Assets.xcassets/Alternate Icons/`,
  `macos/Assets.xcassets/Custom Icon/`
- `macos/Sources/Features/Custom App Icon/`
- `macos/Tests/ColorizedGhosttyIconTests.swift`

### Pre-Tahoe titlebar tabs window

The hand-built tab bar for `macos-titlebar-style = tabs` on macOS 13 to 15.
Nubb targets macOS 26, which uses the native implementation. On older macOS,
`tabs` falls back to the transparent titlebar.

- `macos/Sources/Features/Terminal/Window Styles/TerminalTabsTitlebarVentura.xib`
- `macos/Sources/Features/Terminal/Window Styles/TitlebarTabsVenturaTerminalWindow.swift`

### Quick Terminal

A drop-down terminal window toggled from the menu or a keybind. It was meant
for global keybinds, which were removed earlier. Config options removed:
`quick-terminal-position`, `quick-terminal-size`, `quick-terminal-screen`,
`quick-terminal-animation-duration`, `quick-terminal-autohide`,
`quick-terminal-space-behavior`. Keybind action removed:
`toggle_quick_terminal`. CLI action removed: `+toggle-quick-terminal`.

- `macos/Sources/Features/QuickTerminal/`
- `macos/Tests/QuickTerminalScreenStateCacheTests.swift`
- `src/cli/toggle_quick_terminal.zig`

## Terminal and core

### Translations and gettext

Nubb is English-only, and nothing called the translated strings.

- `pkg/libintl/`, `po/`
- `src/build/GhosttyI18n.zig`
- `src/os/i18n.zig`, `src/os/i18n_locales.zig`

### Sentry crash capture

Sentry and Breakpad wrote local minidumps for `+crash-report`. macOS already
records app crashes in its own crash reports. CLI action removed:
`+crash-report`.

- `pkg/breakpad/`, `pkg/sentry/`
- `src/cli/crash_report.zig`
- `src/crash/`

### tmux control mode

The `tmux -CC` parser ran, but no UI ever showed its windows or panes.

- `src/terminal/tmux.zig`, `src/terminal/tmux/`

### APC glyph protocol

Glyphs registered over APC were stored but never drawn.

- `src/font/glyf_rasterize.zig`, `src/font/glyf_rasterize_png_test.zig`
- `src/font/opentype/glyf.zig`
- `src/font/testdata/`
- `src/terminal/apc/`

### Terminal snapshot format

Only the removed C library used it. This also removed the CRC32C code and the
Kaitai format spec.

- `src/benchmark/TerminalSnapshot.zig`
- `src/crc32c.zig`
- `src/terminal/snapshot/`

### Elvish and Nushell shell integrations

Nubb keeps the bash, fish, and zsh integrations.

- `src/shell-integration/elvish/`, `src/shell-integration/nushell/`

### `+boo` animation

A full-screen playback of the ghost animation from the Ghostty website. The
235 text frames were compressed with zlib at build time and embedded in the
binary. This was the only dist resource, so the dist tarball no longer
injects generated files. CLI action removed: `+boo`.

- `src/build/GhosttyFrameData.zig`
- `src/build/framegen/`
- `src/cli/boo.zig`

### Light and tinted themes

Ghostty downloaded 771 themes from iTerm2-Color-Schemes at build time. Nubb
now keeps the 219 with a black or gray background in
`vendor/iterm2-color-schemes/` and drops the download. The other 552 are the
light themes and the dark ones with a visibly tinted background (blue,
purple, red, brown, green, or teal). A first pass kept dark blue backgrounds,
and a second pass dropped those too. They were never in this repo, so
restore one by copying it from
<https://github.com/mbadolato/iTerm2-Color-Schemes/tree/master/ghostty> into
`~/.config/nubb/themes/`.

- the `iterm2_themes` dependency in `build.zig.zon`
