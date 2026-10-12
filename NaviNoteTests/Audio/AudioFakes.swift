import Foundation
@testable import NaviNote

/// Shared, ordered record of what the fakes were asked to do, so tests can
/// check ordering across services (e.g. recognition stops before speech).
@MainActor
final class AudioEventLog {
    private(set) var entries: [String] = []
    func record(_ entry: String) { entries.append(entry) }
    func index(of entry: String) -> Int? { entries.firstIndex(of: entry) }
    func count(_ entry: String) -> Int { entries.filter { $0 == entry }.count }
}

@MainActor
final class FakeAudioSession: AudioSessionControlling {
    let log: AudioEventLog
    var failSpeaking = false
    var failListening = false
    private var continuation: AsyncStream<AudioSessionEvent>.Continuation?

    init(log: AudioEventLog) { self.log = log }

    var speakingActivations: Int { log.count("session.speaking") }
    var listeningActivations: Int { log.count("session.listening") }

    func activateForSpeaking() async throws {
        if failSpeaking { throw FakeError.failed }
        log.record("session.speaking")
    }

    func activateForListening() async throws {
        if failListening { throw FakeError.failed }
        log.record("session.listening")
    }

    func deactivate() { log.record("session.deactivate") }

    func events() -> AsyncStream<AudioSessionEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: AudioSessionEvent.self)
        self.continuation = continuation
        return stream
    }

    func send(_ event: AudioSessionEvent) { continuation?.yield(event) }
}

@MainActor
final class FakePermissions: SpeechPermissionProviding {
    var microphoneStatus: PermissionStatus
    var speechRecognitionStatus: PermissionStatus
    var microphoneAnswer: PermissionStatus = .granted
    var speechAnswer: PermissionStatus = .granted
    private(set) var microphoneRequests = 0
    private(set) var speechRequests = 0

    init(microphone: PermissionStatus = .granted, speech: PermissionStatus = .granted) {
        microphoneStatus = microphone
        speechRecognitionStatus = speech
    }

    func requestMicrophone() async -> PermissionStatus {
        microphoneRequests += 1
        microphoneStatus = microphoneAnswer
        return microphoneAnswer
    }

    func requestSpeechRecognition() async -> PermissionStatus {
        speechRequests += 1
        speechRecognitionStatus = speechAnswer
        return speechAnswer
    }
}

@MainActor
final class FakeRecognizer: SpeechRecognizing {
    let log: AudioEventLog
    var isAvailable = true
    var startError: Error?
    /// When set, `finish()` delivers this final transcript.
    var finalOnFinish: String?
    private(set) var startCount = 0
    private(set) var finishCount = 0
    private(set) var cancelCount = 0
    /// Every stream ever started, so tests can deliver stale callbacks.
    private(set) var streams: [AsyncStream<RecognizerEvent>.Continuation] = []
    private var running = false

    init(log: AudioEventLog) { self.log = log }

    func start() throws -> AsyncStream<RecognizerEvent> {
        if let startError { throw startError }
        // Mirrors the real contract: never two tasks at once.
        guard !running else { throw FakeError.alreadyRunning }
        running = true
        startCount += 1
        log.record("recognizer.start")
        let (stream, continuation) = AsyncStream.makeStream(of: RecognizerEvent.self)
        streams.append(continuation)
        return stream
    }

    func finish() {
        finishCount += 1
        log.record("recognizer.finish")
        if let finalOnFinish { streams.last?.yield(.final(finalOnFinish)) }
    }

    func cancel() {
        cancelCount += 1
        running = false
        log.record("recognizer.cancel")
    }

    /// Delivers an event on the most recent stream, or an earlier one.
    func emit(_ event: RecognizerEvent, onStream index: Int? = nil) {
        streams[index ?? streams.count - 1].yield(event)
    }
}

@MainActor
final class FakeSynthesizer: SpeechSynthesizing {
    enum Mode {
        /// Each chunk finishes immediately.
        case immediate
        /// Each chunk waits for `completeCurrent()` or `stop()`.
        case manual
    }

    let log: AudioEventLog
    var mode: Mode = .immediate
    private(set) var spoken: [String] = []
    private(set) var stopCount = 0
    private var pending: CheckedContinuation<Void, Never>?

    init(log: AudioEventLog) { self.log = log }

