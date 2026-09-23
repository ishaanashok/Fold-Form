# FoldForm — Bitrig Hacks: iPhone Duo Edition

## Codex-ready build brief

Create a polished native SwiftUI + RealityKit iPhone Duo hackathon demo called **FoldForm**. FoldForm turns the physical iPhone Duo crease into the bend axis of a live 3D engineering model. As the user folds the device, the model bends by the same angle, the bend axis is visibly marked, sheet-metal calculations update live, collisions are detected, and critical events produce distinct haptic feedback.

The demo should make one idea immediately obvious:

> The crease is not merely where the app avoids placing content. It is a physical design input and the exact bend axis of the digital part.

## 1. Event fit and constraints

Bitrig Hacks: iPhone Duo Edition is an in-person YC Office event in San Francisco on September 26, 2026. Doors open at 10:30 AM, hacking runs from 11:30 AM to 3:30 PM, live demos and judging run from 3:30 PM to 5:00 PM, and awards follow from 5:00 PM to 6:00 PM.

The event asks participants to use Apple’s newly released iPhone Duo APIs to build something that would not have been as compelling or possible before. A polished demo is enough; a complete production app is not required. Judges are specifically looking for creative, thoughtful use of the new APIs and something meaningfully new. All code must be created at the hackathon. Design assets may be prepared in advance. Participants do not have to use Bitrig, but there is a prize for the best project created in Bitrig.

This plan therefore has two modes:

1. **Before the event:** prepare the concept, design assets, test script, prompt, project outline, and acceptance criteria. Do not generate the Swift source or Xcode project before the event.
2. **At the event:** paste this brief into Codex/Bitrig, create the project from scratch, implement the vertical slice first, and only then add polish.

Relevant references:

