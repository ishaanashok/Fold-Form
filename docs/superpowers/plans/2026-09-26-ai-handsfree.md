# Voice and Imagine Implementation Plan

> Later provider change: see the [OpenAI Imagine amendment](../specs/2026-09-26-openai-imagine-amendment.md)
> for the current Imagine client and model. The NIM-specific tasks below record the original plan.
> The [Apple voice amendment](../specs/2026-09-26-apple-voice-amendment.md) records the current
> speech and command model; the Moonshine/Needle tasks below are historical.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (inline). Steps use checkbox syntax.

**Goal:** Voice commands (on-device speech and interpreter) and Imagine (sketch plus description, cloud plan) that edit the same document as touch and the hinge.

**Architecture:** A typed `CADAction` layer executed against `AppModel`/`ViewportEntities`; interpreters and Imagine only produce `ToolCall`s or an `ImaginePlan`, which are validated into `CADAction`s. Everything ends as document bodies, so folding, undo and autosave are unchanged.

**Tech Stack:** Swift 6, SwiftUI, RealityKit, XCTest, AVFoundation, Security (Keychain), URLSession, Moonshine (Swift package), Cactus/Needle (optional runtime).

**Spec:** `docs/superpowers/specs/2026-09-26-ai-handsfree-design.md` (product source: `~/Downloads/FOLDFORM_AI_HANDSFREE_SPEC.md`).

## Global Constraints

- iOS deployment target 27.1, Swift language mode 6 (strict concurrency), iPhone portrait only.
- No API key or key-shaped string in the repo; keys only via `KeychainStore`.
- No networking in `AI/Actions`, `AI/Voice` interpreters or `AI/Models` except `ModelStore`'s explicit download and `NIMClient`.
- Interim transcripts never reach an interpreter; only `FinalUtterance`.
- One utterance or plan is one undo step.
- Tests never touch the network, the microphone, or the live simulator UI. Run the unit tests with the command in "Test command".
- After adding files run `xcodegen generate`.
- Scene unit is metres, world axes are x right, y up, z toward the viewer.

**Test command** (from the repo root; log to a file, read its tail):
`xcodebuild test -project FoldForm.xcodeproj -scheme FoldForm -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:FoldFormTests 2>&1 > $LOG`
(use whichever simulator name exists; the dashboard work used `runtests.sh` in the scratchpad).

## Deviations from the product spec (also in the design spec)

No face or edge selection (body-level only); `finish_sketch` discards unextruded shapes; rotation makes a body non-resizable; chamfer is reported as unsupported; a model-file manifest with hashes is filled when the files are located, so the app shows "not installed" until then.

## Review Focus

1. Interim speech text must never execute an action, even if a stale final arrives late or twice.
2. "3" vs "30", "mm" vs "cm", "minus 10" vs "10": a wrong sign or unit silently corrupts a design.
3. A plan whose step 4 of 5 fails must leave the document exactly as before (no partial bodies, one undo entry or none).
4. A stale Imagine reply (document changed after the request) must be rejected, not applied.
5. A hostile or malformed GLM reply (huge counts, NaN, references to bodies that do not exist, `delete` of the plate) must fail validation without touching the document.

---

### Task 1: Quantity and unit parsing

**Files:** Create `FoldForm/AI/Actions/Quantity.swift`; Test `FoldFormTests/QuantityTests.swift`

**Interfaces:**
- Produces: `enum LengthUnitWord { static func metres(_ value: Double, unit: String) -> Double? }` via `struct Quantity`:
  - `Quantity.length(_ value: Double, unit: String) -> Float?` (metres; nil for an unknown unit or a non-finite value)
  - `Quantity.angle(_ value: Double, unit: String) -> Float?` (radians; accepts degrees/degree/deg/°/radians)
  - `SpokenNumber.parse(_ text: String) -> Double?` ("three", "twenty five", "two point five", "3.5", "minus ten")

- [ ] Write tests: `length(3,"cm")==0.03`, `("mm")`, `("millimeters")`, `("inches")==0.0254*n`, `("m")`, unknown unit nil, NaN nil; angle 45 degrees == π/4; `SpokenNumber`: "three"→3, "twenty five"→25, "fifteen"→15, "two point five"→2.5, "3.5"→3.5, "minus ten"→-10, "negative 4"→-4, "a hundred"→100, "banana"→nil.
- [ ] Run: fails to compile (types missing).
- [ ] Implement: alias table; number-word parser (units, teens, tens, hundred, "point" decimals, sign words).
- [ ] Run: all pass. Commit `Add Quantity and spoken number parsing`.

