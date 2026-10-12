import Foundation
import Testing
@testable import NaviNote

/// Text as it might be read off a note, one string per recognized line.
/// Invented layouts that mimic the kind of text printed on real notes.
func noteText(_ texts: [String], score: Double? = 0.95) -> [RecognizedTextLine] {
    texts.enumerated().map { index, text in
        RecognizedTextLine(
            text: text,
            confidence: score.flatMap(RecognitionConfidence.init(score:)),
            boundingBox: CGRect(x: 0.2, y: 0.9 - Double(index) * 0.08, width: 0.5, height: 0.05)
        )
    }
}

@Suite("Banknote text parser")
struct BanknoteTextParserTests {
    let parser = BanknoteTextParser()

    func read(_ texts: [String]) -> BanknoteReading? {
        parser.parse(noteText(texts))?.value
    }

    // MARK: US dollars

    @Test func usdTwentyFromWords() {
        let note = ["FEDERAL RESERVE NOTE", "THE UNITED STATES OF AMERICA", "20", "L 12345678 A",
                    "TWENTY DOLLARS", "SERIES 2017 A", "20", "5 E"]
        #expect(read(note) == BanknoteReading(currency: .usd, majorValue: 20))
    }

    @Test(arguments: [
        ("ONE DOLLAR", 1), ("TWO DOLLARS", 2), ("FIVE DOLLARS", 5), ("TEN DOLLARS", 10),
        ("TWENTY DOLLARS", 20), ("FIFTY DOLLARS", 50), ("ONE HUNDRED DOLLARS", 100),
    ])
    func everyUSDNoteByWords(_ words: String, _ value: Int) {
        #expect(read(["THE UNITED STATES OF AMERICA", words]) == BanknoteReading(currency: .usd, majorValue: value))
    }

    @Test func usdHundredSplitAcrossLines() {
        #expect(read(["FEDERAL RESERVE NOTE", "ONE", "HUNDRED DOLLARS"])?.majorValue == 100)
    }

    @Test func legalTenderDoesNotReadAsTen() {
        let note = ["THIS NOTE IS LEGAL TENDER", "FOR ALL DEBTS PUBLIC AND PRIVATE", "THE UNITED STATES OF AMERICA",
                    "50", "FIFTY DOLLARS"]
        #expect(read(note)?.majorValue == 50)
    }

    @Test func serialsYearsAndPlateCodesAreIgnored() {
        // No value words: only standalone valid numerals count.
        let note = ["FEDERAL RESERVE NOTE", "MB 12345678 C", "SERIES 2013", "B2", "10", "10"]
        #expect(read(note) == BanknoteReading(currency: .usd, majorValue: 10))
    }

    // MARK: UAE dirhams

    @Test func aedFiftyFromEnglishSide() {
        let note = ["CENTRAL BANK OF THE U.A.E.", "FIFTY DIRHAMS", "50", "50"]
        #expect(read(note) == BanknoteReading(currency: .aed, majorValue: 50))
    }

    @Test(arguments: [5, 10, 20, 50, 100, 200, 500, 1000])
    func everyAEDNoteByNumerals(_ value: Int) {
        #expect(read(["UNITED ARAB EMIRATES", "\(value)", "\(value)"]) == BanknoteReading(currency: .aed, majorValue: value))
    }

    @Test func aedTwoHundredByWords() {
        #expect(read(["UNITED ARAB EMIRATES", "TWO HUNDRED DIRHAMS"])?.majorValue == 200)
    }

    @Test func aTwoIsNotADirhamNote() {
        #expect(read(["UNITED ARAB EMIRATES", "TWO DIRHAMS"]) == nil)
        #expect(read(["UNITED ARAB EMIRATES", "2", "2"]) == nil)
    }

    // MARK: Kenyan shillings

    @Test func kesThousandInEnglishAndSwahili() {
        let note = ["CENTRAL BANK OF KENYA", "ONE THOUSAND SHILLINGS", "SHILINGI ELFU MOJA", "1000"]
        #expect(read(note) == BanknoteReading(currency: .kes, majorValue: 1000))
    }

