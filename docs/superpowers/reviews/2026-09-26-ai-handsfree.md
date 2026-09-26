# Voice and Imagine review

Reviewed against the approved spec and the plan's five Review Focus items after integrating Tasks
1–12. The full simulator unit suite and the host credential test are the required gates.

| Focus | Pinning tests | Review result |
| --- | --- | --- |
| Interim speech, stale finals and duplicates never execute | `AppleSpeechResultRouterTests.testOnlyAFinalResultCanBecomeAnExecutableUtterance`, `testARecognitionSegmentCanBeFinishedOnlyOnce`; `VoiceCommandSessionTests.testInterimTextNeverRunsACommand`, `testAnOlderResultArrivingAfterANewerUtteranceStartedIsDropped`, `testTheSameUtteranceDeliveredTwiceRunsOnce`, `testStopExecutesTheLastSentenceFlushedBeforeIdle` | Only Apple's final result becomes `SpeechEvent.final(FinalUtterance)`; interim text changes the caption only. Session IDs gate delayed and repeated results, while Stop preserves a flushed final sentence. |
| `3`/`30`, mm/cm and negative signs keep their meaning | `QuantityTests.testThreeAndThirtyAreNotConfused`, `testLengthUnitsConvertToMetres`, `testSpokenNegatives`; `RuleBasedInterpreterTests.testNegativeMoveFlipsDirection`; `ImagineTests.testMissingAndBadUnitsAreRejected` | Every action length is converted by `Quantity`; Imagine now requires an explicit unit on every length step. |
| A failure at step 4 of 5 leaves no partial document or undo entry | `CADSequenceTests.testAnAtomicPlanWithAFailingFourthOfFiveLeavesEverythingAsItWas`; `ImagineSessionTests.testFailureAtThirdStepRollsBackAllBodiesAndAddsNoUndoEntry` | Imagine uses `runAtomically`, which restores the document, fold state and selection when an action fails. |
| A stale Imagine reply is rejected | `ImagineTests.testStaleRevisionRejectsThePlanBeforeApplyingIt`; `ImagineSessionTests.testStaleReplyAfterDocumentEditIsRejected` | The request captures `documentRevision`, which advances on committed edits, undo and redo. Session checks it again before the atomic run. |
| Hostile or malformed model output cannot touch the design | `ImagineTests.testUnknownOperationIsRejected`, `testNonFiniteNegativeAndHugeDimensionsAreRejected`, `testForwardAndUnknownReferencesAreRejected`, `testMoreThanTwelveStepsAreRejected`, `testDeleteRequiresPermissionAndNeverDeletesTheBasePlate`; `ImagineSessionTests.testFailureAtThirdStepRollsBackAllBodiesAndAddsNoUndoEntry` | JSON is decoded into typed values, validated without mutation, then run atomically. Bad references and plate deletion are refused. |

Additional boundary tests cover OpenAI HTTPS and bearer placement, no key in the body, missing key,
unauthorized/offline/timeout errors, URLSession cancellation, Keychain round-trip, Apple model
proposal validation, and the separate host scan for embedded credentials.

After the [Apple voice replacement](../specs/2026-09-26-apple-voice-amendment.md) and Imagine
correction path, the full simulator suite passed 393 tests with no failures. Bitrig's simulator build,
an earlier no-signing iOS device build, and the host credential scanner passed. Unit tests do not
exercise microphone hardware,
Apple dictation quality, Foundation Models availability on a device, a complete keyed CAD-plan reply,
or the on-device visual feel of the sheet and caption.
