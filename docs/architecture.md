# How it works

## Hinge and crease

`HingeInputManager` wraps `onHingeChange` and exposes the bend in radians (`bend = pi - rawAngle`,
clamped to 0...pi, then snapped to 0/45/90/135/180 degrees within 1 degree). The crease comes from `GeometryProxy.reservedRegions(kind: .division)`; if none is
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
body it overlaps). The viewport keeps one undo stack: before each action it stores a snapshot (document features,
`FoldSession`, corner style and the id maps) and the Undo button restores the last one.
`AppModel.snapshotDocument`/`restoreDocument` cover the document part.

## Sketching (`SketchController`, `SketchOverlay`)

Shapes live in the plane's 2D coordinates. Closed profiles come from rectangles, circles and loops of
snapped lines. `SketchGeometry.slab` extrudes toward the viewer; `SketchGeometry.cutter` reaches down
into the material (with a small lift above the surface so faces are never coplanar).

## Touch up (`ShapeAnalysis`, `MeshTouchUp`, `TouchUp`)

`ShapeAnalysis` (2D) simplifies a hand-drawn loop with Ramer-Douglas-Peucker, then builds candidate
readings with triangle theorems. `MeshTouchUp` (3D) welds vertices, then flattens spikes and flat-patch bumps, flips edges to fix
sliver triangles, collapses tiny edges and drops zero-area triangles; `prismProfile` recovers the
outline and holes of a straight extrusion so it can be read like a sketch and rebuilt with
`GeometryBuilder.prism(outer:holes:)`.
`TouchUpEngine` asks a `TouchUpAdvisor` (`OnDeviceAdvisor`, FoundationModels, 8 second timeout) to
choose among the candidates and falls back to the best geometric fit. `DesignScene` reads every body as a world-axis block (`DesignPart`: box, cylinder or other). A
`DesignPlan` (`DesignIntent.swift`) lists groups of parts with matching, mirroring, alignment, spacing,
corner and colour rules; it comes from `OnDeviceAdvisor.plan` (guided generation into `DesignPlanOutput`),
is checked by `DesignIntent.validated`, and falls back to `DesignRegularizer.heuristicPlan`.
`DesignRegularizer.apply` carries out the layout rules and `DesignFinish` rounds slab corners, adds rails
under a slab and picks colours (`PartStyle`/`Palette`, stored per body in `AppModel.partStyles`, part of
the undo snapshot). Nothing in the pipeline knows about a particular kind of object. `Symmetry.mirror` pairs each part with its
mirror image; `HolePattern` does the same for holes in a plate.
Body results are stored as
`ViewportTouchUpFeature`s, so they regenerate and undo like other edits.

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

## Design library (`Library/`, `Dashboard/`)

Designs live in `Application Support/FoldForm/Designs/<id>.fold/`: `manifest.json` (name, dates,
favourite, folder, part count), `content.json` (bodies by mesh hash, colours by position, corner
style, camera), `meshes/<sha256>.mesh` (one binary file per distinct mesh, see `MeshBlob`),
`thumbnail.png` and `versions/`. Files are replaced atomically, blobs first and the manifest last, so
a crash leaves the previous state readable. Deleted designs move to `Trash/`, emptied at launch.

- `DesignStore` does the disk work and is the only type that touches the files.
- `DesignLibrary` is the observable list the dashboard reads: create, rename, duplicate, favourite,
  folders, delete with undo, search/sort/filter (pure functions), stats, and version operations.
- `ViewportEntities.captureDesign()` reads the fold session (held folds baked in), colours, corner
  and camera. `AppModel(loaded:)` rebuilds the document from those, one `ViewportSolidFeature` per body.
- `DesignSession` autosaves: 1.5 s after the last change (signalled from the undo stack's `push`/`undo`),
  on backgrounding, and on close. A capture with no usable bodies never overwrites a good save.
- `ThumbnailRenderer` draws thumbnails in CoreGraphics from the meshes (fixed three-quarter view,
  decimated above 40,000 triangles), so it needs no GPU pass and is unit tested.
- `AppRoot` switches between `DashboardView` and `EditorView`; a fresh editor is built per opened design.
- **Collaboration:** `CollaborationService` is the plug point for a real backend. The only
  implementation, `LocalPreviewCollaborationService`, keeps invitations in a local file and never
  touches the network.

## Source map

| Area | Files |
| --- | --- |
| App shell and HUD | `FoldFormApp.swift`, `ViewCubeView.swift`, `ReferenceScene.swift` (also the view-options sheet) |
| Viewport | `RealityViewport.swift`, `ViewportGestureView.swift`, `CameraRig.swift` |
| Folding | `BendDeformer.swift`, `FoldSession.swift`, `HingeInputManager.swift` |
| Geometry | `GeometryBuilder.swift`, `GeometryKernel.swift`, `MeshOps.swift`, `MeshCSG.swift` |
| Sketch and features | `SketchController.swift`, `SketchOverlayViews.swift`, `FeatureOperations.swift`, `FeatureGraph.swift` |
| Document | `AppModel.swift`, `CADDocument.swift`, `PartStudio.swift`, `UndoRedoManager.swift` |
| Touch up | `ShapeAnalysis.swift`, `MeshTouchUp.swift`, `DesignScene.swift`, `DesignRegularizer.swift`, `DesignIntent.swift`, `DesignFinish.swift`, `HolePattern.swift`, `PartStyle.swift`, `TouchUp.swift` |
| Measure and export | `Dimensions.swift`, `ModelExporter.swift` |
