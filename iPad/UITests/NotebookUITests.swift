import XCTest

final class NotebookUITests: XCTestCase {
    func testOfflineLectureWorkflow() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launch()
        let create = app.buttons["New notebook"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 45), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Ready offline"].firstMatch.exists)
        create.tap()
        let menu = app.buttons["Notebook menu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 15))
        menu.tap()
        app.buttons["Open sample exercise"].firstMatch.tap()
        let saved = app.buttons["Saved"].firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 15))
        let preview = app.buttons["Preview PDF"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        // The normal file import, notebook database, PDF worker and system export
        // should all work using the resources in the installed app.
        preview.tap()
        let share = app.buttons["Share or save PDF"].firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 45), app.debugDescription)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Gridnote-iPad-PDF"
        attachment.lifetime = .keepAlways
        add(attachment)
        share.tap()
        let save = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Save to Files")).firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 25), app.debugDescription)
        app.terminate()
        app.launch()
        let resume = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Continue notebook")).firstMatch
        XCTAssertTrue(resume.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(resume.label.contains("Series circuit"), resume.label)
        resume.tap()
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        let page = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        page.name = "Gridnote-iPad-Circuit"
        page.lifetime = .keepAlways
        add(page)
    }
}
