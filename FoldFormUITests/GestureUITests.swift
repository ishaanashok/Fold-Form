import XCTest

/// Drives real touches at the running app and measures how the blue block moves on screen.
final class GestureUITests: XCTestCase {

    /// Bounding box + centroid of the "blue block" pixels in a screenshot.
    private struct BlockShape {
        var minX = Double.infinity, maxX = -Double.infinity
        var minY = Double.infinity, maxY = -Double.infinity
        var sumX = 0.0, sumY = 0.0, count = 0.0
        var width: Double { maxX - minX }
        var height: Double { maxY - minY }
        var centroidX: Double { count > 0 ? sumX / count : .nan }
        var centroidY: Double { count > 0 ? sumY / count : .nan }
    }

    private func measure(_ image: UIImage, name: String) -> BlockShape {
        if let data = image.pngData() {
            try? data.write(to: URL(fileURLWithPath: "/tmp/uitest_\(name).png"))
        }
        guard let cg = image.cgImage else { return BlockShape() }
        let w = cg.width, h = cg.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var shape = BlockShape()
        for y in stride(from: 0, to: h, by: 3) {
            for x in stride(from: 0, to: w, by: 3) {
                let i = (y * w + x) * 4
                let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
                if b > 120 && b > r + 60 && b > g + 20 {
                    shape.minX = min(shape.minX, Double(x)); shape.maxX = max(shape.maxX, Double(x))
                    shape.minY = min(shape.minY, Double(y)); shape.maxY = max(shape.maxY, Double(y))
                    shape.sumX += Double(x); shape.sumY += Double(y); shape.count += 1
                }
            }
        }
        return shape
    }

    /// This device has several displays and the default screenshot can pick a blank one; measure
    /// every screen and keep the one that actually shows the block.
    private func shot(_ name: String) -> BlockShape {
        var best = BlockShape()
        for (i, screen) in XCUIScreen.screens.enumerated() {
            let shape = measure(screen.screenshot().image, name: "\(name)_screen\(i)")
            if shape.count > best.count { best = shape }
        }
        return best
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-FoldFormDebugBendDegrees", "0"]
        app.launch()
        Thread.sleep(forTimeInterval: 3)
        return app
    }

    private func viewport(_ app: XCUIApplication) -> XCUIElement {
        let v = app.otherElements["viewport"]
        XCTAssertTrue(v.waitForExistence(timeout: 5), "the 3D viewport should be addressable")
        return v
    }

    /// The reported complaint: one finger rotates.
    func testOneFingerDragRotatesTheBlock() {
        let app = launch()
        let view = viewport(app)
        let before = shot("rotate_before")
        XCTAssertGreaterThan(before.count, 100, "block should be visible before dragging")

        view.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: view.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        Thread.sleep(forTimeInterval: 1)

        let after = shot("rotate_after")
        print("UITEST rotate before w=\(before.width) cx=\(before.centroidX) | after w=\(after.width) cx=\(after.centroidX)")
        XCTAssertGreaterThan(abs(after.width - before.width), 20, "one-finger drag should rotate the block")
    }

    /// Two real touches (pinch) reach the recognizers and zoom.
    func testPinchZoomsTheBlock() {
        let app = launch()
        let view = viewport(app)
        let before = shot("zoom_before")
        view.pinch(withScale: 1.8, velocity: 1)
        Thread.sleep(forTimeInterval: 1)
        let after = shot("zoom_after")
        print("UITEST zoom before w=\(before.width) | after w=\(after.width)")
        XCTAssertGreaterThan(after.width, before.width * 1.2, "pinch out should zoom in")
    }

    /// Control: a plain tap on a SwiftUI button, no gesture code of ours involved.
    func testTapOpensTheToolsSheet() {
        let app = launch()
        let waffle = app.buttons["toolsButton"]
        XCTAssertTrue(waffle.waitForExistence(timeout: 5), "waffle button should exist")
        waffle.tap()
        XCTAssertTrue(app.staticTexts["Part Studio 1"].waitForExistence(timeout: 5), "tools sheet should open")
    }

