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

The first voice-control use downloads Moonshine speech and Needle interpreter weights, pinned to
SHA-256 hashes. Audio stays on the device. The rules-based interpreter works while Needle is
unavailable. Imagine is the explicit cloud path: enter a NVIDIA NIM key in its sheet, sketch or
describe a change, then tap **Generate** to send the sketch, text, and current design image to
GLM-5.3-Flash. The key is stored in Keychain.

## Demo path

Start a design from the dashboard, draw a profile with the pencil, then extrude it. Fold the Duo to
bend the result. Tap the microphone for hands-free CAD commands or the sparkles button to sketch a
concept in Imagine. The crease and the parts share one local coordinate system, so resizing the
interface does not recenter the part or leave the crease behind.

See [features](docs/features.md), [controls](docs/controls.md), [architecture](docs/architecture.md),
and [development notes](docs/development.md) for more detail.

The procedural kernel deliberately reports unsupported advanced operations in the feature tree
instead of silently pretending they succeeded. The sheet-metal calculator is an educational demo
model; confirm tooling and material data before fabrication.
