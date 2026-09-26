# Features

## Dashboard and saved designs

The app opens on a dashboard of every design you have made. Designs save automatically (a moment
after each change, when you leave the app, and when you go back to the dashboard) and reopen exactly
as you left them: every part with its held folds, its colour, the corner style and the camera view.
Undo history is not saved, so it starts fresh each time you open a design.

- **Cards** show a live thumbnail, the name, when it was last edited and how many parts it has.
- **New design** offers a template: flat plate, box, cylinder, beam or I-beam.
- **Manage:** rename, duplicate, favourite (star), move to a folder, delete. Delete asks first and
  then offers Undo for a few seconds.
- **Find:** search by name, sort by last edited, name or date created, and filter by All, Favourites,
  Shared or a folder.
- **Stats** at the top: designs, parts, favourites and designs edited this week.
- A design that cannot be read shows as "Couldn't open" and its files are kept until you delete it.

A reopened design is a flat list of bodies ("Body 1", "Body 2", ...). The feature history and sketches
that made them are not kept, matching how viewport work is already stored.

## Version history

Long-press a design and choose **Version history**. Save a named version (with an optional note) at
any time. A checkpoint is also saved automatically when you leave a design you changed. Restore any
version: the current state is saved as a version first, so a restore can itself be undone. Up to 20
automatic versions are kept (oldest removed first); named versions are never removed automatically.

## Collaboration preview (no server)

**Share** on a design opens a preview of sharing: invite people by email, set them to view or edit,
and see an activity feed and presence avatars in the editor. There is **no backend**: invitations are
only stored on this device, nothing is sent and nobody else sees your design. Every collaboration
screen says "Preview: not connected to a server", and made-up activity is marked "Sample".

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
- **Angle snapping:** within 1 degree of 0, 45, 90, 135 or 180 degrees of bend (so a hinge reading
  from 89 to 91 degrees), the fold locks to exactly that angle. Outside the window it tracks 1:1.
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
- **Undo** (circular arrow in the left column) takes back the last action of any kind: extrude, cut,
  duplicate, paste, delete, hold, fold undo or reset, the sharp/rounded corner switch, and even
  Reset everything. While sketching it first removes the shape being drawn. **Reset everything** (red round arrow) returns to the very first flat plate with every part,
  fold and sketch cleared.

## Touch up

The wand button in the left column cleans up what you made and works out what you meant.

- **While sketching** it works on closed outlines of lines. Odd bumps and wobbles are removed, then
  the outline is read with triangle geometry: the law of cosines for the angles, the angle-sum theorem,
  Pythagoras' converse (right triangle), equal sides (equilateral, isosceles), all four angles near 90
  degrees (rectangle, square), equal sides and angles (regular polygon) and equal radius (circle). The
  outline snaps to the exact shape.
- **Otherwise** it works on every body, in two ways:
  - **Extruded outlines:** a body that is a straight extrusion (a slab, a cylinder, a plate with a
    through-hole) has its outline and holes read exactly like a sketch: bumps out, corners snapped to a
    rectangle, triangle, circle and so on, then the solid is rebuilt from the clean outline.
  - **Any mesh** (including bodies with cuts): a vertex sticking out of a flat patch, or a gentle bump or
    dent across several vertices, is pulled back onto the surface. Needle-thin triangles (the kind cuts
    leave behind, which bend badly) are re-meshed by flipping edges without moving the surface, tiny edges
    are merged, and zero-area triangles are removed.
- **Whole designs (any kind):** when there are two or more bodies, they are read together as blocks in
  world axes. Nothing is specific to tables: it applies to a chair, bookcase, robot, bracket or anything
  else with parts that repeat, mirror or line up. Boxes and cylinders (extrusions of a rectangle or circle)
  are adjusted; other shapes stay as they are and act as things to line up with.
  - **Matching:** parts meant to be the same become identical, using the median size. A face resting on
    a neighbour stays where it is and the free end changes.
  - **Symmetry:** about the middle of the whole design, along each axis where at least 60% of the parts
    take part. A part on the centre line (within 8%) is centred; others are paired with their nearest
    mirror image and share one distance from the centre.
  - **Even spacing:** three or more matching parts standing in a row.
  - **Flush edges:** an edge within 4% of the design's size of a bigger neighbour's edge snaps to it (the
    whole part moves, so its size is kept). Bigger parts never snap to smaller ones, and a part already
    lined up or centred is left alone.
  - **Colours and finish:** each group gets a palette colour, thin flat parts get rounded corners (never
    so round that a part resting in a corner is cut), and four identical posts standing on a slab, with
    nothing else on that side, get four rails just under the slab. A part that already has a colour keeps
    it, so finishing twice never repaints.
