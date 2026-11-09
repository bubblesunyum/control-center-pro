// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import XCTest
@testable import CCPKit

/// The registry's dynamic-id hook: ids no static registration covers (the
/// website-xxx sites minted at runtime) resolve through `fallback` and
/// `fallbackDescriptor`, while everything else behaves as before.
@MainActor
final class WebsiteRegistryTests: XCTestCase {
    private func registryWithWebsiteFallback() -> WidgetRegistry {
        let registry = stubRegistry()
        registry.fallbackDescriptor = { id in
            guard id.isWebsiteInstance else { return nil }
            return WidgetDescriptor(id: id, title: "Website", symbolName: "globe", size: .tall)
        }
        registry.fallback = { id in
            guard id.isWebsiteInstance else { return nil }
            return WidgetInstance.erasing(StubWidget())
        }
        return registry
    }

    func testFallbackResolvesUnknownWebsiteIDs() {
        let registry = registryWithWebsiteFallback()

        XCTAssertEqual(registry.descriptor(for: "website-abc123")?.title, "Website")
        XCTAssertNotNil(registry.makeInstance(of: "website-abc123"))
    }

    func testUnknownNonWebsiteIDsStillResolveToNil() {
        let registry = registryWithWebsiteFallback()

        XCTAssertNil(registry.descriptor(for: "widget-from-a-newer-build"))
        XCTAssertNil(registry.makeInstance(of: "widget-from-a-newer-build"))
    }

    func testRegisteredEntriesWinOverFallback() {
        let registry = stubRegistry()
        registry.fallbackDescriptor = { id in
            WidgetDescriptor(id: id, title: "Fallback", symbolName: "questionmark")
        }
        registry.fallback = { _ in WidgetInstance.erasing(OtherStubWidget()) }

        XCTAssertEqual(registry.descriptor(for: StubWidget.descriptor.id)?.title, "Stub")
        XCTAssertEqual(registry.makeInstance(of: StubWidget.descriptor.id)?.id, StubWidget.descriptor.id)
    }

    func testWithoutFallbackUnknownWebsiteIDsStayAbsent() {
        let registry = stubRegistry()

        XCTAssertNil(registry.descriptor(for: "website-abc123"))
        XCTAssertNil(registry.makeInstance(of: "website-abc123"))
    }

    func testSharedDescriptorClosureResolvesWithoutRetainingRegistry() {
        weak var weakRegistry: WidgetRegistry?
        var descriptorTitle: String?
        var madeInstanceID: WidgetID?
        do {
            let registry = stubRegistry()
            weakRegistry = registry
            let websiteDescriptor: @MainActor (WidgetID) -> WidgetDescriptor? = { id in
                guard id.isWebsiteInstance else { return nil }
                return WidgetDescriptor(id: id, title: "Website", symbolName: "globe", size: .tall)
            }
            registry.fallbackDescriptor = websiteDescriptor
            registry.fallback = { id in
                guard let d = websiteDescriptor(id) else { return nil }
                return WidgetInstance.erasing(StubWidget(), descriptor: d)
            }
            descriptorTitle = registry.descriptor(for: "website-abc123")?.title
            madeInstanceID = registry.makeInstance(of: "website-abc123")?.id
        }

        XCTAssertEqual(descriptorTitle, "Website")
        XCTAssertEqual(madeInstanceID, "website-abc123")
        XCTAssertNil(weakRegistry, "fallback closures must not retain the registry")
    }

    func testRegisteredEntriesWinOverSharedWebsiteFallback() {
        let registry = stubRegistry()
        let websiteDescriptor: @MainActor (WidgetID) -> WidgetDescriptor? = { id in
            WidgetDescriptor(id: id, title: "Fallback", symbolName: "globe")
        }
        registry.fallbackDescriptor = websiteDescriptor
        registry.fallback = { id in
            guard let d = websiteDescriptor(id) else { return nil }
            return WidgetInstance.erasing(StubWidget(), descriptor: d)
        }

        XCTAssertEqual(registry.descriptor(for: StubWidget.descriptor.id)?.title, "Stub")
        XCTAssertEqual(registry.makeInstance(of: StubWidget.descriptor.id)?.descriptor.title, "Stub")
    }
}
