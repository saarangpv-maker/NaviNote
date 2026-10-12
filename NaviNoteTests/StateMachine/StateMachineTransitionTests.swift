import Testing
@testable import NaviNote

@Suite("State machine: valid transitions")
struct StateMachineTransitionTests {
    @Test func startsAtHomeWithAWelcome() {
        let h = Harness()
        #expect(h.state.phase == .home)
        #expect(h.state.generation == .initial)
        #expect(h.state.lastAnnouncement == .welcome)
        #expect(h.state.pendingRequest == nil)
    }

    @Test func everyPhaseIsReachableThroughPublicActions() {
        for phase in allPhases {
            let h = Harness.at(phase)
            #expect(h.state.phase == phase)
        }
    }

    @Test func checkoutHappyPathWithChangeDue() {
        var h = Harness()
        #expect(h.send(.startCheckout) == .applied([.announce(.checkoutIntroduction)]))
        h.apply(.continueCheckout)
        #expect(h.state.phase == .acquiringTotal)

        h.apply(.enterTotalManually(minorUnits: 17_35, currency: .usd))
        #expect(h.state.phase == .confirmingTotal)
        #expect(h.state.proposedTotal == ProposedAmount(minorUnits: 17_35, currency: .usd, source: .manualEntry))
        #expect(h.state.checkout.confirmedTotal == nil, "A proposal is not a confirmed total")

        h.apply(.confirmTotal)
        #expect(h.state.phase == .acquiringPaymentNote)
        #expect(h.state.checkout.confirmedTotal == ConfirmedAmount(money: .usd(17_35), source: .manualEntry))

        h.apply(.selectPaymentNoteManually(note(.usd, 20)))
        #expect(h.state.phase == .confirmingPaymentNote)
        #expect(h.state.checkout.confirmedPayment == nil, "A proposal is not a confirmed payment")

        let result = h.send(.confirmPaymentNote)
        #expect(h.state.phase == .showingExpectedChange)
        #expect(h.state.checkout.outcome == .changeDue(.usd(2_65)))
        #expect(result.effects.contains(.announce(.checkoutResult(total: .usd(17_35), payment: .usd(20_00), outcome: .changeDue(.usd(2_65))))))

        h.apply(.startReturnedChange)
        #expect(h.state.phase == .collectingReturnedChange)
        #expect(h.state.returnedChange?.expectedChange == .usd(2_65))
    }

    @Test func exactPaymentOffersNoReturnedChangeStep() {
        var h = Harness.at(.acquiringTotal)
        h.apply(.enterTotalManually(minorUnits: 50_00, currency: .aed), .confirmTotal)
        h.apply(.selectPaymentNoteManually(note(.aed, 50)), .confirmPaymentNote)
        #expect(h.state.checkout.outcome == .exactPayment)
        #expect(h.send(.startReturnedChange) == .ignored(.nothingToActOn))
        #expect(!h.machine.permits(.startReturnedChange))
        h.apply(.finish)
        #expect(h.state.phase == .home)
    }

    @Test func aNoteThatDoesNotCoverTheTotalAsksForAnother() {
        var h = Harness.at(.acquiringTotal)
        h.apply(.enterTotalManually(minorUnits: 750_00, currency: .kes), .confirmTotal)
        h.apply(.selectPaymentNoteManually(note(.kes, 500)))
        let result = h.send(.confirmPaymentNote)
        #expect(h.state.phase == .acquiringPaymentNote)
        #expect(h.state.checkout.outcome == .amountRemaining(.kes(250_00)))
        let proposal = ProposedBanknote(denomination: note(.kes, 500), source: .manualEntry)
        #expect(result.effects.contains(.announce(.paymentNoteAdded(proposal, paid: .kes(500_00), remaining: .kes(250_00)))))
        #expect(h.send(.repeatLastInstruction).effects == [.announce(.paymentNoteAdded(proposal, paid: .kes(500_00), remaining: .kes(250_00)))])
    }