### Task 2: ToolCall, CADAction, ToolCatalog

**Files:** Create `FoldForm/AI/Actions/CADAction.swift`, `ToolCatalog.swift`; Test `FoldFormTests/ToolCatalogTests.swift`

**Interfaces:**
- Consumes: `Quantity`.
- Produces:
  - `enum ToolValue: Equatable { case number(Double), string(String), bool(Bool) }`, `struct ToolCall: Equatable { var name: String; var arguments: [String: ToolValue] }`
  - `enum Axis3: String { case x, y, z, thinnest, longest }`, `enum BodyTarget: Equatable { case selected; case existing(Int); case named(String) }`
  - `enum CADAction: Equatable` (cases as in the spec, all lengths in metres, angles in radians)
  - `struct ToolContext: Equatable { var isSketching: Bool; var selectionKind: SelectionKind; var defaultUnit: String; var canUndo: Bool; var canRedo: Bool }`, `enum SelectionKind { case none, box, cylinder, other }`
  - `enum ToolError: Error, Equatable { case unknownTool(String), missing(String), invalid(String), notAvailable(String) }`
  - `enum ToolCatalog { static func tools(for: ToolContext) -> [ToolSpec]; static func schema(for: ToolContext) -> [[String: Any]]; static func validate(_ call: ToolCall, context: ToolContext) throws -> CADAction }`

- [ ] Tests: `create_cube(size:3,unit:"cm")` → `.createCube(size:0.03)`; missing size throws `.missing("size")`; `size:-1` throws invalid; `size:0` invalid; unknown unit invalid; `move_selected(direction:"right",distance:10,unit:"mm")` valid only when selection present else `.notAvailable`; `extrude(distance:2,unit:"cm",operation:"cut")`; distance 500 mm rejected (sketch range is 2–150 mm); tools list differs across contexts (sketching exposes `add_rectangle`, no selection hides `resize`); schema is an array of `{"type":"function","function":{name,description,parameters}}`.
- [ ] Run: fail. Implement. Run: pass. Commit.

### Task 3: RuleBasedInterpreter

**Files:** Create `FoldForm/AI/Voice/CommandInterpreter.swift`, `RuleBasedInterpreter.swift`; Test `FoldFormTests/RuleBasedInterpreterTests.swift`

**Interfaces:**
- Consumes: `ToolCall`, `ToolContext`, `SpokenNumber`.
- Produces: `struct FinalUtterance: Equatable { let id: UUID; let text: String; init(id:text:) fileprivate(set)… }` (initialiser internal to the speech layer via `FinalUtterance.make(text:)`), `enum InterpretResult: Equatable { case calls([ToolCall]); case clarify(String); case needsImagine }`, `protocol CommandInterpreter: Sendable { func interpret(_ utterance: FinalUtterance, context: ToolContext) async -> InterpretResult }`, `struct RuleBasedInterpreter: CommandInterpreter`

Test phrases (each asserts the exact `ToolCall`s, then `validate` into a `CADAction`):
- "Make a 3 centimeter cube." → `create_cube(size 3, cm)`; "make a cube that's three centimeters wide" same; "make a 30 millimeter cube" → 30 mm (not 3).
- "Create a box 20 by 40 by 5 millimeters." → `create_box(width 20, depth 40, height 5, mm)`.
- "Make a circle with a radius of 12 millimeters." (sketching) → `add_circle(radius 12, mm)`; "diameter" → `diameter`.
- "Create a 4 by 6 centimeter rectangle and extrude it 2 centimeters." → `start_sketch`, `add_rectangle(4,6,cm)`, `extrude(2,cm,add)`.
- "Extrude this by 2 centimeters." while sketching → `extrude`; with nothing to extrude/no sketch and nothing selected → `.clarify("Start a sketch first")`.
- "Move this 10 millimeters to the right." (box selected) → `move_selected(right,10,mm)`; "move it minus 10 millimeters right" → distance -10 flips to left in validation; "move it two centimeters to the right" → 2 cm.
- "Rotate this 45 degrees around Z." → `rotate_selected(45, z)`; "rotate this 90 degrees" → default axis y.
- "Undo that." → `undo`; "redo" → `redo`.
- "Make this box 2 centimeters taller." → `resize_selected(axis y, mode add, 2 cm)`; "make it 5 millimeters thicker" → axis thinnest add; "make this extrusion 15 millimeters deep" → axis thinnest set 15 mm; "change this rectangle to 40 by 60 millimeters" → `resize_selected(width 40, depth 60, set)`.
- "Round these edges by 2 millimeters." → `round_selected(2, mm)`; "chamfer this" → `.clarify` explaining chamfer is unavailable.
- "Add a 5 millimeter hole on this face." → `add_hole(diameter 5, mm)`.
- "Delete this" / "duplicate this".
- With nothing selected: "Fillet that." / "Move this 5 mm up" → `.clarify("Select a part first")`.
- Negation: "do not move it" and "don't create a cube" → `.calls([])`-equivalent `.clarify("Nothing to do")`.
- "Turn this into a phone stand" → `.needsImagine`. Gibberish → `.needsImagine`? No: gibberish → `.clarify("I didn't catch a command")`; only design-intent verbs ("turn into", "design", "add a handle", "generate") → `.needsImagine`.
- [ ] Run: fail. Implement (normalise; split compounds on `and then|then|and` only before a verb keyword; per-clause matchers; camera-relative directions are resolved later by the executor). Run: pass. Commit.

