import Testing
@testable import NaviNote

@Suite("State machine: scans, stale results, duplicates")
struct StateMachineAsyncEventTests {
    @Test func startScanCreatesOnePendingRequest() {
        var h = Harness.at(.acquiringTotal)
        let result = h.send(.startScan)
        let request = h.state.pendingRequest
        #expect(request?.kind == .total)
        #expect(result == .applied([.startScan(request!), .announce(.scanning(.total))]))
        #expect(h.send(.startScan) == .ignored(.scanAlreadyInProgress))
        #expect(h.state.pendingRequest == request)
    }

    @Test func scanKindFollowsThePhase() {
        let expectations: [(Phase, ScanKind)] = [
            (.acquiringTotal, .total), (.acquiringPaymentNote, .paymentNote),
            (.collectingReturnedChange, .returnedNote), (.readingCurrency, .currencyReading),
        ]
        for (phase, kind) in expectations {
            var h = Harness.at(phase)
            #expect(h.startScan().kind == kind)
        }
    }

    @Test func scanningIsOnlyAllowedInScanningPhases() {
        for phase in allPhases where phase.scanKind == nil {
            var h = Harness.at(phase)
            #expect(h.send(.startScan) == .ignored(.invalidInPhase), "\(phase)")
        }
    }

    @Test func stopScanCancelsTheRequest() {
        var h = Harness.at(.acquiringTotal)
        let request = h.startScan()
        #expect(h.send(.stopScan) == .applied([.cancelScan(request.id), .announce(.scanStopped)]))
        #expect(h.state.pendingRequest == nil)
        #expect(h.send(h.event(request, .totalCandidate(cameraTotal(10_00, .usd)))) == .ignored(.unexpectedRequest))
    }

    @Test func matchingCameraTotalProposesAndStillNeedsConfirmation() {
        var h = Harness.at(.acquiringTotal)
        let request = h.startScan()
        h.apply(h.event(request, .totalCandidate(cameraTotal(42_00, .aed))))
        #expect(h.state.phase == .confirmingTotal)
        #expect(h.state.proposedTotal == ProposedAmount(minorUnits: 42_00, currency: .aed, source: .camera))
        #expect(h.state.checkout.confirmedTotal == nil)
        #expect(h.state.pendingRequest == nil)
    }

    @Test func lowConfidenceCameraTotalIsRejectedAndNothingChanges() {
        var h = Harness.at(.acquiringTotal)
        let request = h.startScan()
        h.send(h.event(request, .totalCandidate(cameraTotal(42_00, .aed, score: 0.4))))
        #expect(h.state.phase == .acquiringTotal)
        #expect(h.state.proposedTotal == nil)
        #expect(h.state.lastRejection == .lowConfidence(.insufficient))
        #expect(h.state.pendingRequest == nil, "The one-shot request is finished")
    }

    @Test func staleGenerationIsIgnoredAfterCancel() {
        var h = Harness.at(.acquiringTotal)
        let request = h.startScan()
        let oldGeneration = h.state.generation
        h.apply(.cancel)
        h.drive(to: .acquiringTotal)
        _ = h.startScan()
        let before = h.state

        let late = NaviNoteAction.serviceEvent(ServiceEvent(
            requestID: request.id,
            generation: oldGeneration,
            payload: .totalCandidate(cameraTotal(99_00, .usd))
        ))
        #expect(h.send(late) == .ignored(.staleGeneration))
        #expect(h.state == before)
    }

    @Test func staleGenerationIsIgnoredAfterReset() {
        var h = Harness.at(.collectingReturnedChange)
        let request = h.startScan()
        let old = h.event(request, .banknoteCandidate(cameraNote(.usd, 10)))
        h.apply(.reset)
        h.drive(to: .collectingReturnedChange)
        #expect(h.send(old) == .ignored(.staleGeneration))
        #expect(h.state.returnedChange?.acceptedNotes.isEmpty == true)
    }

