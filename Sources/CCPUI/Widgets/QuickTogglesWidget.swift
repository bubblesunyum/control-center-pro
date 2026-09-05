// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import AppKit
import SwiftUI
import Vision
import CoreGraphics
import ScreenCaptureKit

/// The tools strip: one-click helpers that act on the screen.
///
/// The Finder "show hidden files" toggle has moved to the Files widget's
/// header (where the file affordance lives). This card now hosts screen
/// utilities ported from `ScreenTextService` — "Copy text from screen"
/// selects an area, runs offline Vision OCR (with a QR fast-path) and
/// lands the result on the pasteboard.
@MainActor
public final class QuickTogglesWidget: CCPWidget {
    public static let descriptor = WidgetDescriptor(
        id: "quick-toggles",
        title: "Tools",
        symbolName: "wrench.and.screwdriver",
        size: .compact
    )

    private let rocket: RocketAdapter

    public init() {
        self.rocket = RocketAdapter()
    }

    /// Test seam: a widget backed by a fake source.
    init(source: RocketSource) {
        self.rocket = RocketAdapter(source: source)
    }

    public func makeView() -> some View {
        ToolsContent(rocket: rocket)
    }

    public func activate() { rocket.activate() }
    public func deactivate() { rocket.deactivate() }
}

/// Keep the historic name as an alias so existing registries and tests
/// that name `QuickTogglesWidget` keep resolving to the same widget.
public typealias ToolsWidget = QuickTogglesWidget

// MARK: - Content

private struct ToolsContent: View {
    @Bindable var rocket: RocketAdapter
    @Environment(\.hidePanel) private var hidePanel
    @State private var isCapturing = false
    @State private var isOpeningRocket = false

    var body: some View {
        WidgetCard(QuickTogglesWidget.descriptor) {
            HStack(spacing: Space.one) {
                copyTextButton
                // Rocket keeps working with its icon hidden, so the strip
                // gives the hidden icon back its menu. Not installed means
                // no button rather than a dead one.
                if rocket.isInstalled {
                    rocketButton
                }
                Spacer(minLength: 0)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isCapturing)
    }

    private var copyTextButton: some View {
        ToolIconButton(
            title: "Copy Text",
            subtitle: isCapturing ? "…" : "From Screen",
            systemImage: "text.viewfinder",
            isBusy: isCapturing,
            help: "Select an area and copy the text in it"
        ) {
            startCapture()
        }
    }

    private var rocketButton: some View {
        ToolIconButton(
            title: "Rocket",
            subtitle: rocket.isRunning ? "Menu" : "Launch",
            systemImage: "rocket",
            isBusy: isOpeningRocket,
            help: rocket.isRunning ? "Open Rocket's menu" : "Launch Rocket"
        ) {
            openRocketMenu()
        }
    }

    /// Tap shows Rocket's whole status menu — Preferences, Browse & Search,
    /// Fun Stats, all of it — rather than deep-linking one pane. The menu
    /// opens in the menu bar, so the panel gets out of the way first.
    private func openRocketMenu() {
        guard !isOpeningRocket else { return }
        isOpeningRocket = true
        Task { @MainActor in
            let outcome = await rocket.showMenu()
            isOpeningRocket = false
            switch outcome {
            case .shown:
                hidePanel?()
            case .launched:
                ToolHUD.show(icon: "rocket", message: "Rocket launched")
            case .needsAccessibility:
                ToolHUD.show(icon: "rocket", message: "Allow Accessibility to open Rocket's menu")
            case .failed:
                ToolHUD.show(icon: "rocket", message: "Couldn't open Rocket's menu")
            case .notInstalled:
                break // Unreachable: the button only draws when installed.
            }
        }
    }

    private func startCapture() {
        guard !isCapturing else { return }
        // Screen Recording is the gate for any screen capture. Ask once
        // contextually; if the user denies, the next tap will offer
        // System Settings rather than silently doing nothing.
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            // The prompt is One-Shot. If the user denied previously,
            // opening the pane is the only route that helps.
            if !CGPreflightScreenCaptureAccess() {
                // Give the system a turn to show its prompt, then check
                // again. If still denied, send them to Settings.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    if !CGPreflightScreenCaptureAccess() {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }
                }
            }
            return
        }

