import XCTest

@MainActor final class StudioUITests: XCTestCase {
    func testQuoteShareRemainsAboveTabsOnCompactScreen() {
        let app = XCUIApplication(); app.launchArguments = ["--studio-ui-test"]; app.launch()
        let share = app.buttons["studio.shareQuote"]
        XCTAssertTrue(share.waitForExistence(timeout: 20))
        let tabs = app.staticTexts["slowclaw.tabs"]
        XCTAssertTrue(tabs.exists); XCTAssertLessThanOrEqual(share.frame.maxY, tabs.frame.minY)
        XCTAssertTrue(share.isHittable)
        let evidence = XCTAttachment(screenshot: app.screenshot()); evidence.name = "quote-actions-above-tabs"; evidence.lifetime = .keepAlways; add(evidence)
        share.tap()
        XCTAssertEqual(app.state, .runningForeground)
    }
    func testPlayAndPauseRemainReachableWithoutScrolling() {
        let app = XCUIApplication(); app.launchArguments = ["--studio-ui-test", "--video"]; app.launch()
        let play = app.buttons["studio.playPause"]
        XCTAssertTrue(play.waitForExistence(timeout: 20)); XCTAssertTrue(play.isHittable)
        let tabs = app.staticTexts["slowclaw.tabs"]
        XCTAssertLessThanOrEqual(play.frame.maxY, tabs.frame.minY)
        XCTAssertTrue(app.buttons["studio.shareVideo"].isHittable)
        play.tap(); XCTAssertEqual(play.label, "Pause")
        play.tap(); XCTAssertEqual(play.label, "Play")
        let evidence = XCTAttachment(screenshot: app.screenshot()); evidence.name = "video-actions-above-tabs"; evidence.lifetime = .keepAlways; add(evidence)
    }
    func testEditedRangeReturnsToTheFeedCard() {
        let app = XCUIApplication(); app.launchArguments = ["--studio-ui-test", "--video", "--card"]; app.launch()
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 20))
        let originalDuration = app.staticTexts["studio.cardDuration"]
        XCTAssertTrue(originalDuration.waitForExistence(timeout: 20))
        let original = originalDuration.label
        app.buttons["Edit"].tap()
        let slider = app.sliders["studio.endWord"]
        XCTAssertTrue(slider.waitForExistence(timeout: 10))
        app.scrollViews.firstMatch.swipeUp()
        XCTAssertTrue(slider.isHittable)
        // Drag the visible thumb center. The iOS 26 normalized-position helper
        // starts at the track's far edge and can leave the SwiftUI value unchanged.
        let thumb = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
        let middle = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5))
        thumb.press(forDuration: 0.2, thenDragTo: middle)
        let evidence = XCTAttachment(screenshot: app.screenshot()); evidence.name = "edited-word-range"; evidence.lifetime = .keepAlways; add(evidence)
        let duration = app.staticTexts["studio.duration"].label
        XCTAssertNotEqual(duration, original)
        app.buttons["Done"].tap()
        let restored = app.staticTexts["studio.cardDuration"]
        XCTAssertTrue(restored.waitForExistence(timeout: 10))
        XCTAssertEqual(restored.label, duration)
    }

}