    @Test(arguments: [("HAMSINI", 50), ("MIA MOJA", 100), ("MIA MBILI", 200), ("MIA TANO", 500), ("ELFU MOJA", 1000)])
    func kesSwahiliValues(_ words: String, _ value: Int) {
        #expect(read(["BANKI KUU YA KENYA", "SHILINGI \(words)"]) == BanknoteReading(currency: .kes, majorValue: value))
    }

    @Test func twentyShillingsIsNotASupportedNote() {
        #expect(read(["CENTRAL BANK OF KENYA", "TWENTY SHILLINGS"]) == nil)
    }

    // MARK: Refusals

    @Test func noCurrencyTextMeansNothing() {
        #expect(parser.observe(noteText(["20", "TWENTY", "20"])) == .nothing)
        #expect(parser.observe([]) == .nothing)
    }

    @Test func twoCurrenciesAreAmbiguous() {
        #expect(parser.observe(noteText(["DOLLARS", "DIRHAMS", "20"])) == .ambiguous)
    }

    @Test func twoDifferentValueWordsAreAmbiguous() {
        #expect(parser.observe(noteText(["FEDERAL RESERVE NOTE", "TWENTY DOLLARS", "FIFTY DOLLARS"])) == .ambiguous)
    }

    @Test func evenlySplitNumeralsAreAmbiguous() {
        #expect(parser.observe(noteText(["UNITED ARAB EMIRATES", "50", "100"])) == .ambiguous)
    }

    @Test func aSingleNumeralIsNotEnough() {
        #expect(parser.observe(noteText(["UNITED ARAB EMIRATES", "50"])) == .nothing)
    }

    @Test func wordsInsideOtherWordsDoNotCount() {
        #expect(read(["FEDERAL RESERVE NOTE", "PHONE", "MONEY", "OFTEN"]) == nil)
    }

    // MARK: Confidence

    func lines(_ entries: [(String, Double?)]) -> [RecognizedTextLine] {
        entries.enumerated().map { index, entry in
            RecognizedTextLine(
                text: entry.0,
                confidence: entry.1.flatMap(RecognitionConfidence.init(score:)),
                boundingBox: CGRect(x: 0.2, y: 0.9 - Double(index) * 0.08, width: 0.5, height: 0.05)
            )
        }
    }

    @Test func confidenceIsTheWeakerOfCurrencyAndValue() {
        // Currency is stated clearly by the first line (0.97); the value
        // only by "TWENTY DOLLARS" (0.82).
        let note = lines([("FEDERAL RESERVE NOTE", 0.97), ("TWENTY DOLLARS", 0.82)])
        #expect(parser.parse(note)?.confidence == confidence(0.82))
    }

    /// Device finding: ornate lettering read with low confidence held back a
    /// clearly read "ONE DOLLAR" on a 1 dollar note.
    @Test func decorativeLinesThatAgreeDoNotLowerConfidence() {
        let note = lines([("FEDERAL RESERVE NOTE", 0.72), ("THE UNITED STATES OF AMERICA", 0.75), ("ONE DOLLAR", 0.98)])
        #expect(parser.parse(note) == ParsedReading(value: BanknoteReading(currency: .usd, majorValue: 1), confidence: confidence(0.98)))
    }

    @Test func aDisagreeingLineStillMakesItAmbiguous() {
        let note = lines([("ONE DOLLAR", 0.98), ("TEN", 0.4)])
        #expect(parser.observe(note) == .ambiguous)
    }

    @Test func missingConfidenceIsNeverInvented() {
        #expect(parser.parse(noteText(["FEDERAL RESERVE NOTE", "TWENTY DOLLARS"], score: nil))?.confidence == nil)
        // The value is stated only by a line without a confidence.
        let note = lines([("FEDERAL RESERVE NOTE", 0.99), ("FIFTY", nil)])
        #expect(parser.parse(note)?.confidence == nil)
    }
}

@Suite("Banknote currency across frames and coins")
struct BanknoteScanContextTests {
    let parser = BanknoteTextParser()
    let usdHint = CurrencyHint(currency: .usd, confidence: confidence(0.95))

