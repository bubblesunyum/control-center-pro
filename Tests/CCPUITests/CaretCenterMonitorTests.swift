// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import XCTest
@testable import CCPUI

/// Typing or moving the caret while its line is off-screen centers the line;
/// a visible caret is never touched. Geometry is pure (`targetOriginY`), so
/// most of this proves numbers; the monitor tests prove the wiring around
/// them with a canned measure and a recording scroll.
@MainActor
final class CaretCenterMonitorTests: XCTestCase {
    private typealias Snapshot = CaretCenterMonitor.Snapshot

    private func snapshot(caretMin: CGFloat, caretMax: CGFloat,
                          visibleMin: CGFloat, visibleHeight: CGFloat = 200,
                          contentHeight: CGFloat = 1000) -> Snapshot {
        Snapshot(caretMinY: caretMin, caretMaxY: caretMax,
                 visibleMinY: visibleMin, visibleHeight: visibleHeight,
                 contentHeight: contentHeight)
    }

    /// A monitor whose measure and scroll are doubles and whose flush runs
    /// synchronously, so every test is deterministic with no runloop waits.
    /// Returns the monitor (keep it alive) and the scroll recorder.
    private func makeMonitor(center: NotificationCenter,
                             measure: @escaping (NSTextView) -> Snapshot?)
        -> (CaretCenterMonitor, Box)
    {
        let box = Box([])
        let monitor = CaretCenterMonitor(
            center: center,
            schedule: { $0() },
            measure: measure,
            scroll: { _, target in box.values.append(target) })
        monitor.start()
        return (monitor, box)
    }

    func testCaretBelowViewportCentersOnTyping() {
        let center = NotificationCenter()
        // Caret mid 798 in a 200pt viewport: 798 - 100.
        let (m, box) = makeMonitor(center: center,
                                   measure: { _ in self.snapshot(caretMin: 790, caretMax: 806, visibleMin: 0) })
        _ = m
        let textView = RecordingTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        center.post(name: NSText.didChangeNotification, object: textView)
        XCTAssertEqual(box.values, [698])
    }

    func testCaretAboveViewportCentersOnSelectionMove() {
        let center = NotificationCenter()
        // Caret mid 58: 58 - 100 clamps to the top.
        let (m, box) = makeMonitor(center: center,
                                   measure: { _ in self.snapshot(caretMin: 50, caretMax: 66, visibleMin: 400) })
        _ = m
        let textView = RecordingTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        center.post(name: NSTextView.didChangeSelectionNotification, object: textView)
        XCTAssertEqual(box.values, [0])
    }

    func testVisibleCaretIsLeftAlone() {
        let center = NotificationCenter()
        let (m, box) = makeMonitor(center: center,
                                   measure: { _ in self.snapshot(caretMin: 450, caretMax: 466, visibleMin: 400) })
        _ = m
        let textView = RecordingTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        center.post(name: NSText.didChangeNotification, object: textView)
        center.post(name: NSTextView.didChangeSelectionNotification, object: textView)
        XCTAssertTrue(box.values.isEmpty, "a visible caret never scrolls")
    }

    func testTargetClampsToContentBottom() {
        // Caret mid 988 wants 888, but the document ends at 1000.
        let target = CaretCenterMonitor.targetOriginY(
            for: snapshot(caretMin: 980, caretMax: 996, visibleMin: 0), force: false)
        XCTAssertEqual(target, 800)
    }

    func testShortDocumentNeverScrolls() {
        let short = snapshot(caretMin: 50, caretMax: 66, visibleMin: 0,
                             visibleHeight: 200, contentHeight: 150)
        XCTAssertNil(CaretCenterMonitor.targetOriginY(for: short, force: false))
        XCTAssertNil(CaretCenterMonitor.targetOriginY(for: short, force: true),
                     "no scrollable room means nothing to do, even forced")
    }

    func testForceLeavesAMidViewCaretAlone() {
        // The flush runs after AppKit's edge reveal; a caret sitting mid-view
        // got there some other way and stays.
        let mid = snapshot(caretMin: 490, caretMax: 506, visibleMin: 400)
        XCTAssertNil(CaretCenterMonitor.targetOriginY(for: mid, force: true))
    }

    func testForceRescuesAnEdgeStrandedCaret() {
        // Six points from the bottom edge: AppKit's reveal, not a destination.
        let stranded = snapshot(caretMin: 590, caretMax: 606, visibleMin: 400)
        XCTAssertEqual(CaretCenterMonitor.targetOriginY(for: stranded, force: true), 498)
    }

