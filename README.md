# Docklet

Docklet is a lightweight macOS notch widget for music controls, a temporary file shelf,
weather, quick voice notes, and clipboard history.

## Requirements

- macOS 13 or later
- A Mac with or without a display notch
- Xcode command-line tools for source builds

## Install a GitHub release

Docklet releases are ad-hoc signed because the project does not currently use a paid Apple
Developer account. The app is built from this repository by GitHub Actions, but macOS cannot
verify a named developer or Apple notarization ticket for it.

1. Download `Docklet-<version>-macOS.zip` from the repository's Releases page.
2. Optionally compare its SHA-256 digest with the accompanying `.sha256` file.
3. Unzip it and move `Docklet.app` into `/Applications`.
4. Control-click Docklet and choose **Open**. If macOS still blocks it, open **System
   Settings → Privacy & Security** and choose **Open Anyway** for Docklet.

Location, microphone, and Music/Spotify automation prompts are expected when their features
are first used. An ad-hoc signature can cause macOS to ask for permissions again after an app
update.

## Build from source

Run directly from a checkout:

```bash
swift run Docklet
```

Create a local app bundle and release archive:

```bash
./Scripts/package.sh 1.0.0
open dist/Docklet.app
```

The script builds a universal Apple-silicon/Intel executable, constructs `dist/Docklet.app`,
ad-hoc signs it, verifies the signature, and creates a ZIP plus a SHA-256 checksum.

## GitHub releases

The GitHub Actions workflow builds every pull request and push to `main`. Push a version tag
to build the app and publish a GitHub Release automatically:

```bash
git tag v1.0.0
git push origin v1.0.0
```

Release tags must begin with `v` and contain a package-compatible version such as `v1.0.0`.