    @Test func aValueOnlyFrameUsesTheScansCurrency() {
        let frame = noteText(["ONE"], score: 1.0)
        #expect(parser.observe(frame) == .nothing, "Without a hint there is no currency")
        #expect(parser.observe(frame, currencyHint: usdHint)
            == .reading(ParsedReading(value: BanknoteReading(currency: .usd, majorValue: 1), confidence: confidence(0.95))))
    }

    @Test func aDifferentCurrencyInTheFrameIsAmbiguous() {
        #expect(parser.observe(noteText(["DIRHAMS", "TEN"]), currencyHint: usdHint) == .ambiguous)
    }

    @Test func theHintNeverMakesAnUnsupportedValue() {
        #expect(parser.observe(noteText(["TWO", "2", "2"]), currencyHint: CurrencyHint(currency: .aed, confidence: confidence(0.95))) == .nothing)
    }

    @Test func plainUSMarkersIdentifyDollars() {
        #expect(parser.parse(noteText(["IN GOD WE TRUST", "ONE"]))?.value == BanknoteReading(currency: .usd, majorValue: 1))
        #expect(parser.parse(noteText(["THE DEPARTMENT OF THE TREASURY", "FIVE"]))?.value == BanknoteReading(currency: .usd, majorValue: 5))
    }

    @Test func districtNumbersNeverBecomeAValue() {
        // "12" (Federal Reserve district) is printed four times; not a note.
        #expect(parser.observe(noteText(["FEDERAL RESERVE NOTE", "12", "12", "12", "12"])) == .nothing)
    }

    @Test(arguments: [
        ["IN GOD WE TRUST", "UNITED STATES OF AMERICA", "ONE DIME"],
        ["LIBERTY", "IN GOD WE TRUST", "ONE CENT"],
        ["UNITED STATES OF AMERICA", "QUARTER DOLLAR"],
        ["UNITED ARAB EMIRATES", "50 FILS", "50", "50"],
    ])
    func coinsAreNeverReadAsNotes(_ texts: [String]) {
        #expect(parser.observe(noteText(texts)) == .nothing)
        #expect(parser.observe(noteText(texts), currencyHint: usdHint) == .nothing)
        #expect(parser.currencyEvidence(noteText(texts)).isEmpty)
    }

    @Test func contextNeedsTwoFramesOfOneCurrency() {
        var context = BanknoteScanContext()
        context.record([.usd: confidence(0.9)])
        #expect(context.hint == nil)
        context.record([:])
        context.record([.usd: confidence(0.97)])
        #expect(context.hint == CurrencyHint(currency: .usd, confidence: confidence(0.97)))
    }

    @Test func anyOtherCurrencyInTheScanDisablesTheHint() {
        var context = BanknoteScanContext()
        context.record([.usd: confidence(0.9)])
        context.record([.usd: confidence(0.9)])
        context.record([.aed: confidence(0.9)])
        #expect(context.hint == nil)

        var both = BanknoteScanContext()
        both.record([.usd: confidence(0.9), .aed: confidence(0.9)])
        both.record([.usd: confidence(0.9)])
        both.record([.usd: confidence(0.9)])
        #expect(both.hint == nil)
    }

    @Test func aCurrencyWithoutConfidenceGivesNoHint() {
        var context = BanknoteScanContext()
        context.record([.usd: nil])
        context.record([.usd: nil])
        #expect(context.hint == nil)
    }
}

@Suite("Stability tracker: conflicts")
struct StabilityTrackerConflictTests {
    let usd20 = BanknoteReading(currency: .usd, majorValue: 20)
    let usd5 = BanknoteReading(currency: .usd, majorValue: 5)

    func reading(_ value: BanknoteReading) -> ScanObservation<BanknoteReading> {
        .reading(ParsedReading(value: value, confidence: confidence(0.95)))
    }

