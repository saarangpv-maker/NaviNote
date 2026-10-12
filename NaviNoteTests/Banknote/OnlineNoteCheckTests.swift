import Foundation
import Testing
@testable import NaviNote

private func read(
    _ value: Int?, _ currency: Currency = .aed, banknote: Bool = true,
    uncertainty: OnlineNoteRead.Uncertainty = .low, printed: Bool = false, evidence: [String] = ["purple colour"]
) -> OnlineNoteRead {
    OnlineNoteRead(
        isBanknote: banknote,
        denomination: value.flatMap { SupportedDenomination(currency: currency, majorValue: $0) },
        evidence: evidence, usedPrintedValue: printed, uncertainty: uncertainty
    )
}

@Suite("Online note check: the two-read rule")
struct OnlineNoteDecisionTests {
    @Test func agreementIdentifiesTheNote() {
        let outcome = OnlineNoteDecision.decide(
            appearance: read(50, evidence: ["purple colour", "falcon", "museum", "portrait"]),
            withText: read(50, uncertainty: .medium, printed: true)
        )
        #expect(outcome == .identified(OnlineNoteResult(
            denomination: note(.aed, 50), evidence: ["purple colour", "falcon", "museum"], printedValueAlsoRead: true)))
    }

    /// The two errors measured on 2026-10-11 each had the other read unsure.
    @Test(arguments: [
        ("reads disagree", read(100), read(1000)),
        ("appearance unsure", read(100, uncertainty: .high), read(100)),
        ("text read unsure", read(5), read(5, uncertainty: .high)),
        ("one read missing a value", read(nil, uncertainty: .high), read(1000)),
        ("one read sees no note", read(nil, banknote: false), read(10)),
        ("different currencies", read(5, .aed), read(5, .usd)),
    ])
    func anythingElseIsNotSure(_ name: String, _ appearance: OnlineNoteRead, _ withText: OnlineNoteRead) {
        #expect(OnlineNoteDecision.decide(appearance: appearance, withText: withText) == .notSure, "\(name)")
    }

    @Test func aMissingReadIsNeverEnough() {
        #expect(OnlineNoteDecision.decide(appearance: read(50), withText: nil) == .notSure)
        #expect(OnlineNoteDecision.decide(appearance: nil, withText: read(50)) == .notSure)
        #expect(OnlineNoteDecision.decide(appearance: nil, withText: nil) == .unavailable)
    }

    @Test func bothSeeingNoNoteSaysSo() {
        #expect(OnlineNoteDecision.decide(appearance: read(nil, banknote: false), withText: read(nil, banknote: false)) == .noBanknote)
    }
}

