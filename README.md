# FoldForm

FoldForm is a native SwiftUI + RealityKit iPhone Duo engineering prototype with an Onshape-inspired
Part Studio workbench. The device hinge (or the simulator fallback slider) bends an editable
procedural Part Studio around a real local mesh seam at the crease, while sheet-metal values,
collision state, feature history, and haptic fallbacks update live.

## Run it

1. Open `FoldForm.xcodeproj` in Xcode 27.1 beta.
2. Select the `FoldForm` scheme and an iPhone Duo simulator.
3. Choose a development team under the app target's Signing & Capabilities if Xcode asks for one.
4. Build and run. On the simulator, drag `Simulator angle` to drive the hinge.

The app is intentionally offline: there is no login, backend, package dependency, LiDAR, or panel
IMU requirement. If the beta hinge API or Core Haptics is unavailable, the simulator slider and
visual state transitions remain usable.

## Demo path

Start at 0°, open `Model`, use `Sketch` to draw a profile, then use `Extrude` and `Hole`. Switch to
`Sheet Metal`, fold toward the red obstacle, and continue to the demo bend limit. The gold line is
the crease mapped into the model. `Inspect` shows the active document and regeneration state.

The gold line and the part share one stable local coordinate system; arrangement resizing cannot
recenter the part or leave the crease behind. The deformer splits triangles that cross `x = 0`
before applying the bend, so the fold is attached to the geometry rather than being a split-screen
animation.

The procedural kernel deliberately reports unsupported advanced operations in the feature tree
instead of silently pretending they succeeded. The sheet-metal calculator is an educational demo
model; confirm tooling and material data before fabrication.
