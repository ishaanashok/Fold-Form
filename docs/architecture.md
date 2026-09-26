# How it works

## Hinge and crease

`HingeInputManager` wraps `onHingeChange` and exposes the bend in radians (`bend = pi - rawAngle`,
clamped to 0...pi). The crease comes from `GeometryProxy.reservedRegions(kind: .division)`; if none is
reported, a centred vertical crease is used.

## Camera and folding (`CameraRig`, `BendDeformer`)

- `CameraRig` owns the view: target, yaw, pitch, roll (all unbounded), distance and a 60 degree field
  of view. It provides rays, projection, nearest-face detection, snapping and quarter-turn/roll steps.
- The fold is expressed in camera space: a `FoldFrame` (pivot, hinge axis, plane normal) so the fold
  sits on the screen crease from any viewpoint.
- `BendDeformer.deform` slices the mesh into strips (at most 3 degrees each, max 60) and bends it:
  - **fillet:** rigid arms plus a cylindrical zone; every point moves only toward the viewer.
  - **sharp:** a mitre map per arm with a blended corner; watertight and exact in angle.

## Parts and folds (`FoldSession`)

`FoldSession` holds every part's unfolded source mesh, the stack of held folds and whether the shape
is currently held. `displayedParts(bend:frame:corner:)` returns the meshes to draw. Adding, duplicating,
removing and resetting parts go through it. Only the plate and added parts exist in the session;
folds are applied to all of them together.

## Document (`AppModel`, `PartStudio`, features)

The Part Studio keeps an ordered feature tree. Viewport work is stored as features:
`ViewportSolidFeature` (an extruded solid) and `ViewportCutFeature` (a solid subtracted from every
body it overlaps). `AppModel` records a snapshot of the tree before each edit, which is what the Undo
button restores, and `resetDocumentToInitialPlate` clears everything.

## Sketching (`SketchController`, `SketchOverlay`)

Shapes live in the plane's 2D coordinates. Closed profiles come from rectangles, circles and loops of
snapped lines. `SketchGeometry.slab` extrudes toward the viewer; `SketchGeometry.cutter` reaches down
into the material (with a small lift above the surface so faces are never coplanar).

## Boolean cut (`MeshCSG`)

A BSP-tree subtraction on triangle meshes, sized for the simple cutters the sketch tools produce.

## Centre of mass (`MeshOps`)

`RenderMesh.solidProperties` sums signed tetrahedra for volume and centroid; the viewport combines
parts weighted by volume and orbits about that point.

## Dimensions (`Dimensions.swift`)

`DimensionBuilder` produces measured segments for sketch shapes, extrusion depth and part bounding
boxes. `DimensionOverlay` projects them through the camera and draws lines and labels;
`DimensionUnit` converts metres (the scene unit) to mm, cm, m or in.

## Reference planes (`ReferenceScene`)

Three thin translucent quads with outlines and an origin dot, added to the RealityKit scene and
recoloured for the current theme.

## Export (`ModelExporter`)

Writes STL, 3MF (own stored-ZIP writer with CRC32), GLB and OBJ from the merged displayed meshes,
with the unit and axis conventions in [features](features.md).

## Rendering

`RealityView` with an explicit `PerspectiveCamera` (no built-in camera controls). Each part is its own
`ModelEntity`. Rebuilds are throttled to about 20 per second and only happen when the bend, crease
frame, held state, corner style or scene revision changes. A single `UIPanGestureRecognizer` handles
rotate, pan and drawing; tap, double-tap, long-press and pinch recognizers sit beside it.

## Source map

| Area | Files |
| --- | --- |
| App shell and HUD | `FoldFormApp.swift`, `ViewCubeView.swift`, `ReferenceScene.swift` (also the view-options sheet) |
| Viewport | `RealityViewport.swift`, `ViewportGestureView.swift`, `CameraRig.swift` |
| Folding | `BendDeformer.swift`, `FoldSession.swift`, `HingeInputManager.swift` |
| Geometry | `GeometryBuilder.swift`, `GeometryKernel.swift`, `MeshOps.swift`, `MeshCSG.swift` |
| Sketch and features | `SketchController.swift`, `SketchOverlayViews.swift`, `FeatureOperations.swift`, `FeatureGraph.swift` |
| Document | `AppModel.swift`, `CADDocument.swift`, `PartStudio.swift`, `UndoRedoManager.swift` |
| Measure and export | `Dimensions.swift`, `ModelExporter.swift` |