        isCapturing = true
        hidePanel?()

        // Give the panel a frame to order out so it is not in the
        // capture. 350ms matches the panel's hide animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            ScreenAreaSelector.select { cgImage in
                Task { @MainActor in
                    isCapturing = false
                    guard let cgImage else { return }
                    // OCR off the main actor so the HUD is not held up.
                    let outcome = await Task.detached(priority: .userInitiated) {
                        ScreenTextHelper.outcome(for: cgImage)
                    }.value
                    switch outcome {
                    case .qr(let payload, _):
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(payload, forType: .string)
                        ToolHUD.show(icon: "qrcode", message: "QR copied")
                    case .text(let text):
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(text, forType: .string)
                        ToolHUD.show(icon: "text.viewfinder", message: "Text copied")
                    case .empty:
                        ToolHUD.show(icon: "text.viewfinder", message: "No text found")
                    }
                }
            }
        }
    }
}

// MARK: - Icon button

private struct ToolIconButton: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let isBusy: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: Space.half) {
                ZStack {
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .fill(Color.controlFill)
                        .frame(width: Layout.toggleIconSize, height: Layout.toggleIconSize)
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                                .strokeBorder(Color.cardStroke, lineWidth: Stroke.hairline)
                        )
                    if isBusy {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.secondary)
                    } else {
                        Image(systemName: systemImage)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Color.primary)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                VStack(spacing: Space.quarter) {
                    Text(title)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: Layout.toggleCellWidth)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityLabel(title)
        .help(help)
    }
}

// MARK: - OCR helper (ported from ScreenTextService + QuickToolsSupport + BarcodeDetector)

private enum ScreenTextHelper {
    enum Outcome {
        case qr(String, URL?)
        case text(String)
        case empty
    }

    struct RecognizedLine {
        let text: String
        let x: Double
        let y: Double
    }

    struct DecodedBarcode {
        let payload: String
        let x: Double
        let y: Double
    }

    static func outcome(for image: CGImage) -> Outcome {
        if let (payload, url) = barcodePayload(in: image) {
            return .qr(payload, url)
        }
        var lines = recognizedLines(in: image, level: .accurate, automaticallyDetectLanguage: true)
        if lines.isEmpty {
            lines = recognizedLines(in: image, level: .fast, automaticallyDetectLanguage: false)
        }
        let text = joinedRecognizedText(lines, removingLineBreaks: false)
        return text.isEmpty ? .empty : .text(text)
    }

    // MARK: Barcode

    private static func barcodePayload(in image: CGImage) -> (String, URL?)? {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr, .microQR, .aztec, .dataMatrix, .pdf417]
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])
        let codes: [DecodedBarcode] = (request.results ?? []).compactMap { obs in
            guard let payload = obs.payloadStringValue, !payload.isEmpty else { return nil }
            let box = obs.boundingBox
            return DecodedBarcode(payload: payload, x: Double(box.minX), y: Double(box.midY))
        }
        let payload = joinedBarcodePayloads(codes)
        guard !payload.isEmpty else { return nil }
        let url = codes.count == 1 ? openableURL(from: payload) : nil
        return (payload, url)
    }

    private static func joinedBarcodePayloads(_ codes: [DecodedBarcode]) -> String {
        codes
            .filter { !$0.payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted {
                let rowA = (1 - $0.y) * 50
                let rowB = (1 - $1.y) * 50
                if abs(rowA - rowB) >= 0.5 { return rowA < rowB }
                return $0.x < $1.x
            }
            .map(\.payload)
            .joined(separator: "\n")
    }

    private static func openableURL(from payload: String) -> URL? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(where: { $0.isWhitespace }),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    // MARK: Text

    private static func recognizedLines(in image: CGImage, level: VNRequestTextRecognitionLevel, automaticallyDetectLanguage: Bool) -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = automaticallyDetectLanguage
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return [] }
        return (request.results ?? []).compactMap { observation -> RecognizedLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return RecognizedLine(text: candidate.string, x: Double(observation.boundingBox.minX), y: Double(observation.boundingBox.midY))
        }
    }

    static func joinedRecognizedText(_ lines: [RecognizedLine], removingLineBreaks: Bool) -> String {
        let texts = lines
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted {
                let rowA = (1 - $0.y) * 50
                let rowB = (1 - $1.y) * 50
                if abs(rowA - rowB) >= 0.5 { return rowA < rowB }
                return $0.x < $1.x
            }
            .map(\.text)
        guard removingLineBreaks else { return texts.joined(separator: "\n") }
        let normalizedTexts = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return normalizedTexts.reduce(into: "") { joined, line in
            guard !joined.isEmpty else { joined = line; return }
            let joinsTightly = joined.unicodeScalars.last.map(isTightScriptScalar) == true
                && line.unicodeScalars.first.map(isTightScriptScalar) == true
            joined.append(joinsTightly ? "" : " ")
            joined.append(line)
        }
    }

    private static func isTightScriptScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x312F,
             0x3190...0x9FFF,
             0xF900...0xFAFF,
             0xFF01...0xFF9F,
             0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }
}

