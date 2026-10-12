import Foundation
import Testing
@testable import NaviNote

@Suite("Money arithmetic")
struct MoneyTests {
    @Test func addsAndSubtractsInTheSameCurrency() throws {
        #expect(try Money.usd(12_50).adding(.usd(7_50)) == .usd(20_00))
        #expect(try Money.usd(20_00).subtracting(.usd(12_50)) == .usd(7_50))
        #expect(try Money.kes(100_00).subtracting(.kes(500_00)) == .kes(-400_00))
    }

    @Test func mixedCurrencyArithmeticThrows() {
        #expect(throws: MoneyError.currencyMismatch(.usd, .aed)) { try Money.usd(1_00).adding(.aed(1_00)) }
        #expect(throws: MoneyError.currencyMismatch(.kes, .usd)) { try Money.kes(1_00).subtracting(.usd(1_00)) }
        #expect(throws: MoneyError.currencyMismatch(.aed, .kes)) { try Money.aed(1_00).compare(to: .kes(1_00)) }
    }

    @Test func overflowThrowsInsteadOfWrapping() {
        let huge = Money(minorUnits: .max, currency: .usd)
        #expect(throws: MoneyError.overflow) { try huge.adding(.usd(1)) }
        let tiny = Money(minorUnits: .min, currency: .usd)
        #expect(throws: MoneyError.overflow) { try tiny.subtracting(.usd(1)) }
        #expect(Money(majorUnits: .max, currency: .usd) == nil)
    }

    @Test func comparesWithinACurrency() throws {
        #expect(try Money.aed(5_00).compare(to: .aed(10_00)) == .less)
        #expect(try Money.aed(10_00).compare(to: .aed(10_00)) == .equal)
        #expect(try Money.aed(10_01).compare(to: .aed(10_00)) == .greater)
    }

    @Test func amountsInDifferentCurrenciesAreNeverEqual() {
        #expect(Money.usd(10_00) != Money.aed(10_00))
    }

    @Test func splitsIntoMajorAndMinorParts() {
        #expect(Money.usd(12_05).majorPart == 12)
        #expect(Money.usd(12_05).minorPart == 5)
        #expect(Money.usd(-12_05).majorPart == 12)
        #expect(Money.usd(-12_05).minorPart == 5)
    }

    @Test func decimalValueIsExact() {
        #expect(Money.usd(12_34).decimalValue == Decimal(string: "12.34"))
        #expect(Money.usd(-5).decimalValue == Decimal(string: "-0.05"))
        #expect(Money.usd(10_000_000_00).decimalValue == Decimal(string: "10000000"))
    }

    @Test func plausibilityBounds() {
        #expect(Money.usd(1).isPlausibleTransactionAmount)
        #expect(Money.usd(10_000_000_00).isPlausibleTransactionAmount)
        #expect(!Money.usd(10_000_000_01).isPlausibleTransactionAmount)
        #expect(!Money.usd(0).isPlausibleTransactionAmount)
        #expect(!Money.usd(-1).isPlausibleTransactionAmount)
    }

    @Test func sumsALists() throws {
        #expect(try Money.sum([.kes(200_00), .kes(200_00)], in: .kes) == .kes(400_00))
        #expect(try Money.sum([], in: .aed) == .zero(.aed))
        #expect(throws: MoneyError.currencyMismatch(.kes, .usd)) { try Money.sum([.usd(1)], in: .kes) }
    }

    @Test func magnitude() {
        #expect(Money.usd(-7_50).magnitude == .usd(7_50))
        #expect(Money(minorUnits: .min, currency: .usd).magnitude == nil)
    }
}

@Suite("Money formatting")
struct MoneyFormattingTests {
    @Test(arguments: [
        (Money.usd(20_00), "20 dollars"),
        (Money.usd(1_00), "1 dollar"),
        (Money.usd(12_50), "12 dollars and 50 cents"),
        (Money.usd(1_01), "1 dollar and 1 cent"),
        (Money.usd(50), "50 cents"),
        (Money.aed(25_00), "25 dirhams"),
        (Money.aed(1_00), "1 dirham"),
        (Money.aed(10_25), "10 dirhams and 25 fils"),
        (Money.kes(400_00), "400 Kenyan shillings"),
        (Money.kes(1_00), "1 Kenyan shilling"),
        (Money.usd(0), "0 dollars"),
        (Money.usd(-3_00), "minus 3 dollars"),
    ])
    func spokenDescription(_ money: Money, _ expected: String) {
        #expect(money.spokenDescription == expected)
    }

    @Test func displayFormattingIsLocaleAware() {
        let us = Locale(identifier: "en_US")
        #expect(Money.usd(20_00).formatted(locale: us) == "$20")
        #expect(Money.usd(12_50).formatted(locale: us) == "$12.50")
        #expect(Money.usd(1_234_50).formatted(locale: us) == "$1,234.50")

        let aed = Money.aed(12_50).formatted(locale: us)
        #expect(aed.contains("AED") && aed.contains("12.50"))

        let german = Money.usd(12_50).formatted(locale: Locale(identifier: "de_DE"))
        #expect(german.contains("12,50"))
    }

    @Test func denominationDescriptions() {
        #expect(note(.usd, 20).spokenDescription == "20 dollar note")
        #expect(note(.kes, 1000).spokenDescription == "1000 Kenyan shilling note")
        #expect(note(.aed, 5).spokenDescription == "5 dirham note")
    }
}