- **Holes:** a plate with two or more circular holes gets identical holes, mirrored about its centre.
- **Design intent (the model):** the parts are described to the on-device model in millimetres with a
  short guide to how well-made designs look (principles first, examples such as furniture, a bookcase, a
  bracket or a robot second). It answers with what is being built, in its own words, and for each group
  of parts which are meant to be identical, symmetric, flush, evenly spaced, given rounded corners and
  which colour. Geometry checks the answer (real parts only, each in one group, an identical group within
  3x in every dimension, colours from the palette) and carries it out. If the model is unavailable, too
  slow or wrong, the built-in rules make the plan: similar parts are grouped by size and shape, with a
  neutral wood, steel and grey scheme. It never edits geometry directly.
- **Local AI:** where Apple's on-device model is available it picks between the readings the geometry
  produced for an outline (or says none fits), and plans the assembly as above. It does not gate the
  mesh repair. It never invents geometry. Without it, the best geometric fit is used.
- If there are no bumps and it cannot tell what was being made, the banner says "Wasn't able to figure
  out what was being created."
- Undo takes a touch up back. On bodies it resets held folds, like a cut.
- Limits: on a body that is not a plain extrusion (for example a pocket cut into a slab) the outline is not
  re-read, only bumps and slivers are repaired. On sketches only closed loops of lines are read
  (rectangles and circles are already exact). Results are flat-shaded, like every body in the app.

## Hands-free voice control

Tap the microphone in the left column to listen continuously. The caption shows words while they
are still changing; only a finished sentence can change the design. After a command, FoldForm shows
what it did and keeps listening until you stop it. One sentence is one undo step, even when it has
several actions. For example, say “Make a 3 centimeter cube,” “Move this 10 millimeters right,”
“Round these edges by 2 millimeters,” or “Undo that.”

Speech uses Apple's on-device dictation recognizer, with no model download. Known commands use
local rules; other phrasing can use Apple's on-device language model when the device supports it.
The rules remain available when that model cannot run. A finished creative request such as “Make a table” opens Imagine with those
words ready to review; Generate uses a local scripted plan in this demo. Other unrecognized speech asks for
clarification. A selected body
can be moved, resized, rotated, rounded, drilled, duplicated or deleted; the base plate cannot be
deleted. Rotated bodies cannot be resized by dimensions, chamfer is unavailable, and finishing a
sketch without extruding discards its shapes.

## Imagine

Tap the sparkles button in the left column to open Imagine. Draw a rough sketch or add a rectangle
guide, then type a description or dictate one. The prompt stays editable. For this demo, Generate
uses local scripted plans; no request is sent to a model service. A first table request creates a
table, a follow-up adds a lamp on it, and a prompt containing “chair” creates a chair.

Each plan contains at most 12 ordinary CAD edits. FoldForm checks the plan's operations,
dimensions, units, body references and document revision before applying it. A failed step rolls
the entire plan back. Existing bodies are referenced as `P0`, `P1`, and so on; newly made bodies
can be named and reused by later steps. Imagine adds to or edits the current design and preserves
unrelated bodies. New bodies get a temporary green highlight, and the sheet lists the plan's
assumptions. The result is one undo step. Cancelling or changing the design while Imagine is
planning prevents the stale reply from changing anything.

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

- Body edits are mesh-backed features; reopening a design gives a flat body list rather than the
  original per-step sketch history.
- The sketch plane is fixed when sketching starts.
- Very deep blocks folded sharply and viewed from the front look large. That is geometrically
  correct: the arms swing toward you.
- Dimensions shown on the model are read-only; use voice to resize a selected box or cylinder.
- The legacy tools/feature-tree panel (`ControlPanelView`) is still in the source but no longer opened
  from the UI.