    @Test func severalNotesArePaidAndChangeIsShownOnceCovered() {
        var h = Harness.at(.acquiringTotal)
        h.apply(.enterTotalManually(minorUnits: 25_00, currency: .aed), .confirmTotal)
        h.apply(.selectPaymentNoteManually(note(.aed, 20)), .confirmPaymentNote)
        #expect(h.state.phase == .acquiringPaymentNote)
        h.apply(.selectPaymentNoteManually(note(.aed, 10)))
        let result = h.send(.confirmPaymentNote)
        #expect(h.state.phase == .showingExpectedChange)
        #expect(h.state.checkout.confirmedPayment?.notes.map(\.denomination) == [note(.aed, 20), note(.aed, 10)])
        #expect(h.state.checkout.outcome == .changeDue(.aed(5_00)))
        #expect(result.effects.contains(.announce(.checkoutResult(total: .aed(25_00), payment: .aed(30_00), outcome: .changeDue(.aed(5_00))))))
        h.apply(.startReturnedChange)
        #expect(h.state.returnedChange?.expectedChange == .aed(5_00))
    }

    @Test func removingTheLastPaymentNoteGoesBackToAddingNotes() {
        var h = Harness.at(.acquiringTotal)
        h.apply(.enterTotalManually(minorUnits: 25_00, currency: .aed), .confirmTotal)
        h.apply(.selectPaymentNoteManually(note(.aed, 20)), .confirmPaymentNote)
        h.apply(.selectPaymentNoteManually(note(.aed, 10)), .confirmPaymentNote)
        #expect(h.state.phase == .showingExpectedChange)

        let first = h.send(.removeLastPaymentNote)
        #expect(h.state.phase == .acquiringPaymentNote)
        #expect(h.state.checkout.confirmedPayment?.notes.count == 1)
        #expect(first.effects.contains(.announce(.paymentNoteRemoved(paid: .aed(20_00), remaining: .aed(5_00)))))

        let second = h.send(.removeLastPaymentNote)
        #expect(h.state.checkout.confirmedPayment == nil)
        #expect(second.effects.contains(.announce(.paymentNoteRemoved(paid: .aed(0), remaining: .aed(25_00)))))
        #expect(h.send(.removeLastPaymentNote) == .ignored(.nothingToActOn))
        #expect(h.state.checkout.confirmedTotal?.money == .aed(25_00), "The total is kept")
    }

    @Test func thatsAllMyNotesReportsWhatIsStillOwed() {
        var h = Harness.at(.acquiringTotal)
        h.apply(.enterTotalManually(minorUnits: 750_00, currency: .kes), .confirmTotal)
        #expect(h.send(.finishPaymentNotes) == .ignored(.nothingToActOn), "Needs at least one note")
        h.apply(.selectPaymentNoteManually(note(.kes, 500)), .confirmPaymentNote)
        let result = h.send(.finishPaymentNotes)
        #expect(h.state.phase == .showingExpectedChange)
        #expect(result.effects.contains(.announce(.checkoutResult(total: .kes(750_00), payment: .kes(500_00), outcome: .amountRemaining(.kes(250_00))))))
        #expect(!h.machine.permits(.startReturnedChange))
    }

    @Test func rejectingANextNoteRepeatsTheProgress() {
        var h = Harness.at(.acquiringTotal)
        h.apply(.enterTotalManually(minorUnits: 25_00, currency: .aed), .confirmTotal)
        h.apply(.selectPaymentNoteManually(note(.aed, 20)), .confirmPaymentNote)
        h.apply(.selectPaymentNoteManually(note(.aed, 50)))
        let result = h.send(.rejectPaymentNote)
        #expect(h.state.phase == .acquiringPaymentNote)
        #expect(result.effects.contains(.announce(.paymentProgress(paid: .aed(20_00), remaining: .aed(5_00)))))
        #expect(h.state.checkout.confirmedPayment?.notes.count == 1)
    }

    @Test func totalWithoutCurrencyRequiresAChoiceBeforeConfirming() {
        var h = Harness.at(.acquiringTotal)
        h.apply(.enterTotalManually(minorUnits: 12_50, currency: nil))
        let proposal = ProposedAmount(minorUnits: 12_50, currency: nil, source: .manualEntry)
        #expect(h.state.lastAnnouncement == .chooseTotalCurrency(proposal))

        let before = h.state
        #expect(h.send(.confirmTotal) == .declined(.currencyRequired, [.announce(.chooseTotalCurrency(proposal))]))
        #expect(h.state == before, "Declining must not change state")
        #expect(!h.machine.permits(.confirmTotal))

        h.apply(.selectTotalCurrency(.aed))
        #expect(h.state.proposedTotal?.currency == .aed)
        #expect(h.machine.permits(.confirmTotal))
        h.apply(.confirmTotal)
        #expect(h.state.checkout.confirmedTotal?.money == .aed(12_50))
    }

