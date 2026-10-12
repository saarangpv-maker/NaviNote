import XCTest

/// Phase 11: Ask NaviNote answers from NaviNote's own facts, with buttons,
/// typing, and Close back to the step. Astra is off (not set up) in tests.
final class AskNaviNoteUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func tap(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), "Missing \(element)", file: file, line: line)
        // Scroll until the whole element is inside the scroll area: a button
        // half under the voice bar is "hittable" but its centre tap misses.
        let scrollView = app.scrollViews.firstMatch
        var swipes = 0
        while (!element.isHittable || (scrollView.exists && !scrollView.frame.contains(element.frame))) && swipes < 12 {
            scrollView.swipeUp(velocity: .slow)
            swipes += 1
        }
        // A tap while the list is still scrolling only stops the scroll.
        if swipes > 0 { _ = XCTWaiter.wait(for: [XCTestExpectation(description: "scroll settles")], timeout: 1) }
        element.tap()
    }

    /// Types a question and sends it with the keyboard's Send key, as a
    /// person would. (Swiping to reach the Ask button while the keyboard is
    /// up can land on the keyboard, which swipe-types extra words.)
    @MainActor
    private func askTyped(_ question: String) {
        let field = app.textFields["ask.field"]
        tap(field)
        field.typeText(question + "\n")
    }

    @MainActor
    private var message: XCUIElement { app.descendants(matching: .any)["home.assistantMessage"] }

    @MainActor
    private func launch() {
        app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["NaviNote"].waitForExistence(timeout: 10))
    }

    /// Checkout to the result: 17.35 dollars, paid with a 20.
    @MainActor
    private func checkoutToResult() {
        tap(app.buttons["home.startCheckout"])
        tap(app.buttons["checkout.continue"])
        let field = app.textFields["amount.field"]
        tap(field)
        field.typeText("17.35")
        if app.keyboards.buttons["Done"].exists { app.keyboards.buttons["Done"].tap() }
        tap(app.buttons["currency.USD"])
        tap(app.buttons["amount.submit"])
        tap(app.buttons["total.confirm"])
        tap(app.buttons["note.USD-20"])
        tap(app.buttons["payment.confirm"])
        XCTAssertTrue(app.buttons["checkout.finish"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func openAsk() {
        // Ask NaviNote is on Home; from a workflow it opens by voice or typing.
        tap(app.buttons["voice.type"])
        let field = app.textFields["type.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("ask navinote\n")
        XCTAssertTrue(app.navigationBars["Ask NaviNote"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testQuestionButtonsAnswerFromTheTransactionAndCloseReturnsToTheStep() {
        launch()
        checkoutToResult()
        openAsk()

        tap(app.buttons["ask.total"])
        XCTAssertTrue(message.label.contains("The total is 17 dollars and 35 cents."), message.label)
        tap(app.buttons["ask.changeExpected"])
        XCTAssertTrue(message.label.contains("You should receive 2 dollars and 65 cents in change"), message.label)
        tap(app.buttons["ask.paid"])
        XCTAssertTrue(message.label.contains("You've paid 20 dollars with 1 note."), message.label)
        tap(app.buttons["ask.nextStep"])
        XCTAssertTrue(message.label.contains("Check my change"), message.label)

        tap(app.buttons["ask.close"])
        XCTAssertTrue(app.buttons["checkout.finish"].waitForExistence(timeout: 5), "Back on the checkout result")
    }

    @MainActor
    func testTypedQuestionsAndOutOfScopeRequests() {
        launch()
        tap(app.buttons["home.askNaviNote"])
        XCTAssertTrue(app.navigationBars["Ask NaviNote"].waitForExistence(timeout: 5))

        askTyped("what's the total")
        XCTAssertTrue(message.label.contains("There's no total yet."), message.label)

        askTyped("send an email to my mum")
        XCTAssertTrue(message.label.contains("For anything else, turn on Astra language help"), message.label)
        XCTAssertFalse(app.descendants(matching: .any)["ask.online"].exists, "No online answer when Astra is off")
    }

    @MainActor
    func testEveryQuestionButtonIsLabelled() {
        launch()
        tap(app.buttons["home.askNaviNote"])
        for id in ["ask.total", "ask.changeExpected", "ask.received", "ask.missing", "ask.paid", "ask.currency",
                   "ask.whatScanned", "ask.nextStep", "ask.lastInstruction", "ask.explainScreen"] {
            let button = app.buttons[id]
            XCTAssertTrue(button.waitForExistence(timeout: 5), id)
            XCTAssertFalse(button.label.isEmpty, id)
        }
    }
}
