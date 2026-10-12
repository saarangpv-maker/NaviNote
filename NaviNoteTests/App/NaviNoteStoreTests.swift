import Testing
@testable import NaviNote

@MainActor
private final class RecordingHaptics: HapticsPlaying {
    private(set) var events: [HapticEvent] = []
    func play(_ event: HapticEvent) { events.append(event) }
}

@MainActor
@Suite("NaviNoteStore")
struct NaviNoteStoreTests {
    /// VoiceOver on, so every message is observable as a VoiceOver post.
    private let audio = AudioHarness(voiceOver: true)
    private let scan = ScanHarness()
    private let haptics = RecordingHaptics()

    private func makeStore() -> NaviNoteStore {
        NaviNoteStore(audio: audio.coordinator, scanner: scan.scanner, haptics: haptics)
    }

    private var posts: [(text: String, kind: AnnouncementKind)] { audio.accessibility.posts }

    @Test func launchDoesNotAnnounceOrListen() async {
        let store = makeStore()
        await drainMainActor()
        #expect(store.state.phase == .home)
        #expect(posts.isEmpty)
        #expect(store.audio.state == .idle)
        #expect(audio.recognizer.startCount == 0, "Voice must never start on its own")
        #expect(store.message == "NaviNote is ready. Choose an option below.")
    }

    @Test func screenChangesAreAnnouncedAsScreenChanges() {
        let store = makeStore()
        store.send(.startCheckout)
        #expect(store.state.phase == .checkoutIntroduction)
        #expect(posts.count == 1)
        #expect(posts.first?.kind == .screenChange)
        #expect(posts.first?.text == AnnouncementComposer.text(for: .checkoutIntroduction))
    }

    @Test func repeatIsNeverSuppressed() {
        let store = makeStore()
        store.send(.repeatLastInstruction)
        store.send(.repeatLastInstruction)
        #expect(posts.map(\.kind) == [.repeatRequest, .repeatRequest])
        #expect(posts.first?.text == store.message)
    }

    @Test func ignoredActionsDoNothing() {
        let store = makeStore()
        store.send(.confirmTotal)
        store.send(.cancel)
        #expect(posts.isEmpty)
        #expect(haptics.events.isEmpty)
        #expect(store.state == NaviNoteState())
    }

    @Test func cancelStopsAudioAndPlaysAWarningHaptic() async {
        let store = makeStore()
        store.send(.startReadingCurrency)
        let generation = store.audio.generation
        store.send(.cancel)
        #expect(haptics.events == [.warning])
        #expect(store.state.phase == .home)
        #expect(store.audio.generation == generation.next(), "Audio in flight belongs to the old session")
    }

    @Test func spokenCommandsGoThroughTheStateMachine() async {
        let store = makeStore()
        audio.accessibility.setVoiceOver(false)
        await eventually { !store.audio.isVoiceOverRunning }
        await audio.startListening()
        audio.recognizer.emit(.final("Start checkout"))
        await eventually { store.state.phase == .checkoutIntroduction }
        #expect(store.state.phase == .checkoutIntroduction)
    }

    @Test func typedCommandsUseTheSameRouter() {
        let store = makeStore()
        store.handleCommand("verify change")
        #expect(store.state.phase == .settingExpectedChange)
        store.send(.enterExpectedChange(minorUnits: 5_00, currency: .usd))
        store.handleCommand("yes")
        #expect(store.state.phase == .collectingReturnedChange)
    }

    @Test func commandsNotValidHereAreExplained() {
        let store = makeStore()
        store.handleCommand("yes")
        #expect(store.state.phase == .home)
        #expect(posts.last?.text == VoiceCopy.notAvailableHere)
        store.handleCommand("play music")
        #expect(posts.last?.text == VoiceCopy.notUnderstood)
    }

    @Test func helpCommandOpensHelp() {
        let store = makeStore()
        store.handleCommand("help")
        #expect(store.isShowingHelp)
    }

    @Test func permitsDelegatesToTheStateMachine() {
        let store = makeStore()
        #expect(store.permits(.startCheckout))
        #expect(!store.permits(.confirmTotal))
        store.send(.openAskNaviNote)
        #expect(store.permits(.closeAskNaviNote))
    }

    @Test func scanWithoutACameraReportsItHonestly() async {
        scan.camera.isCameraAvailable = false
        let store = makeStore()
        store.send(.startReadingCurrency)
        store.send(.startScan)
        #expect(store.state.isScanning)
        await eventually { store.state.phase != .readingCurrency }
        #expect(store.state.phase == .recoverableError(.cameraUnavailable))
        store.send(.retry)
        #expect(store.state.phase == .readingCurrency)
    }

    /// Device finding (Phase 13): locking the phone during a scan ended it
    /// while locked, and nothing was said on return.
    @Test func aScanInterruptedWhileLockedIsAnnouncedOnReturn() async {
        let store = makeStore()
        store.send(.startReadingCurrency)
        store.send(.startScan)
        #expect(await eventually { scan.camera.isRunning })
        store.lifecycleChanged(to: .inactive)
        store.lifecycleChanged(to: .background)
        #expect(await eventually { store.state.phase == .recoverableError(.interrupted) })
        let before = posts.count
        store.lifecycleChanged(to: .active)
        #expect(posts.count == before + 1)
        #expect(posts.last?.text == AnnouncementComposer.text(for: .recoverableIssue(.interrupted)))
        // Try again goes back to the step.
        store.send(.retry)
        #expect(store.state.phase == .readingCurrency)
    }

    @Test func returningWithNothingMissedSaysNothingExtra() async {
        let store = makeStore()
        store.send(.startCheckout)
        store.lifecycleChanged(to: .background)
        let before = posts.count
        store.lifecycleChanged(to: .active)
        await drainMainActor()
        #expect(posts.count == before)
    }
}
