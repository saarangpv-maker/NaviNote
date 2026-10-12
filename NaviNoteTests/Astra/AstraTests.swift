import Foundation
import Testing
@testable import NaviNote

// MARK: - Fakes

/// A scripted backend. Records requests; never touches the network.
final class FakeAstraService: AstraService, @unchecked Sendable {
    enum Reply {
        case json((AstraRequest) -> [String: Any])
        case raw(Data)
        case failure(AstraFailure)
        /// Waits until cancelled.
        case hang
    }

    private let lock = NSLock()
    private var _requests: [AstraRequest] = []
    private let reply: Reply

    init(_ reply: Reply) { self.reply = reply }

    var requests: [AstraRequest] { lock.withLock { _requests } }

    func send(_ request: AstraRequest) async throws(AstraFailure) -> Data {
        lock.withLock { _requests.append(request) }
        switch reply {
        case .json(let make):
            return (try? JSONSerialization.data(withJSONObject: make(request))) ?? Data()
        case .raw(let data):
            return data
        case .failure(let failure):
            throw failure
        case .hang:
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            throw .cancelled
        }
    }

    /// A well-formed reply echoing the request's IDs.
    static func reply(_ type: String, intent: String? = nil, text: String? = nil) -> Reply {
        .json { request in
            [
                "requestId": request.requestID.rawValue.uuidString.lowercased(),
                "sessionId": request.sessionID.uuidString.lowercased(),
                "type": type,
                "intent": intent.map { $0 as Any } ?? NSNull(),
                "text": text.map { $0 as Any } ?? NSNull(),
            ]
        }
    }
}

private func request(
    kind: AstraKind = .interpretCommand,
    context: AstraContext = AstraContext(currency: .usd, total: 17_35)
) -> AstraRequest {
    AstraRequest(
        requestID: RequestID(UUID(uuidString: "11111111-1111-4111-8111-111111111111")!),
        sessionID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
        installID: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
        kind: kind,
        screen: "acquiringTotal",
        transcript: "could you say that one more time",
        context: context
    )
}

private func reply(
    _ request: AstraRequest, type: String, intent: Any = NSNull(), text: Any = NSNull(),
    extra: [String: Any] = [:]
) -> Data {
    var object: [String: Any] = [
        "requestId": request.requestID.rawValue.uuidString.lowercased(),
        "sessionId": request.sessionID.uuidString.lowercased(),
        "type": type, "intent": intent, "text": text,
    ]
    object.merge(extra) { $1 }
    return try! JSONSerialization.data(withJSONObject: object)
}

// MARK: - Contract

@Suite("Astra contract")
struct AstraContractTests {
    @Test func requestJSONHasEveryFieldNullsIncludedAndLowercaseIDs() throws {
        let data = try request().jsonData()
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["requestId", "sessionId", "installId", "kind", "screen", "transcript", "context"])
        #expect(object["requestId"] as? String == "11111111-1111-4111-8111-111111111111")
        let context = try #require(object["context"] as? [String: Any])
        #expect(Set(context.keys) == ["currency", "total", "paid", "expectedChange", "receivedTotal", "lastInstruction"])
        #expect(context["currency"] as? String == "USD")
        #expect(context["total"] as? Int == 17_35)
        #expect(context["paid"] is NSNull)
        #expect(context["lastInstruction"] is NSNull)
    }

    @Test func transcriptIsTrimmedAndCapped() {
        let long = AstraRequest(
            requestID: RequestID(), sessionID: UUID(), installID: UUID(), kind: .interpretCommand,
            screen: "home", transcript: "  " + String(repeating: "a", count: 400) + "  ", context: .empty
        )
        #expect(long.transcript.count == 300)
        #expect(!long.transcript.hasPrefix(" "))
    }

    @Test func contextCarriesOnlyConfirmedValues() {
        // A proposed total is not confirmed: neither it nor the question
        // stating it is sent.
        var proposing = Harness.at(.acquiringTotal)
        proposing.apply(.enterTotalManually(minorUnits: 42_00, currency: .aed))
        let proposed = AstraContext(state: proposing.state, lastInstruction: AnnouncementComposer.text(for: proposing.state.lastAnnouncement))
        #expect(proposed.total == nil)
        #expect(proposed.currency == nil)
        #expect(proposed.lastInstruction == nil, "The confirmation question states an unconfirmed amount")

        // After checkout: total, paid and change due.
        let result = Harness.at(.showingExpectedChange)
        let checkout = AstraContext(state: result.state, lastInstruction: AnnouncementComposer.text(for: result.state.lastAnnouncement))
        #expect(checkout.currency == .usd)
        #expect(checkout.total == 7_00)
        #expect(checkout.paid == 20_00)
        #expect(checkout.expectedChange == 13_00)
        #expect(checkout.receivedTotal == nil)
        #expect(checkout.lastInstruction != nil, "It mentions only confirmed amounts")

        // Collecting change: received so far.
        var collecting = Harness.at(.collectingReturnedChange)
        collecting.addManually(note(.usd, 10))
        let change = AstraContext(state: collecting.state, lastInstruction: "")
        #expect(change.expectedChange == 13_00)
        #expect(change.receivedTotal == 10_00)
    }

    @Test func noIntentConfirmsRejectsEntersOrFinishes() {
        for intent in AstraIntent.allCases {
            guard case .actions(let actions) = intent.command else { continue }
            for action in actions {
                let name = action.logName.lowercased()
                for forbidden in ["confirm", "reject", "enter", "select", "add", "finish", "continue", "interpret"] {
                    #expect(!name.hasPrefix(forbidden), "\(intent) maps to \(action.logName)")
                }
            }
        }
    }

    @Test func intentsMatchTheBackendAllowlist() {
        #expect(AstraIntent.allCases.map(\.rawValue) == [
            "repeat", "help", "scan", "stopScan", "cancel", "startCheckout", "startReadingCurrency",
            "startVerifyChange", "removeLastNote",
        ])
    }
}

