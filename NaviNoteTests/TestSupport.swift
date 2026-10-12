import Foundation
@testable import NaviNote

/// Produces predictable request IDs: 00000000-0000-0000-0000-000000000001, …
final class SequentialRequestIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var next: Int = 1

    func make() -> RequestID {
        lock.lock()
        defer { lock.unlock() }
        let value = next
        next += 1
        return RequestID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!)
    }
}

extension Money {
    /// Test shorthand: `.usd(12_50)` is 12.50 US dollars.
    static func usd(_ minor: Int) -> Money { Money(minorUnits: minor, currency: .usd) }
    static func aed(_ minor: Int) -> Money { Money(minorUnits: minor, currency: .aed) }
    static func kes(_ minor: Int) -> Money { Money(minorUnits: minor, currency: .kes) }
}

func note(_ currency: Currency, _ value: Int) -> SupportedDenomination {
    SupportedDenomination(currency: currency, majorValue: value)!
}

func confidence(_ score: Double) -> RecognitionConfidence {
    RecognitionConfidence(score: score)!
}

func cameraTotal(_ minor: Int, _ currency: Currency?, score: Double? = 0.97, observations: Int = 3) -> TotalCandidate {
    TotalCandidate(
        value: AmountReading(minorUnits: minor, currency: currency),
        source: .camera,
        confidence: score.map(confidence),
        agreeingObservations: observations
    )
}

func cameraNote(
    _ currency: Currency,
    _ value: Int,
    score: Double? = 0.97,
    observations: Int = 3,
    source: RecognitionSource = .camera
) -> BanknoteCandidate {
    BanknoteCandidate(
        value: BanknoteReading(currency: currency, majorValue: value),
        source: source,
        confidence: score.map(confidence),
        agreeingObservations: observations
    )
}
