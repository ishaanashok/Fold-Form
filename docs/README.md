# FoldForm documentation

FoldForm is a native SwiftUI + RealityKit app for the iPhone Duo. One matte-blue block fills the whole
screen, and the physical hinge folds it: open the phone flat and the block is flat, close it and the
block bends 1:1 along the crease you see on screen. On top of that sit a small sketch, extrude and
cut workbench, dimensions, reference planes, a view cube and model export.

| Page | What it covers |
| --- | --- |
| [Features](features.md) | Everything the app can do, feature by feature |
| [Controls](controls.md) | Every button, gesture and menu, and what it does |
| [How it works](architecture.md) | The bend maths, camera, part model and code layout |
| [Building and testing](development.md) | Requirements, project setup, tests, debug switches |

## The idea in one paragraph

The iPhone Duo's crease is not only where content avoids the screen. It is a physical input. FoldForm
reads the hinge angle (`onHingeChange`) and the crease position (the `.division` reserved region) and
bends a 3D part exactly there. The bend is not a preset animation: fold the phone 40 degrees and the
part folds 40 degrees.

## Quick start

1. Build and run the `FoldForm` scheme on the **iPhone Duo** simulator (or device).
2. Fold the phone. The angle readout in the bottom-right corner follows the hinge and the block bends.
3. Drag to rotate, pinch to zoom, two fingers to pan. Tap a face of the view cube to snap to that side.
4. Tap the pencil to sketch on the block, extrude or remove material, and export the result with the
   share button.