### Task 4: Executor foundation — transactions, redo, selection

**Files:** Modify `FoldForm/RealityViewport.swift` (add `transact`, redo stack, `selectedDocumentBodyID`, `select(documentBodyID:)`, `cameraAxes`), `FoldForm/AppModel.swift` (add `applyBodyEdit(_:label:)`); Test `FoldFormTests/ViewportTransactionTests.swift`

**Interfaces:**
- Produces on `ViewportEntities`: `func transact(_ body: () -> Bool) -> Bool` (snapshot, run, on false restore the snapshot, on true push exactly one undo entry and notify), `func redo()`, `var canRedo: Bool`, `var selectedDocumentBodyID: UUID?`, `func select(documentBodyID: UUID?)`, `var bodyCount`. `undo()` also pushes a redo entry; any new `push` clears redo.
- On `AppModel`: `func applyBodyEdit(_ meshes: [UUID: RenderMesh], label: String)`.

- [ ] Tests (with a bare `AppModel` and a `ViewportEntities` never attached to a RealityView; call `update(appModel:)` to sync): transact success adds one undo step; returning false leaves the document unchanged and adds none; undo then redo restores; a new edit after undo clears redo.
- [ ] Run: fail. Implement. Run: pass; run the full existing suite to confirm undo still behaves. Commit.

### Task 5: CADActionExecutor — bodies

**Files:** Create `FoldForm/AI/Actions/CADActionExecutor.swift`, `MeshTransforms.swift` (`RenderMesh.rotated(by:about:)`); Test `FoldFormTests/CADActionExecutorTests.swift`

**Interfaces:**
- Produces: `@MainActor final class CADActionExecutor { init(appModel: AppModel, viewport: ViewportEntities); func run(_ actions: [CADAction]) -> SequenceResult; func runAtomically(_ actions: [CADAction]) -> SequenceResult }`, `enum ActionResult: Equatable { case done(String); case failed(String) }`, `struct SequenceResult: Equatable { var results: [ActionResult]; var completed: Int; var failure: String? }`

Behaviour and tests:
- `createCube(0.03)` adds one body of 30 mm on each side, placed to the right of the scene, on the scene's base, and selects it. `createBox` and `createCylinder` likewise.
- `move(right, 0.02)` with the new cube selected moves it by exactly 0.02 along the world axis nearest the camera's right vector; a negative distance moves the other way.
- `resize(axis .y, add 0.02)` on a box grows it upward from its base and keeps x/z centre; `.thinnest` set 0.015 on a slab sets its thin side; a cylinder resizes its diameter or height; a rotated ("other") body fails with "This part can't be resized after rotating".
- `rotate(45° about z)` keeps volume and centre, leaves the bounding box larger; the body is now `.other` kind.
- `round(0.002)` on a box changes the mesh and keeps its bounds; radius larger than half the shortest side fails.
- `addHole(diameter 0.005)` subtracts only from the selected body and changes its volume by ≈ π r² × thickness.
- `delete` removes a non-plate body; deleting the plate fails with "The base plate can't be deleted".
- `duplicate` adds a copy beside the original.
- Any edit with no selection fails with "Select a part first" and leaves the document unchanged.
- One `run` of three actions creates exactly one undo step; `viewport.undo()` removes all three effects.
- Created bodies appear in the fold session: `viewport.captureDesign()` contains them (hinge path).
- [ ] Run each new test: fail. Implement. Run: pass. Commit.

