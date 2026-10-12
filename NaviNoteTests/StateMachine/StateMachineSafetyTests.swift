import Testing
@testable import NaviNote

@Suite("State machine: invalid transitions, cancel, reset")
struct StateMachineSafetyTests {
    /// Actions that do something somewhere, used to probe every phase.
    static let probeActions: [NaviNoteAction] = [
        .startCheckout, .continueCheckout, .startReadingCurrency, .startChangeVerification, .closeAskNaviNote,
        .stopScan, .enterTotalManually(minorUnits: 5_00, currency: .usd), .selectTotalCurrency(.usd),
        .confirmTotal, .rejectTotal, .selectPaymentNoteManually(note(.usd, 5)), .confirmPaymentNote,
        .rejectPaymentNote, .removeLastPaymentNote, .finishPaymentNotes, .cancelAstraRequest, .startReturnedChange, .enterExpectedChange(minorUnits: 5_00, currency: .usd),
        .selectExpectedChangeCurrency(.usd), .confirmExpectedChange, .rejectExpectedChange,
        .addReturnedNoteManually(note(.usd, 5)), .confirmReturnedNote, .rejectReturnedNote, .removeLastReturnedNote, .finishReturnedChange,
        .continueCollectingChange, .retry, .dismissPermissionNotice, .finish,
    ]

    @Test func checkoutStartsOnlyFromHome() {
        for phase in allPhases where phase != .home {
            var h = Harness.at(phase)
            let before = h.state
            #expect(h.send(.startCheckout) == .ignored(.invalidInPhase), "startCheckout accepted in \(phase)")
            #expect(h.state == before)
        }
    }

    @Test func ignoredActionsNeverChangeState() {
        for phase in allPhases {
            for action in Self.probeActions {
                var h = Harness.at(phase)
                let before = h.state
                let result = h.send(action)
                switch result {
                case .ignored, .declined:
                    #expect(h.state == before, "\(action.logName) in \(phase) changed state without applying")
                case .applied:
                    break
                }
            }
        }
    }

    @Test func homeRejectsWorkflowActions() {
        let invalid: [NaviNoteAction] = [
            .continueCheckout, .confirmTotal, .rejectTotal, .confirmPaymentNote, .removeLastPaymentNote,
            .finishPaymentNotes, .startReturnedChange,
            .addReturnedNoteManually(note(.usd, 5)), .removeLastReturnedNote, .finishReturnedChange,
            .finish, .cancel, .retry, .closeAskNaviNote, .startScan, .stopScan,
            .enterTotalManually(minorUnits: 1_00, currency: .usd),
        ]
        for action in invalid {
            var h = Harness()
            #expect(!h.send(action).isApplied, "\(action.logName) should not apply at home")
            #expect(h.state == NaviNoteState())
        }
    }

    @Test func cancelFromEveryNonHomePhaseReturnsHomeWithANewGeneration() {
        for phase in allPhases where phase != .home {
            var h = Harness.at(phase)
            let generation = h.state.generation
            let result = h.send(.cancel)
            #expect(result.effects.first == .cancelAllPendingWork, "\(phase)")
            #expect(result.effects.contains(.announce(.cancelled)))
            #expect(h.state.phase == .home)
            #expect(h.state.generation == generation.next())
            #expect(h.state.checkout == .empty)
            #expect(h.state.returnedChange == nil)
            #expect(h.state.proposedTotal == nil)
            #expect(h.state.pendingRequest == nil)
            #expect(h.state.resumePoint == nil)
        }
    }

    @Test func cancelAtHomeIsIgnored() {
        var h = Harness()
        #expect(h.send(.cancel) == .ignored(.invalidInPhase))
    }

    @Test func resetAlwaysStartsANewSession() {
        for phase in allPhases {
            var h = Harness.at(phase)
            let generation = h.state.generation
            h.apply(.reset)
            #expect(h.state == NaviNoteState(generation: generation.next(), lastAnnouncement: .home))
        }
    }

    @Test func finishOnlyFromCompletedPhases() {
        let finishable: Set<Phase> = [.showingExpectedChange, .exactChange, .shortChange, .excessiveChange, .unresolvedChange, .readingCurrency]
        for phase in allPhases {
            var h = Harness.at(phase)
            #expect(h.send(.finish).isApplied == finishable.contains(phase), "\(phase)")
        }
    }

    @Test func interruptionsCannotStack() {
        var h = Harness.at(.askingNaviNote)
        #expect(h.send(.openAskNaviNote) == .ignored(.invalidInPhase))
        var e = Harness.at(.recoverableError(.interrupted))
        #expect(e.send(.openAskNaviNote) == .ignored(.invalidInPhase))
    }

    @Test func permitsMatchesHandle() {
        for phase in allPhases {
            for action in Self.probeActions {
                var h = Harness.at(phase)
                let permitted = h.machine.permits(action)
                #expect(permitted == h.send(action).isApplied, "\(action.logName) in \(phase)")
            }
        }
    }
}
