# FoldForm

FoldForm is a SwiftUI + RealityKit CAD workbench for iPhone Duo. The device hinge bends an editable
design at the screen crease. You can sketch, extrude, cut, round, duplicate, export, and edit parts
by touch, voice, or Imagine.

## Run it

Open the folder in Bitrig and build the `FoldForm` scheme for iPhone Duo. The Xcode project is
generated from `project.yml`; after adding or removing source files, run
`/opt/homebrew/bin/xcodegen generate`. Run the unit tests without operating the live simulator UI:

```sh
xcodebuild test -project FoldForm.xcodeproj -scheme FoldForm \
  -destination 'platform=iOS Simulator,name=iPhone Duo' \
  -only-testing:FoldFormTests
python3 scripts/check_credentials.py
```

Voice uses Apple's on-device speech recognizer and system language model, with local rules for
supported commands and when the language model is unavailable. Audio stays on the device; no
separate speech or interpreter weights are downloaded. For this demo, Imagine uses local scripted
plans and sends no design request over the network. Generate builds a table, a chair for a prompt
containing “chair”, or a lamp on the table after the table has been made.

## Demo path

Start a new design. The light canvas shows three open reference grids; the view-options tool in the
left dropdown can switch to dark mode or hide the grids. Open the left dropdown, tap Imagine
(sparkles), enter **create a table**, and tap Generate. After the planning animation, a table appears.
Open Imagine again, enter **add a lamp on the table**, and tap Generate; a lamp appears on its top.
A prompt containing **chair** creates a chair instead. Each generation is one undo step. These demo
requests stay on the device and need no API key or subscription.

For the CAD controls, draw a profile with Sketch and extrude it, or select a model edge and fold the
Duo to preview a fillet. The crease and the parts share one local coordinate system, so resizing the
interface does not recenter the part or leave the crease behind.

See [features](docs/features.md), [controls](docs/controls.md), [architecture](docs/architecture.md),
and [development notes](docs/development.md) for more detail.

The procedural kernel deliberately reports unsupported advanced operations in the feature tree
instead of silently pretending they succeeded. The sheet-metal calculator is an educational demo
model; confirm tooling and material data before fabrication.
