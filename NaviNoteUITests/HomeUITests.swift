import XCTest

final class HomeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(arguments: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
    }

    /// Waits until an element can be tapped, scrolling if it is below the fold.
    @MainActor
    private func tapWhenReady(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), file: file, line: line)
        var swipes = 0
        while !element.isHittable && swipes < 5 { app.swipeUp(); swipes += 1 }
        let hittable = expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: element)
        wait(for: [hittable], timeout: 5)
        element.tap()
    }

    @MainActor
    func testHomeShowsEveryPrimaryControl() {
        launch()
        XCTAssertTrue(app.navigationBars["NaviNote"].waitForExistence(timeout: 10))
        for id in ["home.startCheckout", "home.readCurrency", "home.verifyChange", "home.askNaviNote",
                   "voice.repeat", "voice.help", "voice.type", "voice.talk", "home.settings"] {
            let button = app.buttons[id]
            XCTAssertTrue(button.exists, "Missing \(id)")
            XCTAssertTrue(button.isEnabled, "\(id) should be enabled")
        }
        XCTAssertEqual(app.buttons["home.startCheckout"].label, "Start Checkout")
        XCTAssertEqual(app.buttons["home.settings"].label, "Settings")
        XCTAssertTrue(app.staticTexts["What would you like to do?"].exists)
        XCTAssertTrue(app.otherElements["home.privacyNotice"].exists || app.staticTexts.matching(identifier: "home.privacyNotice").firstMatch.exists)
    }

    @MainActor
    func testTalkIsReadyButNothingListensAtLaunch() {
        launch()
        let talk = app.buttons["voice.talk"]
        XCTAssertTrue(talk.waitForExistence(timeout: 10))
        XCTAssertTrue(talk.isEnabled, "Push-to-talk is available")
        XCTAssertEqual(talk.label, "Talk")
        // Nothing listens until Talk is pressed. (Talk is not pressed here:
        // the simulator has no real microphone, and permission prompts
        // belong to the physical-iPhone checklist.)
        let status = app.descendants(matching: .any)["voice.status"]
        XCTAssertTrue(status.label.contains("Press Talk"), "Status was: \(status.label)")
    }

    @MainActor
    func testTypedCommandsDriveTheSameWorkflow() {
        launch()
        tapWhenReady(app.buttons["voice.type"])
        let field = app.textFields["type.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("start checkout")
        app.buttons["type.send"].tap()
        XCTAssertTrue(app.navigationBars["Checkout"].waitForExistence(timeout: 5))

        tapWhenReady(app.buttons["voice.type"])
        XCTAssertTrue(app.textFields["type.field"].waitForExistence(timeout: 5))
        app.textFields["type.field"].typeText("cancel\n")
        XCTAssertTrue(app.navigationBars["NaviNote"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testWorkflowScreensKeepVoiceControlsAndReturnHome() {
        launch()
        tapWhenReady(app.buttons["home.askNaviNote"])
        XCTAssertTrue(app.navigationBars["Ask NaviNote"].waitForExistence(timeout: 5))
        for id in ["voice.talk", "voice.type", "voice.repeat", "voice.help"] {
            XCTAssertTrue(app.buttons[id].exists, "\(id) must be available on workflow screens too")
        }
        let exit = app.buttons["ask.close"]
        XCTAssertEqual(exit.label, "Close")
        exit.tap()
        XCTAssertTrue(app.navigationBars["NaviNote"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testEachFeatureOpensItsOwnScreen() {
        launch()
        let expectations = [
            ("home.readCurrency", "Read Currency", "currency.done", "Done"),
            ("home.verifyChange", "Verify Change", "checkout.cancel", "Cancel"),
            ("home.askNaviNote", "Ask NaviNote", "ask.close", "Close"),
        ]
        for (id, title, exitID, exitLabel) in expectations {
            tapWhenReady(app.buttons[id])
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5), "\(title) did not open")
            XCTAssertEqual(app.buttons[exitID].label, exitLabel)
            tapWhenReady(app.buttons[exitID])
            XCTAssertTrue(app.navigationBars["NaviNote"].waitForExistence(timeout: 5))
        }
    }

    @MainActor
    func testRepeatKeepsTheHomeScreen() {
        launch()
        app.buttons["voice.repeat"].tap()
        XCTAssertTrue(app.navigationBars["NaviNote"].exists)
        XCTAssertTrue(app.buttons["home.startCheckout"].exists)
    }

    @MainActor
    func testHelpAndSettingsSheets() {
        launch()
        app.buttons["voice.help"].tap()
        XCTAssertTrue(app.navigationBars["Help"].waitForExistence(timeout: 5))
        // The footer is further down a lazily loaded list.
        let coins = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Coins'")).firstMatch
        var swipes = 0
        while !coins.exists && swipes < 6 { app.collectionViews.firstMatch.swipeUp(); swipes += 1 }
        XCTAssertTrue(coins.exists, "Help must say that coins aren't supported")
        tapWhenReady(app.buttons["sheet.done"])
        XCTAssertTrue(app.navigationBars["Help"].waitForNonExistence(timeout: 5))

        tapWhenReady(app.buttons["home.settings"])
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["settings.haptics"].exists)
        XCTAssertTrue(app.switches["settings.spokenFeedback"].exists)
        app.buttons["sheet.done"].tap()
        XCTAssertTrue(app.navigationBars["NaviNote"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testScanWithoutACameraOffersTryAgain() {
        launch()
        tapWhenReady(app.buttons["home.readCurrency"])
        XCTAssertTrue(app.navigationBars["Read Currency"].waitForExistence(timeout: 5))
        tapWhenReady(app.buttons["scan.start"])
        // The simulator has no camera: NaviNote says so and offers a retry,
        // without ever asking for camera permission.
        XCTAssertTrue(app.navigationBars["Camera Unavailable"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.alerts.firstMatch.exists, "No permission prompt without a camera")
        // Device finding (Phase 13): this screen used to say "not available
        // in this build yet". It now says nothing was lost.
        XCTAssertFalse(app.staticTexts["Not available in this build yet"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Nothing was lost'")).firstMatch.exists)
        tapWhenReady(app.buttons["workflow.retry"])
        XCTAssertTrue(app.navigationBars["Read Currency"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["scan.start"].exists)
    }
}
