import Testing
@testable import NaviNote

@Suite("Announcement copy")
struct AnnouncementComposerTests {
    func text(_ announcement: Announcement) -> String {
        AnnouncementComposer.text(for: announcement)
    }

    @Test func simulatedReadingsAreAlwaysLabelled() {
        let simulated = ProposedBanknote(denomination: note(.usd, 20), source: .simulated)
        let camera = ProposedBanknote(denomination: note(.usd, 20), source: .camera)
        #expect(text(.currencyRead(simulated)).hasPrefix("Simulated reading, not real recognition."))
        #expect(text(.confirmPaymentNote(simulated)).contains("Simulated"))
        #expect(!text(.currencyRead(camera)).contains("Simulated"))
        let total = ProposedAmount(minorUnits: 5_00, currency: .usd, source: .simulated)
        #expect(text(.confirmTotal(total)).contains("Simulated"))
    }

    @Test func amountsAreSpokenWithUnits() {
        #expect(text(.checkoutResult(total: .usd(17_35), payment: .usd(20_00), outcome: .changeDue(.usd(2_65))))
            == "You paid 20 dollars for a total of 17 dollars and 35 cents. You should receive 2 dollars and 65 cents in change.")
        #expect(text(.checkoutResult(total: .aed(50_00), payment: .aed(50_00), outcome: .exactPayment))
            == "You paid 50 dirhams for a total of 50 dirhams. Exact payment. No change is due.")
        #expect(text(.checkoutResult(total: .kes(750_00), payment: .kes(500_00), outcome: .amountRemaining(.kes(250_00))))
            .contains("250 Kenyan shillings"))
    }

    @Test func paymentProgressSaysWhatIsPaidAndStillNeeded() {
        let twenty = ProposedBanknote(denomination: note(.aed, 20), source: .camera)
        #expect(text(.paymentNoteAdded(twenty, paid: .aed(20_00), remaining: .aed(5_00)))
            == "Added a 20 dirham note. Paid 20 dirhams so far. 5 dirhams still needed. Add another note, or say that's all.")
        #expect(text(.paymentNoteRemoved(paid: .aed(0), remaining: .aed(25_00)))
            == "Removed the last note. Now scan or choose the note you're paying with.")
        #expect(text(.paymentNoteRemoved(paid: .aed(20_00), remaining: .aed(5_00))).hasPrefix("Removed the last note. Paid 20 dirhams"))
    }

    @Test func totalWithoutCurrencyAsksForOne() {
        let proposal = ProposedAmount(minorUnits: 12_05, currency: nil, source: .camera)
        #expect(text(.chooseTotalCurrency(proposal)) == "The total reads 12.05, but no currency was shown. Choose the currency.")
    }

    @Test func rejectionsExplainWhatHappened() {
        #expect(text(.rejected(.mixedCurrency(expected: .usd, found: .aed))).contains("wasn't counted"))
        #expect(text(.rejected(.unsupportedDenomination(currency: .kes, majorValue: 20))).contains("Coins aren't supported"))
    }

    @Test func readCurrencyNeverClaimsAuthenticity() {
        let intro = text(.readingCurrency)
        #expect(intro.contains("can't tell whether a note is genuine"))
        for currency in Currency.allCases {
            for denomination in currency.denominations {
                let spoken = text(.currencyRead(ProposedBanknote(denomination: denomination, source: .camera)))
                #expect(!spoken.localizedCaseInsensitiveContains("genuine"))
                #expect(!spoken.localizedCaseInsensitiveContains("counterfeit"))
                #expect(!spoken.localizedCaseInsensitiveContains("fake"))
            }
        }
    }

    @Test func verdictsNeverClaimGuarantees() {
        let exact = text(.changeVerdict(expected: .usd(5_00), received: .usd(5_00), status: .exact))
        #expect(exact == "You received 5 dollars, which matches the expected change.")
        #expect(!exact.localizedCaseInsensitiveContains("guarantee"))
    }
}