// MARK: - Screen area selection overlay

@MainActor
private final class ScreenAreaSelector {
    private var panel: NSPanel?
    private var completion: ((CGImage?) -> Void)?
    private static var current: ScreenAreaSelector?

    static func select(completion: @escaping (CGImage?) -> Void) {
        let selector = ScreenAreaSelector()
        current = selector
        selector.start(completion: completion)
    }

    private func start(completion: @escaping (CGImage?) -> Void) {
        self.completion = completion

        // Union of all screens so the overlay covers every display.
        let frame = NSScreen.screens.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        let resolved = frame.isNull ? (NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)) : frame

        let panel = NSPanel(contentRect: resolved, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let selectionView = SelectionView(frame: NSRect(origin: .zero, size: resolved.size))
        selectionView.onDone = { [weak self] globalRect in
            self?.panel?.orderOut(nil)
            Task { @MainActor [weak self] in
                // Brief pause so the overlay is fully off-screen before pixels are sampled.
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard let self else { return }
                if let rect = globalRect {
                    let image = await self.captureImage(for: rect)
                    self.finish(with: image)
                } else {
                    self.finish(with: nil)
                }
            }
        }
        panel.contentView = selectionView
        self.panel = panel
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(selectionView)
    }

    private func finish(with image: CGImage?) {
        panel?.orderOut(nil)
        panel = nil
        let cb = completion
        completion = nil
        Self.current = nil
        cb?(image)
    }

    private func captureImage(for globalRect: CGRect) async -> CGImage? {
        let center = CGPoint(x: globalRect.midX, y: globalRect.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main else { return nil }
        let displayID = screen.ccp_displayID
        guard displayID != 0 else { return nil }
        guard let full = await captureFullDisplay(displayID: displayID, screen: screen) else { return nil }
        let screenFrame = screen.frame
        let local = CGRect(x: globalRect.minX - screenFrame.minX, y: globalRect.minY - screenFrame.minY, width: globalRect.width, height: globalRect.height)
        let imageWidth = CGFloat(full.width)
        let imageHeight = CGFloat(full.height)
        let scaleX = imageWidth / screenFrame.width
        let scaleY = imageHeight / screenFrame.height
        let crop = CGRect(
            x: local.minX * scaleX,
            y: (screenFrame.height - local.maxY) * scaleY,
            width: local.width * scaleX,
            height: local.height * scaleY
        ).integral
        guard crop.width > 1, crop.height > 1 else { return nil }
        let clamped = crop.intersection(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
        guard !clamped.isEmpty else { return nil }
        return full.cropping(to: clamped)
    }

    private func captureFullDisplay(displayID: CGDirectDisplayID, screen: NSScreen) async -> CGImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == displayID }) else { return nil }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        let scale = screen.backingScaleFactor
        config.width = Int((CGFloat(display.width) * scale).rounded())
        config.height = Int((CGFloat(display.height) * scale).rounded())
        config.showsCursor = false
        config.colorSpaceName = CGColorSpace.sRGB
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    private final class SelectionView: NSView {
        var startPoint: NSPoint?
        var currentPoint: NSPoint?
        var onDone: ((NSRect?) -> Void)?

        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            let loc = convert(event.locationInWindow, from: nil)
            startPoint = loc
            currentPoint = loc
            needsDisplay = true
        }