    @Test func rejectingTheTotalReturnsToAcquiring() {
        var h = Harness.at(.confirmingTotal)
        h.apply(.rejectTotal)
        #expect(h.state.phase == .acquiringTotal)
        #expect(h.state.proposedTotal == nil)
    }

    @Test func rejectingThePaymentNoteKeepsTheConfirmedTotal() {
        var h = Harness.at(.confirmingPaymentNote)
        h.apply(.rejectPaymentNote)
        #expect(h.state.phase == .acquiringPaymentNote)
        #expect(h.state.proposedPaymentNote == nil)
        #expect(h.state.checkout.confirmedTotal?.money == .usd(7_00))
    }

    @Test func mixedCurrencyPaymentNoteIsRejected() {
        var h = Harness.at(.acquiringPaymentNote)
        let result = h.send(.selectPaymentNoteManually(note(.aed, 20)))
        #expect(result.effects.contains(.announce(.rejected(.mixedCurrency(expected: .usd, found: .aed)))))
        #expect(h.state.phase == .acquiringPaymentNote)
        #expect(h.state.lastRejection == .mixedCurrency(expected: .usd, found: .aed))
        #expect(h.state.proposedPaymentNote == nil)
    }

    @Test func implausibleManualTotalIsRejected() {
        var h = Harness.at(.acquiringTotal)
        h.send(.enterTotalManually(minorUnits: 0, currency: .usd))
        #expect(h.state.phase == .acquiringTotal)
        #expect(h.state.lastRejection == .implausibleAmount)
    }

    @Test func returnedChangeReachesExact() {
        let h = Harness.at(.exactChange)
        #expect(h.state.returnedChange?.receivedTotal == .usd(13_00))
        #expect(h.state.returnedChange?.status == .exact)
    }

    @Test func returnedChangeExcessiveMovesImmediately() {
        let h = Harness.at(.excessiveChange)
        #expect(h.state.returnedChange?.status == .excessive(over: .usd(7_00)))
    }

    @Test func finishingShortReportsTheMissingAmount() {
        let h = Harness.at(.shortChange)
        #expect(h.state.lastAnnouncement == .changeVerdict(expected: .usd(13_00), received: .usd(10_00), status: .shortSoFar(missing: .usd(3_00))))
    }

    @Test func finishingWithNoNotesIsUnresolved() {
        let h = Harness.at(.unresolvedChange)
        #expect(h.state.lastAnnouncement == .unresolvedChange(expected: .usd(13_00)))
    }

    @Test func continueCollectingAfterShortOrUnresolved() {
        for phase: Phase in [.shortChange, .unresolvedChange] {
            var h = Harness.at(phase)
            h.apply(.continueCollectingChange)
            #expect(h.state.phase == .collectingReturnedChange)
        }
    }

    @Test func removeLastNoteFromAnOutcomeReturnsToCollecting() {
        for phase: Phase in [.exactChange, .excessiveChange, .shortChange] {
            var h = Harness.at(phase)
            let before = h.state.returnedChange!.acceptedNotes.count
            h.apply(.removeLastReturnedNote)
            #expect(h.state.phase == .collectingReturnedChange)
            #expect(h.state.returnedChange!.acceptedNotes.count == before - 1)
        }
    }

    @Test func removeLastWithNoNotesIsIgnored() {
        var h = Harness.at(.collectingReturnedChange)
        #expect(h.send(.removeLastReturnedNote) == .ignored(.nothingToActOn))
    }

    @Test func mixedCurrencyReturnedNoteNeverAffectsTheTotal() {
        var h = Harness.at(.collectingReturnedChange)
        h.send(.addReturnedNoteManually(note(.kes, 50)))
        #expect(h.state.returnedChange?.acceptedNotes.isEmpty == true)
        #expect(h.state.lastRejection == .mixedCurrency(expected: .usd, found: .kes))
        #expect(h.state.phase == .collectingReturnedChange)
    }