    @Test func anAmbiguousFrameBlocksUntilItAgesOut() {
        var tracker = StabilityTracker<BanknoteReading>(windowSize: 6)
        _ = tracker.add(.ambiguous)
        for _ in 0..<5 { #expect(tracker.add(reading(usd20)) == nil) }
        #expect(tracker.add(reading(usd20))?.value == usd20)
    }

    @Test func oneStrayReadingIsTolerated() {
        var tracker = StabilityTracker<BanknoteReading>()
        _ = tracker.add(reading(usd20))
        _ = tracker.add(reading(usd5))
        _ = tracker.add(reading(usd20))
        #expect(tracker.add(reading(usd20))?.value == usd20)
    }

    @Test func readingsThatKeepDisagreeingNeverProduceANote() {
        var tracker = StabilityTracker<BanknoteReading>()
        for value in [usd20, usd5, usd20, usd5, usd20, usd20, usd5, usd20] {
            #expect(tracker.add(reading(value)) == nil)
        }
    }
}

@MainActor
@Suite("Reading currency end to end (fakes)")
struct CurrencyScanIntegrationTests {
    @Test func aStableNoteIsReadAndAnnounced() async {
        let scan = ScanHarness(parsers: ScanParsers(banknote: BanknoteTextParser()))
        let audio = AudioHarness(voiceOver: true)
        let store = NaviNoteStore(audio: audio.coordinator, scanner: scan.scanner, haptics: SilentTestHaptics())
        store.send(.startReadingCurrency)
        scan.recognizer.script = Array(repeating: noteText(["UNITED ARAB EMIRATES", "FIFTY DIRHAMS", "50"]), count: 3)
        store.send(.startScan)
        await eventually { scan.camera.isRunning }
        await scan.feedFrames(3)
        await eventually { store.state.lastCurrencyReading != nil }
        #expect(store.state.lastCurrencyReading == ProposedBanknote(denomination: note(.aed, 50), source: .camera))
        #expect(store.state.phase == .readingCurrency)
        #expect(!scan.camera.isRunning, "Each scan reads one note; the next needs another press")
        #expect(audio.accessibility.posts.last?.text == "This is a 50 UAE dirham note.")
    }

    /// Device finding, end to end: on a 1 dollar note the currency text is
    /// rarely legible and the district number "12" is everywhere; frames
    /// that only show "ONE" must still produce a 1 dollar note.
    @Test func aDollarNoteWithIntermittentCurrencyIsRead() async {
        let scan = ScanHarness(parsers: ScanParsers(banknote: BanknoteTextParser()))
        let audio = AudioHarness(voiceOver: true)
        let store = NaviNoteStore(audio: audio.coordinator, scanner: scan.scanner, haptics: SilentTestHaptics())
        store.send(.startReadingCurrency)
        let currencyOnly = noteText(["FEDERAL RESERVE NOTE", "12", "12"], score: 1.0)
        let noise = noteText(["12", "12", "12"], score: 1.0)
        let valueOnly = noteText(["ONE", "12"], score: 1.0)
        scan.recognizer.script = [currencyOnly, noise, currencyOnly, noise, valueOnly, noise, valueOnly, noise, valueOnly]
        store.send(.startScan)
        await eventually { scan.camera.isRunning }
        await scan.feedFrames(9)
        await eventually { store.state.lastCurrencyReading != nil }
        #expect(store.state.lastCurrencyReading == ProposedBanknote(denomination: note(.usd, 1), source: .camera))
    }

    /// Device finding: the portrait side of a 1 dollar note shows its
    /// currency but its value is almost never legible. NaviNote says so and
    /// suggests turning it over, once, instead of guessing.
    @Test func currencyWithoutValueSuggestsTheOtherSideOnce() async {
        var timing = ScanTiming.testing
        timing.framesBeforeSuggestingOtherSide = 5
        let scan = ScanHarness(parsers: ScanParsers(banknote: BanknoteTextParser()), timing: timing)
        scan.recognizer.script = Array(repeating: noteText(["THE UNITED STATES OFAMERICA", "WASHINGTON,D.C.", "12", "12"], score: 1.0), count: 20)
        await scan.startScanning(scan.request(.currencyReading))
        await scan.feedFrames(20)
        let tryOtherSide = AimingGuidance.tryOtherSide.spokenText
        #expect(scan.sink.guidance.filter { $0 == tryOtherSide }.count == 1)
        #expect(scan.scanner.status == .scanning(.tryOtherSide))
        #expect(scan.sink.events.isEmpty, "No value is ever guessed")
    }