    @Test func eventForADifferentRequestIsIgnored() {
        var h = Harness.at(.acquiringTotal)
        _ = h.startScan()
        let stranger = NaviNoteAction.serviceEvent(ServiceEvent(
            requestID: RequestID(),
            generation: h.state.generation,
            payload: .totalCandidate(cameraTotal(10_00, .usd))
        ))
        let before = h.state
        #expect(h.send(stranger) == .ignored(.unexpectedRequest))
        #expect(h.state == before)
    }

    @Test func duplicateDeliveryCountsAReturnedNoteOnce() {
        var h = Harness.at(.collectingReturnedChange)
        let request = h.startScan()
        let event = h.event(request, .banknoteCandidate(cameraNote(.usd, 5)))
        h.apply(event)
        #expect(h.send(event) == .ignored(.unexpectedRequest))
        #expect(h.state.returnedChange?.receivedTotal == .usd(5_00))
    }

    @Test func mismatchedPayloadIsIgnoredAndTheRequestStaysPending() {
        var h = Harness.at(.acquiringTotal)
        let request = h.startScan()
        #expect(h.send(h.event(request, .banknoteCandidate(cameraNote(.usd, 5)))) == .ignored(.unexpectedPayload))
        #expect(h.state.pendingRequest == request)
    }

    @Test func stableConfidentReturnedNoteIsCountedImmediately() {
        var h = Harness.at(.collectingReturnedChange)
        let request = h.startScan()
        let result = h.send(h.event(request, .banknoteCandidate(cameraNote(.usd, 10))))
        #expect(h.state.phase == .collectingReturnedChange)
        #expect(h.state.returnedChange?.receivedTotal == .usd(10_00))
        let expected = Announcement.returnedNoteAdded(
            ProposedBanknote(denomination: note(.usd, 10), source: .camera),
            received: .usd(10_00),
            status: .shortSoFar(missing: .usd(3_00))
        )
        #expect(result.effects.contains(.announce(expected)), "Announces currency and denomination")
        #expect(result.effects.contains(.haptic(.success)), "Clear haptic feedback")
        #expect(h.machine.permits(.removeLastReturnedNote), "Remove Last Note is available")
    }

    @Test func borderlineConfidenceReturnedNoteNeedsConfirmation() {
        var h = Harness.at(.collectingReturnedChange)
        let request = h.startScan()
        h.apply(h.event(request, .banknoteCandidate(cameraNote(.usd, 10, score: 0.75))))
        #expect(h.state.phase == .confirmingReturnedNote)
        #expect(h.state.proposedReturnedNote?.reason == .uncertain)
        #expect(h.state.returnedChange?.acceptedNotes.isEmpty == true)
        h.apply(.confirmReturnedNote)
        #expect(h.state.returnedChange?.receivedTotal == .usd(10_00))
    }

    @Test func unstableReturnedNoteNeedsConfirmation() {
        var h = Harness.at(.collectingReturnedChange)
        let request = h.startScan()
        h.apply(h.event(request, .banknoteCandidate(cameraNote(.usd, 10, observations: 1))))
        #expect(h.state.proposedReturnedNote?.reason == .unstable)
        #expect(h.state.returnedChange?.acceptedNotes.isEmpty == true)
    }

    @Test func simulatedReturnedNoteNeedsConfirmation() {
        var h = Harness.at(.collectingReturnedChange)
        let request = h.startScan()
        h.apply(h.event(request, .banknoteCandidate(cameraNote(.usd, 10, source: .simulated))))
        #expect(h.state.proposedReturnedNote?.reason == .simulated)
        #expect(h.state.returnedChange?.acceptedNotes.isEmpty == true)
    }

    @Test func lowConfidenceOrConflictingReturnedNotesAreRejected() {
        let cases: [(BanknoteCandidate, CandidateRejection)] = [
            (cameraNote(.usd, 10, score: 0.4), .lowConfidence(.insufficient)),
            (cameraNote(.usd, 10, score: nil), .lowConfidence(.insufficient)),
            (cameraNote(.aed, 10), .mixedCurrency(expected: .usd, found: .aed)),
            (cameraNote(.usd, 3), .unsupportedDenomination(currency: .usd, majorValue: 3)),
        ]
        for (candidate, rejection) in cases {
            var h = Harness.at(.collectingReturnedChange)
            let request = h.startScan()
            h.send(h.event(request, .banknoteCandidate(candidate)))
            #expect(h.state.phase == .collectingReturnedChange)
            #expect(h.state.lastRejection == rejection)
            #expect(h.state.returnedChange?.acceptedNotes.isEmpty == true)
        }
    }

