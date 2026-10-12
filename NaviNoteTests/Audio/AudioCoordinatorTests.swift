import Foundation
import Testing
@testable import NaviNote

@MainActor
@Suite("Audio coordinator: permissions and listening")
struct AudioListeningTests {
    @Test func launchNeverListensOrAsksForPermission() async {
        let h = AudioHarness(microphone: .notDetermined, speech: .notDetermined)
        await drainMainActor()
        #expect(h.coordinator.state == .idle)
        #expect(h.recognizer.startCount == 0)
        #expect(h.permissions.microphoneRequests == 0)
        #expect(h.permissions.speechRequests == 0)
        #expect(h.session.listeningActivations == 0)
    }

    @Test func grantedPermissionsStartListeningAfterTalk() async {
        let h = AudioHarness(microphone: .notDetermined, speech: .notDetermined)
        h.coordinator.talkPressed()
        #expect(h.coordinator.state == .requestingPermission)
        await eventually { h.coordinator.state == .listening }
        #expect(h.coordinator.state == .listening)
        #expect(h.permissions.microphoneRequests == 1)
        #expect(h.permissions.speechRequests == 1)
        #expect(h.session.listeningActivations == 1)
        #expect(h.recognizer.startCount == 1)
    }

    @Test func microphoneDeniedNeverStartsRecognitionOrAsksForSpeech() async {
        let h = AudioHarness(microphone: .notDetermined, speech: .notDetermined)
        h.permissions.microphoneAnswer = .denied
        h.coordinator.talkPressed()
        await eventually { h.coordinator.state == .permissionDenied(.microphone) }
        #expect(h.coordinator.state == .permissionDenied(.microphone))
        #expect(h.permissions.speechRequests == 0, "Speech recognition permission is handled separately")
        #expect(h.recognizer.startCount == 0)
        await eventually { !h.synthesizer.spoken.isEmpty }
        #expect(h.synthesizer.spoken.joined(separator: " ").contains("Microphone access is off"))
    }

    @Test func speechRecognitionDeniedAfterMicrophoneGranted() async {
        let h = AudioHarness(microphone: .granted, speech: .notDetermined)
        h.permissions.speechAnswer = .denied
        h.coordinator.talkPressed()
        await eventually { h.coordinator.state == .permissionDenied(.speechRecognition) }
        #expect(h.coordinator.state == .permissionDenied(.speechRecognition))
        #expect(h.permissions.microphoneRequests == 0, "Already granted; not asked again")
        #expect(h.recognizer.startCount == 0)
    }

    @Test func restrictedPermissionIsExplained() async {
        let h = AudioHarness(speech: .restricted)
        h.coordinator.talkPressed()
        await eventually { h.coordinator.state == .permissionDenied(.speechRecognition) }
        await eventually { !h.synthesizer.spoken.isEmpty }
        #expect(h.synthesizer.spoken.joined(separator: " ").contains("restricted"))
        #expect(h.permissions.speechRequests == 0, "A restricted permission can't be requested")
    }

    @Test func deniedStateRechecksWhenTalkIsPressedAgain() async {
        let h = AudioHarness(microphone: .denied)
        h.coordinator.talkPressed()
        await eventually { h.coordinator.state == .permissionDenied(.microphone) }
        h.permissions.microphoneStatus = .granted // allowed in Settings meanwhile
        await h.startListening()
        #expect(h.recognizer.startCount == 1)
    }

    @Test func unavailableRecognizerIsReported() async {
        let h = AudioHarness()
        h.recognizer.isAvailable = false
        h.coordinator.talkPressed()
        await eventually { h.coordinator.state == .unavailable(.recognizerUnavailable) }
        #expect(h.coordinator.state == .unavailable(.recognizerUnavailable))
        #expect(h.recognizer.startCount == 0)
        #expect(h.session.listeningActivations == 0)
    }

