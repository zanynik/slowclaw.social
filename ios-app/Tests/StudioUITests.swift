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
}
