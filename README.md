# Docklet

Docklet is a lightweight macOS notch widget that keeps useful tools close at hand.

It includes music controls, a temporary file shelf, weather, quick voice notes,
clipboard history, and system stats. It works on Macs with or without a notch.

## Requirements

- macOS 13 or later
- Xcode command-line tools (for source builds)

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