    @Test func talkTwiceStopsListeningAndUsesTheFinalResult() async {
        let h = AudioHarness()
        await h.startListening()
        h.recognizer.finalOnFinish = "start checkout"
        h.coordinator.talkPressed()
        await eventually { h.transcripts.received.count == 1 }
        #expect(h.recognizer.finishCount == 1)
        #expect(h.transcripts.received.map(\.text) == ["start checkout"])
        #expect(h.transcripts.received.first?.generation == h.coordinator.generation)
        #expect(h.coordinator.state == .idle)
        #expect(h.recognizer.cancelCount >= 1, "The recognition task is torn down")
        #expect(h.log.entries.last == "session.deactivate")
    }

    @Test func partialResultsAreDisplayOnlyAndFinalResultsBecomeCommands() async {
        let h = AudioHarness()
        await h.startListening()
        h.recognizer.emit(.partial("start che"))
        await eventually { h.coordinator.partialTranscript == "start che" }
        #expect(h.coordinator.partialTranscript == "start che")
        #expect(h.transcripts.received.isEmpty, "Partial text is never a command")

        h.recognizer.emit(.final("start checkout"))
        await eventually { !h.transcripts.received.isEmpty }
        #expect(h.transcripts.received.map(\.text) == ["start checkout"])
        #expect(h.coordinator.partialTranscript.isEmpty)
    }

    @Test func duplicateFinalCallbacksAreDeliveredOnce() async {
        let h = AudioHarness()
        await h.startListening()
        h.recognizer.emit(.final("repeat"))
        h.recognizer.emit(.final("repeat"))
        h.recognizer.emit(.ended)
        await drainMainActor()
        #expect(h.transcripts.received.count == 1)
    }

    @Test func rapidTalkPressesStartOneRecognitionTask() async {
        let h = AudioHarness(microphone: .notDetermined)
        h.coordinator.talkPressed()
        h.coordinator.talkPressed()
        h.coordinator.talkPressed()
        await eventually { h.coordinator.state == .listening }
        await drainMainActor()
        #expect(h.recognizer.startCount == 1)
        #expect(h.permissions.microphoneRequests == 1)
    }

    @Test func emptyOrMissingFinalIsNotACommand() async {
        let h = AudioHarness()
        await h.startListening()
        h.recognizer.emit(.final("   "))
        await eventually { h.coordinator.state == .idle }
        #expect(h.transcripts.received.isEmpty)

        await h.startListening()
        h.recognizer.emit(.ended)
        await eventually { h.coordinator.state == .idle }
        #expect(h.transcripts.received.isEmpty)
    }
}

@MainActor
@Suite("Audio coordinator: speech output")
struct AudioSpeechTests {
    @Test func recognitionStopsCompletelyBeforeSpeaking() async {
        let h = AudioHarness()
        await h.startListening()
        h.coordinator.announce("Total confirmed.", kind: .update)
        await eventually { h.synthesizer.spoken.count == 1 }

        let cancel = h.log.index(of: "recognizer.cancel")
        let speakingSession = h.log.index(of: "session.speaking")
        let speak = h.log.index(of: "synth.speak")
        #expect(cancel != nil && speakingSession != nil && speak != nil)
        #expect(cancel! < speakingSession!)
        #expect(speakingSession! < speak!)

        // Anything the recognizer reports afterwards is ignored.
        h.recognizer.emit(.final("yes"))
        await drainMainActor()
        #expect(h.transcripts.received.isEmpty)
    }

    @Test func multiSentenceMessagesAreQueuedInOrder() async {
        let h = AudioHarness()
        h.coordinator.announce("One. Two costs 12.50 dollars. Three!", kind: .update)
        h.coordinator.announce("Four.", kind: .update)
        await eventually { h.synthesizer.spoken.count == 4 }
        #expect(h.synthesizer.spoken == ["One.", "Two costs 12.50 dollars.", "Three!", "Four."])
        await eventually { h.coordinator.state == .idle }
        #expect(h.coordinator.state == .idle)
    }

