import Testing
@testable import NaviNote

@Suite("Manual amount parsing")
struct MoneyParserTests {
    @Test(arguments: [
        ("12", 12_00),
        ("12.5", 12_50),
        ("12.50", 12_50),
        ("0.05", 5),
        ("1,250", 1_250_00),
        ("1,250.75", 1_250_75),
        ("1 250", 1_250_00),
        ("  40  ", 40_00),
        // Regression from the prototype: a 4+ digit amount without grouping
        // was once truncated to its first three digits.
        ("8976", 8976_00),
        ("10000000", 10_000_000_00),
    ])
    func parsesValidAmounts(_ text: String, _ minorUnits: Int) {
        #expect(MoneyParser.parse(text, currency: .usd) == Money.usd(minorUnits))
    }

    @Test(arguments: [
        "", " ", "abc", "12.", ".5", "12.345", "1,00", "12,50", "1..2", "-5", "+5",
        "0", "0.00", "10000000.01", "999999999999999", "12.5.0", "$12", "12 dollars",
        "1,2345", ",100",
    ])
    func rejectsInvalidAmounts(_ text: String) {
        #expect(MoneyParser.parse(text, currency: .usd) == nil)
    }

    @Test func supportsCommaDecimalLocales() {
        let parsed = MoneyParser.parse("1.250,75", currency: .aed, decimalSeparator: ",", groupingSeparator: ".")
        #expect(parsed == .aed(1_250_75))
        #expect(MoneyParser.parse("12,5", currency: .aed, decimalSeparator: ",", groupingSeparator: ".") == .aed(12_50))
    }

    @Test func refusesIdenticalSeparators() {
        #expect(MoneyParser.parse("12", currency: .usd, decimalSeparator: ",", groupingSeparator: ",") == nil)
    }

    @Test func keepsTheRequestedCurrency() {
        #expect(MoneyParser.parse("400", currency: .kes)?.currency == .kes)
    }
}
