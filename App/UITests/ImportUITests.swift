import XCTest
import CoreImage

/// Import review and upload of two new images into a new album (cleaned up through the UI afterwards).
@MainActor
final class ImportUITests: XCTestCase {
    func testImportReviewAndUpload() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "darkroom-uitest-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let context = CIContext()
        for name in ["uitest-import-1.jpg", "uitest-import-2.jpg"] {
            let c = CIColor(red: .random(in: 0...1), green: .random(in: 0...1), blue: .random(in: 0...1))
            try context.writeJPEGRepresentation(of: CIImage(color: c).cropped(to: CGRect(x: 0, y: 0, width: 120, height: 90)),
                                                to: folder.appending(path: name), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        let app = XCUIApplication()
        let base = UITestSupport.launch(extraEnvironment: ["DARKROOM_TEST_IMPORT": folder.path])
        _ = app
        try UITestSupport.signIn(base)
        let summary = base.staticTexts["import-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 30), "Import review opens")
        let ready = NSPredicate(format: "value BEGINSWITH '2 of 2 selected'")
        expectation(for: ready, evaluatedWith: summary)
        waitForExpectations(timeout: 30)
        sleep(2)
        UITestSupport.screenshot("m7-1-import-review", in: self)
        base.buttons["import-start"].click()
        let status = base.staticTexts["status-message"]
        expectation(for: NSPredicate(format: "value CONTAINS 'Import finished'"), evaluatedWith: status)
        waitForExpectations(timeout: 60)
        // Recently Added shows them; trash them again (test fixtures).
        UITestSupport.go(base, "Recently Added")
        let cells = base.images.matching(NSPredicate(format: "identifier BEGINSWITH 'asset-'"))
        XCTAssertTrue(cells.firstMatch.waitForExistence(timeout: 20))
        cells.element(boundBy: 0).click()
        XCUIElement.perform(withKeyModifiers: .shift) { cells.element(boundBy: 1).click() }
        base.typeKey(.delete, modifierFlags: [])
        expectation(for: NSPredicate(format: "value CONTAINS 'Move to Trash'"), evaluatedWith: status)
        waitForExpectations(timeout: 30)
        try? FileManager.default.removeItem(at: folder)
    }
}