    /// Device finding: a 10 dirham note shows "10" once in most frames —
    /// too little to read from one frame, but the value is on this side, so
    /// NaviNote must not ask to turn it over.
    @Test func valueSeenBrieflyDoesNotSuggestTheOtherSide() async {
        var timing = ScanTiming.testing
        timing.framesBeforeSuggestingOtherSide = 5
        let scan = ScanHarness(parsers: ScanParsers(banknote: BanknoteTextParser()), timing: timing)
        let currencyOnly = noteText(["CENTRAL BANK OF THE U.A.E."], score: 1.0)
        let valueOnce = noteText(["CENTRAL BANK OF THE U.A.E.", "10"], score: 1.0)
        scan.recognizer.script = Array(repeating: [currencyOnly, currencyOnly, valueOnce], count: 8).flatMap { $0 }
        await scan.startScanning(scan.request(.paymentNote))
        await scan.feedFrames(24)
        #expect(!scan.sink.guidance.contains(AimingGuidance.tryOtherSide.spokenText))
    }

    /// Device finding: the value can vanish for longer than the suggestion
    /// delay. Once it has been clearly seen twice, it's on this side.
    @Test func valueClearlySeenTwiceSuppressesTheSuggestionForTheScan() async {
        var timing = ScanTiming.testing
        timing.framesBeforeSuggestingOtherSide = 5
        let scan = ScanHarness(parsers: ScanParsers(banknote: BanknoteTextParser()), timing: timing)
        let currencyOnly = noteText(["CENTRAL BANK OF THE U.A.E."], score: 1.0)
        let valueOnce = noteText(["CENTRAL BANK OF THE U.A.E.", "10"], score: 1.0)
        scan.recognizer.script = [currencyOnly, currencyOnly, valueOnce, valueOnce] + Array(repeating: currencyOnly, count: 20)
        await scan.startScanning(scan.request(.returnedNote))
        await scan.feedFrames(24)
        #expect(!scan.sink.guidance.contains(AimingGuidance.tryOtherSide.spokenText))
    }

    /// A single, unclear value sighting (the $1 portrait side read "2" at
    /// 0.30 once) doesn't stop the suggestion.
    @Test func unclearValueSightingsStillAllowTheSuggestion() async {
        var timing = ScanTiming.testing
        timing.framesBeforeSuggestingOtherSide = 5
        let scan = ScanHarness(parsers: ScanParsers(banknote: BanknoteTextParser()), timing: timing)
        let currencyOnly = noteText(["THE UNITED STATES OF AMERICA", "12"], score: 1.0)
        let blurry = noteText(["THE UNITED STATES OF AMERICA"], score: 1.0) + noteText(["2"], score: 0.3)
        scan.recognizer.script = [currencyOnly, currencyOnly, blurry, blurry] + Array(repeating: currencyOnly, count: 20)
        await scan.startScanning(scan.request(.currencyReading))
        await scan.feedFrames(24)
        #expect(scan.sink.guidance.contains(AimingGuidance.tryOtherSide.spokenText))
    }

    @Test func showsValueOnlyForRealNotesOfThatCurrency() {
        let parser = BanknoteTextParser()
        #expect(parser.showsValue(noteText(["10"]), for: .aed))
        #expect(parser.showsValue(noteText(["TEN DIRHAMS"]), for: .aed))
        #expect(!parser.showsValue(noteText(["12"]), for: .usd), "A Federal Reserve district number is not a value")
        #expect(!parser.showsValue(noteText(["L12345678A"]), for: .usd))
        #expect(!parser.showsValue(noteText(["10"]), for: .kes), "10 isn't a Kenyan shilling note")
    }

    @Test func noCurrencyNoSuggestion() async {
        var timing = ScanTiming.testing
        timing.framesBeforeSuggestingOtherSide = 3
        let scan = ScanHarness(parsers: ScanParsers(banknote: BanknoteTextParser()), timing: timing)
        scan.recognizer.script = Array(repeating: noteText(["RANDOM TEXT"], score: 1.0), count: 10)
        await scan.startScanning(scan.request(.currencyReading))
        await scan.feedFrames(10)
        #expect(!scan.sink.guidance.contains(AimingGuidance.tryOtherSide.spokenText))
    }
}