### Task 6: CADActionExecutor — sketch, sequences, atomicity

**Files:** Modify `CADActionExecutor.swift`; Test `FoldFormTests/CADSequenceTests.swift`

- `startSketch` begins a sketch; `addRectangle(0.04, 0.06)` adds a centred rectangle shape; `extrude(0.02, add)` adds a 40×60×20 mm body and ends the sketch; `extrude(…, cut)` subtracts into the surface; extruding with no shapes fails "Draw a shape first"; `addCircle`, `addLine(dx,dy)` add shapes; `finishSketch` discards them.
- Compound "rectangle then extrude" is one undo step and produces the expected mesh dimensions.
- `run` stops at the first failing action, keeps earlier effects, reports `completed` and `failure` truthfully, and a second call with the same actions after a failure does not repeat the earlier steps (the session layer owns the utterance ID; this test covers that `run([])` after partial does nothing).
- `runAtomically` with a failing 4th of 5 actions leaves `captureDesign()` identical to before and adds no undo entry.
- [ ] Fail, implement, pass. Commit.

### Task 7: Voice session and captions

**Files:** Create `FoldForm/AI/Voice/SpeechService.swift`, `VoiceCommandSession.swift`, `VoiceCaptionView.swift`; Modify `FoldFormApp.swift` (mic button, caption overlay); Test `FoldFormTests/VoiceCommandSessionTests.swift`

**Interfaces:**
- `enum SpeechEvent: Equatable { case state(SpeechState); case interim(String); case final(FinalUtterance) }`, `enum SpeechState { case idle, listening, finalizing, unavailable(String) }`
- `protocol SpeechService: AnyObject, Sendable { var events: AsyncStream<SpeechEvent> { get }; func start() async; func stop() async; func cancel() async }`
- `final class ScriptedSpeechService: SpeechService` with `emit(_:)` for tests.
- `@MainActor final class VoiceCommandSession: ObservableObject` with `@Published phase: VoicePhase` (`idle, listening(interim), interpreting(text), executing(steps), done(summary), failed(text, message)`), `init(speech:interpreter:executor:contextProvider:)`, `start()`, `stop()`, `cancel()`.

Tests: interim events never call the executor; a final runs the interpreter then the executor; a final with empty or whitespace text does nothing; `cancel` during listening drops a later final; a superseded utterance result (older ID arrives after a newer one started) is dropped; the same `FinalUtterance.id` delivered twice runs once; a failed step shows failure text and keeps earlier steps; the session returns to listening after done (hands-free) until `stop`; `.clarify` shows the message and changes nothing; `.needsImagine` shows "This request needs Imagine" and changes nothing.
- [ ] Fail, implement, pass. Build the caption view and mic button; verify it compiles. Commit.

### Task 8: Model store and Moonshine speech service

**Files:** Modify `project.yml` (Moonshine package, `INFOPLIST_KEY_NSMicrophoneUsageDescription`); Create `FoldForm/AI/Models/ModelStore.swift`, `ModelManifest.swift`, `FoldForm/AI/Voice/MoonshineSpeechService.swift`; Test `FoldFormTests/ModelStoreTests.swift`

- `ModelStore` tests with a `URLProtocol` stub: downloads to a temp dir, reports progress, verifies SHA-256 and refuses a wrong hash (nothing installed), is idempotent, `isInstalled` reflects disk, https only.
- Add the Moonshine package (`moonshine-swift`, from the release the package pins), read its Swift sources to learn the streaming API, and write `MoonshineSpeechService` behind `SpeechService`: AVAudioEngine tap, resample to the model's rate, feed the stream, map line-changed to `.interim` and line-completed to `.final`, audio never written to disk. If the package cannot be added, build a `SpeechService` that reports `.unavailable("Speech model not installed")` and say so.
- [ ] Fail (ModelStore), implement, pass; project builds with the package; commit.

### Task 9: Needle interpreter and composite

**Files:** Create `FoldForm/AI/Voice/NeedleInterpreter.swift`, `CompositeInterpreter.swift`; Test `FoldFormTests/CompositeInterpreterTests.swift`

