# Installing

1. Download `medh5-Viewer-<version>-macOS-arm64.dmg` from the
   [releases](../../releases) page.
2. Open it and drag **medh5 Viewer** to **Applications**.
3. Open it from Applications.

medh5 Viewer needs a Mac with Apple silicon and macOS 14 (Sonoma) or later.

## "Apple could not verify…"

A release that is not notarized by Apple (one built without a Developer ID)
is stopped by Gatekeeper the first time it opens. Either:

- in Finder, Control-click the app, choose **Open**, then **Open** again;
  or open **System Settings › Privacy & Security** and click **Open Anyway**;
- or, in Terminal:

  ```bash
  xattr -dr com.apple.quarantine "/Applications/medh5 Viewer.app"
  ```

## Building it yourself

See [BUILDING.md](BUILDING.md).