    @Test func theSessionIsPreparedOncePerMessageNotPerSentence() async {
        let h = AudioHarness()
        h.coordinator.announce("First sentence. Second sentence. Third sentence.", kind: .update)
        await eventually { h.synthesizer.spoken.count == 3 }
        await eventually { h.coordinator.state == .idle }
        #expect(h.session.speakingActivations == 1)

        h.coordinator.announce("Another message. With two sentences.", kind: .update)
        await eventually { h.synthesizer.spoken.count == 5 }
        #expect(h.session.speakingActivations == 2)
    }

    @Test func speakingStateWhileSpeaking() async {
        let h = AudioHarness()
        h.synthesizer.mode = .manual
        h.coordinator.announce("Hello there.", kind: .update)
        await eventually { h.synthesizer.isSpeakingChunk }
        #expect(h.coordinator.state == .speaking)
        h.synthesizer.completeCurrent()
        await eventually { h.coordinator.state == .idle }
        #expect(h.log.entries.last == "session.deactivate")
    }

    @Test func aScreenChangeDropsOutOfDateSpeech() async {
        let h = AudioHarness()
        h.synthesizer.mode = .manual
        h.coordinator.announce("Old one. Old two.", kind: .update)
        await eventually { h.synthesizer.isSpeakingChunk }
        h.coordinator.announce("Stale queued.", kind: .update)
        h.coordinator.announce("New screen.", kind: .screenChange)
        h.synthesizer.completeCurrent()
        await eventually { h.synthesizer.spoken.count == 2 }
        h.synthesizer.completeCurrent()
        await eventually { h.coordinator.state == .idle }
        #expect(h.synthesizer.spoken == ["Old one.", "New screen."])
    }

    @Test func duplicateAnnouncementsAreSpokenOnceButRepeatAlwaysSpeaks() async {
        let h = AudioHarness()
        h.coordinator.announce("Cancelled.", kind: .update)
        h.coordinator.announce("Cancelled.", kind: .update)
        await eventually { h.coordinator.state == .idle && !h.synthesizer.spoken.isEmpty }
        #expect(h.synthesizer.spoken == ["Cancelled."])

        h.coordinator.announce("Cancelled.", kind: .repeatRequest)
        await eventually { h.synthesizer.spoken.count == 2 }
        #expect(h.synthesizer.spoken.count == 2)

        h.clock.advance(2)
        h.coordinator.announce("Cancelled.", kind: .update)
        await eventually { h.synthesizer.spoken.count == 3 }
        #expect(h.synthesizer.spoken.count == 3)
    }

    @Test func talkWhileSpeakingStopsSpeechThenListens() async {
        let h = AudioHarness()
        h.synthesizer.mode = .manual
        h.coordinator.announce("A long message. With more.", kind: .update)
        await eventually { h.synthesizer.isSpeakingChunk }
        h.coordinator.talkPressed()
        await eventually { h.coordinator.state == .listening }
        #expect(h.synthesizer.stopCount >= 1)
        #expect(h.synthesizer.spoken == ["A long message."], "The rest of the message is dropped")
        let stop = h.log.index(of: "synth.stop")!
        let listen = h.log.index(of: "session.listening")!
        #expect(stop < listen)
    }

    /// Regression: a message queued just before Talk must not cancel the
    /// listening that Talk started.
    @Test func talkRightAfterAMessageIsQueuedStillListens() async {
        let h = AudioHarness()
        h.coordinator.announce("Voice input stopped.", kind: .update)
        h.coordinator.talkPressed()
        await eventually { h.coordinator.state == .listening }
        await drainMainActor()
        #expect(h.coordinator.state == .listening)
        #expect(h.recognizer.startCount == 1)
        #expect(h.synthesizer.spoken.isEmpty, "The queued message was superseded by Talk")
    }