    @Test func verifyChangeFromHomeRequiresCurrencyAndConfirmation() {
        var h = Harness.at(.settingExpectedChange)
        h.send(.enterExpectedChange(minorUnits: 0, currency: .aed))
        #expect(h.state.phase == .settingExpectedChange)
        #expect(h.state.lastRejection == .implausibleAmount)

        h.apply(.enterExpectedChange(minorUnits: 30_00, currency: nil))
        #expect(h.state.phase == .confirmingExpectedChange)
        #expect(h.state.returnedChange == nil, "Nothing is collected before confirmation")
        #expect(h.send(.confirmExpectedChange) == .declined(.currencyRequired, [.announce(.chooseExpectedChangeCurrency(ProposedAmount(minorUnits: 30_00, currency: nil, source: .manualEntry)))]))
        #expect(!h.machine.permits(.startScan), "Scanning can't begin before the expected change is confirmed")

        h.apply(.selectExpectedChangeCurrency(.aed))
        h.apply(.confirmExpectedChange)
        #expect(h.state.phase == .collectingReturnedChange)
        #expect(h.state.returnedChange?.expectedChange == .aed(30_00))
        h.addManually(note(.aed, 20)); h.addManually(note(.aed, 10))
        #expect(h.state.phase == .exactChange)
    }

    @Test func rejectingTheExpectedChangeReturnsToEntry() {
        var h = Harness.at(.confirmingExpectedChange)
        h.apply(.rejectExpectedChange)
        #expect(h.state.phase == .settingExpectedChange)
        #expect(h.state.proposedExpectedChange == nil)
    }

    @Test func manualReturnedNoteNeedsConfirmation() {
        var h = Harness.at(.collectingReturnedChange)
        h.apply(.addReturnedNoteManually(note(.usd, 10)))
        #expect(h.state.phase == .confirmingReturnedNote)
        #expect(h.state.proposedReturnedNote?.reason == .manualSelection)
        #expect(h.state.returnedChange?.acceptedNotes.isEmpty == true, "Never added before confirmation")
        h.apply(.rejectReturnedNote)
        #expect(h.state.phase == .collectingReturnedChange)
        #expect(h.state.returnedChange?.acceptedNotes.isEmpty == true)
        h.addManually(note(.usd, 10))
        #expect(h.state.returnedChange?.receivedTotal == .usd(10_00))
    }

    @Test func readingCurrencyIdentifiesNotesAndStays() {
        var h = Harness.at(.readingCurrency)
        let request = h.startScan()
        h.apply(h.event(request, .banknoteCandidate(cameraNote(.kes, 500))))
        #expect(h.state.phase == .readingCurrency)
        #expect(h.state.lastCurrencyReading == ProposedBanknote(denomination: note(.kes, 500), source: .camera))
        #expect(h.state.pendingRequest == nil)

        let second = h.startScan()
        h.send(h.event(second, .banknoteCandidate(cameraNote(.usd, 3))))
        #expect(h.state.lastRejection == .unsupportedDenomination(currency: .usd, majorValue: 3))
        h.apply(.finish)
        #expect(h.state.phase == .home)
    }

    @Test func askNaviNoteResumesWhereTheUserWas() {
        var h = Harness.at(.confirmingTotal)
        let before = h.state
        h.apply(.openAskNaviNote)
        #expect(h.state.phase == .askingNaviNote)
        h.apply(.closeAskNaviNote)
        #expect(h.state.phase == .confirmingTotal)
        #expect(h.state.proposedTotal == before.proposedTotal)
        #expect(h.state.lastAnnouncement == before.lastAnnouncement)
    }

    @Test func repeatSaysTheLastAnnouncementWithoutChangingState() {
        var h = Harness.at(.acquiringPaymentNote)
        let before = h.state
        #expect(h.send(.repeatLastInstruction) == .applied([.announce(.askForPaymentNote(total: .usd(7_00)))]))
        #expect(h.state == before)
    }

    @Test func hapticsMatchOutcomes() {
        var h = Harness.at(.collectingReturnedChange)
        #expect(h.send(.addReturnedNoteManually(note(.usd, 10))).effects.contains(.haptic(.warning)), "Asking for confirmation")
        #expect(h.send(.confirmReturnedNote).effects.contains(.haptic(.success)))
        h.addManually(note(.usd, 2))
        h.apply(.addReturnedNoteManually(note(.usd, 20)))
        #expect(h.send(.confirmReturnedNote).effects.contains(.haptic(.warning)), "Too much change")
    }
}
