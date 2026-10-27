# medh5 Viewer User Guide

*A stub of the guide, to exercise the Help window; the full guide replaces
it.*

medh5 Viewer opens a `.medh5` sample — one subject, at every timepoint, with
all of its ground truth — and shows everything in it. Start with
[Getting started](#getting-started); the keys are in
[Keyboard basics](#keyboard-basics).

![The document window: the sidebar, four views and the inspector](images/viewer.png)

## Getting started

1. Choose **Help ▸ Open Demo Sample**: a synthetic two-visit phantom with
   every kind of annotation.
2. Double-click an image in the sidebar to make it the *base* image of the
   views.
3. Use the eye button to show segmentations, boxes and meshes over it.
   - An overlay in another frame is placed through the stored transform.
   - Without one it is not drawn: alignment is never assumed.

To check a file the way the engine does, choose **Tools ▸ Validate…**
(`⇧⌘V`). It runs the same validator as the command line:

```sh
medh5 validate sample.medh5 --level integrity
```

## Keyboard basics

| Keys | Does |
|:-----|:-----|
| `1`–`5` | layouts: single, 1 × 3, 2 × 2, 3-D, compare |
| `V`, `W`, `H`, `Z` | navigate, window/level, pan, zoom |
| `⌘]` / `⌘[` | next / previous timepoint |
| `⇧⌘V` | validate the saved file |

Every shortcut is in **Help ▸ Keyboard Shortcuts**. The format itself is
documented at <https://medh5.readthedocs.io/>.