        override func mouseDragged(with event: NSEvent) {
            currentPoint = convert(event.locationInWindow, from: nil)
            needsDisplay = true
        }

        override func mouseUp(with event: NSEvent) {
            currentPoint = convert(event.locationInWindow, from: nil)
            needsDisplay = true
            guard let s = startPoint, let c = currentPoint else { onDone?(nil); return }
            let rect = NSRect(x: min(s.x, c.x), y: min(s.y, c.y), width: abs(c.x - s.x), height: abs(c.y - s.y))
            if rect.width < 4 || rect.height < 4 {
                onDone?(nil)
                return
            }
            let windowOrigin = window?.frame.origin ?? .zero
            let global = NSRect(x: windowOrigin.x + rect.minX, y: windowOrigin.y + rect.minY, width: rect.width, height: rect.height)
            onDone?(global)
        }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { // Esc
                onDone?(nil)
            } else {
                super.keyDown(with: event)
            }
        }

        override func draw(_ dirtyRect: NSRect) {
            // Dim the whole desktop.
            NSColor.black.withAlphaComponent(0.35).setFill()
            dirtyRect.fill(using: .sourceOver)

            guard let s = startPoint, let c = currentPoint else { return }
            let rect = NSRect(x: min(s.x, c.x), y: min(s.y, c.y), width: abs(s.x - c.x), height: abs(c.y - s.y))
            if rect.width < 1 || rect.height < 1 { return }

            // Cut out the selection so the desktop shows through.
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(rect: rect).fill()
            NSGraphicsContext.restoreGraphicsState()

            // Border.
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: rect)
            border.lineWidth = 1.5
            border.stroke()

            // Crosshair hint.
            let hint = "Drag to select · Esc to cancel"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white
            ]
            let size = (hint as NSString).size(withAttributes: attrs)
            let labelRect = NSRect(x: rect.midX - size.width / 2 - 6, y: rect.minY - size.height - 8, width: size.width + 12, height: size.height + 6)
            NSColor.black.withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: labelRect, xRadius: 6, yRadius: 6).fill()
            (hint as NSString).draw(at: NSPoint(x: labelRect.minX + 6, y: labelRect.minY + 3), withAttributes: attrs)
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }
}

private extension NSScreen {
    var ccp_displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

// MARK: - HUD (lightweight copy of QuickToolHUD for CCPUI)

private enum ToolHUD {
    private static var panel: NSPanel?
    private static var dismissWork: DispatchWorkItem?
    private static var generation = 0
    private static let messageWidthLimit: CGFloat = 360

    static func show(icon: String, message: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { show(icon: icon, message: message) }
            return
        }
        let content = HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text(message)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: messageWidthLimit, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        present(AnyView(content), dismissAfter: 1.5)
    }

    private static func present(_ content: AnyView, dismissAfter: Double) {
        let host = NSHostingController(rootView: content)
        host.view.layoutSubtreeIfNeeded()
        let size = host.view.fittingSize
        let panel = ensurePanel()
        panel.contentViewController = host
        let frame: NSRect
        if let visible = NSScreen.main?.visibleFrame {
            frame = NSRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 24, width: size.width, height: size.height)
        } else {
            frame = NSRect(x: 200, y: 200, width: size.width, height: size.height)
        }
        panel.setFrame(frame, display: true)
        generation += 1
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
        dismissWork?.cancel()
        let work = DispatchWorkItem { dismiss() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + dismissAfter, execute: work)
    }

    private static func dismiss() {
        guard let panel else { return }
        let dismissed = generation
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            panel.animator().alphaValue = 0
        }, completionHandler: {
            guard generation == dismissed else { return }
            panel.orderOut(nil)
            panel.contentViewController = nil
            dismissWork = nil
        })
    }

    private static func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        self.panel = panel
        return panel
    }
}