    @Test func spokenFeedbackOffStaysSilent() async {
        let h = AudioHarness(spokenFeedback: false)
        h.coordinator.announce("Hello.", kind: .update)
        await drainMainActor()
        #expect(h.synthesizer.spoken.isEmpty)
        #expect(h.session.speakingActivations == 0)
    }
}

@MainActor
@Suite("Audio coordinator: VoiceOver policy")
struct AudioVoiceOverTests {
    @Test func voiceOverOnRoutesMessagesToVoiceOverOnly() async {
        let h = AudioHarness(voiceOver: true)
        h.coordinator.announce("Total confirmed.", kind: .update)
        h.coordinator.announce("Checkout.", kind: .screenChange)
        await drainMainActor()
        #expect(h.synthesizer.spoken.isEmpty, "Never spoken twice")
        #expect(h.session.speakingActivations == 0)
        #expect(h.accessibility.posts.map(\.text) == ["Total confirmed.", "Checkout."])
        #expect(h.accessibility.posts.map(\.kind) == [.update, .screenChange])
    }

    @Test func voiceOverOffUsesTheSynthesizer() async {
        let h = AudioHarness(voiceOver: false)
        h.coordinator.announce("Hello.", kind: .update)
        await eventually { !h.synthesizer.spoken.isEmpty }
        #expect(h.synthesizer.spoken == ["Hello."])
        #expect(h.accessibility.posts.isEmpty)
    }

    @Test func voiceOverTurningOnStopsNaviNoteSpeechImmediately() async {
        let h = AudioHarness()
        h.synthesizer.mode = .manual
        h.coordinator.announce("One. Two. Three.", kind: .update)
        await eventually { h.synthesizer.isSpeakingChunk }
        h.accessibility.setVoiceOver(true)
        await eventually { h.coordinator.isVoiceOverRunning }
        await eventually { h.coordinator.state == .idle }
        #expect(h.synthesizer.stopCount >= 1)
        #expect(h.synthesizer.spoken == ["One."])

        h.coordinator.announce("Next.", kind: .update)
        await drainMainActor()
        #expect(h.accessibility.posts.map(\.text) == ["Next."])
        #expect(h.synthesizer.spoken == ["One."])
    }

    @Test func voiceOverTurningOffRestoresSpeechOutput() async {
        let h = AudioHarness(voiceOver: true)
        h.accessibility.setVoiceOver(false)
        await eventually { !h.coordinator.isVoiceOverRunning }
        h.coordinator.announce("Hello.", kind: .update)
        await eventually { !h.synthesizer.spoken.isEmpty }
        #expect(h.synthesizer.spoken == ["Hello."])
        #expect(h.accessibility.posts.isEmpty)
    }

    @Test func voiceOverAnnouncementWhileListeningClosesTheMicrophone() async {
        let h = AudioHarness(voiceOver: true)
        await h.startListening()
        h.coordinator.announce("Something happened.", kind: .update)
        #expect(h.coordinator.state == .idle)
        #expect(h.recognizer.cancelCount >= 1)
        h.recognizer.emit(.final("yes"))
        await drainMainActor()
        #expect(h.transcripts.received.isEmpty)
    }
}

@MainActor
@Suite("Audio coordinator: interruptions, routes, lifecycle")
struct AudioSystemEventTests {
    @Test func interruptionStopsEverythingAndRecoversWithoutListening() async {
        let h = AudioHarness()
        h.synthesizer.mode = .manual
        h.coordinator.announce("One. Two.", kind: .update)
        await eventually { h.synthesizer.isSpeakingChunk }

        h.session.send(.interruptionBegan)
        await eventually { h.coordinator.state == .interrupted }
        #expect(h.synthesizer.stopCount >= 1)

        h.session.send(.interruptionEnded(shouldResume: true))
        await eventually { h.coordinator.state == .idle }
        #expect(h.coordinator.state == .idle)
        #expect(h.recognizer.startCount == 0, "Never resumes listening automatically")
        #expect(h.synthesizer.spoken == ["One."], "Interrupted speech isn't replayed")
    }

