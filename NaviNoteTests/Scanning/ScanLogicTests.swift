import Foundation
import Testing
@testable import NaviNote

@Suite("Stability tracker")
struct StabilityTrackerTests {
    let usd10 = AmountReading(minorUnits: 10_00, currency: .usd)
    let usd11 = AmountReading(minorUnits: 11_00, currency: .usd)

    @Test func oneFrameIsNeverEnough() {
        var tracker = StabilityTracker<AmountReading>()
        #expect(tracker.add(usd10, confidence: confidence(1.0)) == nil)
    }

    @Test func threeAgreeingFramesProduceACandidate() {
        var tracker = StabilityTracker<AmountReading>()
        #expect(tracker.add(usd10, confidence: confidence(0.95)) == nil)
        #expect(tracker.add(usd10, confidence: confidence(0.99)) == nil)
        let candidate = tracker.add(usd10, confidence: confidence(0.92))
        #expect(candidate == ScanCandidate(value: usd10, source: .camera, confidence: confidence(0.92), agreeingObservations: 3))
    }

    @Test func candidateCarriesTheLowestConfidence() {
        var tracker = StabilityTracker<AmountReading>()
        _ = tracker.add(usd10, confidence: confidence(0.99))
        _ = tracker.add(usd10, confidence: confidence(0.75))
        #expect(tracker.add(usd10, confidence: confidence(0.98))?.confidence == confidence(0.75))
    }

    @Test func anOccasionalNoisyFrameIsTolerated() {
        var tracker = StabilityTracker<AmountReading>()
        _ = tracker.add(usd10, confidence: confidence(0.95))
        _ = tracker.add(usd11, confidence: confidence(0.95))
        _ = tracker.add(usd10, confidence: confidence(0.95))
        #expect(tracker.add(usd10, confidence: confidence(0.95)) != nil)
    }

    @Test func oldReadingsAgeOutIncludingEmptyFrames() {
        var tracker = StabilityTracker<AmountReading>(windowSize: 4)
        _ = tracker.add(usd10, confidence: confidence(0.95))
        _ = tracker.add(usd10, confidence: confidence(0.95))
        _ = tracker.add(nil, confidence: nil)
        _ = tracker.add(nil, confidence: nil)
        _ = tracker.add(nil, confidence: nil)
        #expect(tracker.add(usd10, confidence: confidence(0.95)) == nil, "Earlier readings fell out of the window")
    }

    @Test func missingOrVeryLowConfidenceNeverCounts() {
        var tracker = StabilityTracker<AmountReading>()
        for _ in 0..<5 { #expect(tracker.add(usd10, confidence: nil) == nil) }
        for _ in 0..<5 { #expect(tracker.add(usd10, confidence: confidence(0.5)) == nil) }
    }

    @Test func startsOverAfterACandidate() {
        var tracker = StabilityTracker<AmountReading>()
        for _ in 0..<2 { _ = tracker.add(usd10, confidence: confidence(0.95)) }
        #expect(tracker.add(usd10, confidence: confidence(0.95)) != nil)
        #expect(tracker.add(usd10, confidence: confidence(0.95)) == nil)
    }
}

@Suite("Aiming guidance")
struct AimingGuidanceTests {
    @Test func noTextMeansLookingForText() {
        #expect(AimingGuidance.assess([]) == .lookingForText)
        #expect(AimingGuidance.assess([line("   ")]) == .lookingForText)
    }

    @Test func centredTextIsFound() {
        #expect(AimingGuidance.assess([line("TOTAL")]) == .textFound)
    }

    @Test func textTouchingAnEdgeAsksToMoveBack() {
        let edge = CGRect(x: 0.0, y: 0.4, width: 0.5, height: 0.1)
        #expect(AimingGuidance.assess([line("TOTAL"), line("12.50", box: edge)]) == .textAtEdge)
        let top = CGRect(x: 0.3, y: 0.9, width: 0.3, height: 0.099)
        #expect(AimingGuidance.assess([line("x", box: top)]) == .textAtEdge)
    }
}
