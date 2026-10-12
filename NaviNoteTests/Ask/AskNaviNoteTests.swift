import Foundation
import Testing
@testable import NaviNote

@Suite("Ask NaviNote: question matching")
struct AskQuestionRouterTests {
    @Test(arguments: [
        ("What's the total?", AskQuestion.total),
        ("What\u{2019}s the total", .total),
        ("what's the total", .total),
        ("how much does it cost", .total),
        ("How much change should I get back?", .changeExpected),
        ("what's my change", .changeExpected),
        ("How much change have I received?", .received),
        ("how much have I got back so far", .received),
        ("is anything still missing", .missing),
        ("how much more do I need", .missing),
        ("How much did I pay?", .paid),
        ("which currency are we using", .currency),
        ("what did you scan", .whatScanned),
        ("What should I do next?", .nextStep),
        ("now what", .nextStep),
        ("what was the last instruction", .lastInstruction),
        ("Explain this screen", .explainScreen),
        ("where am I", .explainScreen),
        ("what can I ask", .help),
        ("is this note real or fake", .authenticity),
        ("Is it genuine?", .authenticity),
        ("could this be counterfeit", .authenticity),
    ])
    func routes(_ text: String, _ question: AskQuestion) {
        #expect(AskQuestionRouter.route(text) == question, "\(text)")
    }

    @Test(arguments: ["send an email to my mum", "play some music", "what's the weather", "should I buy shares",
                      "repeat", "say that again", "close", "go back"])
    func leavesEverythingElseAlone(_ text: String) {
        #expect(AskQuestionRouter.route(text) == nil, "\(text)")
    }
}

@Suite("Ask NaviNote: answers")
struct AskAnswersTests {
    private func ask(_ question: AskQuestion, after phase: NaviNoteState.Phase) -> AskAnswer {
        var h = Harness.at(phase)
        h.apply(.openAskNaviNote)
        return AskAnswers.answer(question, state: h.state)
    }

    @Test func fromHomeNothingIsKnownYet() {
        #expect(ask(.total, after: .home) == .total(.none))
        #expect(ask(.currency, after: .home) == .currency(nil, confirmed: false))
        #expect(ask(.paid, after: .home) == .paid(nil, noteCount: 0, inCheckout: false))
        #expect(ask(.changeExpected, after: .home) == .changeExpected(.none))
        #expect(ask(.received, after: .home) == .received(nil, noteCount: 0))
        #expect(ask(.missing, after: .home) == .missing(.nothingYet))
        #expect(ask(.whatScanned, after: .home) == .whatScanned(nil))
        #expect(ask(.explainScreen, after: .home) == .explainScreen(.home))
    }

    @Test func afterCheckoutTheConfirmedFactsAreAnswered() {
        // Harness: 7 dollars total, paid with a 20.
        #expect(ask(.total, after: .showingExpectedChange) == .total(.confirmed(.usd(7_00))))
        #expect(ask(.currency, after: .showingExpectedChange) == .currency(.usd, confirmed: true))
        #expect(ask(.paid, after: .showingExpectedChange) == .paid(.usd(20_00), noteCount: 1, inCheckout: true))
        #expect(ask(.changeExpected, after: .showingExpectedChange) == .changeExpected(.due(.usd(13_00))))
        #expect(ask(.nextStep, after: .showingExpectedChange) == .nextStep(.showingExpectedChange, partlyPaid: false))
    }

