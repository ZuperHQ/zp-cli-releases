# zp releases

This repo holds the released builds of `zp`, the command-line tool for the Zuper Developer Platform.

It holds no source code. Each release has one archive per system and a `SHA256SUMS` file.

## Install

macOS and Linux:

```sh
curl -fsSL https://raw.githubusercontent.com/ZuperHQ/zp-cli-releases/main/install.sh | sh
```

Windows (PowerShell):

```powershell
irm https://raw.githubusercontent.com/ZuperHQ/zp-cli-releases/main/install.ps1 | iex
```

The script installs the newest release into `~/.zuper`. It uses no `sudo`.
To update, run the same command again. To install one version, add `-s -- --version X.Y.Z` after `sh`.

## Files of a release

| System | File |
|---|---|
| macOS, Apple chip | `zp-darwin-arm64.tar.gz` |
| macOS, Intel | `zp-darwin-x64.tar.gz` |
| Linux x64 | `zp-linux-x64.tar.gz` |
| Linux arm64 | `zp-linux-arm64.tar.gz` |
| Windows x64 | `zp-win32-x64.zip` |

Each archive includes Node.js, so you need nothing else installed.
