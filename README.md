# Docklet

Docklet is a lightweight macOS notch widget that keeps useful tools close at hand.

It includes music controls, a temporary file shelf, weather, quick voice notes,
clipboard history, and system stats. It works on Macs with or without a notch.
**Settings…** and **Replay Onboarding…** live on the menu-bar icon.

## Requirements

- macOS 13 or later
- Swift 5.9 or later and Xcode command-line tools (Xcode 15+; for source builds)

## Install

Download the latest `Docklet-<version>-macOS.zip` from
[Releases](https://github.com/rpatra29/docklet/releases), unzip it, and move
`Docklet.app` to `/Applications`.

Because Docklet is ad-hoc signed, macOS may block the first launch. Control-click
the app and choose **Open**, or allow it from **System Settings → Privacy & Security**.

## Build from source

```bash
git clone https://github.com/rpatra29/docklet.git
cd docklet
swift run Docklet
```

Docklet may request access to your location, microphone, clipboard, and music apps
when you use the related features.

To build a local app bundle instead of running from the checkout:

```bash
./Scripts/package.sh 1.0.0
open dist/Docklet.app
```

That script produces a universal (Apple silicon and Intel) `dist/Docklet.app`,
ad-hoc signs it, and writes a zip plus a SHA-256 checksum beside it.
`BUILD_NUMBER` (digits only, default `1`) is written to `CFBundleVersion`.
`OUTPUT_DIR` (default `dist/` in the repo root) chooses where the app, zip, and checksum are written.

## Publish a release

GitHub Actions builds pull requests and pushes to `main`. Pushing a version tag
also publishes a GitHub Release of the packaged app:

```bash
git tag v1.0.0
git push origin v1.0.0
```

The tag must start with `v` followed by a version such as `1.0.0` or `1.0.0-beta.1`.