    /// Device finding (2026-10-08): voice stayed "paused by a call or
    /// another app" with Talk disabled, because iOS never reported the end
    /// of the interruption. Talk is now an explicit retry.
    @Test func talkRetriesAfterAnInterruptionThatNeverReportedItsEnd() async {
        let h = AudioHarness()
        await h.startListening()
        h.session.send(.interruptionBegan)
        await eventually { h.coordinator.state == .interrupted }
        #expect(h.coordinator.state.acceptsTalk)
        h.coordinator.talkPressed()
        await eventually { h.coordinator.state == .listening }
        #expect(h.recognizer.startCount == 2, "The interrupted session, then the retry")
        h.coordinator.cancelAll()
    }

    @Test func talkWhileACallStillHoldsTheAudioStaysPausedAndSaysSo() async {
        let h = AudioHarness(voiceOver: true)
        await h.startListening()
        h.session.send(.interruptionBegan)
        await eventually { h.coordinator.state == .interrupted }
        h.session.failListening = true
        h.coordinator.talkPressed()
        await eventually { h.accessibility.posts.contains { $0.text == VoiceCopy.stillInterrupted } }
        #expect(h.coordinator.state == .interrupted, "Still paused, not unavailable")
        #expect(h.recognizer.startCount == 1, "No new listening while the call holds the audio")
        // Once the call is over, Talk works.
        h.session.failListening = false
        h.coordinator.talkPressed()
        await eventually { h.coordinator.state == .listening }
        h.coordinator.cancelAll()
    }

    @Test func returningToTheAppClearsAStuckInterruption() async {
        let h = AudioHarness()
        await h.startListening()
        h.session.send(.interruptionBegan)
        await eventually { h.coordinator.state == .interrupted }
        h.coordinator.lifecycleChanged(to: .inactive)
        h.coordinator.lifecycleChanged(to: .active)
        await eventually { h.coordinator.state == .idle }
        #expect(h.coordinator.state == .idle)
        #expect(h.recognizer.startCount == 1, "Never starts listening again by itself")
    }

    /// With VoiceOver on, the "unavailable" message must not reset the
    /// state it announces.
    @Test func unavailableSurvivesItsVoiceOverAnnouncement() async {
        let h = AudioHarness(voiceOver: true)
        h.session.failListening = true
        h.coordinator.talkPressed()
        await eventually { h.coordinator.state == .unavailable(.audioSessionFailed) }
        await drainMainActor()
        #expect(h.coordinator.state == .unavailable(.audioSessionFailed))
    }

    @Test func anInterruptionWhileIdleDoesNotPauseVoice() async {
        let h = AudioHarness()
        h.session.send(.interruptionBegan)
        await drainMainActor()
        #expect(h.coordinator.state == .idle)
        #expect(h.coordinator.state.acceptsTalk)
    }

    @Test func interruptionWhileListeningDiscardsIt() async {
        let h = AudioHarness()
        await h.startListening()
        h.session.send(.interruptionBegan)
        await eventually { h.coordinator.state == .interrupted }
        h.recognizer.emit(.final("yes"))
        await drainMainActor()
        #expect(h.transcripts.received.isEmpty)
    }

    @Test func removingPrivateOutputStopsSpeech() async {
        let h = AudioHarness()
        h.synthesizer.mode = .manual
        h.coordinator.announce("Change due: 5 dollars. More detail.", kind: .update)
        await eventually { h.synthesizer.isSpeakingChunk }
        h.session.send(.routeChanged(.privateOutputRemoved))
        await eventually { h.coordinator.state == .paused }
        #expect(h.synthesizer.stopCount >= 1)
        #expect(h.synthesizer.spoken.count == 1, "Nothing more is played aloud")

        h.synthesizer.mode = .immediate
        h.coordinator.announce("Next message.", kind: .update)
        await eventually { h.synthesizer.spoken.count == 2 }
        #expect(h.synthesizer.spoken.last == "Next message.")
    }