// MARK: - Validation

@Suite("Astra reply validation (Swift)")
struct AstraValidationTests {
    let base = request()

    @Test func acceptsAnAllowlistedIntent() {
        #expect(AstraResponseValidator.validate(reply(base, type: "intent", intent: "repeat"), for: base)
            == .success(.intent(.repeatInstruction, text: nil)))
        #expect(AstraResponseValidator.validate(reply(base, type: "unsupported"), for: base) == .success(.unsupported))
    }

    @Test(arguments: [
        ("not JSON", Data("nope".utf8), AstraRejection.notJSON),
        ("an extra field", reply(request(), type: "intent", intent: "scan", extra: ["amount": 5]), .unexpectedFields),
        ("an unknown intent", reply(request(), type: "intent", intent: "confirmTotal"), .unsupportedIntent),
        ("an intent type without an intent", reply(request(), type: "intent"), .inconsistent),
        ("unsupported with an intent", reply(request(), type: "unsupported", intent: "scan"), .inconsistent),
        ("prose for a command", reply(request(), type: "answer", text: "Sure."), .wrongTypeForKind),
        ("an unknown type", reply(request(), type: "action", intent: "scan"), .unknownType),
        ("an invented amount", reply(request(), type: "intent", intent: "repeat", text: "Your change is 2.65."), .unprovidedAmount),
        ("an amount in words", reply(request(), type: "intent", intent: "repeat", text: "Twenty dollars."), .unprovidedAmount),
        ("overlong text", reply(request(), type: "intent", intent: "repeat", text: String(repeating: "a", count: 401)), .textTooLong),
        ("control characters", reply(request(), type: "intent", intent: "repeat", text: "ok\u{0007}"), .controlCharacters),
    ])
    func rejects(_ name: String, _ data: Data, _ rejection: AstraRejection) {
        #expect(AstraResponseValidator.validate(data, for: base) == .failure(rejection), "\(name)")
    }

    @Test func rejectsARepliesForAnotherRequestOrSession() {
        let other = AstraRequest(
            requestID: RequestID(), sessionID: base.sessionID, installID: base.installID, kind: .interpretCommand,
            screen: "home", transcript: "x", context: .empty
        )
        #expect(AstraResponseValidator.validate(reply(other, type: "unsupported"), for: base) == .failure(.mismatchedRequest))
        let otherSession = AstraRequest(
            requestID: base.requestID, sessionID: UUID(), installID: base.installID, kind: .interpretCommand,
            screen: "home", transcript: "x", context: .empty
        )
        #expect(AstraResponseValidator.validate(reply(otherSession, type: "unsupported"), for: base) == .failure(.mismatchedSession))
    }

    @Test func answersAreAllowedOnlyForQuestionsAndOnlyWithProvidedAmounts() {
        let question = request(kind: .askQuestion, context: AstraContext(currency: .usd, total: 17_35, paid: 20_00, expectedChange: 2_65))
        #expect(AstraResponseValidator.validate(reply(question, type: "answer", text: "Your change should be 2.65 USD."), for: question)
            == .success(.answer("Your change should be 2.65 USD.")))
        #expect(AstraResponseValidator.validate(reply(question, type: "answer", text: "Your change should be 3 USD."), for: question)
            == .failure(.unprovidedAmount))
    }

    @Test func generalAnswersOnlyForQuestionsWithOrdinaryNumbersAllowed() {
        let question = request(kind: .askQuestion, context: AstraContext(currency: .usd, total: 17_35, paid: 20_00, expectedChange: 2_65))
        #expect(AstraResponseValidator.validate(reply(question, type: "general", text: "Most people have 2 hands and 10 fingers."), for: question)
            == .success(.general("Most people have 2 hands and 10 fingers.")))
        #expect(AstraResponseValidator.validate(reply(base, type: "general", text: "Hi!"), for: base) == .failure(.wrongTypeForKind))
        for text in ["That costs about 40 dollars.", "You should get $5 back.", "Twenty dirhams is a lot.", "Your change is 3 USD."] {
            #expect(AstraResponseValidator.validate(reply(question, type: "general", text: text), for: question) == .failure(.unprovidedAmount), "\(text)")
        }
        #expect(AstraResponseValidator.validate(reply(question, type: "general", text: "NaviNote says your change is 2.65 USD."), for: question)
            == .success(.general("NaviNote says your change is 2.65 USD.")))
    }

    @Test func neverAboutWhetherANoteIsGenuine() {
        let question = request(kind: .askQuestion)
        for text in ["That note looks genuine.", "Here is how to spot a counterfeit."] {
            #expect(AstraResponseValidator.validate(reply(question, type: "general", text: text), for: question) == .failure(.noteAuthenticity), "\(text)")
            #expect(AstraResponseValidator.validate(reply(question, type: "answer", text: text), for: question) == .failure(.noteAuthenticity), "\(text)")
        }
    }

    @Test func moneyGuardMatchesTheBackend() {
        let context = AstraContext(currency: .usd, total: 17_35, paid: 20_00, expectedChange: 2_65)
        #expect(AstraAmountGuard.mentionsOnlyProvidedMoney("It's 25 degrees and 3 o'clock somewhere.", in: context))
        #expect(AstraAmountGuard.mentionsOnlyProvidedMoney("Paid 20 dollars.", in: context))
        #expect(!AstraAmountGuard.mentionsOnlyProvidedMoney("Paid 21 dollars.", in: context))
        #expect(!AstraAmountGuard.mentionsOnlyProvidedMoney("fifty dollars", in: context))
        #expect(!AstraAmountGuard.mentionsOnlyProvidedMoney("$1,500 please", in: context))
    }

    @Test func amountGuardMatchesTheBackend() {
        let context = AstraContext(currency: .usd, total: 17_35, paid: 20_00, expectedChange: 2_65)
        #expect(AstraAmountGuard.mentionsOnlyProvidedAmounts("The total is 17.35 USD; you paid 20.", in: context))
        #expect(AstraAmountGuard.mentionsOnlyProvidedAmounts("Change: 2 dollars and 65 cents.", in: context))
        #expect(!AstraAmountGuard.mentionsOnlyProvidedAmounts("Change: 3 dollars.", in: context))
        #expect(AstraAmountGuard.mentionsOnlyProvidedAmounts("Add one note at a time.", in: context))
        #expect(AstraAmountGuard.numbers(in: "1,000.50 and 7") == ["1000.50", "7"])
        #expect(AstraAmountGuard.allowedNumbers(in: AstraContext(currency: .aed, total: 1000_00, expectedChange: 5))
            == ["1000", "1000.00", "0", "0.05", "05", "5"])
    }
}

