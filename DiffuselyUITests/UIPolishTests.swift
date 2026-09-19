import XCTest

final class UIPolishTests: XCTestCase {
    @MainActor
    func testShortMultilinePromptCanExpandAndAlbumCanCancel() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-review"]
        app.launch()
        XCTAssertTrue(app.buttons["Show more"].waitForExistence(timeout: 10))
        app.buttons["Show more"].tap()
        XCTAssertTrue(app.buttons["Show less"].exists)
        saveScreenshot("Shared controls", app)
        app.buttons["New Album"].tap()
        let field = app.textFields["Album name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Review album")
        saveScreenshot("New album", app)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Show less"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSettingsPresentation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-review"]
        app.launch()
        app.buttons["Settings"].tap()
        #if os(macOS)
        XCTAssertTrue(app.windows.count >= 2)
        #else
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        #endif
        saveScreenshot("Settings", app)
        #if os(iOS)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["New Album"].waitForExistence(timeout: 5))
        #endif
    }

    @MainActor
    private func saveScreenshot(_ name: String, _ app: XCUIApplication) {
        Thread.sleep(forTimeInterval: 0.4)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