    @Test func anUnconfirmedTotalIsSaidToBeUnconfirmed() {
        var h = Harness.at(.acquiringTotal)
        h.apply(.enterTotalManually(minorUnits: 42_00, currency: .aed), .openAskNaviNote)
        #expect(AskAnswers.answer(.total, state: h.state)
            == .total(.proposed(ProposedAmount(minorUnits: 42_00, currency: .aed, source: .manualEntry))))
        #expect(AskAnswers.answer(.currency, state: h.state) == .currency(.aed, confirmed: false))
        #expect(AnnouncementComposer.askAnswerText(AskAnswers.answer(.total, state: h.state))
            == "NaviNote read 42 dirhams, but you haven't confirmed the total yet.")
    }

    @Test func returnedChangeProgress() {
        var h = Harness.at(.collectingReturnedChange) // 13 dollars expected
        h.addManually(note(.usd, 10))
        h.apply(.openAskNaviNote)
        #expect(AskAnswers.answer(.received, state: h.state) == .received(.usd(10_00), noteCount: 1))
        #expect(AskAnswers.answer(.missing, state: h.state) == .missing(.changeMissing(.usd(3_00))))
        #expect(AnnouncementComposer.askAnswerText(AskAnswers.answer(.missing, state: h.state))
            == "3 dollars of your change is still missing.")
    }

    @Test func scannedReadingsAreReportedWithTheirStatus() {
        var h = Harness.at(.acquiringTotal)
        let request = h.startScan()
        h.apply(h.event(request, .totalCandidate(cameraTotal(25_00, .usd))))
        h.apply(.openAskNaviNote)
        let answer = AskAnswers.answer(.whatScanned, state: h.state)
        #expect(answer == .whatScanned(.total(ProposedAmount(minorUnits: 25_00, currency: .usd, source: .camera), confirmed: false)))
        #expect(AnnouncementComposer.askAnswerText(answer) == "NaviNote read a total of 25 dollars. It isn't confirmed yet.")
    }

    @Test func partlyPaidNextStepMentionsAnotherNote() {
        var h = Harness.at(.acquiringTotal)
        h.apply(.enterTotalManually(minorUnits: 25_00, currency: .aed), .confirmTotal)
        h.apply(.selectPaymentNoteManually(note(.aed, 20)), .confirmPaymentNote, .openAskNaviNote)
        let answer = AskAnswers.answer(.nextStep, state: h.state)
        #expect(answer == .nextStep(.acquiringPaymentNote, partlyPaid: true))
        #expect(AnnouncementComposer.askAnswerText(answer).contains("Add another note"))
    }

    @Test func lastInstructionIsTheStepUnderneath() {
        let answer = ask(.lastInstruction, after: .acquiringTotal)
        #expect(answer == .lastInstruction(.askForTotal))
        #expect(AnnouncementComposer.askAnswerText(answer).hasSuffix(AnnouncementComposer.text(for: .askForTotal)))
    }

    @Test func answersNeverClaimGuaranteesOrGenuineness() {
        for question in AskQuestion.allCases {
            for phase in allPhases where !phase.isInterruption {
                let text = AnnouncementComposer.askAnswerText(ask(question, after: phase)).lowercased()
                for claim in ["guarantee", "this note is genuine", "the note is genuine", "is real money",
                              "counterfeit", "payment succeeded", "payment was successful"] {
                    #expect(!text.contains(claim), "\(question) in \(phase): \(text)")
                }
            }
        }
        // The Read Currency explanation carries the required disclaimer.
        #expect(AnnouncementComposer.askAnswerText(.explainScreen(.readingCurrency)).contains("can't tell whether a note is genuine"))
    }
}

@Suite("Ask NaviNote: state machine")
struct AskStateMachineTests {
    @Test func questionsOnlyApplyInAskNaviNoteAndChangeNoWorkflowState() {
        var h = Harness.at(.showingExpectedChange)
        #expect(h.send(.askQuestion(.total)) == .ignored(.invalidInPhase))
        #expect(h.send(.askUnanswerable) == .ignored(.invalidInPhase))
        h.apply(.openAskNaviNote)
        let before = h.state
        let result = h.send(.askQuestion(.changeExpected))
        #expect(result == .applied([.announce(.askAnswer(.changeExpected(.due(.usd(13_00)))))]))
        var expected = before
        expected.lastAnnouncement = .askAnswer(.changeExpected(.due(.usd(13_00))))
        #expect(h.state == expected, "Only the message changes")
        // Repeat repeats the answer.
        #expect(h.send(.repeatLastInstruction).effects == [.announce(.askAnswer(.changeExpected(.due(.usd(13_00)))))])
        // Close goes back to the step and its instruction.
        h.apply(.closeAskNaviNote)
        #expect(h.state.phase == .showingExpectedChange)
        #expect(h.state.checkout == before.checkout)
    }

    @Test func unanswerableQuestionsSaySo() {
        var h = Harness()
        h.apply(.openAskNaviNote)
        #expect(h.send(.askUnanswerable) == .applied([.announce(.askAnswer(.cantAnswer))]))
    }

    @Test func astraAnswersAreSpokenAndFailuresFallBack() {
        var h = Harness()
        h.apply(.openAskNaviNote)
        guard case .applied(let effects) = h.send(.askAstra), case .askWithAstra(let id) = effects.first else {
            Issue.record("askAstra not applied"); return
        }
        #expect(h.send(.askAstra) == .ignored(.scanAlreadyInProgress))
        let answered = h.send(.serviceEvent(ServiceEvent(requestID: id, generation: h.state.generation, payload: .astraAnswer(AstraAnswer(text: "You're on the home screen.", isGeneral: false)))))
        #expect(answered == .applied([.announce(.astraAnswer(AstraAnswer(text: "You're on the home screen.", isGeneral: false)))]))

        guard case .applied(let second) = h.send(.askAstra), case .askWithAstra(let id2) = second.first else {
            Issue.record("askAstra not applied"); return
        }
        let failed = h.send(.serviceEvent(ServiceEvent(requestID: id2, generation: h.state.generation, payload: .astraAnswer(nil))))
        #expect(failed == .applied([.announce(.askAnswer(.astraUnavailable))]))
    }

