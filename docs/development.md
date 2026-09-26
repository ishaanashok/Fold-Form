# Building and testing

## Requirements

- Xcode 27.1 with the iOS 27.1 SDK, iPhone Duo simulator (or device)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): the Xcode project is generated from
  `project.yml`. After adding or removing source files run:

```bash
/opt/homebrew/bin/xcodegen generate
```

## Run

Open this folder in Bitrig, pick the **iPhone Duo** simulator, and build the `FoldForm` scheme. The
project uses Swift 6 language mode.

## Tests

Unit tests (fast, no UI):

```bash
xcodebuild -project FoldForm.xcodeproj -scheme FoldForm \
  -destination 'platform=iOS Simulator,name=iPhone Duo' test -only-testing:FoldFormTests
python3 scripts/check_credentials.py
```

They cover the bend maths (fillet and sharp), camera rig and hinge convention, fold sessions,
sketching, export formats, reset/undo, reference scene toggles, dimensions, the boolean cut,
voice command safety, model-file hash verification, Imagine plan validation and atomic rollback.
The source-credential test runs on the host because a simulator test cannot inspect the checkout.
No unit test uses the network or microphone.

UI tests (`FoldFormUITests`) drive rotation, pinch, taps, the sketch flow, the view cube and more.
They relaunch the app repeatedly with debug flags and are outside the unit-test gate. Run them
only when intentionally testing the live simulator UI.

## Debug switches

Debug launches ignore the real hinge and show `DEBUG` in the readout:

- launch arguments `-FoldFormDebugBendDegrees`, `-FoldFormDebugYawDegrees`,
  `-FoldFormDebugPitchDegrees`, `-FoldFormDebugTargetX`
- or the file `/tmp/foldform_debug_bend.txt`

Always relaunch the app normally afterwards so it follows the hinge again.
