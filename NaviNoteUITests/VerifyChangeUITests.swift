import XCTest

/// Phase 9: checking returned change, from checkout and from home, using
/// typed amounts and chosen notes (no camera needed). Chosen notes always
/// need a yes before they count.
final class VerifyChangeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func tap(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), "Missing \(element)", file: file, line: line)
        var swipes = 0
        while !element.isHittable && swipes < 10 {
            app.scrollViews.firstMatch.swipeUp()
            swipes += 1
        }
        element.tap()
    }

    @MainActor
    private func launch() {
        app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["NaviNote"].waitForExistence(timeout: 10))
    }

    @MainActor
    private func typeAmount(_ text: String) {
        let field = app.textFields["amount.field"]
        tap(field)
        field.typeText(text)
        if app.keyboards.buttons["Done"].exists { app.keyboards.buttons["Done"].tap() }
    }

    /// Home → Verify Change → expected amount and currency → confirmed.
    @MainActor
    private func startFromHome(expecting amount: String, currency: String) {
        launch()
        tap(app.buttons["home.verifyChange"])
        typeAmount(amount)
        tap(app.buttons["currency.\(currency)"])
        tap(app.buttons["amount.submit"])
        tap(app.buttons["expected.confirm"])
        XCTAssertTrue(app.descendants(matching: .any)["change.tally"].waitForExistence(timeout: 5))
    }

    /// Chooses a note and confirms it.
    @MainActor
    private func add(_ note: String) {
        tap(app.buttons["note.\(note)"])
        tap(app.buttons["returned.confirm"])
    }

    @MainActor private var verdict: XCUIElement { app.descendants(matching: .any)["change.verdict"] }
    @MainActor private var tally: XCUIElement { app.descendants(matching: .any)["change.tally"] }

    @MainActor
    func testCheckoutChangeIsCheckedAndMatches() {
        launch()
        tap(app.buttons["home.startCheckout"])
        tap(app.buttons["checkout.continue"])
        typeAmount("15")
        tap(app.buttons["currency.AED"])
        tap(app.buttons["amount.submit"])
        tap(app.buttons["total.confirm"])
        tap(app.buttons["note.AED-20"])
        tap(app.buttons["payment.confirm"])

        tap(app.buttons["checkout.checkChange"])
        XCTAssertTrue(tally.waitForExistence(timeout: 5))
        XCTAssertTrue(tally.label.contains("Change expected: 5 dirhams"), tally.label)

        tap(app.buttons["note.AED-5"])
        XCTAssertTrue(app.descendants(matching: .any)["returned.value"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Chosen by you."].exists)
        tap(app.buttons["returned.confirm"])

        XCTAssertTrue(verdict.waitForExistence(timeout: 5))
        XCTAssertTrue(verdict.label.contains("Change matches"), verdict.label)
    }

    @MainActor
    func testHomeVerifyChangeReportsShortChange() {
        startFromHome(expecting: "30", currency: "USD")
        add("USD-20")
        XCTAssertTrue(tally.label.contains("Received so far: 20 dollars"), tally.label)
        XCTAssertTrue(tally.label.contains("10 dollars still to come"), tally.label)
        add("USD-5")
        tap(app.buttons["change.finish"])
        XCTAssertTrue(verdict.waitForExistence(timeout: 5))
        XCTAssertTrue(verdict.label.contains("Less than expected"), verdict.label)
        XCTAssertTrue(verdict.label.contains("5 dollars"), verdict.label)
        // More notes can still be added.
        tap(app.buttons["change.addMore"])
        add("USD-5")
        XCTAssertTrue(verdict.waitForExistence(timeout: 5))
        XCTAssertTrue(verdict.label.contains("Change matches"), verdict.label)
    }

    @MainActor
    func testTooMuchChangeAndRemoveLastNote() {
        startFromHome(expecting: "5", currency: "USD")
        add("USD-10")
        XCTAssertTrue(verdict.waitForExistence(timeout: 5))
        XCTAssertTrue(verdict.label.contains("More than expected"), verdict.label)
        tap(app.buttons["change.removeLast"])
        XCTAssertTrue(tally.waitForExistence(timeout: 5))
        XCTAssertTrue(tally.label.contains("No notes counted yet"), tally.label)
        XCTAssertFalse(app.buttons["change.removeLast"].exists, "Nothing left to remove")
    }

    @MainActor
    func testRejectedNoteIsNotCounted() {
        startFromHome(expecting: "10", currency: "AED")
        tap(app.buttons["note.AED-10"])
        tap(app.buttons["returned.reject"])
        XCTAssertTrue(tally.waitForExistence(timeout: 5))
        XCTAssertTrue(tally.label.contains("No notes counted yet"), tally.label)
    }

    @MainActor
    func testFinishingWithNoNotesSaysChangeWasNotChecked() {
        startFromHome(expecting: "50", currency: "KES")
        XCTAssertFalse(app.buttons["note.USD-10"].exists, "Only the expected currency's notes are offered")
        tap(app.buttons["change.finish"])
        XCTAssertTrue(verdict.waitForExistence(timeout: 5))
        XCTAssertTrue(verdict.label.contains("Change not checked"), verdict.label)
        tap(app.buttons["change.done"])
        XCTAssertTrue(app.buttons["home.startCheckout"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testExpectedChangeNeedsACurrencyBeforeConfirming() {
        launch()
        tap(app.buttons["home.verifyChange"])
        typeAmount("20")
        tap(app.buttons["amount.submit"])
        let value = app.descendants(matching: .any)["expected.value"]
        XCTAssertTrue(value.waitForExistence(timeout: 5))
        XCTAssertTrue(value.label.contains("currency not chosen"), value.label)
        tap(app.buttons["expected.confirm"])
        XCTAssertTrue(app.buttons["expected.confirm"].exists, "Refused without a currency")
        tap(app.buttons["currency.AED"])
        XCTAssertEqual(value.label, "Change you expect: 20 dirhams")
        tap(app.buttons["expected.reject"])
        XCTAssertTrue(app.textFields["amount.field"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testExactPaymentOffersNoChangeCheck() {
        launch()
        tap(app.buttons["home.startCheckout"])
        tap(app.buttons["checkout.continue"])
        typeAmount("20")
        tap(app.buttons["currency.USD"])
        tap(app.buttons["amount.submit"])
        tap(app.buttons["total.confirm"])
        tap(app.buttons["note.USD-20"])
        tap(app.buttons["payment.confirm"])
        XCTAssertTrue(app.buttons["checkout.finish"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["checkout.checkChange"].exists)
    }
}
