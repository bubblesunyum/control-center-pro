// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import XCTest
@testable import CCPKit

@MainActor
final class WidgetRegistryTests: XCTestCase {
    func testListsWidgetsInRegistrationOrder() {
        XCTAssertEqual(
            stubRegistry().descriptors.map(\.id),
            [StubWidget.descriptor.id, OtherStubWidget.descriptor.id]
        )
    }

    func testFindsDescriptorByID() {
        let descriptor = stubRegistry().descriptor(for: OtherStubWidget.descriptor.id)
        XCTAssertEqual(descriptor?.title, "Other Stub")
        XCTAssertEqual(descriptor?.size, .tall)
        XCTAssertEqual(descriptor?.permissions, [.audioCapture])
    }

    func testUnknownIDIsAbsentRatherThanFatal() {
        let registry = stubRegistry()
        XCTAssertNil(registry.descriptor(for: "widget-from-a-newer-build"))
        XCTAssertNil(registry.makeInstance(of: "widget-from-a-newer-build"))
    }

    func testRegisteringTheSameIDReplacesItInPlace() {
        let registry = stubRegistry()
        registry.register(RenamedStubWidget.self)

        XCTAssertEqual(registry.descriptors.count, 2)
        XCTAssertEqual(registry.descriptor(for: StubWidget.descriptor.id)?.title, "Renamed Stub")
        XCTAssertEqual(
            registry.descriptors.map(\.id),
            [StubWidget.descriptor.id, OtherStubWidget.descriptor.id],
            "a replaced widget keeps its place in the gallery's order"
        )
    }

    func testEachInstanceIsFresh() {
        let registry = stubRegistry()
        let first = registry.makeInstance(of: StubWidget.descriptor.id)
        let second = registry.makeInstance(of: StubWidget.descriptor.id)

        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertFalse(first === second)
    }
}

@MainActor
final class WidgetDescriptorTests: XCTestCase {
    func testDefaultsToARegularWidgetNeedingNothing() {
        XCTAssertEqual(StubWidget.descriptor.size, .regular)
        XCTAssertTrue(StubWidget.descriptor.permissions.isEmpty)
    }

    func testInstanceCarriesItsKindsDescriptor() {
        let instance = stubRegistry().makeInstance(of: OtherStubWidget.descriptor.id)
        XCTAssertEqual(instance?.descriptor, OtherStubWidget.descriptor)
        XCTAssertEqual(instance?.id, OtherStubWidget.descriptor.id)
    }

    func testWidgetsThatSampleNothingInheritADoNothingLifecycle() {
        let instance = stubRegistry().makeInstance(of: OtherStubWidget.descriptor.id)
        instance?.activate()
        instance?.deactivate()
    }

    func testLifecycleReachesTheWidgetItself() {
        let widget = StubWidget()
        let instance = WidgetInstance(widget)

        instance.activate()
        instance.activate()
        instance.deactivate()

        XCTAssertEqual(widget.activations, 2)
        XCTAssertEqual(widget.deactivations, 1)
    }
}

@MainActor
final class WidgetIDTests: XCTestCase {
    func testRoundTripsAsAPlainStringSoLayoutJSONStaysReadable() throws {
        let encoded = try JSONEncoder().encode(["clipboard", "audio-mixer"] as [WidgetID])
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), #"["clipboard","audio-mixer"]"#)
        XCTAssertEqual(
            try JSONDecoder().decode([WidgetID].self, from: encoded),
            ["clipboard", "audio-mixer"]
        )
    }
}
