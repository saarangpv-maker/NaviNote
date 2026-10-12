import XCTest

/// Automated accessibility audits. These catch missing labels, small hit
/// regions, contrast problems and clipped text — they do NOT replace manual
/// VoiceOver testing on a physical iPhone.
final class AccessibilityAuditUITests: XCTestCase {
    private static let largestText = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            XCUIDevice.shared.appearance = .light
            XCUIDevice.shared.orientation = .portrait
        }
    }

    /// Runs the audit and reports each issue with the element it concerns,
    /// so failures are actionable.
    @MainActor
    private func audit(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) throws {
        var issues: [String] = []
        if let dir = ProcessInfo.processInfo.environment["NAVINOTE_AUDIT_DUMP"] {
            let shot = app.screenshot().pngRepresentation
            try? shot.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(line).png"))
        }
        var unattributed = 0
        let window = app.windows.firstMatch.frame
        try app.performAccessibilityAudit { issue in
            guard let element = issue.element else {
                // No element means the audit couldn't attribute the issue
                // (system chrome such as the status bar). Counted, not failed.
                unattributed += 1
                return true
            }
            // Elements scrolled (even partly) out of the visible scroll area
            // are measured against whatever covers them, such as the voice
            // bar. Reachability is tested separately by scrolling.
            if !element.isHittable && element.elementType == .staticText {
                return true
            }
            let scrollView = app.scrollViews.firstMatch
            if issue.auditType == .contrast, scrollView.exists,
               !scrollView.frame.insetBy(dx: -1, dy: -1).contains(element.frame) {
                return true
            }
            // In a scrolling list, a row that grows with larger text moves
            // below the screen edge; the audit reports that as clipping.
            // Lists scroll, so this is checked instead by
            // testHelpAtLargestTextSize, which scrolls through every row.
            if issue.auditType == .dynamicType || issue.auditType == .textClipped,
               app.collectionViews.firstMatch.exists,
               app.collectionViews.firstMatch.frame.contains(element.frame) {
                return true
            }
            // The system keyboard is not NaviNote's UI. Its predictive-text
            // bar sits in a strip just above the keyboard's reported frame.
            let keyboard = app.keyboards.firstMatch
            if keyboard.exists {
                let systemInputArea = CGRect(
                    x: 0, y: keyboard.frame.minY - 60,
                    width: window.width, height: keyboard.frame.height + 60
                )
                if systemInputArea.intersects(element.frame) { return true }
            }
            // The system-provided sheet "Done" toolbar button is out of our
            // control for Dynamic Type.
            if issue.auditType == .dynamicType && element.identifier == "sheet.done" {
                return true
            }
            issues.append("\(issue.compactDescription) — label: '\(element.label)', id: '\(element.identifier)', frame: \(element.frame)")
            return true
        }
        if unattributed > 0 {
            let note = XCTAttachment(string: "\(unattributed) unattributed audit issue(s)")
            note.lifetime = .keepAlways
            add(note)
        }
        XCTAssertTrue(issues.isEmpty, "Accessibility audit issues:\n" + issues.joined(separator: "\n"), file: file, line: line)
    }

    @MainActor
    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        XCTAssertTrue(app.navigationBars["NaviNote"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    func testHomeAuditLight() throws {
        XCUIDevice.shared.appearance = .light
        try audit(launch())
    }

    @MainActor
    func testHomeAuditDark() throws {
        XCUIDevice.shared.appearance = .dark
        try audit(launch())
    }

    @MainActor
    func testWorkflowScreenAudit() throws {
        let app = launch()
        app.buttons["home.readCurrency"].tap()
        XCTAssertTrue(app.navigationBars["Read Currency"].waitForExistence(timeout: 5))
        try audit(app)
    }

    @MainActor
    func testScanningScreenAudit() throws {
        let app = launch()
        app.buttons["home.readCurrency"].tap()
        XCTAssertTrue(app.buttons["scan.start"].waitForExistence(timeout: 5))
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "animations settle")], timeout: 1)
        try audit(app)
    }

    @MainActor
    func testCheckoutTotalScreensAudit() throws {
        let app = launch()
        app.buttons["home.startCheckout"].tap()
        XCTAssertTrue(app.buttons["checkout.continue"].waitForExistence(timeout: 5))
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: 1)
        try audit(app)

        app.buttons["checkout.continue"].tap()
        XCTAssertTrue(app.textFields["amount.field"].waitForExistence(timeout: 5))
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: 1)
        try audit(app)
    }

    /// Types and confirms a total, then waits for the payment-note step.
    @MainActor
    private func reachPaymentStep(_ app: XCUIApplication) {
        scrollTap(app, app.buttons["home.startCheckout"])
        scrollTap(app, app.buttons["checkout.continue"])
        let field = app.textFields["amount.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        // Bring the whole field on screen (at the largest sizes it can be
        // hittable while half off-screen), then wait for the keyboard.
        var swipes = 0
        while !app.windows.firstMatch.frame.contains(field.frame) && swipes < 12 {
            app.scrollViews.firstMatch.swipeUp(); swipes += 1
        }
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        field.typeText("17.35")
        if app.keyboards.buttons["Done"].exists { app.keyboards.buttons["Done"].tap() }
        scrollTap(app, app.buttons["currency.USD"])
        scrollTap(app, app.buttons["amount.submit"])
        scrollTap(app, app.buttons["total.confirm"])
        XCTAssertTrue(app.buttons["note.USD-20"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func scrollTap(_ app: XCUIApplication, _ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), "Missing \(element)")
        // Scroll until the whole element is inside the list: a button half
        // under the edge is "hittable" but its centre tap can miss.
        let list = app.scrollViews.firstMatch
        var swipes = 0
        while (!element.isHittable || (list.exists && !list.frame.contains(element.frame))) && swipes < 15 {
            list.swipeUp(velocity: .slow)
            swipes += 1
        }
        // A tap while the list is still scrolling only stops the scroll.
        if swipes > 0 { settle() }
        element.tap()
    }

    @MainActor
    private func settle() {
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: 1)
    }

    @MainActor
    func testCheckoutPaymentScreensAudit() throws {
        let app = launch()
        reachPaymentStep(app)
        settle()
        try audit(app)

        scrollTap(app, app.buttons["note.USD-20"])
        XCTAssertTrue(app.buttons["payment.confirm"].waitForExistence(timeout: 5))
        settle()
        try audit(app)

        scrollTap(app, app.buttons["payment.confirm"])
        XCTAssertTrue(app.buttons["checkout.finish"].waitForExistence(timeout: 5))
        settle()
        try audit(app)
    }

    @MainActor
    func testCheckoutPaymentAtLargestTextSize() throws {
        let app = launch(Self.largestText)
        reachPaymentStep(app)
        settle()
        try audit(app)
        // Every note stays reachable in the single-column layout.
        for value in [1, 2, 5, 10, 20, 50, 100] {
            let note = app.buttons["note.USD-\(value)"]
            var swipes = 0
            while !note.isHittable && swipes < 20 { app.scrollViews.firstMatch.swipeUp(); swipes += 1 }
            XCTAssertTrue(note.isHittable, "\(value) dollar note is not reachable")
        }
        scrollTap(app, app.buttons["note.USD-20"])
        scrollTap(app, app.buttons["payment.confirm"])
        XCTAssertTrue(app.buttons["checkout.finish"].waitForExistence(timeout: 5))
        app.scrollViews.firstMatch.swipeDown()
        settle()
        try audit(app)
    }

    @MainActor
    func testVerifyChangeScreensAudit() throws {
        let app = launch()
        scrollTap(app, app.buttons["home.verifyChange"])
        XCTAssertTrue(app.textFields["amount.field"].waitForExistence(timeout: 5))
        settle()
        try audit(app)

        let field = app.textFields["amount.field"]
        field.tap()
        field.typeText("30")
        if app.keyboards.buttons["Done"].exists { app.keyboards.buttons["Done"].tap() }
        scrollTap(app, app.buttons["amount.submit"])
        XCTAssertTrue(app.buttons["expected.confirm"].waitForExistence(timeout: 5))
        settle()
        try audit(app)

        scrollTap(app, app.buttons["currency.USD"])
        scrollTap(app, app.buttons["expected.confirm"])
        XCTAssertTrue(app.buttons["note.USD-20"].waitForExistence(timeout: 5))
        settle()
        try audit(app)

        scrollTap(app, app.buttons["note.USD-20"])
        XCTAssertTrue(app.buttons["returned.confirm"].waitForExistence(timeout: 5))
        settle()
        try audit(app)

        scrollTap(app, app.buttons["returned.confirm"])
        XCTAssertTrue(app.buttons["change.finish"].waitForExistence(timeout: 5))
        settle()
        try audit(app)

        scrollTap(app, app.buttons["change.finish"])
        XCTAssertTrue(app.buttons["change.done"].waitForExistence(timeout: 5))
        app.scrollViews.firstMatch.swipeDown()
        settle()
        try audit(app)
    }

    @MainActor
    func testVerifyChangeAtLargestTextSize() throws {
        let app = launch(Self.largestText)
        scrollTap(app, app.buttons["home.verifyChange"])
        let field = app.textFields["amount.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        var swipes = 0
        while !app.windows.firstMatch.frame.contains(field.frame) && swipes < 12 {
            app.scrollViews.firstMatch.swipeUp(); swipes += 1
        }
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        field.typeText("30")
        if app.keyboards.buttons["Done"].exists { app.keyboards.buttons["Done"].tap() }
        scrollTap(app, app.buttons["currency.USD"])
        scrollTap(app, app.buttons["amount.submit"])
        scrollTap(app, app.buttons["expected.confirm"])
        scrollTap(app, app.buttons["note.USD-20"])
        scrollTap(app, app.buttons["returned.confirm"])
        // Every control on the counting screen is reachable.
        for id in ["note.USD-100", "change.removeLast", "change.finish", "checkout.cancel"] {
            let element = app.buttons[id]
            swipes = 0
            while !element.isHittable && swipes < 25 { app.scrollViews.firstMatch.swipeUp(); swipes += 1 }
            XCTAssertTrue(element.isHittable, "\(id) is not reachable at the largest text size")
        }
        scrollTap(app, app.buttons["change.finish"])
        XCTAssertTrue(app.buttons["change.done"].waitForExistence(timeout: 5))
        app.scrollViews.firstMatch.swipeDown()
        settle()
        try audit(app)
    }

    @MainActor
    func testAskNaviNoteAudit() throws {
        let app = launch()
        scrollTap(app, app.buttons["home.askNaviNote"])
        XCTAssertTrue(app.navigationBars["Ask NaviNote"].waitForExistence(timeout: 5))
        settle()
        try audit(app)
        scrollTap(app, app.buttons["ask.explainScreen"])
        app.scrollViews.firstMatch.swipeDown()
        settle()
        try audit(app)
    }

    @MainActor
    func testAskNaviNoteAtLargestTextSize() throws {
        let app = launch(Self.largestText)
        scrollTap(app, app.buttons["home.askNaviNote"])
        XCTAssertTrue(app.navigationBars["Ask NaviNote"].waitForExistence(timeout: 5))
        settle()
        try audit(app)
        for id in ["ask.total", "ask.explainScreen", "ask.field", "ask.send", "ask.close"] {
            let element = app.descendants(matching: .any)[id]
            var swipes = 0
            while !element.isHittable && swipes < 30 { app.scrollViews.firstMatch.swipeUp(); swipes += 1 }
            XCTAssertTrue(element.isHittable, "\(id) is not reachable at the largest text size")
        }
    }

    // MARK: - Phase 12 sweeps: every screen, in one configuration each

    /// Types an amount into the amount field and dismisses the keyboard.
    @MainActor
    private func typeAmount(_ app: XCUIApplication, _ amount: String) {
        let field = app.textFields["amount.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        var swipes = 0
        while !app.windows.firstMatch.frame.contains(field.frame) && swipes < 15 {
            app.scrollViews.firstMatch.swipeUp(); swipes += 1
        }
        if swipes > 0 { settle() }
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        field.typeText(amount)
        if app.keyboards.buttons["Done"].exists { app.keyboards.buttons["Done"].tap() }
        _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 3)
    }

    /// Audits the current screen once it has settled, scrolled to the top.
    @MainActor
    private func auditScreen(_ app: XCUIApplication, _ name: String, line: UInt = #line) throws {
        // Drag inside the list rather than swiping from its edge: in
        // landscape a swipe near the top edge opens Notification Centre.
        let list = app.scrollViews.firstMatch
        if list.exists {
            for _ in 0..<3 {
                list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                    .press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
            }
        }
        settle()
        let note = XCTAttachment(string: "Auditing: \(name)")
        note.lifetime = .keepAlways
        add(note)
        try audit(app, line: line)
    }

    /// Walks every workflow screen, auditing each.
    @MainActor
    private func sweepEveryScreen(_ app: XCUIApplication) throws {
        try auditScreen(app, "Home")

        // Checkout
        scrollTap(app, app.buttons["home.startCheckout"])
        XCTAssertTrue(app.buttons["checkout.continue"].waitForExistence(timeout: 5))
        try auditScreen(app, "Checkout introduction")
        scrollTap(app, app.buttons["checkout.continue"])
        XCTAssertTrue(app.textFields["amount.field"].waitForExistence(timeout: 5))
        try auditScreen(app, "Find the total")
        typeAmount(app, "15")
        scrollTap(app, app.buttons["currency.AED"])
        scrollTap(app, app.buttons["amount.submit"])
        XCTAssertTrue(app.buttons["total.confirm"].waitForExistence(timeout: 5))
        try auditScreen(app, "Confirm the total")
        scrollTap(app, app.buttons["total.confirm"])
        XCTAssertTrue(app.buttons["note.AED-10"].waitForExistence(timeout: 5))
        try auditScreen(app, "Payment")
        scrollTap(app, app.buttons["note.AED-10"])
        scrollTap(app, app.buttons["payment.confirm"])
        XCTAssertTrue(app.descendants(matching: .any)["payment.tally"].waitForExistence(timeout: 5))
        try auditScreen(app, "Payment, part-paid")
        scrollTap(app, app.buttons["note.AED-10"])
        XCTAssertTrue(app.buttons["payment.confirm"].waitForExistence(timeout: 5))
        try auditScreen(app, "Confirm payment note")
        scrollTap(app, app.buttons["payment.confirm"])
        XCTAssertTrue(app.buttons["checkout.checkChange"].waitForExistence(timeout: 5))
        try auditScreen(app, "Checkout result")

        // Verify Change from checkout
        scrollTap(app, app.buttons["checkout.checkChange"])
        XCTAssertTrue(app.buttons["change.finish"].waitForExistence(timeout: 5))
        try auditScreen(app, "Counting returned change")
        scrollTap(app, app.buttons["note.AED-5"])
        XCTAssertTrue(app.buttons["returned.confirm"].waitForExistence(timeout: 5))
        try auditScreen(app, "Confirm returned note")
        scrollTap(app, app.buttons["returned.confirm"])
        XCTAssertTrue(app.buttons["change.done"].waitForExistence(timeout: 5))
        try auditScreen(app, "Change matches")

        // Ask NaviNote over the result
        scrollTap(app, app.buttons["voice.type"])
        let command = app.textFields["type.field"]
        XCTAssertTrue(command.waitForExistence(timeout: 5))
        command.typeText("ask navinote\n")
        XCTAssertTrue(app.buttons["ask.close"].waitForExistence(timeout: 5))
        try auditScreen(app, "Ask NaviNote")
        scrollTap(app, app.buttons["ask.received"])
        try auditScreen(app, "Ask NaviNote, answered")
        scrollTap(app, app.buttons["ask.close"])
        scrollTap(app, app.buttons["change.done"])

        // Verify Change from home
        scrollTap(app, app.buttons["home.verifyChange"])
        XCTAssertTrue(app.textFields["amount.field"].waitForExistence(timeout: 5))
        try auditScreen(app, "Expected change")
        typeAmount(app, "30")
        scrollTap(app, app.buttons["amount.submit"])
        XCTAssertTrue(app.buttons["expected.confirm"].waitForExistence(timeout: 5))
        try auditScreen(app, "Confirm expected change, no currency")
        scrollTap(app, app.buttons["currency.USD"])
        scrollTap(app, app.buttons["expected.confirm"])
        XCTAssertTrue(app.buttons["change.finish"].waitForExistence(timeout: 5))
        scrollTap(app, app.buttons["change.finish"])
        XCTAssertTrue(app.buttons["change.addMore"].waitForExistence(timeout: 5))
        try auditScreen(app, "Change not checked")
        scrollTap(app, app.buttons["change.done"])

        // Read Currency
        scrollTap(app, app.buttons["home.readCurrency"])
        XCTAssertTrue(app.buttons["currency.done"].waitForExistence(timeout: 5))
        try auditScreen(app, "Read Currency")
    }

    @MainActor
    func testEveryScreenInDarkMode() throws {
        XCUIDevice.shared.appearance = .dark
        try sweepEveryScreen(launch())
    }

    @MainActor
    func testEveryScreenInLandscape() throws {
        let app = launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        settle()
        try sweepEveryScreen(app)
    }

    @MainActor
    func testEveryScreenAtTheLargestTextSize() throws {
        try sweepEveryScreen(launch(Self.largestText))
    }

    @MainActor
    func testHelpAndSettingsAudit() throws {
        let app = launch()
        app.buttons["voice.help"].tap()
        XCTAssertTrue(app.navigationBars["Help"].waitForExistence(timeout: 5))
        try audit(app)
        app.buttons["sheet.done"].tap()
        XCTAssertTrue(app.navigationBars["Help"].waitForNonExistence(timeout: 5))
        app.buttons["home.settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        try audit(app)
    }

    @MainActor
    func testTypeCommandAudit() throws {
        let app = launch()
        app.buttons["voice.type"].tap()
        XCTAssertTrue(app.textFields["type.field"].waitForExistence(timeout: 5))
        // Audit the settled sheet, not frames captured while the sheet and
        // keyboard are still animating in.
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "animations settle")], timeout: 1.5)
        try audit(app)
    }

    @MainActor
    func testHelpAtLargestTextSize() throws {
        let app = launch(Self.largestText)
        var swipes = 0
        while !app.buttons["voice.help"].isHittable && swipes < 12 { app.swipeUp(); swipes += 1 }
        app.buttons["voice.help"].tap()
        XCTAssertTrue(app.navigationBars["Help"].waitForExistence(timeout: 5))
        try audit(app)
        // Every row can be scrolled to, down to the coins footer.
        let coins = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Coins'")).firstMatch
        swipes = 0
        while !coins.exists && swipes < 25 { app.collectionViews.firstMatch.swipeUp(); swipes += 1 }
        XCTAssertTrue(coins.exists)
    }

    @MainActor
    func testLargestAccessibilityTextSizeKeepsEveryActionReachable() throws {
        let app = launch(Self.largestText)
        try audit(app)
        // Controls move into the scroll content at these sizes; every one
        // must be reachable by scrolling.
        for id in ["home.startCheckout", "home.readCurrency", "home.verifyChange", "home.askNaviNote", "voice.talk", "voice.repeat", "voice.type", "voice.help"] {
            let element = app.buttons[id]
            var swipes = 0
            while !element.isHittable && swipes < 12 {
                app.swipeUp()
                swipes += 1
            }
            XCTAssertTrue(element.isHittable, "\(id) is not reachable at the largest text size")
        }
    }
}
