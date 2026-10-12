import XCTest

/// Checkout steps 2 and 3: payment note and change, using typed totals and
/// chosen notes (no camera needed).
final class CheckoutPaymentUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func tap(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), "Missing \(element)", file: file, line: line)
        var swipes = 0
        while !element.isHittable && swipes < 8 {
            app.scrollViews.firstMatch.swipeUp()
            swipes += 1
        }
        element.tap()
    }

    /// Launches, types and confirms a total, and waits for the note step.
    @MainActor
    private func launchToPaymentStep(total: String, currency: String) {
        app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["NaviNote"].waitForExistence(timeout: 10))
        tap(app.buttons["home.startCheckout"])
        tap(app.buttons["checkout.continue"])
        let field = app.textFields["amount.field"]
        tap(field)
        field.typeText(total)
        if app.keyboards.buttons["Done"].exists { app.keyboards.buttons["Done"].tap() }
        tap(app.buttons["currency.\(currency)"])
        tap(app.buttons["amount.submit"])
        tap(app.buttons["total.confirm"])
        XCTAssertTrue(app.descendants(matching: .any)["checkout.totalSummary"].waitForExistence(timeout: 5))
    }

    @MainActor
    private var result: XCUIElement { app.descendants(matching: .any)["checkout.result"] }

    @MainActor
    private var message: XCUIElement { app.descendants(matching: .any)["home.assistantMessage"] }

    @MainActor
    func testChosenNoteIsConfirmedAndChangeIsShown() {
        launchToPaymentStep(total: "17.35", currency: "USD")
        tap(app.buttons["note.USD-20"])

        let value = app.descendants(matching: .any)["payment.value"]
        XCTAssertTrue(value.waitForExistence(timeout: 5))
        XCTAssertEqual(value.label, "Paying with: 20 dollars")
        tap(app.buttons["payment.confirm"])

        XCTAssertTrue(result.waitForExistence(timeout: 5))
        XCTAssertTrue(result.label.contains("Change due"), result.label)
        XCTAssertTrue(result.label.contains("2 dollars and 65 cents"), result.label)
        XCTAssertTrue(message.label.contains("You should receive 2 dollars and 65 cents in change."), message.label)
        XCTAssertFalse(app.buttons["checkout.cancel"].exists, "The result offers Finish, not Cancel")
    }

    @MainActor
    func testExactPayment() {
        launchToPaymentStep(total: "50", currency: "AED")
        tap(app.buttons["note.AED-50"])
        tap(app.buttons["payment.confirm"])
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        XCTAssertTrue(result.label.contains("Exact payment"), result.label)
        XCTAssertTrue(result.label.contains("No change is due"), result.label)
    }

    @MainActor
    func testSeveralNotesArePaidUntilTheTotalIsCovered() {
        launchToPaymentStep(total: "25", currency: "AED")
        tap(app.buttons["note.AED-20"])
        tap(app.buttons["payment.confirm"])

        let tally = app.descendants(matching: .any)["payment.tally"]
        XCTAssertTrue(tally.waitForExistence(timeout: 5))
        XCTAssertTrue(tally.label.contains("Paid so far: 20 dirhams"), tally.label)
        XCTAssertTrue(tally.label.contains("Still needed: 5 dirhams"), tally.label)
        XCTAssertTrue(message.label.contains("Added a 20 dirham note"), message.label)

        tap(app.buttons["note.AED-10"])
        tap(app.buttons["payment.confirm"])
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        XCTAssertTrue(result.label.contains("5 dirhams"), result.label)
        XCTAssertTrue(message.label.contains("You paid 30 dirhams for a total of 25 dirhams"), message.label)
        XCTAssertTrue(app.descendants(matching: .any)["payment.notes"].exists, "Both notes are listed")

        // A note added by mistake can be taken off again.
        tap(app.buttons["payment.removeLast"])
        XCTAssertTrue(tally.waitForExistence(timeout: 5))
        XCTAssertTrue(tally.label.contains("Paid so far: 20 dirhams"), tally.label)
    }

    @MainActor
    func testNotesThatDontCoverTheTotalSayWhatIsStillOwed() {
        launchToPaymentStep(total: "750", currency: "KES")
        tap(app.buttons["note.KES-500"])
        tap(app.buttons["payment.confirm"])
        tap(app.buttons["payment.finish"])
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        XCTAssertTrue(result.label.contains("Still to pay"), result.label)
        XCTAssertTrue(result.label.contains("250 Kenyan shillings"), result.label)
    }

    @MainActor
    func testOnlyTheCheckoutCurrencysNotesAreOffered() {
        launchToPaymentStep(total: "10", currency: "USD")
        XCTAssertTrue(app.buttons["note.USD-1"].exists)
        XCTAssertTrue(app.buttons["note.USD-100"].exists)
        XCTAssertFalse(app.buttons["note.AED-10"].exists)
        XCTAssertFalse(app.buttons["note.KES-50"].exists)
        XCTAssertEqual(app.buttons["note.USD-20"].label, "20 dollar note")
    }

    @MainActor
    func testRejectingTheNoteGoesBackToChoosingIt() {
        launchToPaymentStep(total: "10", currency: "USD")
        tap(app.buttons["note.USD-5"])
        tap(app.buttons["payment.reject"])
        XCTAssertTrue(app.buttons["note.USD-20"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testFinishReturnsHome() {
        launchToPaymentStep(total: "12", currency: "AED")
        tap(app.buttons["note.AED-20"])
        tap(app.buttons["payment.confirm"])
        tap(app.buttons["checkout.finish"])
        XCTAssertTrue(app.buttons["home.startCheckout"].waitForExistence(timeout: 5))
        XCTAssertTrue(message.label.contains("Home. Choose"), message.label)
    }

    @MainActor
    func testCancelFromThePaymentStepReturnsHome() {
        launchToPaymentStep(total: "10", currency: "USD")
        tap(app.buttons["checkout.cancel"])
        XCTAssertTrue(app.buttons["home.startCheckout"].waitForExistence(timeout: 5))
    }
}