    /// The reported complaint: moving the object around (not rotating it). In Move mode a plain
    /// drag pans. The screenshot API returns the display in a different orientation than the app,
    /// so measure total displacement rather than one axis. A pan slides the same silhouette across
    /// the screen (large displacement, unchanged pixel area).
    func testMoveModeDragPansTheBlockAcrossTheScreen() {
        let app = launch()
        let view = viewport(app)
        let toggle = app.buttons["moveToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Move toggle should exist")
        toggle.tap()

        let before = shot("pan_before")
        XCTAssertGreaterThan(before.count, 100)
        view.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: view.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)))
        Thread.sleep(forTimeInterval: 1)
        let after = shot("pan_after")

        let moved = hypot(after.centroidX - before.centroidX, after.centroidY - before.centroidY)
        print("UITEST pan displacement=\(moved) px (pixels before=\(before.count) after=\(after.count))")
        XCTAssertGreaterThan(moved, 150, "a Move-mode drag should slide the block across the screen")
        XCTAssertLessThan(abs(after.count - before.count), before.count * 0.06,
                          "panning moves the same silhouette; it must not turn the block")
    }

    /// Without Move mode the same drag rotates, so the block's shape changes rather than just moving.
    func testPlainDragStillRotates() {
        let app = launch()
        let view = viewport(app)
        let before = shot("plain_before")
        view.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: view.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        Thread.sleep(forTimeInterval: 1)
        let after = shot("plain_after")
        XCTAssertGreaterThan(abs(after.width - before.width), 20, "the block's shape should change (rotation)")
    }

    // MARK: Hold

    private func launch(bendDegrees: Int) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-FoldFormDebugBendDegrees", "\(bendDegrees)",
                               "-FoldFormDebugYawDegrees", "0", "-FoldFormDebugPitchDegrees", "20"]
        app.launch()
        Thread.sleep(forTimeInterval: 3)
        return app
    }

    /// Drives the hinge input by writing the bend to the app's debug file (see HingeInputManager),
    /// the same path a real hinge reading takes.
    private func setBend(_ degrees: Double) {
        try? "\(degrees)".write(toFile: "/tmp/foldform_debug_bend.txt", atomically: true, encoding: .utf8)
        Thread.sleep(forTimeInterval: 1.5)
    }

    /// The reported request: hold a fold, open the phone back up without the shape unfolding, and
    /// have the next fold build on it.
    func testHoldKeepsTheFoldThroughOpeningAndStacksTheNextOne() {
        try? FileManager.default.removeItem(atPath: "/tmp/foldform_debug_bend.txt")
        defer { try? FileManager.default.removeItem(atPath: "/tmp/foldform_debug_bend.txt") }

        // Reference: the flat block from this same view.
        let flatApp = launch(bendDegrees: 0)
        let flat = shot("hold_flat")
        XCTAssertGreaterThan(flat.count, 100)
        flatApp.terminate()

        let app = launch(bendDegrees: 110)
        let live = shot("hold_live")
        XCTAssertGreaterThan(abs(live.count - flat.count), flat.count * 0.04, "a 110° fold should look different from flat")

        // Hold it.
        let hold = app.buttons["holdButton"]
        XCTAssertTrue(hold.waitForExistence(timeout: 5))
        hold.tap()
        XCTAssertTrue(app.staticTexts["HELD"].waitForExistence(timeout: 5), "the HUD should say HELD")
        let held = shot("hold_held")
        XCTAssertLessThan(abs(held.count - live.count), live.count * 0.03, "holding must not change the shape on screen")
        XCTAssertTrue(app.buttons["undoFoldButton"].exists, "a held fold can be undone")

        // Open the phone all the way flat: the held shape must stay folded.
        setBend(0)
        let opened = shot("hold_opened")
        print("UITEST hold flat=\(flat.count) live=\(live.count) held=\(held.count) openedFlat=\(opened.count)")
        XCTAssertLessThan(abs(opened.count - held.count), held.count * 0.03, "opening flat must not unfold a held fold")
        XCTAssertGreaterThan(abs(opened.count - flat.count), flat.count * 0.04, "it must not have gone back to the flat block")
        XCTAssertFalse(app.staticTexts["HELD"].exists, "back at flat, the hold has let go")

        // Fold again: it builds on the held shape instead of starting over.
        setBend(100)
        let second = shot("hold_second")
        print("UITEST hold second=\(second.count)")
        XCTAssertGreaterThan(abs(second.count - opened.count), opened.count * 0.02, "the next fold should visibly change the held shape")

        // Reset clears every held fold: the flat block is back, and the buttons go away.
        setBend(0)
        let reset = app.buttons["resetFoldsButton"]
        XCTAssertTrue(reset.waitForExistence(timeout: 5))
        reset.tap()
        Thread.sleep(forTimeInterval: 1.5)
        let restored = shot("hold_reset")
        XCTAssertLessThan(abs(restored.count - flat.count), flat.count * 0.02, "reset returns the original block")
        XCTAssertFalse(app.buttons["resetFoldsButton"].exists)
    }

    /// Tapping the view cube snaps the camera onto a face.
    func testViewCubeTapSnapsToAFace() {
        let app = launch()
        let cube = app.otherElements["viewCube"]
        XCTAssertTrue(cube.waitForExistence(timeout: 5), "the view cube should be in the corner")
        let before = shot("cube_before")
        cube.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 1.5)
        let after = shot("cube_after")
        print("UITEST cube before w=\(before.width) h=\(before.height) | after w=\(after.width) h=\(after.height)")
        XCTAssertGreaterThan(abs(after.width - before.width) + abs(after.height - before.height), 20, "the view should have snapped")
    }
}
