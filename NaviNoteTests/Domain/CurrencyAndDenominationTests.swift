import Testing
@testable import NaviNote

@Suite("Currency and supported denominations")
struct CurrencyAndDenominationTests {
    @Test func phaseOneBanknoteValuesMatchTheApprovedList() {
        #expect(Currency.aed.approvedBanknoteValues == [5, 10, 20, 50, 100, 200, 500, 1000])
        #expect(Currency.usd.approvedBanknoteValues == [1, 2, 5, 10, 20, 50, 100])
        #expect(Currency.kes.approvedBanknoteValues == [50, 100, 200, 500, 1000])
    }

    @Test func onlyThreeCurrenciesAreSupported() {
        #expect(Currency.allCases == [.aed, .usd, .kes])
    }

    @Test(arguments: ["AED", "aed", " usd ", "KES\n"])
    func parsesSupportedCodes(_ code: String) {
        #expect(Currency(code: code) != nil)
    }

    @Test(arguments: ["EUR", "GBP", "", "US", "$", "DHS"])
    func rejectsUnsupportedCodes(_ code: String) {
        #expect(Currency(code: code) == nil)
    }

    @Test(arguments: Currency.allCases)
    func everyApprovedValueIsASupportedDenomination(_ currency: Currency) {
        for value in currency.approvedBanknoteValues {
            let denomination = SupportedDenomination(currency: currency, majorValue: value)
            #expect(denomination?.value == Money(majorUnits: value, currency: currency))
        }
        #expect(currency.denominations.count == currency.approvedBanknoteValues.count)
    }

    @Test(arguments: [
        (Currency.aed, 1), (.aed, 2), (.aed, 25), (.aed, 2000),
        (.usd, 500), (.usd, 1000), (.usd, 3),
        (.kes, 5), (.kes, 10), (.kes, 20), (.kes, 2000),
        (.usd, 0), (.aed, -5),
    ])
    func rejectsUnsupportedDenominations(_ currency: Currency, _ value: Int) {
        #expect(SupportedDenomination(currency: currency, majorValue: value) == nil)
    }

    @Test func denominationValidityDependsOnCurrency() {
        #expect(SupportedDenomination(currency: .usd, majorValue: 2) != nil)
        #expect(SupportedDenomination(currency: .aed, majorValue: 2) == nil)
        #expect(SupportedDenomination(currency: .kes, majorValue: 1000) != nil)
        #expect(SupportedDenomination(currency: .usd, majorValue: 1000) == nil)
    }

    @Test func denominationValueUsesMinorUnits() {
        #expect(note(.aed, 500).value.minorUnits == 50_000)
        #expect(note(.usd, 1).value.minorUnits == 100)
    }
}
