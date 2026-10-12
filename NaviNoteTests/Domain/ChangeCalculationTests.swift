import Testing
@testable import NaviNote

@Suite("Checkout calculation")
struct CheckoutCalculatorTests {
    @Test func paperExampleKES() throws {
        #expect(try CheckoutCalculator.outcome(total: .kes(100_00), payment: .kes(500_00)) == .changeDue(.kes(400_00)))
    }

    @Test func paperExampleAED() throws {
        #expect(try CheckoutCalculator.outcome(total: .aed(25_00), payment: .aed(50_00)) == .changeDue(.aed(25_00)))
    }

    @Test(arguments: Currency.allCases)
    func everyDenominationAgainstBoundaryTotals(_ currency: Currency) throws {
        for denomination in currency.denominations {
            let payment = denomination.value
            let exact = try CheckoutCalculator.outcome(total: payment, payment: payment)
            #expect(exact == .exactPayment)

            let oneMinorLess = Money(minorUnits: payment.minorUnits - 1, currency: currency)
            #expect(try CheckoutCalculator.outcome(total: oneMinorLess, payment: payment) == .changeDue(Money(minorUnits: 1, currency: currency)))

            let oneMinorMore = Money(minorUnits: payment.minorUnits + 1, currency: currency)
            #expect(try CheckoutCalculator.outcome(total: oneMinorMore, payment: payment) == .amountRemaining(Money(minorUnits: 1, currency: currency)))
        }
    }

    @Test func fractionalTotalsAreExact() throws {
        #expect(try CheckoutCalculator.outcome(total: .usd(17_35), payment: .usd(20_00)) == .changeDue(.usd(2_65)))
        #expect(try CheckoutCalculator.outcome(total: .aed(0_10), payment: .aed(5_00)) == .changeDue(.aed(4_90)))
    }

    @Test func currencyMismatchThrows() {
        #expect(throws: MoneyError.currencyMismatch(.usd, .aed)) {
            try CheckoutCalculator.outcome(total: .aed(10_00), payment: .usd(20_00))
        }
    }

    @Test func sessionOutcomeNeedsBothValues() {
        var session = CheckoutSession()
        #expect(session.outcome == nil)
        session.confirmedTotal = ConfirmedAmount(money: .usd(7_00), source: .manualEntry)
        #expect(session.outcome == nil)
        session.confirmedPayment = CashPayment(singleNote: ConfirmedBanknote(denomination: note(.usd, 10), source: .manualEntry))
        #expect(session.outcome == .changeDue(.usd(3_00)))
        #expect(session.confirmedPayment?.notes.count == 1)
    }

    @Test func paymentsAddUpAndRefuseOtherCurrencies() throws {
        let twenty = ConfirmedBanknote(denomination: note(.aed, 20), source: .manualEntry)
        let ten = ConfirmedBanknote(denomination: note(.aed, 10), source: .camera)
        let dollar = ConfirmedBanknote(denomination: note(.usd, 1), source: .manualEntry)
        let payment = try #require(CashPayment(singleNote: twenty).adding(ten))
        #expect(payment.total == .aed(30_00))
        #expect(payment.adding(dollar) == nil, "Mixed-currency payments are refused")
        #expect(payment.removingLast() == CashPayment(singleNote: twenty))
        #expect(CashPayment(singleNote: twenty).removingLast() == nil, "A payment is never empty")
    }

    @Test func sessionNeverReturnsAWrongAnswerForMixedCurrencies() {
        var session = CheckoutSession()
        session.confirmedTotal = ConfirmedAmount(money: .usd(7_00), source: .manualEntry)
        session.confirmedPayment = CashPayment(singleNote: ConfirmedBanknote(denomination: note(.aed, 10), source: .manualEntry))
        #expect(session.outcome == nil)
    }
}

@Suite("Returned change verification")
struct ReturnedChangeSessionTests {
    let ids = SequentialRequestIDs()

    func banknote(_ currency: Currency, _ value: Int) -> ConfirmedBanknote {
        ConfirmedBanknote(denomination: note(currency, value), source: .camera)
    }

    @Test func requiresPositiveExpectedChange() {
        #expect(ReturnedChangeSession(expectedChange: .usd(0)) == nil)
        #expect(ReturnedChangeSession(expectedChange: .usd(-1)) == nil)
        #expect(ReturnedChangeSession(expectedChange: .usd(1)) != nil)
    }

    @Test func paperExampleTwoKES200NotesIsExact() throws {
        var session = try #require(ReturnedChangeSession(expectedChange: .kes(400_00)))
        #expect(session.status == .awaitingNotes)
        #expect(session.add(banknote(.kes, 200), requestID: ids.make()) == .success(.shortSoFar(missing: .kes(200_00))))
        #expect(session.add(banknote(.kes, 200), requestID: ids.make()) == .success(.exact))
        #expect(session.receivedTotal == .kes(400_00))
    }

    @Test func excessiveChange() throws {
        var session = try #require(ReturnedChangeSession(expectedChange: .usd(3_00)))
        session.add(banknote(.usd, 2), requestID: ids.make())
        #expect(session.add(banknote(.usd, 2), requestID: ids.make()) == .success(.excessive(over: .usd(1_00))))
    }

    @Test func mixedCurrencyNoteDoesNotAffectTheTotal() throws {
        var session = try #require(ReturnedChangeSession(expectedChange: .aed(20_00)))
        session.add(banknote(.aed, 10), requestID: ids.make())
        #expect(session.add(banknote(.usd, 10), requestID: ids.make()) == .failure(.mixedCurrency(expected: .aed, found: .usd)))
        #expect(session.receivedTotal == .aed(10_00))
        #expect(session.acceptedNotes.count == 1)
    }

    @Test func duplicateRequestIsCountedOnce() throws {
        var session = try #require(ReturnedChangeSession(expectedChange: .usd(40_00)))
        let id = ids.make()
        #expect(session.add(banknote(.usd, 20), requestID: id) == .success(.shortSoFar(missing: .usd(20_00))))
        #expect(session.add(banknote(.usd, 20), requestID: id) == .failure(.duplicate))
        #expect(session.receivedTotal == .usd(20_00))
    }

    @Test func removeLastReEvaluates() throws {
        var session = try #require(ReturnedChangeSession(expectedChange: .usd(5_00)))
        session.add(banknote(.usd, 5), requestID: ids.make())
        session.add(banknote(.usd, 5), requestID: ids.make())
        #expect(session.status == .excessive(over: .usd(5_00)))
        #expect(session.removeLast() == banknote(.usd, 5))
        #expect(session.status == .exact)
        session.removeLast()
        #expect(session.status == .awaitingNotes)
        #expect(session.removeLast() == nil)
    }

    @Test func identicalNotesFromDifferentRequestsBothCount() throws {
        var session = try #require(ReturnedChangeSession(expectedChange: .aed(100_00)))
        session.add(banknote(.aed, 50), requestID: ids.make())
        #expect(session.add(banknote(.aed, 50), requestID: ids.make()) == .success(.exact))
    }
}