// MARK: - State machine

@Suite("Astra in the state machine")
struct AstraStateMachineTests {
    private func pending(_ h: inout Harness) -> RequestID {
        let result = h.send(.interpretWithAstra)
        guard case .applied(let effects) = result, case .interpretWithAstra(let id) = effects.first else {
            Issue.record("interpretWithAstra not applied")
            return RequestID()
        }
        return id
    }

    private func event(_ id: RequestID, _ intent: AstraIntent?, generation: SessionGeneration) -> NaviNoteAction {
        .serviceEvent(ServiceEvent(requestID: id, generation: generation, payload: .astraInterpretation(intent)))
    }

    @Test func oneRequestAtATimeAndStateOtherwiseUnchanged() {
        var h = Harness.at(.acquiringTotal)
        let before = h.state
        let id = pending(&h)
        #expect(h.state.pendingAstraRequest == id)
        #expect(h.state.phase == before.phase)
        #expect(h.state.lastAnnouncement == before.lastAnnouncement)
        #expect(h.send(.interpretWithAstra) == .ignored(.scanAlreadyInProgress))
    }

    @Test func anAllowlistedIntentIsHandledLikeAButton() {
        var h = Harness.at(.acquiringTotal)
        let id = pending(&h)
        let result = h.send(event(id, .repeatInstruction, generation: h.state.generation))
        #expect(result.effects == [.announce(.askForTotal)])
        #expect(h.state.pendingAstraRequest == nil)
    }

