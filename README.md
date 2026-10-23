<!-- LOGO -->
<h1>
<p align="center">
  <img src="https://github.com/user-attachments/assets/fe853809-ba8b-400b-83ab-a9a0da25be8a" alt="Logo" width="128">
  <br>Nubb
</h1>
  <p align="center">
    A personal terminal for running AI coding agents, built on Ghostty.
  </p>
</p>

## About Nubb

Nubb is a hard fork of [Ghostty](https://github.com/ghostty-org/ghostty) by
Mitchell Hashimoto and the Ghostty contributors, used under the MIT license.
It does not track Ghostty's repo and has no update feed. To update, pull this
repo and rebuild:

```sh
zig build -Doptimize=ReleaseFast -Dxcframework-target=native
open zig-out/Nubb.app
```

For everything about the terminal itself, see
[Ghostty's README](https://github.com/ghostty-org/ghostty#readme).
[REMOVED.md](REMOVED.md) lists every Ghostty feature and file Nubb removed,
and how to get each one back.
