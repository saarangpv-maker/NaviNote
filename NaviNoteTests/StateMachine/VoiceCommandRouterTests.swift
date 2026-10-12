import Testing
@testable import NaviNote

@Suite("Voice command routing")
struct VoiceCommandRouterTests {
    @Test(arguments: [
        ("Start checkout", NaviNoteAction.startCheckout),
        ("check out please", .startCheckout),
        ("Read currency.", .startReadingCurrency),
        ("what note is this?", .startReadingCurrency),
        ("What note am I holding?", .startReadingCurrency),
        ("what's this note", .startReadingCurrency),
        ("Verify change", .startChangeVerification),
        ("Ask NaviNote", .openAskNaviNote),
        ("Can you repeat", .repeatLastInstruction),
        ("Remove last note", .removeLastReturnedNote),
        ("undo", .removeLastReturnedNote),
        ("scan", .startScan),
        ("Close", .closeAskNaviNote),
    ])
    func routesCommandsToTheirFirstAction(_ text: String, _ action: NaviNoteAction) {
        guard case .actions(let candidates) = VoiceCommandRouter.route(text) else {
            Issue.record("\(text) was not routed")
            return
        }
        #expect(candidates.first == action)
    }

    @Test func paymentNotesCanBeFinishedAndRemovedByVoice() {
        #expect(VoiceCommandRouter.route("that's all") == .actions([.finishReturnedChange, .finishPaymentNotes, .finish, .closeAskNaviNote]))
        #expect(VoiceCommandRouter.route("remove the last note") == .actions([.removeLastReturnedNote, .removeLastPaymentNote]))
    }

    @Test func yesAndNoMapToConfirmAndReject() {
        #expect(VoiceCommandRouter.route("Yes") == .actions([.confirmTotal, .confirmPaymentNote, .confirmExpectedChange, .confirmReturnedNote, .continueCheckout]))
        #expect(VoiceCommandRouter.route("That’s right") == VoiceCommandRouter.route("yes"))
        #expect(VoiceCommandRouter.route("no") == .actions([.rejectTotal, .rejectPaymentNote, .rejectExpectedChange, .rejectReturnedNote]))
    }

    @Test func longerPhrasesWin() {
        #expect(VoiceCommandRouter.route("stop scanning") == .actions([.stopScan, .cancel]))
        #expect(VoiceCommandRouter.route("scan again") == .actions([.rejectTotal, .rejectPaymentNote, .rejectReturnedNote, .retry, .startScan]))
    }

    @Test func wordsInsideOtherWordsDoNotMatch() {
        #expect(VoiceCommandRouter.route("I know") == .unrecognized, "\"no\" inside \"know\"")
        #expect(VoiceCommandRouter.route("yesterday") == .unrecognized)
        #expect(VoiceCommandRouter.route("scanner") == .unrecognized)
    }

    @Test func helpAndUnrecognized() {
        #expect(VoiceCommandRouter.route("help") == .showHelp)
        #expect(VoiceCommandRouter.route("what can I say") == .showHelp)
        #expect(VoiceCommandRouter.route("play some music") == .unrecognized)
        #expect(VoiceCommandRouter.route("") == .unrecognized)
        #expect(VoiceCommandRouter.route("?!") == .unrecognized)
    }

    @Test func amountsAreNotGuessed() {
        #expect(VoiceCommandRouter.route("twenty dollars") == .unrecognized)
    }
}
