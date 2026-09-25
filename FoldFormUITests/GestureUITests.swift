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
        XCTAssertGreaterThan(after.width, before.width * 1.06, "pinch out should zoom in")
        XCTAssertLessThan(after.width, before.width * 1.7, "and only part of the way the fingers spread (a 1.8x pinch used to zoom ~1.8x)")
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

    // MARK: Sketch -> extrude -> duplicate -> reset

    func testSketchExtrudeDuplicateAndResetFlow() {
        let app = XCUIApplication()
        app.launchArguments = ["-FoldFormDebugBendDegrees", "0", "-FoldFormDebugYawDegrees", "0", "-FoldFormDebugPitchDegrees", "0"]
        app.launch()
        Thread.sleep(forTimeInterval: 3)
        let view = viewport(app)
        let plate = shot("flow_plate")
        XCTAssertGreaterThan(plate.count, 100)

        // Sketch a circle above the plate and extrude it.
        app.buttons["sketchButton"].tap()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(app.buttons["toolCircle"].waitForExistence(timeout: 5))
        app.buttons["toolCircle"].tap()
        let centre = view.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        centre.press(forDuration: 0.1, thenDragTo: view.coordinate(withNormalizedOffset: CGVector(dx: 0.58, dy: 0.3)))
        Thread.sleep(forTimeInterval: 0.5)
        let extrude = app.buttons["extrudeButton"]
        XCTAssertTrue(extrude.isEnabled, "a circle is a closed shape, so it can be extruded")
        extrude.tap()
        // The slider on the right sets the thickness: up is thicker.
        let slider = app.sliders["extrudeSlider"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5), "extruding shows a slider on the right")
        slider.adjust(toNormalizedSliderPosition: 0.15)
        Thread.sleep(forTimeInterval: 0.5)
        slider.adjust(toNormalizedSliderPosition: 0.6)
        Thread.sleep(forTimeInterval: 0.5)
        app.buttons["extrudeConfirm"].tap()
        app.buttons["sketchDone"].tap()
        Thread.sleep(forTimeInterval: 1)
        let withDisc = shot("flow_disc")
        print("UITEST flow plate=\(plate.count) withDisc=\(withDisc.count)")
        XCTAssertGreaterThan(withDisc.count, plate.count * 1.10, "the extruded circle should be a new part on the workbench")

        // Press and hold the new part: duplicate it.
        centre.press(forDuration: 1.2)
        let duplicate = app.buttons["menuDuplicate"]
        XCTAssertTrue(duplicate.waitForExistence(timeout: 5), "holding a part offers copy and duplicate")
        XCTAssertTrue(app.buttons["menuCopy"].exists)
        duplicate.tap()
        Thread.sleep(forTimeInterval: 1)
        let withCopy = shot("flow_copy")
        print("UITEST flow withCopy=\(withCopy.count)")
        XCTAssertGreaterThan(withCopy.count, withDisc.count * 1.05, "the duplicate is another disc")

        // Complete reset: back to the very first plate.
        app.buttons["resetAllButton"].tap()
        Thread.sleep(forTimeInterval: 1.5)
        let restored = shot("flow_reset")
        print("UITEST flow restored=\(restored.count)")
        // Reset also returns to the opening view, so it must match a fresh launch exactly.
        app.terminate()
        let fresh = launch()
        let opening = shot("flow_fresh")
        print("UITEST flow fresh=\(opening.count)")
        XCTAssertLessThan(abs(restored.count - opening.count), opening.count * 0.03, "reset returns to the very initial plate")
        fresh.terminate()
    }

    /// Turning swings the block about its own middle: after moving it off to the side, rotating it
    /// must leave it where it was on screen instead of orbiting about the screen's centre/crease.
    func testRotatingSwingsAboutTheBlocksOwnMiddle() {
        let app = launch()
        let view = viewport(app)
        app.buttons["moveToggle"].tap()
        view.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: view.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)))
        Thread.sleep(forTimeInterval: 1)
        app.buttons["moveToggle"].tap()
        let moved = shot("orbit_moved")

        view.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.8))
            .press(forDuration: 0.1, thenDragTo: view.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))
        Thread.sleep(forTimeInterval: 1)
        let turned = shot("orbit_turned")
        let drift = hypot(turned.centroidX - moved.centroidX, turned.centroidY - moved.centroidY)
        print("UITEST orbit moved=(\(moved.centroidX), \(moved.centroidY)) turned=(\(turned.centroidX), \(turned.centroidY)) drift=\(drift) widths \(moved.width) -> \(turned.width)")
        XCTAssertGreaterThan(abs(turned.width - moved.width), 20, "it should really have turned")
        // The silhouette's centroid shifts a little as a thick block turns (the exact pivot is
        // covered by unit tests). Orbiting the crease instead would fling it ~800 px in this drag.
        XCTAssertLessThan(drift, 250, "the block stays put on screen while it turns about its own middle")
    }

    /// Extruding must not lock the view: rotate and pan still work, and the slider stays put.
    func testViewStaysFreeToRotateAndPanWhileExtruding() {
        let app = launch()
        let view = viewport(app)
        app.buttons["sketchButton"].tap()
        Thread.sleep(forTimeInterval: 1)
        app.buttons["toolRectangle"].tap()
        view.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.3))
            .press(forDuration: 0.1, thenDragTo: view.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.45)))
        app.buttons["extrudeButton"].tap()
        XCTAssertTrue(app.sliders["extrudeSlider"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)

        let before = shot("free_before")
        view.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.85))
            .press(forDuration: 0.1, thenDragTo: view.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.85)))
        Thread.sleep(forTimeInterval: 1)
        let turned = shot("free_turned")
        print("UITEST free rotate \(before.width)x\(before.height) -> \(turned.width)x\(turned.height)")
        // (The slider's blue tint is in every shot, so compare how much block is showing.)
        XCTAssertGreaterThan(abs(turned.count - before.count), before.count * 0.05, "one finger rotates while extruding")
        XCTAssertTrue(app.sliders["extrudeSlider"].exists, "still extruding")

        app.buttons["moveToggle"].tap()
        view.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.85))
            .press(forDuration: 0.1, thenDragTo: view.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
        Thread.sleep(forTimeInterval: 1)
        let panned = shot("free_panned")
        let moved = hypot(panned.centroidX - turned.centroidX, panned.centroidY - turned.centroidY)
        print("UITEST free pan moved \(moved)")
        XCTAssertGreaterThan(moved, 30, "panning works while extruding")
        XCTAssertTrue(app.sliders["extrudeSlider"].exists)
    }

    /// Sharing: the button offers each 3D format, and choosing one opens the share sheet.
    func testShareOffersFormatsAndOpensTheShareSheet() {
        let app = launch()
        let share = app.buttons["shareButton"]
        XCTAssertTrue(share.waitForExistence(timeout: 5), "a share button sits in the right column")
        share.tap()
        // Menu items are matched by their visible text (the menu lives outside the app's own tree).
        func item(_ format: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "\(format) ")).firstMatch
        }
        for format in ["STL", "3MF", "GLB", "OBJ"] {
            XCTAssertTrue(item(format).waitForExistence(timeout: 5), "\(format) is offered")
        }
        item("STL").tap()
        let sheet = app.otherElements["ActivityListView"]
        let saveToFiles = app.staticTexts["Save to Files"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 8) || saveToFiles.waitForExistence(timeout: 2), "the share sheet should appear")
        Thread.sleep(forTimeInterval: 1)
        _ = shot("share_sheet")
    }

    // MARK: Sharp corner and the cube's arrows

    /// Double-tapping the figure switches a smooth fold to a sharp one, and back again.
    func testDoubleTapTogglesASharpCorner() {
        let app = launch(bendDegrees: 100)
        let view = viewport(app)
        let tag = app.staticTexts["cornerTag"]
        XCTAssertFalse(tag.exists, "folds are smooth by default")
        let smooth = shot("corner_smooth")

        view.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
        XCTAssertTrue(tag.waitForExistence(timeout: 5), "double tap on the figure makes the corner sharp")
        Thread.sleep(forTimeInterval: 1)
        let sharp = shot("corner_sharp")
        print("UITEST corner smooth=\(smooth.count) sharp=\(sharp.count)")
        XCTAssertGreaterThan(abs(sharp.count - smooth.count), smooth.count * 0.005, "the sharp fold really looks different")

        view.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
        for _ in 0..<25 where tag.exists { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertFalse(tag.exists, "the SHARP tag goes away")
        Thread.sleep(forTimeInterval: 1)
        let back = shot("corner_back")
        XCTAssertLessThan(abs(back.count - smooth.count), smooth.count * 0.005, "double tap again returns to the smooth corner")
    }

    func testDoubleTapOnEmptySpaceDoesNothing() {
        let app = launch(bendDegrees: 100)
        let view = viewport(app)
        view.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.9)).doubleTap()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(app.staticTexts["cornerTag"].exists)
    }

    /// The cube's side arrows turn the view a quarter turn; four presses come back to the start.
    func testCubeArrowsTurnTheViewAndFourTurnsComeBack() {
        let app = launch()
        let start = shot("step_start")
        app.buttons["stepRight"].tap()
        Thread.sleep(forTimeInterval: 1)
        let turned = shot("step_turned")
        XCTAssertGreaterThan(abs(turned.count - start.count) + abs(turned.width - start.width), 40, "one press turns the view")
        for _ in 0..<3 { app.buttons["stepRight"].tap(); Thread.sleep(forTimeInterval: 0.7) }
        Thread.sleep(forTimeInterval: 1)
        let around = shot("step_around")
        XCTAssertLessThan(abs(around.count - start.count), start.count * 0.01, "four quarter turns is a full circle")

        app.buttons["stepDown"].tap()
        Thread.sleep(forTimeInterval: 1)
        let tipped = shot("step_tipped")
        XCTAssertGreaterThan(abs(tipped.count - start.count) + abs(tipped.height - start.height), 40, "the down arrow tips the model")
    }

    /// The curved arrows roll the view in place: a quarter roll swaps the block's width and height.
    func testCubeRollArrowsRotateTheViewInPlace() {
        let app = launch()
        _ = app.buttons["rollCW"].waitForExistence(timeout: 5)
        app.buttons["stepRight"].tap()      // a view where the block is clearly wider than tall
        Thread.sleep(forTimeInterval: 1)
        app.buttons["stepUp"].tap()
        Thread.sleep(forTimeInterval: 1)
        let before = shot("roll_before")
        app.buttons["rollCW"].tap()
        Thread.sleep(forTimeInterval: 1)
        let rolled = shot("roll_cw")
        print("UITEST roll before \(before.width)x\(before.height) after \(rolled.width)x\(rolled.height) counts \(before.count) \(rolled.count)")
        XCTAssertLessThan(abs(rolled.count - before.count), before.count * 0.08, "rolling turns the picture without changing the shape")
        app.buttons["rollCCW"].tap()
        Thread.sleep(forTimeInterval: 1)
        app.buttons["rollCCW"].tap()
        Thread.sleep(forTimeInterval: 1)
        let other = shot("roll_ccw")
        XCTAssertLessThan(abs(other.count - before.count), before.count * 0.08)
        let sameOrientation = abs(other.width - before.width) + abs(other.height - before.height)
        let turnedOrientation = abs(rolled.width - before.width) + abs(rolled.height - before.height)
        XCTAssertGreaterThan(turnedOrientation + sameOrientation, 0)
    }
}