    var isSpeakingChunk: Bool { pending != nil }

    func speak(_ text: String, rate: SpeechRate) async {
        spoken.append(text)
        log.record("synth.speak")
        guard mode == .manual else { return }
        await withCheckedContinuation { pending = $0 }
    }

    func completeCurrent() {
        pending?.resume()
        pending = nil
    }

    func stop() {
        stopCount += 1
        log.record("synth.stop")
        completeCurrent()
    }
}

@MainActor
final class FakeAccessibility: AccessibilityStatusProviding {
    var isVoiceOverRunning: Bool
    private(set) var posts: [(text: String, kind: AnnouncementKind)] = []
    private var continuation: AsyncStream<Bool>.Continuation?

    init(voiceOver: Bool = false) { isVoiceOverRunning = voiceOver }

    func voiceOverStatusChanges() -> AsyncStream<Bool> {
        let (stream, continuation) = AsyncStream.makeStream(of: Bool.self)
        self.continuation = continuation
        return stream
    }

    func setVoiceOver(_ running: Bool) {
        isVoiceOverRunning = running
        continuation?.yield(running)
    }

    func postAnnouncement(_ text: String, kind: AnnouncementKind) {
        posts.append((text, kind))
    }
}

enum FakeError: Error {
    case failed
    case alreadyRunning
}

/// A coordinator wired to fakes, with zero settling delays.
@MainActor
struct AudioHarness {
    let log = AudioEventLog()
    let session: FakeAudioSession
    let permissions: FakePermissions
    let recognizer: FakeRecognizer
    let synthesizer: FakeSynthesizer
    let accessibility: FakeAccessibility
    let coordinator: AudioCoordinator
    let transcripts: TranscriptSink
    var clock: ManualDate

    init(
        microphone: PermissionStatus = .granted,
        speech: PermissionStatus = .granted,
        voiceOver: Bool = false,
        spokenFeedback: Bool = true,
        timing: AudioTiming = .testing
    ) {
        session = FakeAudioSession(log: log)
        permissions = FakePermissions(microphone: microphone, speech: speech)
        recognizer = FakeRecognizer(log: log)
        synthesizer = FakeSynthesizer(log: log)
        accessibility = FakeAccessibility(voiceOver: voiceOver)
        let clock = ManualDate()
        self.clock = clock
        let ids = SequentialRequestIDs()
        coordinator = AudioCoordinator(
            session: session,
            permissions: permissions,
            recognizer: recognizer,
            synthesizer: synthesizer,
            accessibility: accessibility,
            timing: timing,
            preferences: { SpeechPreferences(spokenFeedback: spokenFeedback) },
            makeRequestID: { ids.make() },
            now: { clock.now }
        )
        let sink = TranscriptSink()
        transcripts = sink
        coordinator.onFinalTranscript = { sink.received.append($0) }
    }

    /// Presses Talk and waits until the microphone is open.
    func startListening() async {
        coordinator.talkPressed()
        await eventually { coordinator.state == .listening }
    }
}

@MainActor
final class TranscriptSink {
    var received: [VoiceTranscript] = []
}

@MainActor
final class ManualDate {
    var now = Date(timeIntervalSinceReferenceDate: 0)
    func advance(_ seconds: TimeInterval) { now += seconds }
}

extension AudioTiming {
    /// No settling delays; generous limits so only timeout tests time out.
    static let testing = AudioTiming(
        afterListeningBeforeSpeaking: .zero,
        afterSpeakingBeforeListening: .zero,
        betweenChunks: .zero,
        listeningLimit: .seconds(60),
        finishGrace: .seconds(60),
        endOfSpeechSilence: .seconds(60),
        recoveryDelay: .zero,
        duplicateWindow: 1.0,
        watchdogBase: .seconds(60),
        watchdogPerCharacter: .zero
    )
}

/// Lets queued main-actor work run until `condition` holds (or gives up).
@MainActor
@discardableResult
func eventually(_ condition: () -> Bool, attempts: Int = 200) async -> Bool {
    for _ in 0..<attempts {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

/// Lets queued main-actor work run for a while, for checking that
/// something does *not* happen.
@MainActor
func drainMainActor(_ rounds: Int = 50) async {
    for _ in 0..<rounds { await Task.yield() }
}
