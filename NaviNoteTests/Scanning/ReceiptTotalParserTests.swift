import Foundation
import Testing
@testable import NaviNote

/// Builds recognized lines laid out like a real page: each inner array is a
/// visual row (top to bottom), each string a separate text observation
/// placed left to right. All fixtures are invented and contain no real
/// business or personal data.
func page(_ rows: [[String]], score: Double? = 0.95, shuffled: Bool = false) -> [RecognizedTextLine] {
    var lines: [RecognizedTextLine] = []
    for (rowIndex, row) in rows.enumerated() {
        let y = 0.92 - Double(rowIndex) * 0.05
        for (column, text) in row.enumerated() {
            let x = 0.1 + Double(column) * (0.8 / Double(max(row.count, 1)))
            lines.append(RecognizedTextLine(
                text: text,
                confidence: score.flatMap(RecognitionConfidence.init(score:)),
                boundingBox: CGRect(x: x, y: y, width: 0.25, height: 0.03)
            ))
        }
    }
    return shuffled ? lines.reversed() : lines
}

@Suite("Receipt and terminal total parser")
struct ReceiptTotalParserTests {
    let parser = ReceiptTotalParser()

    func total(_ lines: [RecognizedTextLine]) -> AmountReading? {
        parser.parse(lines)?.value
    }

    // MARK: Receipts

    @Test func aedReceiptWithVATCashAndChange() {
        let receipt = page([
            ["CAFE EXAMPLE LLC"],
            ["TRN 100000000000003"],
            ["Tel: 04 000 0000"],
            ["Date: 24/09/2026", "12:41"],
            ["Latte", "18.00"],
            ["Croissant", "12.00"],
            ["Subtotal", "30.00"],
            ["VAT 5%", "1.50"],
            ["TOTAL AED", "31.50"],
            ["Cash", "50.00"],
            ["Change", "18.50"],
        ])
        #expect(total(receipt) == AmountReading(minorUnits: 31_50, currency: .aed))
        #expect(parser.analyze(receipt) == .found(ParsedReading(value: AmountReading(minorUnits: 31_50, currency: .aed), confidence: confidence(0.95)), rule: .labelledRow, labelScore: 80))
    }

    @Test func usdReceiptWithTaxAndCard() {
        let receipt = page([
            ["EXAMPLE MARKET"],
            ["Order #4821"],
            ["Milk", "$3.49"],
            ["Bread", "$2.99"],
            ["Subtotal", "$6.48"],
            ["Tax", "$0.52"],
            ["Total", "$7.00"],
            ["VISA ****1234", "$7.00"],
        ])
        #expect(total(receipt) == AmountReading(minorUnits: 7_00, currency: .usd))
    }

    @Test func kesReceiptWithThousandsSeparator() {
        let receipt = page([
            ["EXAMPLE SUPERMARKET"],
            ["Sugar 2kg", "340.00"],
            ["Rice 5kg", "1,020.00"],
            ["TOTAL KSH", "1,360.00"],
            ["CASH", "2,000.00"],
            ["CHANGE", "640.00"],
        ])
        #expect(total(receipt) == AmountReading(minorUnits: 1_360_00, currency: .kes))
    }

    @Test func grandTotalBeatsTotal() {
        let receipt = page([
            ["Total", "95.00"],
            ["Service charge", "5.00"],
            ["Grand Total", "100.00"],
        ])
        #expect(total(receipt)?.minorUnits == 100_00)
    }

    @Test func amountDueBeatsPlainTotal() {
        let receipt = page([["Total", "40.00"], ["Deposit", "10.00"], ["Balance due", "30.00"]])
        #expect(total(receipt)?.minorUnits == 30_00)
    }

    @Test func totalIncludingVATIsTheTotalButTotalVATIsNot() {
        let receipt = page([
            ["Total excl. VAT", "100.00"],
            ["Total VAT", "5.00"],
            ["Total incl. VAT", "105.00"],
        ])
        #expect(total(receipt)?.minorUnits == 105_00)
    }

    @Test func labelAndValueOnSeparateLines() {
        let receipt = page([["Item", "5.00"], ["TOTAL"], ["25.00"]])
        #expect(parser.analyze(receipt) == .found(ParsedReading(value: AmountReading(minorUnits: 25_00, currency: nil), confidence: confidence(0.95)), rule: .labelledNextRow, labelScore: 80))
    }

