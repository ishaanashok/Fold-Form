# Features

## Live hinge folding

- The hinge angle drives the bend. Raw hinge angle 180 degrees is flat; the bend is `180 - angle`,
  clamped from 0 to 180 degrees. There is no smoothing, so the model tracks the hinge directly.
- The fold happens at the on-screen crease (read from the display's `.division` region), whichever
  way the model is turned. The crease plane passes through the camera, so the fold always looks
  centred on the crease. Both halves swing toward the viewer.
- **Rounded corner (default):** a smooth cylindrical fillet. The inner radius is half the part's
  thickness at the crease. Nothing ever moves deeper than it started, so nothing pokes out the back.
- **Sharp corner:** double-tap the model to switch. The fold becomes a mitred corner (watertight,
  exact angle). A yellow `SHARP` tag shows in the readout. Double-tap again to go back.
- The readout (bottom-right) shows the angle and a status: `READY`, `BENDING`, `HELD`, `LIMIT` or
  `DEBUG` (only in debug launches).

## Hold, undo and reset folds

- **Hold** (lock icon) bakes the current fold and keeps it while you open the phone back up. It lets
  go only once the hinge is flat again. The next fold then builds on the held shape, so folds stack.
- **Undo last held fold** and **Reset all folds** appear once at least one fold is held.

## Free 3D viewing

- Unlimited rotation: keep spinning in 360 degrees with no limit, upside down included.
- The model turns about its **centre of mass** (volume-weighted, folds included), not about the
  crease. A fold changes the centre of mass, and the pivot follows it.
- Pinch to zoom (smooth and eased, with a small dead zone so a resting pinch does nothing), two
  fingers to pan.
- **View cube** (top-right): tap a face to snap to that view exactly. Its labels always describe the
  original block faces, and they don't get scrambled by folds.
- **Cube arrows:** four arrows turn the model a quarter turn up, down, left or right; two curved
  arrows roll it in place, like the arrows on Onshape's cube.

## Sketch, extrude and remove

1. Tap the pencil. The sketch plane is the front-most surface of the model facing you, drawn with a
   faint grid.
2. Pick **Line**, **Rectangle** or **Circle** and drag. A circle is click-and-drag for any radius.
   Lines snap to each other's end points, and a closed loop of lines becomes a fillable shape. Undo
   removes the last shape.
3. Tap **Extrude** to push the closed shapes out toward you, or **Remove** to cut them down into the
   surface. A slider on the right sets the depth: up is deeper, down is shallower. You can still
   rotate, pan and zoom while it is active.
4. Confirm (tick) to finish. The app leaves sketch mode immediately so you can rotate and fold as
   normal. Cancel to back out.

Extruded shapes become separate parts that fold together with the plate. **Remove** subtracts the
shape from every part it touches (a boolean cut done on the mesh); note that a cut resets any held
folds, because the part's shape changed.

## Working with parts

- Tap a part to select it (it highlights when there is more than one).
- Press and hold a part for **Duplicate**, **Copy** and **Delete**. Press and hold empty space to
  **Paste**. The base plate can't be deleted.
- **Undo** (circular arrow in the left column) takes back the last extrude, cut, duplicate, paste or
  delete. **Reset everything** (red round arrow) returns to the very first flat plate with every part,
  fold and sketch cleared.

## Reference planes and origin

Like a Part Studio, the scene has three translucent planes through the origin (Right/Left, Up/Down
and Front/Back) and a dot at the origin. They take the colour of the background, so they stay faint:
dark grey on the dark theme and light grey on the light one.

## Dimensions

- The **Show dimensions** toggle puts measurements on the model. On parts, each shows its length, width
  and thickness along the box edge nearest to you, labelled at the midpoint. On sketches, a line shows
  its length, a rectangle both sides and a circle its diameter, updated live as you drag. While
  extruding or removing, the depth is measured too.
- Choose the unit under the toggle: millimetres, centimetres (default), metres or inches.

## View options (waffle menu)

The grid button in the top-left opens toggles for: **Hide planes**, **Right/Left plane**, **Up/Down
plane**, **Front/Back plane**, **Hide origin**, **Show dimensions** (with the unit picker) and **Dark
mode**. Settings are remembered between launches.

## Themes

Dark mode (default) and light mode. The background, buttons, view cube, sketch grid and reference
planes all follow the choice.

## Export and share

The share button (under the view cube) exports the whole model as one file, then opens the system
share sheet (AirDrop, Save to Files, other apps):

| Format | Notes |
| --- | --- |
| STL | Binary, millimetres, Z-up (for slicers and printing) |
| 3MF | Zipped 3MF package, millimetres |
| GLB | Binary glTF, metres, Y-up, blue material |
| OBJ | Plain-text Wavefront |

All parts are merged into a single model (no separate colours, except GLB's blue material).

## Known limits

- Part bodies can't be moved individually after they are created.
- The sketch plane is fixed when sketching starts.
- Very deep blocks folded sharply and viewed from the front look large. That is geometrically
  correct: the arms swing toward you.
- Dimensions show sizes only; they can't be typed in to resize a shape.
- The legacy tools/feature-tree panel (`ControlPanelView`) is still in the source but no longer opened
  from the UI.
