import Testing
@testable import NaviNote

@Suite("Recognition confidence and gate")
struct RecognitionTests {
    let gate = CandidateGate()

    @Test(arguments: [-0.01, 1.01, Double.nan, Double.infinity, -Double.infinity])
    func rejectsInvalidScores(_ score: Double) {
        #expect(RecognitionConfidence(score: score) == nil)
    }

    @Test func policyThresholds() {
        let policy = RecognitionPolicy.standard
        #expect(policy.assess(confidence(0.90)) == .sufficient)
        #expect(policy.assess(confidence(1.0)) == .sufficient)
        #expect(policy.assess(confidence(0.89)) == .needsRescan)
        #expect(policy.assess(confidence(0.70)) == .needsRescan)
        #expect(policy.assess(confidence(0.69)) == .insufficient)
        #expect(policy.assess(nil) == .insufficient)
    }

    @Test func missingConfidenceIsNeverAccepted() {
        let result = gate.evaluate(cameraTotal(10_00, .usd, score: nil))
        #expect(result == .failure(.lowConfidence(.insufficient)))
    }

    @Test func lowAndBorderlineConfidenceAreRejected() {
        #expect(gate.evaluate(cameraTotal(10_00, .usd, score: 0.5)) == .failure(.lowConfidence(.insufficient)))
        #expect(gate.evaluate(cameraTotal(10_00, .usd, score: 0.8)) == .failure(.lowConfidence(.needsRescan)))
    }

    @Test func oneFrameIsNeverEnoughForTheCamera() {
        #expect(gate.evaluate(cameraTotal(10_00, .usd, observations: 1)) == .failure(.insufficientAgreement(observed: 1, required: 3)))
        #expect(gate.evaluate(cameraNote(.usd, 20, observations: 2), requiredCurrency: .usd)
            == .failure(.insufficientAgreement(observed: 2, required: 3)))
    }

    @Test func stableConfidentCameraReadingsPass() {
        #expect(gate.evaluate(cameraTotal(10_00, .usd)) == .success(AmountReading(minorUnits: 10_00, currency: .usd)))
        #expect(gate.evaluate(cameraNote(.usd, 20), requiredCurrency: .usd) == .success(note(.usd, 20)))
    }

    @Test func manualEntryNeedsNoConfidence() {
        let candidate = TotalCandidate.manual(AmountReading(minorUnits: 25_00, currency: nil))
        #expect(gate.evaluate(candidate) == .success(AmountReading(minorUnits: 25_00, currency: nil)))
    }

    @Test func simulatedReadingsStillNeedConfidence() {
        let low = cameraNote(.aed, 10, score: 0.3, source: .simulated)
        #expect(gate.evaluate(low, requiredCurrency: nil) == .failure(.lowConfidence(.insufficient)))
    }

    @Test(arguments: [0, -100, 10_000_000_01])
    func implausibleTotalsAreRejected(_ minor: Int) {
        #expect(gate.evaluate(cameraTotal(minor, .kes)) == .failure(.implausibleAmount))
        #expect(gate.evaluate(TotalCandidate.manual(AmountReading(minorUnits: minor, currency: nil))) == .failure(.implausibleAmount))
    }

    @Test func mixedCurrencyNotesAreRejectedEvenWhenConfident() {
        let result = gate.evaluate(cameraNote(.aed, 50, score: 0.99), requiredCurrency: .usd)
        #expect(result == .failure(.mixedCurrency(expected: .usd, found: .aed)))
    }

    @Test func unsupportedDenominationsAreRejected() {
        #expect(gate.evaluate(cameraNote(.aed, 2), requiredCurrency: .aed) == .failure(.unsupportedDenomination(currency: .aed, majorValue: 2)))
        #expect(gate.evaluate(cameraNote(.kes, 20), requiredCurrency: nil) == .failure(.unsupportedDenomination(currency: .kes, majorValue: 20)))
    }

    @Test func confidenceIsCheckedBeforeCurrency() {
        let result = gate.evaluate(cameraNote(.aed, 50, score: 0.2), requiredCurrency: .usd)
        #expect(result == .failure(.lowConfidence(.insufficient)))
    }

    @Test func returnedNotePolicyTiers() {
        #expect(gate.decideReturnedNote(cameraNote(.kes, 200), currency: .kes) == .addImmediately(note(.kes, 200)))
        #expect(gate.decideReturnedNote(cameraNote(.kes, 200, score: 0.8), currency: .kes) == .needsConfirmation(note(.kes, 200), .uncertain))
        #expect(gate.decideReturnedNote(cameraNote(.kes, 200, observations: 2), currency: .kes) == .needsConfirmation(note(.kes, 200), .unstable))
        #expect(gate.decideReturnedNote(cameraNote(.kes, 200, source: .simulated), currency: .kes) == .needsConfirmation(note(.kes, 200), .simulated))
        #expect(gate.decideReturnedNote(.manual(BanknoteReading(currency: .kes, majorValue: 200)), currency: .kes) == .needsConfirmation(note(.kes, 200), .manualSelection))
        #expect(gate.decideReturnedNote(cameraNote(.kes, 200, score: 0.5), currency: .kes) == .reject(.lowConfidence(.insufficient)))
        #expect(gate.decideReturnedNote(cameraNote(.usd, 20), currency: .kes) == .reject(.mixedCurrency(expected: .kes, found: .usd)))
        #expect(gate.decideReturnedNote(cameraNote(.kes, 20), currency: .kes) == .reject(.unsupportedDenomination(currency: .kes, majorValue: 20)))
    }
}