    @Test func linesDeliveredOutOfOrderAreStillRead() {
        let receipt = page([["Subtotal", "10.00"], ["TOTAL", "12.00"], ["Cash", "20.00"]], shuffled: true)
        #expect(total(receipt)?.minorUnits == 12_00)
    }

    @Test func totalWithItemCountPrefersTheDecimalAmount() {
        #expect(total(page([["TOTAL 3 ITEMS", "45.50"]]))?.minorUnits == 45_50)
    }

    @Test func largeAmountWithoutGroupingIsNotTruncated() {
        // Regression from the prototype, which read 8976 as 897.
        #expect(total(page([["TOTAL", "8976.00"]]))?.minorUnits == 8976_00)
    }

    @Test func decimalCommaIsUnderstood() {
        #expect(total(page([["TOTAL", "12,50"]]))?.minorUnits == 12_50)
    }

    // MARK: Terminals

    @Test(arguments: [
        (["AED 25.00"], AmountReading(minorUnits: 25_00, currency: .aed)),
        (["$12.50"], AmountReading(minorUnits: 12_50, currency: .usd)),
        (["KES 1,250.00"], AmountReading(minorUnits: 1_250_00, currency: .kes)),
        (["Dhs 40"], AmountReading(minorUnits: 40_00, currency: .aed)),
        (["SALE", "AED 99.00"], AmountReading(minorUnits: 99_00, currency: .aed)),
        (["PAY 15.75"], AmountReading(minorUnits: 15_75, currency: nil)),
    ])
    func terminalDisplays(_ row: [String], _ expected: AmountReading) {
        #expect(total(page([row])) == expected)
    }

    @Test func terminalWithTwoRows() {
        #expect(total(page([["AMOUNT"], ["AED 150.00"]])) == AmountReading(minorUnits: 150_00, currency: .aed))
    }

    @Test func arabicDirhamSignIsRecognised() {
        #expect(total(page([["المجموع", "د.إ 20.00"]]))?.currency == .aed)
    }

    // MARK: Things that must not be read as the total

    @Test func conflictingTotalsAreRejected() {
        let receipt = page([["Total", "10.00"], ["Total", "12.00"]])
        #expect(parser.analyze(receipt) == .notFound(.ambiguous))
    }

    @Test func severalUnlabelledAmountsAreRejected() {
        #expect(parser.analyze(page([["Latte", "18.00"], ["Muffin", "9.00"]])) == .notFound(.ambiguous))
    }

    @Test func aBareIntegerWithoutCurrencyIsNotAccepted() {
        #expect(parser.parse(page([["Table 12"]])) == nil)
        #expect(parser.analyze(page([["Guests", "25"]])) == .notFound(.ambiguous))
    }

    @Test func onlyTaxSubtotalOrPaymentLinesGiveNothing() {
        #expect(parser.parse(page([["Subtotal", "30.00"]])) == nil)
        #expect(parser.parse(page([["VAT 5%", "1.50"]])) == nil)
        #expect(parser.parse(page([["Cash", "50.00"], ["Change", "10.00"]])) == nil)
        #expect(parser.parse(page([["Tip", "5.00"]])) == nil)
    }

    @Test func phoneDateTimeAndReferenceNumbersAreIgnored() {
        let noise = page([
            ["Tel +971 4 123 4567"],
            ["Date 24/09/2026"],
            ["Time 14:05"],
            ["Invoice 000123"],
            ["050-123-4567"],
            ["Discount 10%"],
        ])
        #expect(parser.analyze(noise) == .notFound(.noAmount))
    }

    @Test func negativeAmountsAreIgnored() {
        #expect(parser.parse(page([["-5.00"]])) == nil)
    }

    @Test func zeroAndImplausibleTotalsAreRejected() {
        #expect(parser.parse(page([["TOTAL", "0.00"]])) == nil)
        #expect(parser.parse(page([["TOTAL", "99999999.00"]])) == nil)
    }

    @Test func emptyTextIsNotFound() {
        #expect(parser.analyze([]) == .notFound(.noText))
        #expect(parser.analyze(page([["   "]])) == .notFound(.noText))
    }

