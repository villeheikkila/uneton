import XCTest

final class WatchScreenshots: XCTestCase {
    func testAwakeScreen() {
        let app = launch("awake")
        XCTAssertTrue(app.staticTexts["Awake"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Start sleep"].exists)
        attachScreenshot(of: app, named: "watch-awake")
    }

    func testSleepingScreen() {
        let app = launch("sleeping")
        XCTAssertTrue(app.buttons["Wake up"].waitForExistence(timeout: 10))
        attachScreenshot(of: app, named: "watch-sleeping")
    }

    func testTemperatureEntry() {
        let app = launch("temperature")
        let button = app.buttons["Log temperature"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
        XCTAssertTrue(app.staticTexts["Temperature"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["Temperature °C"].exists)
        attachScreenshot(of: app, named: "watch-temperature-entry")
    }

    private func launch(_ scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["UNETON_WATCH_SCREENSHOT_SCENARIO"] = scenario
        app.launch()
        return app
    }

    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