    @Test func otherRouteChangesDoNotInterrupt() async {
        let h = AudioHarness()
        await h.startListening()
        h.session.send(.routeChanged(.newDeviceAvailable))
        h.session.send(.routeChanged(.other))
        await drainMainActor()
        #expect(h.coordinator.state == .listening)
    }

    @Test func backgroundingStopsListeningAndLateResultsAreIgnored() async {
        let h = AudioHarness()
        await h.startListening()
        let generation = h.coordinator.generation
        h.coordinator.lifecycleChanged(to: .background)
        #expect(h.coordinator.state == .paused)
        #expect(h.coordinator.generation == generation.next())
        #expect(h.recognizer.cancelCount >= 1)
        #expect(h.log.entries.last == "session.deactivate")
        h.recognizer.emit(.final("yes"))
        await drainMainActor()
        #expect(h.transcripts.received.isEmpty)

        h.coordinator.lifecycleChanged(to: .active)
        #expect(h.coordinator.state == .idle)
        await drainMainActor()
        #expect(h.recognizer.startCount == 1, "Returning to the foreground never listens")
    }

    @Test func backgroundingStopsSpeechAndBlocksTalk() async {
        let h = AudioHarness()
        h.synthesizer.mode = .manual
        h.coordinator.announce("One. Two.", kind: .update)
        await eventually { h.synthesizer.isSpeakingChunk }
        h.coordinator.lifecycleChanged(to: .background)
        #expect(h.synthesizer.stopCount >= 1)
        #expect(h.coordinator.state == .paused)
        h.coordinator.talkPressed()
        await drainMainActor()
        #expect(h.recognizer.startCount == 0)
    }

    @Test func inactiveClosesTheMicrophone() async {
        let h = AudioHarness()
        await h.startListening()
        h.coordinator.lifecycleChanged(to: .inactive)
        #expect(h.coordinator.state == .paused)
        #expect(h.recognizer.cancelCount >= 1)
    }

    @Test func mediaServicesResetRecovers() async {
        let h = AudioHarness()
        await h.startListening()
        h.session.send(.mediaServicesReset)
        await eventually { h.coordinator.state == .idle }
        #expect(h.recognizer.cancelCount >= 1)
        await h.startListening()
        #expect(h.recognizer.startCount == 2)
    }
}

@MainActor
@Suite("Audio coordinator: cancel, stale callbacks, failures")
struct AudioSafetyTests {
    @Test func cancelAllStopsEverythingAndStartsANewGeneration() async {
        let h = AudioHarness()
        await h.startListening()
        let generation = h.coordinator.generation
        h.coordinator.cancelAll()
        #expect(h.coordinator.state == .idle)
        #expect(h.coordinator.generation == generation.next())
        #expect(h.recognizer.cancelCount >= 1)
        h.recognizer.emit(.final("yes"))
        await drainMainActor()
        #expect(h.transcripts.received.isEmpty)
    }

    @Test func cancelWhileAskingForPermissionNeverOpensTheMicrophone() async {
        let h = AudioHarness(microphone: .notDetermined)
        h.coordinator.talkPressed()
        h.coordinator.cancelAll()
        await drainMainActor()
        #expect(h.recognizer.startCount == 0)
        #expect(h.coordinator.state == .idle)
    }

    @Test func callbacksFromAnOlderRequestAreIgnored() async {
        let h = AudioHarness()
        await h.startListening()          // stream 0
        h.coordinator.cancelAll()
        await h.startListening()          // stream 1
        h.recognizer.emit(.partial("old words"), onStream: 0)
        h.recognizer.emit(.final("cancel"), onStream: 0)
        await drainMainActor()
        #expect(h.coordinator.partialTranscript.isEmpty)
        #expect(h.transcripts.received.isEmpty)
        #expect(h.coordinator.state == .listening)

        h.recognizer.emit(.final("repeat"), onStream: 1)
        await eventually { !h.transcripts.received.isEmpty }
        #expect(h.transcripts.received.map(\.text) == ["repeat"])
    }