    @Test func anIntentThatIsNotValidHereChangesNothing() {
        var h = Harness()
        let id = pending(&h)
        let result = h.send(event(id, .removeLastNote, generation: h.state.generation))
        #expect(result == .applied([.transient(.notAvailableHere)]))
        #expect(h.state.phase == .home)
    }

    @Test func noIntentSaysItDidNotUnderstand() {
        var h = Harness()
        let id = pending(&h)
        #expect(h.send(event(id, nil, generation: h.state.generation)) == .applied([.transient(.notUnderstood)]))
        #expect(h.state.pendingAstraRequest == nil)
    }

    @Test func helpOpensHelp() {
        var h = Harness()
        let id = pending(&h)
        #expect(h.send(event(id, .help, generation: h.state.generation)) == .applied([.showHelp]))
    }

    @Test func staleAndUnexpectedRepliesAreDropped() {
        var h = Harness.at(.acquiringTotal)
        let id = pending(&h)
        let oldGeneration = h.state.generation
        #expect(h.send(event(RequestID(), .scan, generation: oldGeneration)) == .ignored(.unexpectedRequest))
        h.apply(.cancel)
        #expect(h.state.pendingAstraRequest == nil, "Cancel clears the pending request")
        let before = h.state
        #expect(h.send(event(id, .startCheckout, generation: oldGeneration)) == .ignored(.staleGeneration))
        #expect(h.state == before)
    }

    @Test func astraCannotConfirmAProposedTotal() {
        var h = Harness.at(.confirmingTotal)
        let id = pending(&h)
        // Every intent, applied at the confirmation step, leaves the total unconfirmed.
        for intent in AstraIntent.allCases {
            var copy = h
            _ = copy.send(event(id, intent, generation: copy.state.generation))
            #expect(copy.state.checkout.confirmedTotal == nil, "\(intent) confirmed the total")
        }
    }
}

// MARK: - Store

@MainActor
private final class NoHaptics: HapticsPlaying {
    func play(_ event: HapticEvent) {}
}

@MainActor
@Suite("Astra in the store")
struct AstraStoreTests {
    private let audio = AudioHarness(voiceOver: true)
    private let scan = ScanHarness()

    private func makeStore(_ astra: FakeAstraService?, enabled: Bool = true) -> NaviNoteStore {
        NaviNoteStore(
            audio: audio.coordinator, scanner: scan.scanner, haptics: NoHaptics(),
            astra: astra, astraEnabled: { enabled }, astraInstallID: { UUID(uuidString: "33333333-3333-4333-8333-333333333333")! }
        )
    }

    private var spoken: [String] { audio.accessibility.posts.map(\.text) }

    @Test func recognisedCommandsNeverReachAstra() async {
        let astra = FakeAstraService(FakeAstraService.reply("intent", intent: "scan"))
        let store = makeStore(astra)
        store.handleCommand("start checkout")
        await drainMainActor()
        #expect(store.state.phase == .checkoutIntroduction)
        #expect(astra.requests.isEmpty)
    }

    @Test func unrecognisedWordsAreInterpretedAndTheStateMachineDecides() async {
        let astra = FakeAstraService(FakeAstraService.reply("intent", intent: "startReadingCurrency"))
        let store = makeStore(astra)
        store.handleCommand("what kind of money do I have here")
        #expect(await eventually { store.state.phase == .readingCurrency })
        let sent = astra.requests.first
        #expect(sent?.kind == .interpretCommand)
        #expect(sent?.screen == "home")
        #expect(sent?.transcript == "what kind of money do I have here")
        #expect(spoken.contains(VoiceCopy.checkingMeaning))
    }