    // MARK: Currency

    @Test func noVisibleCurrencyGivesNoCurrency() {
        #expect(total(page([["TOTAL", "25.00"]]))?.currency == nil)
    }

    @Test func currencyElsewhereOnTheReceiptIsUsed() {
        #expect(total(page([["Prices in AED"], ["TOTAL", "25.00"]]))?.currency == .aed)
    }

    @Test func conflictingCurrenciesAreNeverGuessed() {
        let receipt = page([["Accepted: USD, AED"], ["TOTAL", "25.00"]])
        #expect(total(receipt)?.currency == nil)
    }

    /// Device finding: "$" misread inside words must not mean US dollars.
    @Test func aDollarSignInsideWordsIsNotACurrency() {
        let receipt = page([["$AMPLE $HOP"], ["TEST RECEIPT"], ["Notebook", "22.00"], ["Pens", "20.00"], ["TOTAL", "42.00"]])
        #expect(total(receipt) == AmountReading(minorUnits: 42_00, currency: nil))
    }

    @Test(arguments: ["$7.00", "7.00 $", "$ 7.00", "US$ 7.00", "7.00 USD"])
    func aDollarSignNextToAnAmountIsUSD(_ text: String) {
        #expect(total(page([["TOTAL", text]]))?.currency == .usd)
    }

    @Test func parserReportsAmbiguityForStability() {
        let receipt = page([["TOTAL AED", "10.00"], ["TOTAL AED", "12.00"]])
        #expect(parser.observe(receipt) == .ambiguous)
        #expect(parser.observe(page([["TOTAL AED", "12.00"]])) == .reading(ParsedReading(value: AmountReading(minorUnits: 12_00, currency: .aed), confidence: confidence(0.95))))
        #expect(parser.observe(page([["hello"]])) == .nothing)
    }

    @Test func theTotalRowsCurrencyWinsOverTheRestOfThePage() {
        let receipt = page([["Rate 1 USD = 3.67"], ["TOTAL AED", "36.70"]])
        #expect(total(receipt)?.currency == .aed)
    }

    // MARK: Confidence

    @Test func confidenceIsTheLowestOfTheLinesUsed() {
        var lines = page([["TOTAL"], ["25.00"]], score: 0.98)
        lines[1] = RecognizedTextLine(text: "25.00", confidence: confidence(0.81), boundingBox: lines[1].boundingBox)
        #expect(parser.parse(lines)?.confidence == confidence(0.81))
    }

    @Test func missingConfidenceIsNeverInvented() {
        #expect(parser.parse(page([["TOTAL", "25.00"]], score: nil)) != nil)
        #expect(parser.parse(page([["TOTAL", "25.00"]], score: nil))?.confidence == nil)
    }
}

@Suite("Total stability")
struct TotalStabilityTrackerTests {
    func reading(_ minor: Int, _ currency: Currency?, _ score: Double = 0.95) -> ScanObservation<AmountReading> {
        .reading(ParsedReading(value: AmountReading(minorUnits: minor, currency: currency), confidence: confidence(score)))
    }

    @Test func agreesOnTheAmountAndTakesACurrencyNamedTwice() {
        var tracker = TotalStabilityTracker()
        #expect(tracker.add(reading(25_00, .aed)) == nil)
        #expect(tracker.add(reading(25_00, nil)) == nil)
        let candidate = tracker.add(reading(25_00, .aed, 0.9))
        #expect(candidate?.value == AmountReading(minorUnits: 25_00, currency: .aed))
        #expect(candidate?.confidence == confidence(0.9))
        #expect(candidate?.agreeingObservations == 3)
    }

    /// Device finding: one frame read "SAMPLE" as "$AMPLE" and the total
    /// came out in dollars. A currency seen in a single frame is not enough.
    @Test func aCurrencySeenInOnlyOneFrameIsNotUsed() {
        var tracker = TotalStabilityTracker()
        _ = tracker.add(reading(42_00, nil))
        _ = tracker.add(reading(42_00, .usd))
        #expect(tracker.add(reading(42_00, nil))?.value == AmountReading(minorUnits: 42_00, currency: nil))
    }

