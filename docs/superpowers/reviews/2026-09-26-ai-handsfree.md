# Voice and Imagine review

Reviewed against the approved spec and the plan's five Review Focus items after integrating Tasks
1–12. The full simulator unit suite and the host credential test are the required gates.

| Focus | Pinning tests | Review result |
| --- | --- | --- |
| Interim speech, stale finals and duplicates never execute | `VoiceCommandSessionTests.testInterimTextNeverRunsACommand`, `testAnOlderResultArrivingAfterANewerUtteranceStartedIsDropped`, `testTheSameUtteranceDeliveredTwiceRunsOnce`, `testStopExecutesTheLastSentenceFlushedBeforeIdle` | Only `SpeechEvent.final(FinalUtterance)` reaches `CommandInterpreter`; interim text changes the caption only. Session IDs gate delayed and repeated results, while Stop preserves a flushed final sentence. |
| `3`/`30`, mm/cm and negative signs keep their meaning | `QuantityTests.testThreeAndThirtyAreNotConfused`, `testLengthUnitsConvertToMetres`, `testSpokenNegatives`; `RuleBasedInterpreterTests.testNegativeMoveFlipsDirection`; `ImagineTests.testMissingAndBadUnitsAreRejected` | Every action length is converted by `Quantity`; Imagine now requires an explicit unit on every length step. |
| A failure at step 4 of 5 leaves no partial document or undo entry | `CADSequenceTests.testAnAtomicPlanWithAFailingFourthOfFiveLeavesEverythingAsItWas`; `ImagineSessionTests.testFailureAtThirdStepRollsBackAllBodiesAndAddsNoUndoEntry` | Imagine uses `runAtomically`, which restores the document, fold state and selection when an action fails. |
| A stale Imagine reply is rejected | `ImagineTests.testStaleRevisionRejectsThePlanBeforeApplyingIt`; `ImagineSessionTests.testStaleReplyAfterDocumentEditIsRejected` | The request captures `documentRevision`, which advances on committed edits, undo and redo. Session checks it again before the atomic run. |
| Hostile or malformed GLM output cannot touch the design | `ImagineTests.testUnknownOperationIsRejected`, `testNonFiniteNegativeAndHugeDimensionsAreRejected`, `testForwardAndUnknownReferencesAreRejected`, `testMoreThanTwelveStepsAreRejected`, `testDeleteRequiresPermissionAndNeverDeletesTheBasePlate`; `ImagineSessionTests.testFailureAtThirdStepRollsBackAllBodiesAndAddsNoUndoEntry` | JSON is decoded into typed values, validated without mutation, then run atomically. Bad references and plate deletion are refused. |

Additional boundary tests cover NIM HTTPS and bearer placement, no key in the body, missing key,
unauthorized/offline/timeout errors, URLSession cancellation, Keychain round-trip, hash refusal
before Moonshine opens the microphone, and the separate host scan for embedded credentials.

The simulator unit tests do not exercise microphone hardware, Moonshine recognition quality,
Needle/Cactus on a device, a keyed GLM reply, or the visual feel of the new sheet and caption.
