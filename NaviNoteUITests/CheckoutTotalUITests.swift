import XCTest

final class CheckoutTotalUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launchToTotalStep() {
        app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["NaviNote"].waitForExistence(timeout: 10))
        tap(app.buttons["home.startCheckout"])
        tap(app.buttons["checkout.continue"])
        XCTAssertTrue(app.textFields["amount.field"].waitForExistence(timeout: 5))
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

    @MainActor
    private func typeAmount(_ text: String) {
        let field = app.textFields["amount.field"]
        tap(field)
        field.typeText(text)
        if app.keyboards.buttons["Done"].exists { app.keyboards.buttons["Done"].tap() }
        else if app.toolbars.buttons["Done"].exists { app.toolbars.buttons["Done"].tap() }
    }

    @MainActor
    func testTypedTotalWithCurrencyIsConfirmedAndCheckoutMovesOn() {
        launchToTotalStep()
        typeAmount("12.50")
        tap(app.buttons["currency.USD"])
        tap(app.buttons["amount.submit"])

        let value = app.descendants(matching: .any)["total.value"]
        XCTAssertTrue(value.waitForExistence(timeout: 5))
        XCTAssertEqual(value.label, "Total: 12 dollars and 50 cents")
        tap(app.buttons["total.confirm"])

        // The payment-note step follows.
        let message = app.descendants(matching: .any)["home.assistantMessage"]
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertTrue(message.label.contains("Total confirmed: 12 dollars and 50 cents"), message.label)
    }

    @MainActor
    func testTotalWithoutCurrencyMustHaveOneChosen() {
        launchToTotalStep()
        typeAmount("25")
        tap(app.buttons["amount.submit"])
        let value = app.descendants(matching: .any)["total.value"]
        XCTAssertTrue(value.waitForExistence(timeout: 5))
        XCTAssertTrue(value.label.contains("currency not chosen"))

        // Confirming without a currency is refused.
        tap(app.buttons["total.confirm"])
        XCTAssertTrue(app.buttons["total.confirm"].exists)

        tap(app.buttons["currency.AED"])
        XCTAssertEqual(value.label, "Total: 25 dirhams")
        tap(app.buttons["total.confirm"])
        XCTAssertTrue(app.descendants(matching: .any)["home.assistantMessage"].label.contains("Total confirmed: 25 dirhams"))
    }

    @MainActor
    func testInvalidAmountIsExplained() {
        launchToTotalStep()
        typeAmount("12.345")
        tap(app.buttons["amount.submit"])
        XCTAssertTrue(app.descendants(matching: .any)["amount.error"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["amount.field"].exists, "Still on the total step")
    }

    @MainActor
    func testRejectingTheTotalGoesBackToFindingIt() {
        launchToTotalStep()
        typeAmount("5")
        tap(app.buttons["currency.KES"])
        tap(app.buttons["amount.submit"])
        tap(app.buttons["total.reject"])
        XCTAssertTrue(app.textFields["amount.field"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testCancelReturnsHome() {
        launchToTotalStep()
        tap(app.buttons["checkout.cancel"])
        XCTAssertTrue(app.buttons["home.startCheckout"].waitForExistence(timeout: 5))
    }
}
