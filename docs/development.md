# Building and testing

## Requirements

- Xcode 27.1 with the iOS 27.1 SDK, iPhone Duo simulator (or device)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): the Xcode project is generated from
  `project.yml`. After adding or removing source files run:

```bash
xcodegen generate
```

## Run

Open `FoldForm.xcodeproj`, pick the **iPhone Duo** simulator, and run the `FoldForm` scheme. The
project uses Swift 6 language mode.

## Tests

Unit tests (fast, no UI):

```bash
xcodebuild -project FoldForm.xcodeproj -scheme FoldForm \
  -destination 'platform=iOS Simulator,name=iPhone Duo' test -only-testing:FoldFormTests
```

They cover the bend maths (fillet and sharp), camera rig and hinge convention, fold sessions,
sketching, export formats, reset/undo, reference scene toggles, dimensions and the boolean cut.

UI tests (`FoldFormUITests`) drive rotation, pinch, taps, the sketch flow, the view cube and more.
They relaunch the app repeatedly with debug flags, so run them on their own, not while you are
checking the simulator by hand.

## Debug switches

Debug launches ignore the real hinge and show `DEBUG` in the readout:

- launch arguments `-FoldFormDebugBendDegrees`, `-FoldFormDebugYawDegrees`,
  `-FoldFormDebugPitchDegrees`, `-FoldFormDebugTargetX`
- or the file `/tmp/foldform_debug_bend.txt`

Always relaunch the app normally afterwards so it follows the hinge again.