    @Test func cancelDuringSpeechDropsTheQueueButSpeaksWhatFollows() async {
        let h = AudioHarness()
        h.synthesizer.mode = .manual
        h.coordinator.announce("One. Two.", kind: .update)
        await eventually { h.synthesizer.isSpeakingChunk }
        h.coordinator.cancelAll()
        h.synthesizer.mode = .immediate
        h.coordinator.announce("Cancelled.", kind: .update)
        await eventually { h.synthesizer.spoken.contains("Cancelled.") }
        #expect(h.synthesizer.spoken == ["One.", "Cancelled."])
    }

    @Test func recognizerStartFailureIsReportedAndSessionReleased() async {
        let h = AudioHarness()
        h.recognizer.startError = FakeError.failed
        h.coordinator.talkPressed()
        await eventually { h.coordinator.state == .unavailable(.microphoneUnavailable) }
        #expect(h.coordinator.state == .unavailable(.microphoneUnavailable))
        #expect(h.log.index(of: "session.deactivate") != nil)
    }

    /// Regression for the physical-iPhone crash (AirPods removed / Siri):
    /// a microphone that can't start is reported, and the next Talk press
    /// tries again with a fresh start instead of staying broken.
    @Test func microphoneStartFailureRecoversOnTheNextTalkPress() async {
        let h = AudioHarness()
        h.recognizer.startError = FakeError.failed
        h.coordinator.talkPressed()
        await eventually { h.coordinator.state == .unavailable(.microphoneUnavailable) }
        #expect(h.coordinator.state.acceptsTalk)

        h.recognizer.startError = nil
        await h.startListening()
        #expect(h.coordinator.state == .listening)
        #expect(h.recognizer.startCount == 1)
    }

    @Test func routeChangeWhileListeningEndsListeningCleanly() async {
        let h = AudioHarness()
        await h.startListening()
        // What SystemSpeechRecognizer reports when the engine's
        // configuration changes mid-session.
        h.recognizer.emit(.failed(.other))
        await eventually { h.coordinator.state == .idle }
        #expect(h.coordinator.state == .idle)
        #expect(h.transcripts.received.isEmpty)
        await h.startListening()
        #expect(h.recognizer.startCount == 2)
    }

    @Test func audioSessionFailureIsReported() async {
        let h = AudioHarness()
        h.session.failListening = true
        h.coordinator.talkPressed()
        await eventually { h.coordinator.state == .unavailable(.audioSessionFailed) }
        #expect(h.recognizer.startCount == 0)
    }

    @Test func recognizerFailuresEndListeningCleanly() async {
        let h = AudioHarness()
        await h.startListening()
        h.recognizer.emit(.failed(.noSpeech))
        await eventually { h.coordinator.state == .idle }
        #expect(h.coordinator.state == .idle)

        await h.startListening()
        h.recognizer.emit(.failed(.unavailable))
        await eventually { h.coordinator.state == .unavailable(.recognizerUnavailable) }
        #expect(h.transcripts.received.isEmpty)
    }

    /// Device finding (2026-10-08): a command waited for a second Talk
    /// press. A pause after words now closes the microphone; the action
    /// still comes only from the final result.
    @Test func aPauseAfterWordsEndsListeningAndUsesTheFinalResult() async {
        var timing = AudioTiming.testing
        timing.endOfSpeechSilence = .milliseconds(30)
        let h = AudioHarness(timing: timing)
        h.recognizer.finalOnFinish = "start checkout"
        await h.startListening()
        h.recognizer.emit(.partial("start"))
        h.recognizer.emit(.partial("start checkout"))
        #expect(h.transcripts.received.isEmpty, "Partials are never commands")
        try? await Task.sleep(for: .milliseconds(200))
        await eventually { h.transcripts.received.count == 1 }
        #expect(h.recognizer.finishCount == 1)
        #expect(h.transcripts.received.map(\.text) == ["start checkout"])
        #expect(h.coordinator.state == .idle)
    }