    @Test func conflictingCurrenciesLeaveItToThePerson() {
        var tracker = TotalStabilityTracker()
        _ = tracker.add(reading(25_00, .aed))
        _ = tracker.add(reading(25_00, .usd))
        #expect(tracker.add(reading(25_00, .aed))?.value.currency == nil)
    }

    /// Device finding: a page with two different totals was accepted because
    /// some frames only caught one of them.
    @Test func anAmbiguousFrameBlocksUntilItAgesOut() {
        var tracker = TotalStabilityTracker(windowSize: 6)
        #expect(tracker.add(.ambiguous) == nil)
        // The ambiguous frame stays in the 6-frame window for 5 more frames.
        for _ in 0..<5 { #expect(tracker.add(reading(12_00, .aed)) == nil) }
        // On the 7th frame it has left the window.
        #expect(tracker.add(reading(12_00, .aed)) != nil)
    }

    /// Device finding: a large terminal amount held close was sometimes read
    /// partially ("5.00"); one stray reading must not block "25.00".
    @Test func oneStrayPartialReadingDoesNotBlock() {
        var tracker = TotalStabilityTracker()
        _ = tracker.add(reading(25_00, .aed))
        _ = tracker.add(reading(5_00, .aed))
        _ = tracker.add(reading(25_00, .aed))
        #expect(tracker.add(reading(25_00, .aed))?.value == AmountReading(minorUnits: 25_00, currency: .aed))
    }

    @Test func amountsThatKeepDisagreeingNeverProduceATotal() {
        var tracker = TotalStabilityTracker()
        for minor in [10_00, 12_00, 10_00, 12_00, 12_00, 10_00, 12_00, 12_00] {
            #expect(tracker.add(reading(minor, .aed)) == nil, "12.00 never has three times the support of 10.00")
        }
    }

    @Test func lowConfidenceFramesDoNotCount() {
        var tracker = TotalStabilityTracker()
        for _ in 0..<5 { #expect(tracker.add(reading(25_00, .aed, 0.5)) == nil) }
        #expect(tracker.add(.nothing) == nil)
    }
}

@MainActor
@Suite("Scanning totals end to end (fakes)")
struct TotalScanIntegrationTests {
    @Test func aStableReceiptBecomesAProposalNeedingConfirmation() async {
        let scan = ScanHarness(parsers: ScanParsers(total: ReceiptTotalParser()))
        let audio = AudioHarness(voiceOver: true)
        let store = NaviNoteStore(audio: audio.coordinator, scanner: scan.scanner, haptics: SilentTestHaptics())
        store.send(.startCheckout)
        store.send(.continueCheckout)
        let receipt = page([["Subtotal", "40.00"], ["VAT", "2.00"], ["TOTAL AED", "42.00"], ["Cash", "50.00"]])
        scan.recognizer.script = Array(repeating: receipt, count: 3)
        store.send(.startScan)
        await eventually { scan.camera.isRunning }
        await scan.feedFrames(3)
        await eventually { store.state.phase == .confirmingTotal }
        #expect(store.state.proposedTotal == ProposedAmount(minorUnits: 42_00, currency: .aed, source: .camera))
        #expect(store.state.checkout.confirmedTotal == nil)
    }

    /// Device finding, end to end: two different totals where only some
    /// frames catch both lines must not produce a total.
    @Test func twoTotalsWithPartialFramesProduceNothing() async {
        var timing = ScanTiming.testing
        timing.scanTimeout = .milliseconds(400)
        let scan = ScanHarness(parsers: ScanParsers(total: ReceiptTotalParser()), timing: timing)
        let both = page([["TOTAL AED", "10.00"], ["TOTAL AED", "12.00"]])
        let onlySecond = page([["TOTAL AED", "12.00"]])
        let onlyFirst = page([["TOTAL AED", "10.00"]])
        scan.recognizer.script = [both, onlySecond, onlySecond, onlySecond, both, onlyFirst, onlySecond, onlySecond]
        let request = scan.request(.total)
        await scan.startScanning(request)
        await scan.feedFrames(8)
        #expect(scan.sink.events.isEmpty, "No total while competing totals keep appearing")
        try? await Task.sleep(for: .milliseconds(600))
        await eventually { !scan.sink.events.isEmpty }
        #expect(scan.sink.events.first?.payload == .noResult)
    }
}