- [Bitrig Hacks event brief](https://luma.com/yc-meetup-4378)
- [Apple: Get ready for iPhone Duo](https://developer.apple.com/iphone-duo/)
- [Apple: DeviceHinge](https://developer.apple.com/documentation/swiftui/devicehinge)
- [Apple: onHingeChange](https://developer.apple.com/documentation/swiftui/view/onhingechange%28isenabled%3A_%3A%29)
- [Apple: UIHingeInteraction](https://developer.apple.com/documentation/uikit/uihingeinteraction)
- [Apple Tech Talk: adaptive layouts on iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111463/)
- [Apple Tech Talk: multiple displays and scenes on iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111464/)
- [Bitrig iPhone Duo development updates](https://bitrig.com/blog)

## 2. Refined product concept

### One-sentence pitch

**FoldForm is a foldable-phone-native sheet-metal and mechanism sandbox: fold the iPhone Duo and the crease becomes the live bend axis of a 3D part, with engineering calculations, collision detection, and tactile warnings updating in real time.**

### 30-second judge explanation

“Most apps treat a fold as a layout problem. FoldForm treats it as a physical control. The iPhone Duo’s hinge angle drives a real mesh deformation, so a beam at 0° is flat, at 45° is bent 45°, and at 90° forms an L. The gold line is the crease mapped into 3D—the bend axis. Switch to sheet metal and the app calculates bend allowance, bend deduction, K-factor, and flat-pattern length while the part approaches an obstacle. When it collides or reaches its bend limit, the model changes state and the phone gives a distinct haptic warning.”

### Why this is newly possible

The app’s core interaction depends on the iPhone Duo’s continuous hinge angle. Apple’s current documentation describes `onHingeChange`/`DeviceHinge` in SwiftUI and `UIHingeInteraction`/`UIHinge` in UIKit; the angle is continuous while the status also reports closed, partially open, and fully open. Apple’s guidance distinguishes hinge-driven effects from layout decisions: use hinge data for interaction, and use arrangements and reserved regions for layout. FoldForm follows that distinction exactly.

## 3. Product scope and CAD direction

FoldForm should be more than a single animated beam. It should establish a modular, sketch-driven parametric CAD foundation that engineers can use to begin creating real 3D parts, while making the iPhone Duo hinge the signature interaction.

The event demo should prove the foundation with a small, reliable set of modeling operations. The architecture must clearly point toward an Onshape-style Part Studio workflow: 2D sketches become features, features are stored in a history tree, later edits regenerate downstream geometry, and the hinge can bend the resulting model without destroying its design intent.

### Core demo capabilities

- Native SwiftUI app targeting the iPhone Duo simulator in Xcode 27.1 beta.
- Real-time hinge angle input with an interactive simulator fallback slider.
- A selectable 3D modeling viewport, not just a pre-authored mesh.
- Sketch a rectangle, circle, line, arc, or polygon on a reference plane.
- Edit dimensions and apply basic geometric constraints.
- Extrude a closed sketch as a new solid, add material, remove material, or intersect material.
- Create a hole from a sketch point or circle, including simple, counterbore, and countersink variants.
- Select faces and edges for fillet, chamfer, shell, delete-face, and transform operations where supported by the geometry engine.
- Keep every operation as a feature in an ordered, editable feature history.
- Continuously bend the resulting part around the physical crease.
- Show the gold crease/bend-axis indicator on the actual model.
- Show sheet-metal calculations for a selected bendable plate.
- Detect collision with a static obstacle and produce distinct haptic feedback.
- Provide undo, redo, suppress/delete, rename, and parameter editing for features.
- Gracefully fall back when hinge, haptics, or an advanced geometry operation is unavailable.

### CAD capability tiers

These are capability boundaries, not a time schedule. Build the system so each tier is a separately testable module that can be included or omitted without destabilizing the rest of the app.

#### Tier 1 — modeling foundation

- Document containing one Part Studio-like workspace.
- Origin, front/top/right reference planes, axes, and a grid.
- Camera orbit, pan, zoom, fit-to-view, standard views, and section view.
- Selection of vertices, edges, faces, bodies, sketches, and features.
- Sketch creation and editing on a selected plane or planar face.
- Closed-profile validation before a solid feature is created.
- Feature history with rollback, rename, delete, suppress, and edit.

#### Tier 2 — real solid creation and removal

- Extrude: `New`, `Add`, `Remove`, and `Intersect` result types.
- Blind, symmetric, through-all, up-to-next, and up-to-face termination modes.
- Revolve around a sketch line, axis, or reference axis.
- Hole feature from sketch points or circle centers.
- Simple, counterbore, countersink, and tapped-hole metadata; cosmetic threads may be visual-only.
- Boolean union, subtraction, and intersection between bodies.
- Primitive solids such as box, cylinder, sphere, and wedge for quick design starts.
- Move, rotate, mirror, and linear/circular pattern of features or bodies.

#### Tier 3 — engineering refinement

- Fillet with constant radius and tangent propagation.
- Chamfer with equal-distance and distance-angle modes.
- Shell/hollow with wall thickness and selected open faces.
- Draft and taper.
- Thin extrude and sheet-metal flange creation.
- Bend table inputs, K-factor, bend allowance, bend deduction, and flat-pattern view.
- Measure distance, angle, radius, area, and bounding-box dimensions.
- Appearance, material label, units, tolerances, and named parameters.

#### Tier 4 — future CAD platform direction

- More complete constraint solver with horizontal, vertical, coincident, tangent, parallel, perpendicular, equal, concentric, midpoint, symmetry, fixed, and construction constraints.
- Fully constrained/under-constrained/over-constrained diagnostics.
- Sweeps, lofts, guide curves, surfaces, offset, trim, extend, and thicken.
- Multi-body Part Studio workflows and derived geometry.
- Assemblies with mates, joints, interference checking, and exploded views.
- Configurations, variables, feature suppression states, and reusable custom features.
- Drawings, hole callouts, section views, export, version history, and collaboration.

This is an Onshape-inspired modeling direction, not a promise to reproduce every enterprise CAD feature in the hackathon. The key requirement is that the first implementation uses the same conceptual foundation: sketches, parameters, features, history, regeneration, and selectable geometry. Onshape’s own documentation describes Part Studios as environments where sketches and feature tools create and modify parts, and its Extrude and Hole features support both additive and subtractive operations. [Onshape Part Studios](https://cad.onshape.com/help/Content/PartStudio/part_studios.htm) · [Onshape Extrude](https://cad.onshape.com/help/Content/PartStudio/extrude.htm) · [Onshape Hole](https://cad.onshape.com/help/Content/PartStudio/hole.htm)

### Explicit non-goals

- No finite-element analysis, stress tensor, fatigue, or living-hinge simulation.
- No cloud collaboration, login, PDM, or backend dependency for the demo.
- No requirement to support LiDAR, panel IMUs, or camera-based tracking.
- No claim that the prototype is suitable for manufacturing without engineering review.
- Do not hard-code the app around one beam mesh; keep the CAD feature pipeline extensible.

## 4. Demo experience and screen design

Use `ArrangementView` with a split arrangement when the API is available. The primary region is the RealityKit viewport; the secondary region is the control/readout panel. Use `reservedRegions(kind: .division)` to keep important controls and labels clear of the physical crease. Do not branch layout based on `hinge.angle`; use arrangement, geometry, size classes, and reserved-region information for layout. Use hinge angle only as an interaction/effect input.

### Primary 3D region

- Dark, uncluttered engineering-style background.
- Large centered part with a neutral metallic material.
- Gold emissive bend-axis line or narrow translucent plane.
- Small anchored label: “Bend axis: along device crease”.
- Obstacle shown as a red translucent housing wall or block.
- Status badge: `READY`, `BENDING`, `COLLISION`, or `MAX BEND`.
- Camera framing that keeps the whole part visible from 0° through 90°.

### Control/readout region

- App title: `FoldForm`.
- Workbench tabs: `Model`, `Sketch`, `Sheet Metal`, and `Inspect`.
- Feature tree showing sketches, solids, cuts, holes, fillets, chamfers, and patterns in order.
- Contextual feature toolbar with `Sketch`, `Extrude`, `Revolve`, `Hole`, `Fillet`, `Chamfer`, `Shell`, `Pattern`, `Mirror`, `Boolean`, and `Measure`.
- `Add`, `Remove`, and `Intersect` result controls for solid features.
- Large angle readout, for example `45°`.
- Profile/primitive picker: `Beam`, `I-beam`, `Sheet plate`, `Box`, and `Cylinder`.
- For sheet plate: thickness, bend radius, K-factor, and two straight-leg lengths.
- Numeric cards for `BA`, `BD`, and `Flat length`.
- Feature parameter editor with units, expression-ready numeric fields, and a visible regenerate/error state.
- A compact status legend explaining gold axis, red collision, and amber bend limit.
- `Start Demo` button that resets the model and begins the scripted walkthrough.
- `Simulator angle` slider only when a physical hinge is unavailable.
- First-launch help text: “Fold the phone to bend the part. The crease is the bend axis.”

## 5. Technical architecture

Use separate Swift files and modular design assets so the project can be assembled, compiled, and tested at the hackathon. Do not optimize the plan around a four-hour implementation window. Prefer native frameworks only: SwiftUI, RealityKit, Core Haptics, Combine if needed, and Foundation. Avoid third-party dependencies unless a later geometry-kernel adapter explicitly requires one.

RealityKit is the rendering and interaction layer, not a full CAD kernel. Separate the parametric modeling model from RealityKit so FoldForm can begin with a lightweight procedural solid/mesh engine and later replace or extend it with a robust B-rep/CSG kernel without rewriting the iPhone Duo experience.

Suggested structure:

```text
FoldForm/
  FoldFormApp.swift
  AppModel.swift
  HingeInputManager.swift
  CADDocument.swift
  PartStudio.swift
  GeometryKernel.swift
  GeometryTypes.swift
  SketchModel.swift
  SketchSolver.swift
  FeatureGraph.swift
  FeatureOperations.swift
  SelectionManager.swift
  ReferenceGeometry.swift
  UndoRedoManager.swift
  BendDeformer.swift
  PartProfile.swift
  SheetMetalCalculator.swift
  CollisionManager.swift
  HapticManager.swift
  DemoCoordinator.swift
  RealityViewport.swift
  ControlPanelView.swift
  FlatPatternView.swift
  StatusBadgeView.swift
  ModelingToolbarView.swift
  FeatureTreeView.swift
  SketchEditorView.swift
  ParameterEditorView.swift
  Assets.xcassets/
```

### Shared model

Create an `@MainActor` observable app model containing:

- `hingeAngleRadians` and a computed `hingeAngleDegrees`.
- `hingeStatus` and `hingeAvailable`.
- `selectedProfile`.
- `document` containing the active Part Studio, sketches, bodies, feature history, parameters, and named references.
- `activeWorkbench` and `activeTool`.
- `selection` and `hoveredSelection`.
- `featureTree` and `featureRegenerationState`.
- `isSketchEditing` and `activeSketchPlane`.
- `undoStack` and `redoStack`.
- `thickness`, `bendRadius`, `kFactor`, `legOneLength`, `legTwoLength`.
- `sheetMetalResult`.
- `collisionState`, `collisionAngle`, and `maxBendReached`.
- `demoState` and `showOnboarding`.

Keep the model as the single source of truth. The hinge input, deformer, sheet-metal calculator, collision manager, haptic manager, and views should communicate through clear methods or published state rather than directly reaching into one another.

### CADDocument and PartStudio

Create a document model that represents a simple Part Studio rather than a collection of unrelated mesh entities.

- `CADDocument` owns units, metadata, the active Part Studio, undo/redo, and saved camera/view state.
- `PartStudio` owns reference geometry, sketches, bodies, features, variables, and the ordered feature tree.
- Every sketch and feature has a stable identifier, display name, visibility flag, suppression flag, input references, parameter values, and regeneration status.
- Features are evaluated in order. Editing an earlier sketch or feature invalidates and regenerates downstream features.
- A failed feature remains visible in the tree with an explanatory error rather than silently deleting the model.
- The visible RealityKit entities are a projection of the evaluated Part Studio, not the authoritative design data.

### GeometryKernel abstraction

Define a protocol that supports the operations needed by the first modeling foundation:

```swift
protocol GeometryKernel {
    func makePrimitive(_ definition: PrimitiveDefinition) throws -> Solid
    func extrude(_ profile: PlanarProfile, _ parameters: ExtrudeParameters) throws -> Solid
    func revolve(_ profile: PlanarProfile, _ parameters: RevolveParameters) throws -> Solid
    func boolean(_ operation: BooleanOperation, _ lhs: Solid, _ rhs: Solid) throws -> Solid
    func createHole(_ definition: HoleDefinition, in solid: Solid) throws -> Solid
    func fillet(_ definition: FilletDefinition, in solid: Solid) throws -> Solid
    func chamfer(_ definition: ChamferDefinition, in solid: Solid) throws -> Solid
    func shell(_ definition: ShellDefinition, in solid: Solid) throws -> Solid
    func tessellate(_ solid: Solid) throws -> RenderMesh
}
```

The initial implementation may use procedural meshes and constrained constructive-solid-geometry for boxes, cylinders, extrusions, holes, cuts, and intersections. Keep the protocol and data types independent of RealityKit so a more capable solid kernel can be added later. For every operation, preserve the feature parameters even if the first renderer uses an approximate mesh.

### HingeInputManager

Implement the current beta API discovered in the installed Xcode SDK. The preferred SwiftUI path is `onHingeChange`, receiving the current `DeviceHingeContext` and reading `context.hinge?.angle`. If the exact beta signature differs, inspect autocomplete and adapt it rather than inventing an API.

Requirements:

- Normalize the API’s angle units explicitly. Apple documents `UIHinge.angle` as radians; keep the internal representation in radians.
- Clamp to a safe demo range, initially 0...π/2 unless the simulator exposes a different calibrated range.
- Smooth small sensor/simulator noise with a short low-pass filter, but do not add visible latency.
- Publish a simulator angle override for devices without hinge context.
- Reset to 0° when hinge data becomes unavailable.
- Expose `isUsingSimulatorFallback` in the UI.

### BendDeformer

Represent the part in local coordinates with the bend axis at local `x = 0`. Each vertex has a signed distance `x` from the crease and a longitudinal coordinate `z` along the crease. Apply a piecewise rigid bend around the crease:

```text
for vertex p:
    x = p.x
    y = p.y
    theta = sign(x) * bendAngle
    distance = abs(x)
    newX = sign(x) * distance * cos(bendAngle)
    newY = y + distance * sin(bendAngle)
```

Use the coordinate convention that gives a visibly correct flat pose and an L-shape at 90°. If the chosen coordinate system needs a rotation matrix instead, use one consistent `simd_float4x4` transform and document it. The requirement is continuous, non-popping deformation with exact user-visible angle mapping—not a specific internal axis convention.

Implementation order:

1. Start with a subdivided rectangular plate mesh so the deformation is visually smooth.
2. Regenerate vertex positions as the angle changes.
3. Update normals or use a material that remains visually credible while prototyping.
4. If CPU mesh regeneration is too slow, move the bend into a RealityKit custom vertex shader; only do this after the simpler path works.

The mesh must visibly respond to every hinge update. Do not fake the effect with a single entity rotation: the centerline must remain at the crease while both sides form the bend.

Apply the bend after the active Part Studio has regenerated its modeled geometry. The CAD model is authored in a flat/reference state, and the hinge is a non-destructive presentation transform that bends the evaluated mesh and its collision proxy around the crease. Feature parameters, sketches, and the feature tree remain unchanged while the phone folds.

### Part profiles and primitives

Implement profiles as built-in starting geometry, not as the long-term modeling representation:

- `beam`: rectangular solid with a contrasting end face.
- `iBeam`: simplified I-shaped cross-section extruded along the part.
- `sheetPlate`: thin flat rectangular plate, used for sheet-metal math.
- `box`, `cylinder`, `sphere`, and `wedge`: primitive solids that can be created, transformed, combined, or cut.

Make `sheetPlate` the default demo profile because it best connects the 3D bend to the 2D flat-pattern view. Let an engineer switch into Model mode and continue editing the same document rather than replacing it with a separate demo scene.

### Sketch workflow

The first-class modeling workflow should be:

1. Choose a reference plane or planar face.
2. Enter Sketch mode with a visible grid and plane-aligned camera.
3. Draw lines, rectangles, circles, arcs, polygons, construction geometry, and centerlines.
4. Apply dimensions and constraints.
5. Show closed profiles in a distinct color and identify open or self-intersecting profiles.
6. Finish the sketch and select an operation such as Extrude, Revolve, or Hole.
7. Keep the sketch in the feature tree so it can be reopened and edited.

Implement a lightweight constraint model first. It should support coincident, horizontal, vertical, parallel, perpendicular, tangent, equal, concentric, midpoint, symmetry, fixed, construction, and dimensional constraints. A complete industrial constraint solver is a later extension; the prototype must at minimum preserve constraints, report under-constrained geometry, and reject contradictory input without corrupting the document.

### Feature operations

Every modeling command creates a typed feature with editable inputs and a deterministic `regenerate()` method.

#### Additive and subtractive features

- **Extrude:** create a new body, add to a body, remove material, or intersect a body. Support blind, symmetric, through-all, up-to-next, and up-to-face termination.
- **Revolve:** revolve a closed sketch around a construction line or reference axis, with new/add/remove/intersect results.
- **Hole:** create a hole at sketch points or circle centers. Support simple, counterbore, countersink, blind, through-all, and tapped-hole metadata. Threads may be cosmetic for performance.
- **Boolean:** union, subtract, and intersect two selected bodies or feature results.
- **Thin feature:** turn an open profile into a wall with a specified thickness.

#### Refinement and transformation features

- **Fillet:** select edges or faces, specify radius, and propagate along tangent edges where possible.
- **Chamfer:** select edges, specify equal distance or distance-plus-angle.
- **Shell:** remove selected faces and hollow the remaining body to a wall thickness.
- **Draft:** apply a taper to selected faces relative to a neutral plane.
- **Pattern:** linear and circular patterns of features, bodies, or sketch entities.
- **Mirror:** mirror geometry or features across a plane or planar face.
- **Transform:** move, rotate, copy, and align bodies or features.
- **Delete face / heal:** remove a face and attempt to close the resulting gap; if healing fails, show a clear error.

Onshape’s official feature documentation uses the same broad mental model: Extrude can add, remove, or intersect material; Hole supports simple, counterbore, and countersink types; Shell hollows a part to a wall thickness; and Fillet rounds selected edges or faces. FoldForm should use those familiar concepts while keeping the iPhone Duo interaction central. [Onshape Hole](https://cad.onshape.com/help/Content/PartStudio/hole.htm) · [Onshape Shell](https://cad.onshape.com/help/Content/PartStudio/shell.htm) · [Onshape Fillet](https://cad.onshape.com/help/Content/PartStudio/fillet.htm)

### Feature tree and regeneration

The feature tree is a core modeling surface, not merely a debug list.

- Show origin/reference geometry at the top.
- Show sketches and operations in creation order.
- Allow selecting a feature to highlight its resulting geometry.
- Allow rename, hide/show, suppress/unsuppress, edit, delete, and rollback.
- Show warnings and failed features inline.
- When an upstream parameter changes, recompute downstream features and preserve stable references when possible.
- Expose an “Edit feature” sheet with dimensions, operation type, target body, direction, termination, and scope.

### Selection, direct manipulation, and inspection

Support tap selection and clear selection highlighting for vertices, edges, faces, bodies, sketches, and features. Add context-sensitive handles for extrude depth, hole diameter/depth, bend angle, transform, fillet radius, and chamfer distance. Provide measurement overlays for selected geometry and a section-view toggle so the user can see holes and shell interiors.

### Bend-axis indicator

Create the indicator as a child entity of the part so it inherits the same transform/deformation relationship. Use a gold emissive material and a slightly larger scale than the physical crease. It must remain visible at 0°, 45°, and 90°.

The indicator should be the most legible visual explanation in the demo. Keep the label in SwiftUI or as a billboarded RealityKit label, but do not let the text cross the physical division region.

## 6. Sheet-metal calculations

Create a pure, unit-tested `SheetMetalCalculator` with no RealityKit dependencies. Use millimeters for all dimensions and radians for trigonometry.

Inputs:

- `thickness t` in mm.
- `inside bend radius R` in mm.
- `bendAngle θ` in radians.
- `kFactor K`, default `0.44`.
- `legOneLength` and `legTwoLength` in mm.

Core formulas:

```text
BA = θ × (R + K × t)
BD = 2 × (R + t) × tan(θ / 2) − BA
```

Include these formulas in code comments and label them in a small “How it is calculated” disclosure in the UI. At 0°, BA and BD must be 0. Handle near-0° and invalid inputs without NaN or infinity.

Use one explicit dimension convention so the demo is explainable:

- `flatNeutralAxisLength = legOneLength + legTwoLength + BA` when the leg lengths are tangent-to-tangent straight lengths.
- Also show `BD` as the outside-dimension correction for viewers familiar with fabrication drawings.
- If the UI labels a length as an outside dimension, convert it with the documented bend-deduction convention instead of mixing conventions.

The app is an educational simplified model, not a certified fabrication calculator. Make this clear in a small footnote: “Demo model; confirm tooling and material data before fabrication.”

### 2D flat-pattern view

Use SwiftUI `Canvas` or simple `Path` drawing. Show:

- A horizontal flat blank.
- Two dimension arrows for the straight sections.
- A highlighted neutral-axis bend zone whose length equals BA.
- Text values for `θ`, `BA`, `BD`, and `Flat length`.

The 2D view and 3D view must be driven by the same published angle and calculator result. No duplicated angle state.

## 7. Collision detection

Use RealityKit collision events, but optimize for demo reliability rather than maximum physical fidelity.

Preferred path:

- Add a `CollisionComponent` and `PhysicsBodyComponent` to the obstacle.
- Give the deforming part a simplified proxy made from a small set of boxes or capsules positioned along the bent geometry.
- Rebuild or reposition the proxy only when the hinge angle changes beyond a small threshold, not blindly every render frame.
- Subscribe to `CollisionEvents.Began` and `.Ended` through `scene.subscribe(to:on:)`.

On collision begin:

- Set collision state to active.
- Record the current angle.
- Turn the part or a highlight overlay red.
- Show `COLLISION DETECTED at 52°` or the current angle.
- Trigger the collision haptic once.

On collision end:

- Clear the active collision state after a short debounce.
- Restore normal material/status if the maximum bend state is not active.

Make the obstacle position deterministic so the demo reliably collides in the planned range, preferably around 55°–65°. The app should also show a small “Obstacle” label so judges understand why the collision occurs.

## 8. Maximum bend logic

Do not present the threshold as a universal material failure limit. Use a transparent demo heuristic tied to the entered geometry:

```text
radiusToThickness = bendRadius / thickness
baseLimit = 90°
if radiusToThickness < 1.0: subtract 20°
else if radiusToThickness < 1.5: subtract 10°
maxBend = clamp(baseLimit, minimum: 45°, maximum: 90°)
```

Label the state `DEMO BEND LIMIT`, not `MATERIAL FAILURE`. This satisfies the requirement that the threshold comes from geometry rather than an arbitrary isolated constant while avoiding false engineering claims.

Trigger the max-bend haptic only on the transition from below the threshold to at-or-above it. Do not fire on every frame. Reset the transition latch when the angle falls below the threshold by a small hysteresis margin.

## 9. Haptics

Create a `HapticManager` using `CHHapticEngine`.

- Collision: short sharp transient with a bright, higher-intensity pattern.
- Demo bend limit: single firm transient with a lower pitch/roughness profile, clearly different from collision.
- Optional active bending texture: only after the first two events are stable; use a debounced, low-intensity pattern or omit it if it adds latency.

Gracefully handle devices/simulator environments where Core Haptics is unavailable. Haptic failures must never block the visual state transition. The visual event is the source of truth for the judge.

## 10. Demo coordinator

Implement a small state machine:

```text
idle
→ reset
→ explainCrease
→ bendTo45
→ showSheetMetal
→ approachObstacle
→ collision
→ continueToLimit
→ maxBend
→ reset
```

The user should be able to drive the whole experience manually by folding the device. `Start Demo` simply resets the scene, shows a short instruction, and enables a subtle guide overlay. Do not run a long unattended animation; the physical fold is the point.

Suggested 90-second live narration:

1. At 0°: “This is a flat sheet and the gold line is the physical crease mapped into the model.”
2. Enter Model mode: sketch a rectangle, extrude it, sketch a circle on the face, and use Hole or Extrude Remove to cut material away. “This is an actual editable feature sequence, not a pre-rendered mesh.”
3. Fold to 45°: “The resulting model bends exactly 45°; the fold is the design input.”
4. Select sheet metal: “Now the same angle drives bend allowance, deduction, and the unfolded blank.”
5. Fold toward the obstacle: “The part is no longer just animated; it is checked against a housing wall.”
6. Trigger collision: show red state and collision haptic.
7. Continue to the bend limit: show the separate amber/limit state and second haptic.
8. Reset: “This is what becomes possible when the hinge is treated as an engineering control.”

## 11. Modular implementation plan

This is a capability plan, not a timed hackathon schedule. Each area should be implemented as a self-contained design asset or Swift module that can be compiled independently and assembled into the final project at the event.

### Module A — iPhone Duo shell

- SwiftUI app entry point and shared `AppModel`.
- Arrangement-based split layout with primary 3D viewport and secondary modeling panel.
- Reserved-region handling around the physical crease.
- Hinge API adapter and simulator fallback.
- Basic navigation between Model, Sketch, Sheet Metal, and Inspect workbenches.

### Module B — document and feature-history foundation

- `CADDocument`, `PartStudio`, `Body`, `Sketch`, `Feature`, `Parameter`, and `ReferenceGeometry` types.
- Stable IDs and named references for sketches, faces, edges, and vertices.
- Ordered feature tree with visibility, suppression, rename, delete, rollback, undo, and redo.
- Regeneration pipeline that evaluates features in order and reports errors without destroying the document.
- Serializable local document format so demo models can be saved as design assets without requiring a backend.

### Module C — sketching and constraints

- Plane-aligned sketch canvas with grid, snapping, construction geometry, and selection.
- Line, rectangle, circle, arc, polygon, centerline, trim, extend, offset, and mirror sketch tools.
- Dimensional inputs for length, diameter, radius, angle, and distance.
- Constraint records for coincident, horizontal, vertical, parallel, perpendicular, tangent, equal, concentric, midpoint, symmetry, fixed, construction, and dimensional constraints.
- Profile validation with clear messages for open, self-intersecting, or nested geometry.
- A lightweight solver that preserves constraints and reports under-constrained or conflicting sketches.

### Module D — geometry and solid modeling

- Geometry-kernel adapter independent of RealityKit.
- Procedural tessellation for primitives, planar profiles, extrusions, revolutions, and simple Boolean operations.
- Additive and subtractive Extrude with blind, symmetric, through-all, up-to-next, and up-to-face modes.
- Revolve around a sketch axis or reference axis.
- Hole feature with simple, counterbore, countersink, blind, through-all, and cosmetic tapped-hole variants.
- Boolean union, subtraction, and intersection between bodies.
- Fillet, chamfer, shell, draft, thin feature, delete-face/heal, pattern, mirror, and transform interfaces, with robust implementations added progressively behind the same feature protocol.
- Explicit regeneration errors when a geometric operation cannot be resolved.

### Module E — RealityKit presentation layer

- Convert evaluated solids into RealityKit meshes while preserving body/face/edge identity for selection.
- Provide orbit, pan, zoom, fit-to-view, standard views, section view, hidden-edge mode, and selection highlighting.
- Show transform handles and direct numeric manipulators for feature parameters.
- Keep the evaluated flat/reference model separate from the hinge-driven bend presentation transform.
- Use the bend deformer on any supported tessellated body, not only on the original plate.

### Module F — hinge bend and engineering behavior

- Map hinge angle continuously to the model bend angle.
- Keep the crease indicator aligned with the exact bend axis.
- Calculate sheet-metal bend allowance, bend deduction, K-factor, and flat pattern for bendable sheet features.
- Attach collision proxies to evaluated geometry after deformation.
- Show obstacle collisions and bend-limit state transitions.
- Provide distinct Core Haptics patterns with visual fallbacks.

### Module G — engineering inspection

- Measurement tool for distance, angle, radius, area, thickness, and bounding box.
- Material/thickness/radius/K-factor panel.
- Units selector with mm/in support at the document level.
- Tolerance-ready parameter model.
- Section analysis to reveal holes, shells, and internal cuts.
- Model validation panel listing failed features, open profiles, self-intersections, and collision status.

### Module H — prepared design assets

Prepare only non-code assets before the event: iconography, color palette, obstacle geometry reference, empty-state illustrations, demo model descriptions, and presentation copy. Keep all Swift source, project files, and generated implementation code for the hackathon in accordance with the event rules.

### Assembly and compilation requirements

- Each module must have a narrow public interface and a small sample state.
- The app must be able to run with the CAD modules disabled, showing the hinge demo and fallback controls.
- The app must be able to run with hinge input disabled, using a simulator slider.
- The app must be able to render a prebuilt parametric sample document while sketching tools are being connected.
- The final integration should demonstrate that a user can create or edit geometry, not merely view a pre-authored animation.

## 12. Acceptance test matrix

| Area | Test | Expected result |
|---|---|---|
| Hinge | 0° | Part is flat; angle reads 0°; BA/BD are 0 |
| Hinge | 45° | Part visibly bends 45°; readout reads approximately 45° |
| Hinge | 90° | Part forms an L; no popping or inversion |
| Axis | Any angle | Gold axis remains on the crease and visibly tracks it |
| Layout | Folded pose | Controls avoid the division region and remain usable |
| Sketch | Closed rectangle | Profile validates and is available to Extrude |
| Sketch | Circle on face | Circle center can drive a Hole feature |
| Sketch | Constraint edit | Changing a dimension updates sketch geometry without corrupting the document |
| Feature | Extrude Add | New material appears and is listed in feature history |
| Feature | Extrude Remove | Selected material is cut away from the target body |
| Feature | Hole | A visible through-hole/counterbore/countersink is created at the selected point |
| Feature | Boolean | Union, subtraction, and intersection produce the expected body result |
| Feature | Edit upstream | Downstream features regenerate or report a visible, recoverable error |
| Feature | Delete/suppress | The feature tree updates and undo restores the previous model |
| Viewport | Select face/edge | Geometry highlights and the correct contextual tool appears |
| Viewport | Section view | Internal holes and shell cavities are inspectable |
| Sheet metal | Change K-factor | BA and flat length update; BD remains consistent |
| Sheet metal | Change thickness/radius | Calculator updates without NaN/Infinity |
| Collision | Enter obstacle | Red state, angle label, one collision haptic |
| Collision | Exit obstacle | Collision clears after debounce |
| Bend limit | Cross threshold | One distinct max-bend haptic and limit state |
| Fallback | No hinge context | Slider works; app remains demoable |
| Fallback | No haptics | Visual states still work; no crash |
| Recovery | Reset | Scene, calculator, collision, and haptic latches return to initial state |

## 13. Risk controls and implementation decisions

### Beta API mismatch

The event uses Xcode 27.1 beta and Apple marks the new hinge and layout APIs as beta. At the start of the build, inspect the installed SDK headers/autocomplete. Keep all beta-specific calls inside `HingeInputManager` and a small layout adapter so changes do not spread through the app.

### Mesh performance

Start with CPU mesh regeneration on hinge callbacks. A callback-driven update is sufficient for the demo if it is smooth in the simulator. Only move deformation to a custom RealityKit vertex shader if profiling shows visible stutter.

### Physics performance

Use simple proxy shapes rather than rebuilding a full convex hull every frame. Collision reliability and a clean live demo matter more than exact physics.

### CAD-kernel scope

RealityKit does not provide the full topology-aware B-rep modeling behavior of a mature CAD kernel. Keep the `GeometryKernel` protocol explicit. Implement reliable procedural operations for the first modeling path—primitives, sketches, extrude add/remove/intersect, holes, and basic booleans—and make advanced operations fail clearly when unsupported. Do not fake a successful feature by silently leaving the body unchanged. Preserve the feature parameters and error state so a future kernel can regenerate the model.

### Parametric reference stability

Face and edge identity can change after a Boolean or upstream edit. Use stable feature-owned references where possible, provide a visible “reference lost” warning when topology changes, and avoid silently attaching a hole or fillet to a different face. This is essential for an engineer-facing workflow.

### Engineering credibility

Show the actual formulas, units, and K-factor. State the dimension convention. Call the bend-limit logic a demo heuristic. This makes the prototype auditable without pretending it is production manufacturing software.

### Physical-device uncertainty

The event’s public brief says iPhone Duo ships after the hackathon, so rehearse primarily in the simulator. If real hardware is available, validate hinge latency and haptic timing, but never make the demo depend on a hardware-only sensor path.

## 14. Final Codex instruction

When this brief is pasted into Codex at the hackathon, begin with the following instruction:

> Build FoldForm now as a native SwiftUI + RealityKit iPhone Duo CAD prototype. All source code must be created in this hackathon workspace. First inspect the installed Xcode 27.1 beta SDK for the exact iPhone Duo hinge and arrangement APIs, then assemble the modular assets described in this brief. Implement the CAD foundation as a real document/Part Studio model with sketches, constraints, feature history, regeneration, selection, and editable parameters. Prioritize reliable sketch → Extrude Add/Remove → Hole/Boolean → hinge bend behavior, then connect fillet, chamfer, shell, pattern, mirror, measurement, and inspection tools behind the same feature architecture. Do not reduce the app to a pre-authored beam animation. Do not introduce a backend, LiDAR, or panel-IMU dependency. If a beta API or advanced geometry operation is unavailable, isolate it behind an adapter, preserve the feature/error state, and provide a working simulator fallback. Compile and run after integrating each module, and preserve a polished 90-second hinge-driven demo as the app’s proof point.

The final app must compile, launch, respond to the simulated hinge, deform the model continuously, show the crease as the bend axis, update sheet-metal calculations, detect a deterministic collision, produce distinct haptic events when supported, and remain demoable through fallbacks when a beta API or simulator capability is unavailable.