    @Test func closingCancelsAPendingQuestionAndIgnoresALateAnswer() {
        var h = Harness.at(.acquiringTotal)
        h.apply(.openAskNaviNote)
        guard case .applied(let effects) = h.send(.askAstra), case .askWithAstra(let id) = effects.first else {
            Issue.record("askAstra not applied"); return
        }
        let closed = h.send(.closeAskNaviNote)
        #expect(closed.effects.contains(.cancelAstra(id)))
        #expect(h.state.pendingAstraRequest == nil)
        let before = h.state
        let late = h.send(.serviceEvent(ServiceEvent(requestID: id, generation: h.state.generation, payload: .astraAnswer(AstraAnswer(text: "Late.", isGeneral: false)))))
        #expect(late == .ignored(.unexpectedRequest))
        #expect(h.state == before)
    }

    @Test func leavingAScreenCancelsAPendingInterpretation() {
        var h = Harness.at(.acquiringTotal)
        guard case .applied(let effects) = h.send(.interpretWithAstra), case .interpretWithAstra(let id) = effects.first else {
            Issue.record("interpretWithAstra not applied"); return
        }
        // A button press moves on before Astra replies.
        let moved = h.send(.enterTotalManually(minorUnits: 5_00, currency: .usd))
        #expect(moved.effects.contains(.cancelAstra(id)))
        // The late "cancel" proposal from the old screen does nothing.
        #expect(h.send(.serviceEvent(ServiceEvent(requestID: id, generation: h.state.generation, payload: .astraInterpretation(.cancel))))
            == .ignored(.unexpectedRequest))
        #expect(h.state.phase == .confirmingTotal)
    }
}

@MainActor
private final class QuietHaptics: HapticsPlaying {
    func play(_ event: HapticEvent) {}
}

@MainActor
@Suite("Ask NaviNote: store")
struct AskStoreTests {
    private let audio = AudioHarness(voiceOver: true)
    private let scan = ScanHarness()

    private func makeStore(_ astra: FakeAstraService? = nil, enabled: Bool = true) -> NaviNoteStore {
        NaviNoteStore(
            audio: audio.coordinator, scanner: scan.scanner, haptics: QuietHaptics(),
            astra: astra, astraEnabled: { enabled }, astraInstallID: { UUID() }
        )
    }

    private func toCheckoutResult(_ store: NaviNoteStore) {
        store.send(.startCheckout)
        store.send(.continueCheckout)
        store.send(.enterTotalManually(minorUnits: 17_35, currency: .usd))
        store.send(.confirmTotal)
        store.send(.selectPaymentNoteManually(note(.usd, 20)))
        store.send(.confirmPaymentNote)
        store.send(.openAskNaviNote)
    }

    @Test func spokenQuestionsAreAnsweredOnTheIPhone() async {
        let astra = FakeAstraService(FakeAstraService.reply("answer", text: "should not be used"))
        let store = makeStore(astra)
        toCheckoutResult(store)
        store.handleCommand("How much change should I get?")
        #expect(store.message == "You should receive 2 dollars and 65 cents in change, worked out from the total and notes you confirmed.")
        await drainMainActor()
        #expect(astra.requests.isEmpty, "Deterministic answers never use Astra")
    }

    @Test(arguments: ["go back", "close", "Close.", "exit", "close this"])
    func commandsStillWorkInsideAskNaviNote(_ command: String) {
        let store = makeStore()
        toCheckoutResult(store)
        store.handleCommand(command)
        #expect(store.state.phase == .showingExpectedChange, "\(command)")
    }

    /// Device finding (2026-10-08): saying "Close" in Ask NaviNote got
    /// a polite refusal because "close" wasn't a command.
    @Test func closeIsNeverTreatedAsAQuestion() async {
        let astra = FakeAstraService(FakeAstraService.reply("answer", text: "x"))
        let store = makeStore(astra)
        store.send(.openAskNaviNote)
        store.handleCommand("close")
        #expect(store.state.phase == .home)
        await drainMainActor()
        #expect(astra.requests.isEmpty)
    }

    @Test func withoutAstraOtherQuestionsGetAPoliteRefusal() async {
        let astra = FakeAstraService(FakeAstraService.reply("answer", text: "x"))
        let store = makeStore(astra, enabled: false)
        store.send(.openAskNaviNote)
        store.ask("send an email to my mum")
        #expect(store.message == AnnouncementComposer.askAnswerText(.cantAnswer))
        await drainMainActor()
        #expect(astra.requests.isEmpty)
    }

