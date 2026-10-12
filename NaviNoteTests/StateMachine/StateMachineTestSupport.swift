import Testing
@testable import NaviNote

typealias Phase = NaviNoteState.Phase

/// Builds a state machine with predictable request IDs and drives it to a
/// given point in the workflow using only public actions.
struct Harness {
    let ids: SequentialRequestIDs
    var machine: NaviNoteStateMachine

    init() {
        let ids = SequentialRequestIDs()
        self.ids = ids
        machine = NaviNoteStateMachine(makeRequestID: { ids.make() })
    }

    var state: NaviNoteState { machine.state }

    @discardableResult
    mutating func send(_ action: NaviNoteAction) -> TransitionResult {
        machine.handle(action)
    }

    /// Sends and requires the action to be applied.
    mutating func apply(_ actions: NaviNoteAction..., sourceLocation: SourceLocation = #_sourceLocation) {
        for action in actions {
            let result = machine.handle(action)
            #expect(result.isApplied, "\(action.logName) was not applied: \(result)", sourceLocation: sourceLocation)
        }
    }

    /// Starts a scan and returns the service event factory for it.
    mutating func startScan() -> PendingRequest {
        apply(.startScan)
        return state.pendingRequest!
    }

    func event(_ request: PendingRequest, _ payload: ServiceEvent.Payload) -> NaviNoteAction {
        .serviceEvent(ServiceEvent(requestID: request.id, generation: state.generation, payload: payload))
    }

    /// Manual returned notes always need confirmation.
    mutating func addManually(_ denomination: SupportedDenomination, sourceLocation: SourceLocation = #_sourceLocation) {
        apply(.addReturnedNoteManually(denomination), .confirmReturnedNote, sourceLocation: sourceLocation)
    }

    // MARK: - Reaching phases

    static func at(_ phase: Phase) -> Harness {
        var h = Harness()
        h.drive(to: phase)
        #expect(h.state.phase == phase)
        return h
    }

    mutating func drive(to phase: Phase) {
        switch phase {
        case .home:
            break
        case .checkoutIntroduction:
            apply(.startCheckout)
        case .acquiringTotal:
            drive(to: .checkoutIntroduction); apply(.continueCheckout)
        case .confirmingTotal:
            drive(to: .acquiringTotal); apply(.enterTotalManually(minorUnits: 7_00, currency: .usd))
        case .acquiringPaymentNote:
            drive(to: .confirmingTotal); apply(.confirmTotal)
        case .confirmingPaymentNote:
            drive(to: .acquiringPaymentNote); apply(.selectPaymentNoteManually(note(.usd, 20)))
        case .showingExpectedChange:
            drive(to: .confirmingPaymentNote); apply(.confirmPaymentNote)
        case .collectingReturnedChange:
            // Expected change is 13 dollars.
            drive(to: .showingExpectedChange); apply(.startReturnedChange)
        case .exactChange:
            drive(to: .collectingReturnedChange)
            addManually(note(.usd, 10)); addManually(note(.usd, 2)); addManually(note(.usd, 1))
        case .shortChange:
            drive(to: .collectingReturnedChange); addManually(note(.usd, 10)); apply(.finishReturnedChange)
        case .excessiveChange:
            drive(to: .collectingReturnedChange); addManually(note(.usd, 20))
        case .unresolvedChange:
            drive(to: .collectingReturnedChange); apply(.finishReturnedChange)
        case .confirmingReturnedNote:
            drive(to: .collectingReturnedChange); apply(.addReturnedNoteManually(note(.usd, 5)))
        case .settingExpectedChange:
            apply(.startChangeVerification)
        case .confirmingExpectedChange:
            drive(to: .settingExpectedChange); apply(.enterExpectedChange(minorUnits: 30_00, currency: nil))
        case .readingCurrency:
            apply(.startReadingCurrency)
        case .askingNaviNote:
            apply(.openAskNaviNote)
        case .recoverableError(let issue):
            drive(to: .acquiringTotal)
            let request = startScan()
            apply(event(request, .failed(issue)))
        case .permissionDenied(let kind):
            drive(to: .acquiringTotal)
            let request = startScan()
            apply(event(request, .permissionDenied(kind)))
        }
    }
}

/// Every phase, for exhaustive tests.
let allPhases: [Phase] = [
    .home, .checkoutIntroduction, .acquiringTotal, .confirmingTotal, .acquiringPaymentNote,
    .confirmingPaymentNote, .showingExpectedChange, .settingExpectedChange, .confirmingExpectedChange,
    .collectingReturnedChange, .confirmingReturnedNote,
    .exactChange, .shortChange, .excessiveChange, .unresolvedChange, .readingCurrency, .askingNaviNote,
    .recoverableError(.cameraUnavailable), .permissionDenied(.camera),
]