    func testFieldEditorIsIgnored() {
        let center = NotificationCenter()
        let (m, box) = makeMonitor(center: center,
                                   measure: { _ in self.snapshot(caretMin: 790, caretMax: 806, visibleMin: 0) })
        _ = m
        let textView = RecordingTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        textView.isFieldEditor = true
        center.post(name: NSText.didChangeNotification, object: textView)
        XCTAssertTrue(box.values.isEmpty)
    }

    func testNonEditableTextIsIgnored() {
        let center = NotificationCenter()
        let (m, box) = makeMonitor(center: center,
                                   measure: { _ in self.snapshot(caretMin: 790, caretMax: 806, visibleMin: 0) })
        _ = m
        let textView = RecordingTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        textView.isEditable = false
        center.post(name: NSText.didChangeNotification, object: textView)
        XCTAssertTrue(box.values.isEmpty)
    }

    func testMarkedTextIsIgnored() {
        let center = NotificationCenter()
        let (m, box) = makeMonitor(center: center,
                                   measure: { _ in self.snapshot(caretMin: 790, caretMax: 806, visibleMin: 0) })
        _ = m
        let textView = MarkedTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        center.post(name: NSText.didChangeNotification, object: textView)
        XCTAssertTrue(box.values.isEmpty, "IME composition is never interrupted")
    }

    func testSelectionIsIgnored() {
        let center = NotificationCenter()
        let (m, box) = makeMonitor(center: center,
                                   measure: { _ in self.snapshot(caretMin: 790, caretMax: 806, visibleMin: 0) })
        _ = m
        let textView = RecordingTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        textView.string = "abcd"
        textView.setSelectedRange(NSRange(location: 1, length: 2))
        center.post(name: NSTextView.didChangeSelectionNotification, object: textView)
        XCTAssertTrue(box.values.isEmpty, "a selection drag is the user's")
    }

    func testFlushCentersFromTheFreshMeasureNotTheEvent() {
        // The design hinges on this: off-screen at event time (which arms the
        // flush), edge-stranded by flush time (AppKit revealed it meanwhile).
        // The scroll must center the FLUSH caret (mid 598 -> 498), not reuse
        // the event-time one (which would have been 698).
        let center = NotificationCenter()
        var calls = 0
        let (m, box) = makeMonitor(center: center,
                                   measure: { _ in
                                       calls += 1
                                       return calls == 1
                                           ? self.snapshot(caretMin: 790, caretMax: 806, visibleMin: 0)
                                           : self.snapshot(caretMin: 590, caretMax: 606, visibleMin: 400)
                                   })
        _ = m
        let textView = RecordingTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        center.post(name: NSText.didChangeNotification, object: textView)
        XCTAssertEqual(box.values, [498])
    }

    func testFlushSkipsWhenMeasureFailsLate() {
        let center = NotificationCenter()
        var calls = 0
        let (m, box) = makeMonitor(center: center,
                                   measure: { _ in
                                       calls += 1
                                       // Off-screen at event time, gone by flush time.
                                       return calls == 1
                                           ? self.snapshot(caretMin: 790, caretMax: 806, visibleMin: 0)
                                           : nil
                                   })
        _ = m
        let textView = RecordingTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        center.post(name: NSText.didChangeNotification, object: textView)
        XCTAssertTrue(box.values.isEmpty)
    }

    func testStopEndsWatching() {
        let center = NotificationCenter()
        let (m, box) = makeMonitor(center: center,
                                   measure: { _ in self.snapshot(caretMin: 790, caretMax: 806, visibleMin: 0) })
        XCTAssertTrue(m.isWatching)
        let textView = RecordingTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        center.post(name: NSText.didChangeNotification, object: textView)
        XCTAssertEqual(box.values.count, 1)
        m.stop()
        XCTAssertFalse(m.isWatching)
        center.post(name: NSText.didChangeNotification, object: textView)
        XCTAssertEqual(box.values.count, 1, "stopped means stopped")
    }
}

/// A text view mid-IME-composition.
@MainActor
private final class MarkedTextView: NSTextView {
    override func hasMarkedText() -> Bool { true }
}

/// The scroll recorder: a box the recording closure shares with the test.
@MainActor
private final class Box {
    var values: [CGFloat]
    init(_ values: [CGFloat]) { self.values = values }
}