- `NeedleRuntime` protocol (`isLoaded`, `generate(prompt:tools:) async throws -> String`) so the parser is testable with a fake. `NeedleInterpreter` builds the prompt from `ToolCatalog.schema(for: context)`, parses the `function_calls` JSON into `ToolCall`s, and returns `.needsImagine` for an empty list.
- Tests with a fake runtime: valid JSON → calls; empty list → needsImagine; malformed JSON or a tool not in the current context → falls back (Composite then uses `RuleBasedInterpreter`); a Needle call that fails validation is rejected, not executed.
- Attempt the Cactus build (`apple/build.sh`); if it produces an xcframework, add a `CactusNeedleRuntime`; if not, document why and leave the composite on the rule-based path.
- [ ] Fail, implement, pass, commit.

### Task 10: Imagine plan, validator, NIM client, Keychain

**Files:** Create `FoldForm/AI/Imagine/ImaginePlan.swift`, `ImaginePlanValidator.swift`, `NIMClient.swift`, `KeychainStore.swift`, `ImagineRequest.swift`; Test `FoldFormTests/ImagineTests.swift`, `NIMClientTests.swift`

**Interfaces:**
- `struct ImaginePlan: Codable, Equatable { var assumptions: [Assumption]; var steps: [Step] }`, `Step { as: String?; op: String; args: [String: Double or String]; target: String? }`
- `enum ImagineValidationError: Error, Equatable` (unknown op, missing, invalid number, bad unit, unknown reference, forward reference, too many steps, stale revision, forbidden delete)
- `ImaginePlanValidator.validate(_ plan: ImaginePlan, bodyCount: Int, revision: Int, currentRevision: Int, allowDelete: Bool) throws -> [CADAction]`
- `struct NIMClient { init(session: URLSession, keys: KeyProviding); func generate(_ request: ImagineRequest) async throws -> ImaginePlan }`, `enum NIMError`, `protocol KeyProviding`, `KeychainStore: KeyProviding`

Tests: several valid steps convert in order; unknown op; invalid unit; NaN/infinite/negative size; forward reference; unknown `P9`; missing required field; more than 12 steps; stale revision; `delete` without `allowDelete`; `delete` of `P0` (the plate) rejected; assumptions are decoded and preserved; JSON wrapped in a markdown code fence is accepted; extra unknown fields ignored. NIM client with stubbed `URLProtocol`: request URL is the https NVIDIA URL, `Authorization: Bearer <key>` header, key not in the body, body has an `image_url` data URL and the prompt, a 401 maps to `.unauthorized`, a URLError offline maps to `.offline`, a timeout maps to `.timedOut`, cancelling the task cancels the request, a missing key fails before any request. `KeychainStore`: save, read, delete round trip (skipped if the Keychain is unavailable on the test host).
- [ ] Fail, implement, pass, commit.

### Task 11: Imagine executor and UI

**Files:** Create `FoldForm/AI/Imagine/ImagineSession.swift`, `ImagineView.swift`, `SketchCanvas.swift`; Modify `FoldFormApp.swift` (Imagine button and sheet), `RealityViewport.swift` (`aiHighlightIDs` tint, revision accessor); Test `FoldFormTests/ImagineSessionTests.swift`

- `ImagineSession` (`@MainActor ObservableObject`): phases `idle, readingSketch, planning, building(done,total), done(summary, assumptions), failed(message)`; builds the `ImagineRequest` (document revision, symbolic bodies from `DesignScene`, ThumbnailRenderer PNG), calls an injected `ImagineGenerating` (the NIM client, or a fake in tests), validates, and runs `runAtomically`. `cancel()` cancels the request.
- Tests with a fake generator: a good plan adds bodies and one undo step removes them all; a plan that fails at step 3 leaves the document unchanged; a document edit between request and reply produces a stale error and no change; a reply targeting `P1` edits only that body and preserves the others (delta); offline error is reported and the document is unchanged; nothing is sent until `generate()` is called (fake counts calls); `cancel()` mid-request applies nothing.
- UI: canvas draws strokes, keeps normalised polylines and renders a PNG; live caption from the speech service; prompt field; cloud notice; Generate; progress from real phases; assumptions list; ✦ highlight of new bodies that clears on the next action; key entry field.
- [ ] Fail, implement, pass, build the UI, commit.

### Task 12: Hygiene, docs, review

- Test: no source file contains `nvapi-` or an `Authorization` literal with a key; run it.
- Update `docs/features.md`, `controls.md`, `architecture.md`, `README.md`; add a memory note.
- Run the whole test suite; fix anything red. Self-review the diff against the Review Focus list. Commit.
