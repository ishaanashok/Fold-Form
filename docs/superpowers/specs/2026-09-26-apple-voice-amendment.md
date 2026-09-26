# Apple voice implementation amendment

The user replaced Moonshine transcription and the Cactus/Needle interpreter with Apple dictation
and Apple developer APIs. This amendment supersedes the speech and interpreter implementation
sections of the original [hands-free design](2026-09-26-ai-handsfree-design.md). The typed CAD action
layer, final-only execution boundary, Imagine review step, and explicit Generate boundary remain.

`AppleDictationSpeechService` captures microphone buffers with `AVAudioEngine` and sends them to
`SFSpeechRecognizer` using its dictation hint. It requires on-device recognition and reports voice
unavailable when that capability or permission is missing. Partial recognition updates only the
caption. A pause ends the audio request; only a final Apple result becomes a `FinalUtterance`.
Stopping waits briefly for that final result. No recorded audio or transcript is sent to a server by
this voice path.

`RuleBasedInterpreter` handles known commands first. When it cannot parse a finished sentence,
`AppleFoundationCommandModel` asks the available on-device system language model for structured
CAD tool proposals. `ToolCatalog` validates the proposed sequence, and a second guard requires the
tool intent and every numeric value to be grounded in the spoken sentence. An unavailable model,
invalid proposal or unrelated speech leaves the rule parser's clarification in place. A finished
creative request such as “make a table” opens Imagine with that text ready for review. Only tapping
Generate invokes the separate OpenAI client.

The retired Moonshine package, Needle binary link and model-download setup are absent from the
project configuration. Unit tests inject fake speech and model responses; they do not access the
microphone or network. Microphone behavior and language-model availability still need verification
on a supported device.

Apple references: [Speech framework](https://developer.apple.com/documentation/speech/),
[on-device recognition requirement](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition),
[Speech permission](https://developer.apple.com/documentation/speech/asking-permission-to-use-speech-recognition),
[Foundation Models availability](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel),
and [guided generation](https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation).