    @Test func withAstraOnUnmatchedQuestionsAreAskedAboutTheScreenUnderneath() async {
        let astra = FakeAstraService(FakeAstraService.reply("answer", text: "You paid 20 USD, so 2.65 USD comes back."))
        let store = makeStore(astra)
        toCheckoutResult(store)
        store.ask("so am I getting something back or not")
        #expect(await eventually { store.message == "You paid 20 USD, so 2.65 USD comes back." })
        let sent = astra.requests.first
        #expect(sent?.kind == .askQuestion)
        #expect(sent?.screen == "showingExpectedChange")
        #expect(sent?.context.expectedChange == 2_65)
        #expect(sent?.context.total == 17_35)
    }

    @Test func anAstraAnswerWithAnUnprovidedAmountIsDiscarded() async {
        let store = makeStore(FakeAstraService(FakeAstraService.reply("answer", text: "You should get 5 USD back.")))
        toCheckoutResult(store)
        store.ask("so am I getting something back or not")
        #expect(await eventually { store.message == AnnouncementComposer.askAnswerText(.astraUnavailable) })
    }

    /// Accessibility companion (approved 2026-10-09): general questions get
    /// a labelled general answer.
    /// Safety-critical: never left to Astra, even with Astra on.
    @Test func authenticityQuestionsAreAnsweredByNaviNoteItself() async {
        let astra = FakeAstraService(FakeAstraService.reply("general", text: "x"))
        let store = makeStore(astra)
        store.send(.openAskNaviNote)
        store.ask("is this note real or fake")
        #expect(store.message == "NaviNote reads a note's printed value only. It can't tell whether a note is genuine.")
        await drainMainActor()
        #expect(astra.requests.isEmpty)
    }

    @Test func generalQuestionsGetALabelledGeneralAnswer() async {
        let store = makeStore(FakeAstraService(FakeAstraService.reply("general", text: "I'm doing well, thanks! How can I help?")))
        store.send(.openAskNaviNote)
        store.ask("how are you, what's up")
        #expect(await eventually { store.message == "I'm doing well, thanks! How can I help?" })
        #expect(store.state.lastAnnouncement == .astraAnswer(AstraAnswer(text: "I'm doing well, thanks! How can I help?", isGeneral: true)))
    }

    @Test func generalAnswersStillCannotStateMoney() async {
        let store = makeStore(FakeAstraService(FakeAstraService.reply("general", text: "A coffee usually costs about 15 dirhams.")))
        toCheckoutResult(store)
        store.ask("how much is a coffee in Dubai")
        #expect(await eventually { store.message == AnnouncementComposer.askAnswerText(.astraUnavailable) })
    }

    @Test func proposedActionsAreIgnoredInAskNaviNote() async {
        let store = makeStore(FakeAstraService(FakeAstraService.reply("intent", intent: "cancel")))
        toCheckoutResult(store)
        store.ask("ugh forget all this")
        #expect(await eventually { store.message == AnnouncementComposer.askAnswerText(.astraUnavailable) })
        #expect(store.state.phase == .askingNaviNote, "Only answers are used here")
    }

    /// Phase 13: leaving the app while Astra is working drops the request,
    /// so a late reply can't act on a screen the person has left.
    @Test func goingToTheBackgroundDropsAPendingQuestion() async {
        let astra = FakeAstraService(.hang)
        let store = makeStore(astra)
        toCheckoutResult(store)
        store.ask("so am I getting something back or not")
        #expect(await eventually { !astra.requests.isEmpty })
        store.lifecycleChanged(to: .background)
        #expect(store.state.pendingAstraRequest == nil)
        await drainMainActor(200)
        #expect(store.state.phase == .askingNaviNote, "Nothing else changes")
        #expect(store.message == AnnouncementComposer.text(for: .askNaviNoteOpened), "No late answer was shown")
    }

    @Test func goingToTheBackgroundWithNothingPendingDoesNothing() {
        let store = makeStore()
        toCheckoutResult(store)
        let before = store.state
        store.lifecycleChanged(to: .background)
        #expect(store.state == before)
    }

    @Test func closingWhileWaitingDropsTheAnswer() async {
        let astra = FakeAstraService(.hang)
        let store = makeStore(astra)
        toCheckoutResult(store)
        store.ask("so am I getting something back or not")
        #expect(await eventually { !astra.requests.isEmpty })
        #expect(store.isWaitingForAstra)
        store.send(.closeAskNaviNote)
        await drainMainActor(200)
        #expect(store.state.phase == .showingExpectedChange)
        #expect(!store.isWaitingForAstra)
    }
}