    @Test func confirmedReturnedNoteCannotBeCountedTwice() {
        var h = Harness.at(.collectingReturnedChange)
        let request = h.startScan()
        let event = h.event(request, .banknoteCandidate(cameraNote(.usd, 10, score: 0.8)))
        h.apply(event, .confirmReturnedNote)
        #expect(h.send(event) == .ignored(.unexpectedRequest))
        #expect(h.send(.confirmReturnedNote) == .ignored(.invalidInPhase))
        #expect(h.state.returnedChange?.receivedTotal == .usd(10_00))
    }

    @Test func noResultAsksToTryAgain() {
        var h = Harness.at(.acquiringPaymentNote)
        let request = h.startScan()
        let result = h.send(h.event(request, .noResult))
        #expect(result.effects.contains(.announce(.scanFoundNothing(.paymentNote))))
        #expect(h.state.phase == .acquiringPaymentNote)
        #expect(h.state.pendingRequest == nil)
    }

    @Test func failureOffersRetryAndResumes() {
        var h = Harness.at(.acquiringTotal)
        let request = h.startScan()
        h.apply(h.event(request, .failed(.cameraUnavailable)))
        #expect(h.state.phase == .recoverableError(.cameraUnavailable))
        h.apply(.retry)
        #expect(h.state.phase == .acquiringTotal)
        #expect(h.state.lastAnnouncement == .askForTotal, "Resuming must not replay a stale scanning message")
    }

    @Test func permissionDeniedResumesForManualEntry() {
        var h = Harness.at(.acquiringTotal)
        let request = h.startScan()
        h.apply(h.event(request, .permissionDenied(.camera)))
        #expect(h.state.phase == .permissionDenied(.camera))
        h.apply(.dismissPermissionNotice)
        #expect(h.state.phase == .acquiringTotal)
        h.apply(.enterTotalManually(minorUnits: 3_00, currency: .usd))
        #expect(h.state.phase == .confirmingTotal)
    }

    @Test func leavingAPhaseCancelsItsScan() {
        var h = Harness.at(.acquiringTotal)
        let request = h.startScan()
        let result = h.send(.enterTotalManually(minorUnits: 3_00, currency: .usd))
        #expect(result.effects.first == .cancelScan(request.id))
        #expect(h.state.pendingRequest == nil)
        // A late camera result for the cancelled scan is ignored.
        #expect(h.send(h.event(request, .totalCandidate(cameraTotal(9_00, .usd)))) == .ignored(.unexpectedRequest))
        #expect(h.state.proposedTotal?.minorUnits == 3_00)
    }

    @Test func openingAskNaviNoteCancelsAScan() {
        var h = Harness.at(.readingCurrency)
        let request = h.startScan()
        let result = h.send(.openAskNaviNote)
        #expect(result.effects.contains(.cancelScan(request.id)))
        #expect(h.state.pendingRequest == nil)
    }

    @Test func simulatedReadingsKeepTheirSource() {
        var h = Harness.at(.readingCurrency)
        let request = h.startScan()
        h.apply(h.event(request, .banknoteCandidate(cameraNote(.aed, 100, source: .simulated))))
        #expect(h.state.lastCurrencyReading?.source == .simulated)
    }

    @Test func cameraPaymentNoteNeedsConfirmation() {
        var h = Harness.at(.acquiringPaymentNote)
        let request = h.startScan()
        h.apply(h.event(request, .banknoteCandidate(cameraNote(.usd, 10))))
        #expect(h.state.phase == .confirmingPaymentNote)
        #expect(h.state.checkout.confirmedPayment == nil)
        h.apply(.confirmPaymentNote)
        #expect(h.state.checkout.confirmedPayment == CashPayment(singleNote: ConfirmedBanknote(denomination: note(.usd, 10), source: .camera)))
    }
}
