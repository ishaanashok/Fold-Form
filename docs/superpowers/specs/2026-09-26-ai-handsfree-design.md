# FoldForm voice and Imagine

> Later provider change: the user replaced NVIDIA NIM with OpenAI. The
> [OpenAI Imagine amendment](2026-09-26-openai-imagine-amendment.md) supersedes the provider-specific
> sections below.
> The user's later [Apple voice amendment](2026-09-26-apple-voice-amendment.md) supersedes the
> Moonshine and Needle voice implementation below.

Status: approved design direction. Date: 2026-09-26.
Source product spec: `FOLDFORM_AI_HANDSFREE_SPEC.md` (in the user's Downloads folder). This document
is how that spec is built on the real FoldForm code, and where it is deliberately narrower.

## Goal

Add two input methods next to touch and the hinge, all feeding one editable document:

- **Voice.** Live on-device transcription, an on-device interpreter turns a finished sentence into
  CAD actions, the app validates and runs them.
- **Imagine.** A sketch plus a spoken or typed description, sent to GLM-5.3-Flash on NVIDIA NIM only
  when the user presses Generate. The reply is a validated plan of ordinary FoldForm edits, applied
  as a delta to what exists.

## Decisions already made

- The interpreter is a `CommandInterpreter` protocol. A **rule-based interpreter ships and is fully
  tested**; **Needle 3 through Cactus** plugs into the same protocol when its runtime builds. If it
  cannot be built, the rule-based one stays the local path and this is reported, not hidden.
- Model files (Moonshine, Needle) are **downloaded on first use** into Application Support, with
  progress and a hash check, then work offline.
- No face or edge picking. "Round these edges" rounds the selected body.
- Rotating a body makes it an irregular solid: it can still move, be deleted, rounded or holed, but
  not resized by dimension.
- The NVIDIA key is entered by the user in the app and kept in the Keychain. It is never in the repo.

## Reality of the FoldForm document (why this is narrower than the product spec)

A feature in FoldForm is a mesh-backed viewport body (`ViewportSolidFeature`, `ViewportCutFeature`,
`ViewportTouchUpFeature`). There are no stored sketches after an extrude, no per-face or per-edge
identity, and the corner style is global. So:

| Product spec says | Built as |
| --- | --- |
| create cube / box / cylinder | a new body (`ViewportSolidFeature`) |
| start sketch, add rectangle / circle / line, finish | the existing `SketchController`; finishing without extruding discards the shapes, exactly as the Done button does |
| extrude selected profile, add or cut | extrude the sketch profiles (add) or cut them into the material |
| move, rotate | replace the body mesh through a `ViewportTouchUpFeature` |
| resize / set a dimension / "make this extrusion 15 mm deep" | rebuild a box or cylinder body from new bounds (`DesignPart.rebuilt`); a thin box's extrusion depth is its thinnest side |
| fillet / chamfer | round the selected body's corners (`DesignPart.roundedMesh`); chamfer is reported as unsupported |
| hole | subtract a cylinder from the selected body only, through its thinnest axis |
| duplicate, delete, undo, redo | existing behaviour; redo is new |
| "this" | the currently selected body; a body just created by an action becomes selected |

## Architecture

```
speech ──► FinalUtterance ──► CommandInterpreter ──► [ToolCall] ──► ToolCatalog.validate ──► [CADAction]
                                                                                              │
Imagine ──► GLM JSON ──► ImaginePlan ──► ImaginePlanValidator ──► [CADAction] ────────────────┤
                                                                                              ▼
                                       CADActionExecutor ──► AppModel (document) ──► ViewportEntities (fold session)
```

Everything ends as document bodies, so folding, hinge, undo, autosave and export are unchanged.

### CAD action layer (`FoldForm/AI/Actions/`)

- **`Quantity`** turns a number and a unit word into metres (`mm cm m in`, plus spoken aliases) and a
  number and `degrees` into radians. All unit handling lives here, never in a model.
- **`CADAction`**, a typed enum: `createCube`, `createBox`, `createCylinder`, `startSketch`,
  `addRectangle`, `addCircle`, `addLine`, `finishSketch`, `extrude(distance, cut)`, `resize`,
  `move`, `rotate`, `round`, `addHole`, `duplicate`, `delete`, `undo`, `redo`.
  Targets are `.selected` or (for Imagine) a symbolic `BodyRef`.
- **`ToolCatalog`** describes every tool (name, typed parameters, which states expose it),
  produces the JSON-schema list a model is shown, and validates a `ToolCall` (name plus loosely
  typed arguments) into a `CADAction` or a `ToolError`. Rule-based and Needle both emit `ToolCall`s,
  so both go through the same validation.
- **`CADActionExecutor`** (`@MainActor`) runs actions against `AppModel` and `ViewportEntities`.
  It resolves the target, checks preconditions, edits the document, and returns an
  `ActionResult` (`done(summary)` or `failed(reason)`). `run(_ actions:)` executes in order, stops at
  the first failure, and reports how many steps completed. One utterance or plan is **one undo step**.
  `runAtomically` (Imagine) validates the whole list first and rolls the document back if any step fails.
- `ViewportEntities` gains `transact` (snapshot, run, roll back on failure, push one undo entry), a
  redo stack, a selected-body accessor in document IDs, and `select(documentBodyID:)`.

### Voice (`FoldForm/AI/Voice/`)

- **`SpeechService`** protocol: `start()`, `stop()`, `cancel()`, and an `AsyncStream<SpeechEvent>` of
  `.state`, `.interim(String)`, `.final(FinalUtterance)`. `MoonshineSpeechService` (AVAudioEngine into
  a Moonshine stream) and `ScriptedSpeechService` (tests, and DEBUG demos).
- **`FinalUtterance`** has an ID and can only be created by a speech service on a final event. The
  interpreter's only input type is `FinalUtterance`, so interim text cannot execute by construction.
- **`VoiceCommandSession`** (`@MainActor ObservableObject`) is the state machine: idle, listening,
  finalizing, interpreting, executing (per-step status), done, failed. It ignores empty or
  noise-only finals, drops results for an utterance that has been superseded or cancelled, never runs
  the same utterance ID twice, and keeps the mic on between utterances until Stop.
- **`VoiceCaptionView`** shows a compact caption at the bottom (dim interim words, then the list of
  real steps with ✓ / … / ✕). A mic button joins the HUD; Stop is always visible while listening.
- **`CommandInterpreter`** protocol: `interpret(_:context:) async -> InterpretResult` where the result
  is `.calls([ToolCall])`, `.clarify(String)` or `.needsImagine`.
  - **`RuleBasedInterpreter`**: spoken numbers, decimals, negatives ("minus", "negative"), units,
    directions relative to the camera ("right" is the camera's right, snapped to the nearest world axis),
    comparatives ("taller", "thicker"), compound sentences split on "and", "then", "and then".
  - **`NeedleInterpreter`**: Cactus-hosted Needle 3, given only the tools valid in the current state.
    Its JSON is parsed into `ToolCall`s and validated exactly like the rule-based output.
  - **`CompositeInterpreter`** tries Needle (when loaded), and falls back to the rule-based one.
- **`ToolContext`** is the small state a model may see: sketching or not, whether a body is selected
  and its kind, default unit, undo and redo availability. Nothing else.
- Ambiguity: an edit with nothing selected answers "Select a part first"; a request outside the tool
  set answers "This request needs Imagine". Nothing goes to the network from this path.

### Model files (`FoldForm/AI/Models/`)

`ModelStore` downloads a model to `Application Support/FoldForm/Models/<name>/`, streams progress,
verifies a SHA-256 taken from a manifest, and is the only type that knows the paths. The manifest
(URLs, sizes, hashes) lives in one Swift file and is filled in when the files are located; the app
shows "Voice model not installed" with a Download button until then. No download happens at build
or test time.

### Imagine (`FoldForm/AI/Imagine/`)

- **`ImagineView`**: a sheet with a freehand canvas (strokes kept as normalised vector polylines and
  rendered to a PNG), a live caption from the same speech service, an editable prompt, a visible
  "Sends your sketch and text to NVIDIA" notice, and a Generate button. Nothing is sent before Generate.
- **`ImagineRequest`** carries the prompt, the sketch PNG and polylines, units, a headless render of the
  current design (`ThumbnailRenderer`), `DesignScene.description` with the symbolic names `P0…Pn`,
  the selected body's name, and the document revision.
- **`NIMClient`**: HTTPS to `https://integrate.api.nvidia.com/v1/chat/completions`, model
  `z-ai/glm-5.3-flash`, OpenAI-style messages with a base64 `image_url`, 90 s timeout, cancellable,
  `Authorization: Bearer` from `KeychainStore`. Errors are typed: offline, unauthorised, timeout,
  bad status, unreadable reply. The exact body is confirmed with one real call once the user has a key;
  until then it is built to the documented OpenAI-compatible shape and tested with a stubbed
  `URLProtocol`.
- **`ImaginePlan`** (Codable): `assumptions: [{name, value, unit}]` and at most 12 `steps`. A step has an
  optional `as` name and an `op` from a fixed list (`add_box`, `add_cylinder`, `extrude_profile`,
  `move`, `resize`, `rotate`, `round`, `add_hole`, `delete`) with typed arguments and a `target`
  that is either `P<n>` (existing) or the `as` name of an earlier step.
- **`ImaginePlanValidator`** (pure): unknown op, missing or mistyped argument, bad unit, non-finite or
  out-of-range number, unknown or forward reference, too many steps, `delete` without the user having
  asked to remove something, and a stale document revision are all rejected before anything runs.
- **Execution** converts steps to `CADAction`s and runs them with `runAtomically`. New bodies are
  tinted ✦ temporarily and listed; assumptions are shown. A failure rolls everything back and says so.

### Keys and privacy

`KeychainStore` wraps the Keychain. The settings field for the key lives in Imagine. A repo test
greps the source for key-shaped strings (`nvapi-`). Raw audio is never written to disk. Interim
speech never leaves the device. Model output is untrusted: it is decoded into typed values only.

## Testing

Unit tests only, no live simulator UI runs. Covered: `Quantity`; every §21.1 example phrase through the
rule-based interpreter including "3 vs 30", "mm vs cm", "minus", decimals, "do not"; the
`ToolCatalog` validator; the executor (create, resize, move, rotate, round, hole, delete, duplicate,
undo, redo, missing selection, plate delete rejected, one undo per utterance); compound stop-on-failure and
truthful partial results; the voice session (interim never executes, cancel, silence, superseded
utterance, no duplicate on retry); plan validation (§21.4) and rollback; delta preservation and a stale
revision; the NIM client with a stubbed `URLProtocol` (HTTPS only, bearer header, cancellation, error
mapping, the key is never in the body); no key strings in the source; and that created bodies appear in
the `FoldSession` (hinge path).

**Not verifiable here, and reported as such:** the microphone, Moonshine and Needle on a device,
real GLM output quality, and on-device look and feel.

## Risks

- **Cactus/Needle integration is undocumented.** Mitigated by the protocol and the rule-based path.
- **Moonshine's streaming API** must be learned from its source. The service is isolated behind
  `SpeechService`, so a wrong guess costs one file.
- **Model download URLs and hashes** are not known yet. Until they are, the download UI shows a
  clear "not installed" state, and speech uses the scripted service in tests only.
- **Rotated bodies become non-resizable**, and the feature list after reopening stays flat.
- **GLM may return bad plans.** The validator and rollback are the defence, and the UI never claims
  success after a failure.
