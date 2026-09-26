# Voice and Imagine implementation rulings

The design spec remains the authority. These rulings record places where the 12-task plan or
handoff snapshot did not exactly match the integrated implementation.

| Ruling | Reason | Cost if wrong |
| --- | --- | --- |
| Treat Tasks 7–9 as already committed, then verify their tests and review their code before continuing. | The handoff's §5 snapshot was older than the branch: those three commits were already present and the tree was clean except for the untracked handoff. | A missed defect in those commits could survive; the Task 12 review found and corrected Moonshine's unverified download path. |
| Keep the local composite rules-first, asking Needle only when rules cannot parse a sentence. | The integrated Needle tests found valid but wrong tool choices for known phrases; a wrong CAD action is more costly than asking the user to rephrase. | Some novel phrasing that Needle could handle may receive a clarification instead. |
| Let Moonshine's `MicTranscriber` own AVAudioEngine capture, conversion and streaming. | The package already implements the specified audio pipeline; FoldForm maps only changing and completed lines to its speech events. | Device-specific latency or capture behavior remains unverified until tested on hardware. |
| Install Moonshine's versioned model files through `ModelStore` before calling `MicTranscriber.load()`. | The package's automatic downloader checks presence and size but does not enforce the spec's SHA-256 requirement. Hashes were computed from the eight published files and pinned in `MoonshineModel`. | A new upstream model revision needs a deliberate manifest and hash update before it can load. |
| Make the microphone tap initiate the first model download, with caption progress, instead of adding a separate Download button. | The spec also says models download on first use, and the 12-task plan defines no separate download control. The mic tap is the user's explicit first-use action. | A user who wants the weights in advance cannot preload them without starting voice control. |
| Keep file hashes and URLs in the manifest without expected byte counts. | SHA-256 already rejects truncated or changed bytes, including wrong-length files; the plan's `ModelStore` tests focus on that stronger integrity check. | Download progress uses the server's content length rather than a pinned size, so a server that omits it shows progress by completed file count. |
| Use the official prebuilt Cactus/Needle iOS static framework instead of rebuilding `apple/build.sh` here. | The branch already contained a linked, hash-documented framework from the pinned upstream release, and its engine tests passed. | This turn did not reproduce the framework from source; on-device execution still needs verification. |
| Require an explicit unit on every Imagine length step and send the editor's current unit in the request. | A missing unit could silently turn centimetres into millimetres or vice versa. | A GLM plan that omits units is rejected and the user must generate again. |
| Use the documented OpenAI-compatible NIM chat body and test it with a URLProtocol stub; leave the live call unverified. | No NVIDIA key was provided, and a real call is the only way to confirm this endpoint's exact response with GLM-5.3-Flash. | A response-shape mismatch may require an adapter change after a keyed device test. |
| Run source-credential hygiene as a host-side test script alongside XCTest. | The simulator test host stalled while trying to read the checkout's source path; the host script can inspect the real Swift files and self-tests its scanner. | The script must be run as a separate gate when testing outside this workflow. |

## Later OpenAI provider change

The user replaced the NVIDIA NIM requirement with an OpenAI API key after Tasks 1–12 were complete.
The [provider amendment](../specs/2026-09-26-openai-imagine-amendment.md) supersedes the NIM-specific
parts of the earlier design and plan.

| Ruling | Reason | Cost if wrong |
| --- | --- | --- |
| Use GPT-6 Sol through OpenAI Chat Completions, keeping `ImagineGenerating` and plan validation. | The existing client already packages two PNGs and text as Chat Completions content; official OpenAI documentation confirms image inputs and the model's endpoint. | Model behavior and pricing differ from GLM; CAD plan quality needs real designs to evaluate. |
| Use a new `openai-imagine` Keychain account. | A prior NVIDIA credential must never be mistaken for an OpenAI credential. | Existing users must save their OpenAI key once. |
| Omit Cactus/Needle on x86_64 simulators and retain rule-based voice parsing. | The vendored xcframework has only arm64 device and simulator slices; the x86_64 linker could not use it. | Needle-specific interpretation is unavailable in that simulator architecture until an x86_64 slice is supplied. |
| Open Imagine with a finished creative voice transcript prefilled, then wait for Generate. | “Make a table” is a multi-part design request, not a primitive CAD tool call; the user chose a review step before cloud use. | A spoken creative request requires one tap to generate, and objects outside the local creative-noun vocabulary may still need the Sparkles button. |

## Later Apple voice replacement

The user's later request to use Apple dictation and developer APIs supersedes the Moonshine and
Needle decisions above. See the [Apple voice amendment](../specs/2026-09-26-apple-voice-amendment.md).

| Ruling | Reason | Cost if wrong |
| --- | --- | --- |
| Use `SFSpeechRecognizer` with `requiresOnDeviceRecognition` and refuse a recognizer without on-device support. | Apple's Speech framework uses the system dictation models and this recognizer compiles for the available iOS 27.1 SDK. The microphone is segmented at pauses to deliver final utterances. | Language availability and finalization timing need device testing; unsupported locales cannot use voice. |
| Use Foundation Models for unfamiliar command phrasing, with rules first and typed tool validation after. | It is an on-device Apple model with structured generation and availability reporting. Known CAD commands stay deterministic. | The system model may be unavailable on some devices, where unfamiliar phrases still need clarification. |
| Retire the Moonshine package, Needle framework link, and downloadable model store. | They are no longer part of the requested architecture and the Needle binary failed to link for x86_64. | Apple platform support now determines voice availability; third-party models are no longer a fallback. |