    @Test func silenceBeforeAnyWordsDoesNotEndListening() async {
        var timing = AudioTiming.testing
        timing.endOfSpeechSilence = .milliseconds(20)
        let h = AudioHarness(timing: timing)
        await h.startListening()
        h.recognizer.emit(.partial("   "))
        try? await Task.sleep(for: .milliseconds(150))
        await drainMainActor()
        #expect(h.recognizer.finishCount == 0, "Waiting for the person to start speaking")
        #expect(h.coordinator.state == .listening)
        h.coordinator.cancelAll()
    }

    @Test func continuedSpeechKeepsListening() async {
        var timing = AudioTiming.testing
        timing.endOfSpeechSilence = .milliseconds(80)
        let h = AudioHarness(timing: timing)
        await h.startListening()
        for word in ["how", "how much", "how much change", "how much change should"] {
            h.recognizer.emit(.partial(word))
            try? await Task.sleep(for: .milliseconds(30))
            await drainMainActor()
        }
        #expect(h.recognizer.finishCount == 0, "Each new word restarts the silence timer")
        h.coordinator.cancelAll()
    }

    @Test func listeningTimesOutWithoutAResult() async {
        var timing = AudioTiming.testing
        timing.listeningLimit = .milliseconds(20)
        timing.finishGrace = .milliseconds(20)
        let h = AudioHarness(timing: timing)
        await h.startListening()
        try? await Task.sleep(for: .milliseconds(200))
        await eventually { h.coordinator.state == .idle }
        #expect(h.recognizer.finishCount == 1, "The time limit closes the microphone")
        #expect(h.coordinator.state == .idle)
        #expect(h.transcripts.received.isEmpty)
    }

    @Test func speechWatchdogStopsAStuckSynthesizer() async {
        var timing = AudioTiming.testing
        timing.watchdogBase = .milliseconds(20)
        let h = AudioHarness(timing: timing)
        h.synthesizer.mode = .manual // never completes on its own
        h.coordinator.announce("Stuck. Then this.", kind: .update)
        try? await Task.sleep(for: .milliseconds(200))
        await eventually { h.synthesizer.spoken.count == 2 }
        #expect(h.synthesizer.stopCount >= 1)
        #expect(h.synthesizer.spoken == ["Stuck.", "Then this."])
        h.synthesizer.stop()
    }

    @Test func speechSessionFailureSkipsTheMessageSafely() async {
        let h = AudioHarness()
        h.session.failSpeaking = true
        h.coordinator.announce("Hello.", kind: .update)
        await drainMainActor()
        #expect(h.synthesizer.spoken.isEmpty)
        #expect(h.coordinator.state == .idle)
    }
}

@Suite("Speech chunking")
struct SpeechChunkerTests {
    @Test func splitsSentencesButNotDecimals() {
        #expect(SpeechChunker.chunks("You paid 12.50 dollars. Change is 7.50! Okay?") ==
            ["You paid 12.50 dollars.", "Change is 7.50!", "Okay?"])
    }

    @Test func longSentencesBreakAfterCommas() {
        let long = "This sentence is long, it keeps going with more words, and even more words after that, until it is far too long to say."
        let chunks = SpeechChunker.chunks(long, maxLength: 50)
        #expect(chunks.count > 1)
        #expect(chunks.joined(separator: " ") == long)
    }

    @Test func emptyTextHasNoChunks() {
        #expect(SpeechChunker.chunks("   ").isEmpty)
    }
}