@Suite("Online note check: reply validation (Swift)")
struct OnlineNoteValidatorTests {
    let requestID = RequestID(UUID(uuidString: "11111111-1111-4111-8111-111111111111")!)
    let sessionID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    func reply(_ changes: [String: Any] = [:], remove: String? = nil) -> Data {
        var object: [String: Any] = [
            "requestId": requestID.rawValue.uuidString.lowercased(), "sessionId": sessionID.uuidString.lowercased(),
            "method": "cloudVision", "isBanknote": true, "currency": "AED", "denomination": 50, "side": "front",
            "evidence": ["purple colour", "falcon"], "usedPrintedValue": false, "uncertainty": "low",
        ]
        object.merge(changes) { $1 }
        if let remove { object[remove] = nil }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    @Test func acceptsAValidRead() throws {
        let read = try OnlineNoteValidator.validate(reply(), requestID: requestID, sessionID: sessionID).get()
        #expect(read.denomination == note(.aed, 50))
        #expect(read.uncertainty == .low)
        #expect(read.evidence == ["purple colour", "falcon"])
    }

    @Test(arguments: [
        ("an extra field", #"{"confidence": 0.97}"#, OnlineNoteRejection.unexpectedFields),
        ("another request", #"{"requestId": "33333333-3333-4333-8333-333333333333"}"#, .mismatchedRequest),
        ("another session", #"{"sessionId": "33333333-3333-4333-8333-333333333333"}"#, .mismatchedSession),
        ("a value that isn't an AED note", #"{"denomination": 25}"#, .unsupportedValue),
        ("a USD-only value for AED", #"{"denomination": 2}"#, .unsupportedValue),
        ("a value for a non-note", #"{"isBanknote": false}"#, .unsupportedValue),
        ("a fractional value", #"{"denomination": 50.5}"#, .unsupportedValue),
        ("a Boolean value", #"{"denomination": true}"#, .invalidField),
        ("an unknown uncertainty", #"{"uncertainty": "certain"}"#, .invalidField),
        ("another method", #"{"method": "guess"}"#, .invalidField),
        ("too much evidence", #"{"evidence": ["a", "b", "c", "d", "e", "f"]}"#, .evidence),
        ("authenticity claims", #"{"evidence": ["looks genuine"]}"#, .noteAuthenticity),
    ])
    func rejects(_ name: String, _ changesJSON: String, _ rejection: OnlineNoteRejection) throws {
        let changes = try #require(try JSONSerialization.jsonObject(with: Data(changesJSON.utf8)) as? [String: Any])
        #expect(OnlineNoteValidator.validate(reply(changes), requestID: requestID, sessionID: sessionID) == .failure(rejection), "\(name)")
    }

    @Test func rejectsAMissingField() {
        #expect(OnlineNoteValidator.validate(reply(remove: "uncertainty"), requestID: requestID, sessionID: sessionID) == .failure(.unexpectedFields))
    }
}

@Suite("Online note check: state machine")
struct OnlineNoteStateMachineTests {
    private func start(_ h: inout Harness) -> RequestID? {
        guard case .applied(let effects) = h.send(.checkNoteOnline), case .checkNoteOnline(let id) = effects.first else { return nil }
        return id
    }

    private func event(_ id: RequestID, _ outcome: OnlineNoteOutcome, _ h: Harness) -> NaviNoteAction {
        .serviceEvent(ServiceEvent(requestID: id, generation: h.state.generation, payload: .onlineNote(outcome)))
    }

    @Test func onlyInReadCurrencyAndNotWhileScanning() {
        var home = Harness()
        #expect(home.send(.checkNoteOnline) == .ignored(.invalidInPhase))
        var checkout = Harness.at(.acquiringTotal)
        #expect(checkout.send(.checkNoteOnline) == .ignored(.invalidInPhase))

        var scanning = Harness.at(.readingCurrency)
        _ = scanning.startScan()
        #expect(scanning.send(.checkNoteOnline) == .ignored(.scanAlreadyInProgress))

        var checking = Harness.at(.readingCurrency)
        #expect(start(&checking) != nil)
        #expect(checking.send(.startScan) == .ignored(.scanAlreadyInProgress), "The camera is busy with the photo")
        #expect(checking.send(.checkNoteOnline) == .ignored(.scanAlreadyInProgress))
    }

    @Test func anIdentifiedNoteIsShownAndSaid() throws {
        var h = Harness.at(.readingCurrency)
        let id = try #require(start(&h))
        let result = OnlineNoteResult(denomination: note(.aed, 50), evidence: ["purple"], printedValueAlsoRead: false)
        let applied = h.send(event(id, .identified(result), h))
        #expect(applied == .applied([.announce(.onlineNote(.identified(result))), .haptic(.success)]))
        #expect(h.state.lastOnlineNote == result)
        #expect(h.state.pendingOnlineNoteCheck == nil)
        #expect(AnnouncementComposer.text(for: .onlineNote(.identified(result)))
            == "This looks like a 50 UAE dirham note, checked online from its appearance. NaviNote can't tell whether a note is genuine.")
    }

    @Test(arguments: [OnlineNoteOutcome.notSure, .noBanknote, .photoUnavailable, .unavailable])
    func otherOutcomesNeverNameANote(_ outcome: OnlineNoteOutcome) throws {
        var h = Harness.at(.readingCurrency)
        let id = try #require(start(&h))
        _ = h.send(event(id, outcome, h))
        #expect(h.state.lastOnlineNote == nil)
        let text = AnnouncementComposer.text(for: .onlineNote(outcome))
        #expect(!text.contains("dirham note") && !text.contains("dollar note"))
    }

    @Test func leavingCancelsAndALateResultIsIgnored() throws {
        var h = Harness.at(.readingCurrency)
        let id = try #require(start(&h))
        let generation = h.state.generation
        let done = h.send(.finish)
        #expect(done.effects.contains(.cancelAllPendingWork))
        let late = h.send(.serviceEvent(ServiceEvent(requestID: id, generation: generation,
            payload: .onlineNote(.identified(OnlineNoteResult(denomination: note(.aed, 50), evidence: [], printedValueAlsoRead: false))))))
        #expect(late == .ignored(.staleGeneration))
        #expect(h.state.lastOnlineNote == nil)
    }

    @Test func backgroundCancelsAPendingCheck() throws {
        var h = Harness.at(.readingCurrency)
        let id = try #require(start(&h))
        #expect(h.send(.cancelAstraRequest) == .applied([.cancelOnlineNoteCheck(id)]))
        #expect(h.state.pendingOnlineNoteCheck == nil)
    }
}

// MARK: - Store

@MainActor
private final class FakeNotePhotos: NotePhotoTaking {
    var photo: Data? = Data([0xFF, 0xD8, 0xFF])
    private(set) var taken = 0
    private(set) var cameraOn = false
    func takePhoto(cameraStarted: @escaping @MainActor () -> Void) async -> Data? {
        taken += 1
        if photo != nil { cameraOn = true; cameraStarted() }
        return photo
    }
    func stopCamera() { cameraOn = false }
}

private final class FakeOnlineNotes: OnlineNoteService, @unchecked Sendable {
    private let lock = NSLock()
    private var _modes: [OnlineNoteReadMode] = []
    var modes: [OnlineNoteReadMode] { lock.withLock { _modes } }
    let denominations: [OnlineNoteReadMode: Int]
    let hang: Bool

    init(_ denominations: [OnlineNoteReadMode: Int], hang: Bool = false) {
        self.denominations = denominations
        self.hang = hang
    }

    func read(jpeg: Data, mode: OnlineNoteReadMode, requestID: RequestID, sessionID: UUID, installID: UUID) async throws(AstraFailure) -> Data {
        lock.withLock { _modes.append(mode) }
        if hang { while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }; throw .cancelled }
        guard let value = denominations[mode] else { throw .unavailable }
        let object: [String: Any] = [
            "requestId": requestID.rawValue.uuidString.lowercased(), "sessionId": sessionID.uuidString.lowercased(),
            "method": "cloudVision", "isBanknote": true, "currency": "AED", "denomination": value, "side": "front",
            "evidence": ["\(mode.rawValue) evidence"], "usedPrintedValue": mode == .withText, "uncertainty": "low",
        ]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }
}

@MainActor
private final class OnlineNoteTestHaptics: HapticsPlaying {
    func play(_ event: HapticEvent) {}
}

@MainActor
@Suite("Online note check: store")
struct OnlineNoteStoreTests {
    private let audio = AudioHarness(voiceOver: true)
    private let scan = ScanHarness()
    private let photos = FakeNotePhotos()

    private func makeStore(_ service: FakeOnlineNotes, consent: Bool) -> NaviNoteStore {
        let store = NaviNoteStore(
            audio: audio.coordinator, scanner: scan.scanner, haptics: OnlineNoteTestHaptics(),
            onlineNotes: service, notePhotos: photos, notePhotoConsent: { consent }
        )
        store.send(.startReadingCurrency)
        return store
    }

    @Test func withoutConsentNothingIsPhotographedOrSent() async {
        let service = FakeOnlineNotes([.appearance: 50, .withText: 50])
        let store = makeStore(service, consent: false)
        store.checkNoteOnline()
        await drainMainActor()
        #expect(photos.taken == 0)
        #expect(service.modes.isEmpty)
        #expect(audio.accessibility.posts.last?.text == VoiceCopy.notePhotosOff)
        #expect(store.state.pendingOnlineNoteCheck == nil)
    }

    @Test func withConsentOnePhotoIsReadBothWays() async {
        let service = FakeOnlineNotes([.appearance: 50, .withText: 50])
        let store = makeStore(service, consent: true)
        store.checkNoteOnline()
        #expect(await eventually { store.state.lastOnlineNote != nil })
        #expect(photos.taken == 1)
        #expect(Set(service.modes) == [.appearance, .withText])
        #expect(store.state.lastOnlineNote?.denomination == note(.aed, 50))
        #expect(store.state.lastOnlineNote?.evidence == ["appearance evidence"])
        #expect(!photos.cameraOn, "The camera goes off with the answer")
        #expect(!store.isNoteCameraLive)
    }

    /// Device finding (2026-10-11): the preview vanished as soon as the
    /// photo was taken. It now stays until the answer.
    @Test func thePreviewStaysOnWhileChecking() async {
        let service = FakeOnlineNotes([:], hang: true)
        let store = makeStore(service, consent: true)
        store.checkNoteOnline()
        #expect(await eventually { service.modes.count == 2 })
        #expect(store.isNoteCameraLive)
        #expect(photos.cameraOn)
        store.send(.finish)
        await drainMainActor()
        #expect(!store.isNoteCameraLive)
        #expect(!photos.cameraOn)
    }

    @Test func disagreeingReadsAreNotSure() async {
        let store = makeStore(FakeOnlineNotes([.appearance: 100, .withText: 1000]), consent: true)
        store.checkNoteOnline()
        #expect(await eventually { store.state.pendingOnlineNoteCheck == nil })
        #expect(store.state.lastOnlineNote == nil)
        #expect(store.message == AnnouncementComposer.text(for: .onlineNote(.notSure)))
    }

    @Test func noPhotoNoUpload() async {
        photos.photo = nil
        let service = FakeOnlineNotes([.appearance: 50, .withText: 50])
        let store = makeStore(service, consent: true)
        store.checkNoteOnline()
        #expect(await eventually { store.state.pendingOnlineNoteCheck == nil })
        #expect(service.modes.isEmpty)
        #expect(store.message == AnnouncementComposer.text(for: .onlineNote(.photoUnavailable)))
    }

    @Test func leavingWhileCheckingDropsTheResult() async {
        let service = FakeOnlineNotes([:], hang: true)
        let store = makeStore(service, consent: true)
        store.checkNoteOnline()
        #expect(await eventually { service.modes.count == 2 })
        store.send(.finish)
        await drainMainActor(200)
        #expect(store.state.phase == .home)
        #expect(store.state.lastOnlineNote == nil)
    }
}