    @Test func switchedOffOrNotSetUpNothingIsSent() async {
        let astra = FakeAstraService(FakeAstraService.reply("intent", intent: "scan"))
        let off = makeStore(astra, enabled: false)
        off.handleCommand("blah blah")
        await drainMainActor()
        #expect(astra.requests.isEmpty)
        #expect(spoken.last == VoiceCopy.notUnderstood)

        let notSetUp = makeStore(nil)
        notSetUp.handleCommand("blah blah")
        #expect(spoken.last == VoiceCopy.notUnderstood)
    }

    @Test(arguments: [AstraFailure.timeout, .rateLimited, .unavailable, .network, .rejected])
    func failuresFallBackToNotUnderstood(_ failure: AstraFailure) async {
        let store = makeStore(FakeAstraService(.failure(failure)))
        store.handleCommand("blah blah")
        #expect(await eventually { spoken.last == VoiceCopy.notUnderstood })
        #expect(store.state.pendingAstraRequest == nil)
        #expect(store.state.phase == .home)
    }

    @Test func invalidRepliesAreDiscarded() async {
        let store = makeStore(FakeAstraService(FakeAstraService.reply("intent", intent: "confirmTotal")))
        store.send(.startCheckout)
        store.handleCommand("please sort it all out")
        #expect(await eventually { spoken.last == VoiceCopy.notUnderstood })
        #expect(store.state.phase == .checkoutIntroduction)
    }

    @Test func cancellingDropsAPendingInterpretation() async {
        let astra = FakeAstraService(.hang)
        let store = makeStore(astra)
        store.send(.startCheckout)
        store.handleCommand("hmm what")
        #expect(await eventually { !astra.requests.isEmpty })
        store.send(.cancel)
        await drainMainActor(200)
        #expect(store.state.phase == .home)
        #expect(store.state.pendingAstraRequest == nil)
        #expect(!spoken.contains(VoiceCopy.notUnderstood))
    }

    @Test func sessionIDsChangeWithEachNewSession() async {
        let astra = FakeAstraService(FakeAstraService.reply("unsupported"))
        let store = makeStore(astra)
        store.handleCommand("one")
        _ = await eventually { store.state.pendingAstraRequest == nil && astra.requests.count == 1 }
        store.handleCommand("two")
        _ = await eventually { store.state.pendingAstraRequest == nil && astra.requests.count == 2 }
        store.send(.startCheckout)
        store.send(.cancel)
        store.handleCommand("three")
        _ = await eventually { astra.requests.count == 3 }
        let ids = astra.requests.map(\.sessionID)
        #expect(ids.count == 3)
        #expect(ids[0] == ids[1])
        #expect(ids[1] != ids[2])
    }
}

// MARK: - Configuration

@Suite("Astra configuration")
struct AstraConfigurationTests {
    @Test func acceptsHTTPSAndRejectsUnsafeURLs() {
        #expect(AstraConfiguration.validatedURL("https://api.navinote.example") != nil)
        #expect(AstraConfiguration.validatedURL("") == nil)
        #expect(AstraConfiguration.validatedURL("   ") == nil)
        #expect(AstraConfiguration.validatedURL("http://api.navinote.example") == nil, "Plain HTTP to a public host")
        #expect(AstraConfiguration.validatedURL("https://user:pass@api.navinote.example") == nil)
        #expect(AstraConfiguration.validatedURL("ftp://api.navinote.example") == nil)
        #expect(AstraConfiguration.validatedURL("https://api.navinote.example?key=abc") == nil)
    }

    @Test func debugBuildsMayUseThisMacOnTheLocalNetwork() {
        // Tests run in Debug. In Release this code path is compiled out.
        #expect(AstraConfiguration.validatedURL("http://my-mac.local:8787") != nil)
        #expect(AstraConfiguration.validatedURL("http://192.168.1.20:8787") != nil)
        #expect(AstraConfiguration.validatedURL("http://8.8.8.8:8787") == nil)
    }

    @Test func notSetUpInTheTestBuild() {
        #expect(AstraConfiguration.baseURL() == nil)
    }
}
