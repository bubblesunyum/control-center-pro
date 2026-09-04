// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import SwiftUI
import AppKit

/// A scratchpad for short-lived text — meeting notes, numbers, fragments on
/// their way somewhere else — shown directly in the grid.
///
/// UI is pulled from Vorssaint's floating ScratchpadView but reshaped as a
/// lane widget: the floating panel's chrome (pin, drag handle, resize overlay,
/// HUD backdrop) is gone, and the editor lives inside the shared `WidgetCard`
/// glass so the note reads as one more control-center tile rather than a window
/// inside a window. Document mechanics (tabs, retention, debounced UserDefaults
/// persistence, markdown preview) are the same values Vorssaint uses, via
/// `ScratchpadAdapter`, so a note written here is there in the floating pad and
/// vice-versa.
@MainActor
public final class ScratchpadWidget: CCPWidget {
    public static let descriptor = WidgetDescriptor(
        id: "scratchpad",
        title: "Scratchpad",
        symbolName: "note.text",
        size: .tall
    )

    private let adapter: ScratchpadAdapter

    public init() {
        self.adapter = ScratchpadAdapter()
    }

    /// Test seam: widget backed by an in-memory document.
    init(document: ScratchpadDocument) {
        self.adapter = ScratchpadAdapter(document: document)
    }

    init(adapter: ScratchpadAdapter) {
        self.adapter = adapter
    }

    public func makeView() -> some View {
        ScratchpadContent(adapter: adapter)
    }

    public func activate() { adapter.activate() }
    public func deactivate() { adapter.deactivate() }
}

// MARK: - Content

private struct ScratchpadContent: View {
    @Bindable var adapter: ScratchpadAdapter
    @State private var didCopy = false
    @State private var dialog: ScratchpadDialog?
    @State private var renameDraft = ""
    @State private var hoveredPadID: UUID?

    private var isEmpty: Bool { adapter.text.isEmpty }

    var body: some View {
        WidgetCard(ScratchpadWidget.descriptor) {
            VStack(alignment: .leading, spacing: Space.one) {
                tabBar
                editor
                footer
            }
        }
        .alert(dialogTitle, isPresented: dialogIsPresented) {
            switch dialog {
            case .rename(let pad):
                TextField(pad.name, text: $renameDraft)
                Button("Cancel", role: .cancel) { dismissDialog() }
                Button("Save") {
                    adapter.renamePad(pad.id, to: renameDraft)
                    dismissDialog()
                }
            case .close(let pad):
                Button("Cancel", role: .cancel) { dismissDialog() }
                Button("Close Pad", role: .destructive) {
                    _ = adapter.closePad(pad.id)
                    dismissDialog()
                }
            case nil:
                EmptyView()
            }
        } message: {
            if case .close(let pad) = dialog {
                Text("Close “\(pad.name)”? Its text will be lost.")
            }
        }
    }

    // MARK: Tab bar — pulled from ScratchpadView's tab strip, compressed for 240pt

    private var tabBar: some View {
        HStack(spacing: Space.half) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Space.half - Space.quarter) {
                        ForEach(adapter.pads) { pad in
                            tabButton(pad)
                                .id(pad.id)
                        }
                    }
                    .padding(.vertical, Space.quarter)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onAppear {
                    guard let selected = adapter.selectedPadID else { return }
                    proxy.scrollTo(selected, anchor: .center)
                }
                .onChange(of: adapter.selectedPadID) { _, selected in
                    guard let selected else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(selected, anchor: .center)
                    }
                }
            }

            Button {
                adapter.createPad()
            } label: {
                Image(systemName: "plus")
                    .font(.caption.weight(.semibold))
                    .frame(width: Layout.rowActionSize, height: Layout.rowActionSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!adapter.canCreatePad)
            .help(adapter.canCreatePad ? "New pad" : "Pad limit reached (\(ScratchpadDocument.maximumPadCount))")
            .accessibilityLabel("New pad")

            Menu {
                if let selectedPad {
                    Button("Rename Pad") { presentRename(selectedPad) }
                    Button("Close Pad", role: .destructive) { requestClose(selectedPad) }
                        .disabled(!adapter.canClosePad)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.caption.weight(.semibold))
                    .frame(width: Layout.rowActionSize, height: Layout.rowActionSize)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Pad actions")
            .accessibilityLabel("Pad actions")
        }
        .frame(height: 28)
    }

    private func tabButton(_ pad: ScratchpadPad) -> some View {
        let selected = adapter.selectedPadID == pad.id
        let isHovered = hoveredPadID == pad.id
        let showClose = adapter.canClosePad && (isHovered || selected)
        return HStack(spacing: Space.quarter) {
            Text(pad.name)
                .font(.caption.weight(selected ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
            if showClose {
                Button {
                    requestClose(pad)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.secondary)
                        .frame(width: Layout.rowActionSize, height: Layout.rowActionSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close pad")
                .accessibilityLabel("Close pad")
            }
        }
        .padding(.leading, Space.one)
        .padding(.trailing, showClose ? Space.half : Space.one)
        .frame(minWidth: 36, maxWidth: 96)
        .frame(height: Layout.rowActionSize)
        .foregroundStyle(selected ? Color.primary : Color.secondary)
        .background {
            RoundedRectangle(cornerRadius: Radius.sparkline, style: .continuous)
                .fill(selected ? Color.selectedFill : Color.clear)
        }
        .contentShape(RoundedRectangle(cornerRadius: Radius.sparkline, style: .continuous))
        .onTapGesture { adapter.selectPad(pad.id) }
        .onHover { hovering in
            if hovering { hoveredPadID = pad.id } else if hoveredPadID == pad.id { hoveredPadID = nil }
        }
        .contextMenu {
            Button("Rename Pad") { presentRename(pad) }
            Button("Close Pad", role: .destructive) { requestClose(pad) }
                .disabled(!adapter.canClosePad)
        }
        .accessibilityLabel(pad.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAddTraits(.isButton)
    }

    private var selectedPad: ScratchpadPad? {
        adapter.pads.first(where: { $0.id == adapter.selectedPadID })
    }

    // MARK: Dialog

    private var dialogTitle: String {
        switch dialog {
        case .rename: return "Rename Pad"
        case .close: return "Close Pad"
        case nil: return ""
        }
    }

    private var dialogIsPresented: Binding<Bool> {
        Binding(get: { dialog != nil }, set: { if !$0 { dismissDialog() } })
    }

    private func presentRename(_ pad: ScratchpadPad) {
        renameDraft = pad.name
        dialog = .rename(pad)
    }

    private func requestClose(_ pad: ScratchpadPad) {
        guard adapter.canClosePad else { return }
        if !ScratchpadSupport.requiresCloseConfirmation(pad) {
            _ = adapter.closePad(pad.id)
        } else {
            dialog = .close(pad)
        }
    }

    private func dismissDialog() { dialog = nil }

    // MARK: Editor — plain-text surface + on-demand markdown preview

    private static let editorInset = NSSize(width: 6, height: 4)

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            PlainTextEditor(
                text: Binding(get: { adapter.text }, set: { adapter.text = $0 }),
                textColor: .labelColor,
                textContainerInset: Self.editorInset
            )
            .frame(height: 148)
            .background(Color.controlFill, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .strokeBorder(Color.cardStroke.opacity(0.6), lineWidth: 1)
            )
            .opacity(adapter.isPreviewing ? 0 : 1)
            .allowsHitTesting(!adapter.isPreviewing)
            .accessibilityHidden(adapter.isPreviewing)
            .accessibilityLabel("Scratchpad text")
            .accessibilityHint("Editable notes")

            if isEmpty, !adapter.isPreviewing {
                Text("Scratch something…")
                    .font(.system(size: PlainTextEditor.fontSize))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, Self.editorInset.width + PlainTextEditor.lineFragmentPadding)
                    .padding(.top, Self.editorInset.height)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            if adapter.isPreviewing {
                ScratchpadMarkdownPreview(blocks: ScratchpadSupport.markdownPreview(adapter.text))
                    .frame(height: 148)
                    .background(Color.controlFill, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                            .strokeBorder(Color.cardStroke.opacity(0.6), lineWidth: 1)
                    )
                    .accessibilityLabel("Scratchpad preview")
            }
        }
        .onChange(of: adapter.isPreviewing) { _, isPreviewing in
            if isPreviewing {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
    }

    // MARK: Footer — preview, copy, export, clear

    private var footer: some View {
        HStack(spacing: Space.half) {
            footerButton(adapter.isPreviewing ? "pencil" : "eye",
                         label: adapter.isPreviewing ? "Edit" : "Preview",
                         tint: adapter.isPreviewing ? .accentColor : nil) {
                adapter.togglePreview()
            }
            footerButton(didCopy ? "checkmark" : "doc.on.doc",
                         label: didCopy ? "Copied" : "Copy",
                         tint: didCopy ? .green : nil) {
                adapter.copyAll()
                withAnimation(.easeOut(duration: 0.15)) { didCopy = true }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(1200))
                    withAnimation(.easeOut(duration: 0.2)) { didCopy = false }
                }
            }
            footerButton("square.and.arrow.down", label: "Export") {
                adapter.exportText()
            }
            Spacer(minLength: 0)
            footerButton("trash", label: "Clear") {
                adapter.clear()
            }
        }
        .disabled(isEmpty)
        .opacity(isEmpty ? 0.5 : 1)
    }

    private func footerButton(_ symbol: String, label: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

private enum ScratchpadDialog: Equatable {
    case rename(ScratchpadPad)
    case close(ScratchpadPad)
}

// MARK: - Markdown preview (pulled from ScratchpadView's selectable preview)

/// A selectable native preview. NSTextView keeps Markdown links interactive
/// where SwiftUI Text link handling does not reliably receive clicks in a
/// nonactivating panel.
private struct ScratchpadMarkdownPreview: NSViewRepresentable {
    let blocks: [ScratchpadMarkdownBlock]

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.textContainerInset = NSSize(width: 6, height: 4)
        textView.linkTextAttributes = [.foregroundColor: NSColor.controlAccentColor]
        textView.textStorage?.setAttributedString(Self.rendered(blocks))
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        let content = Self.rendered(blocks)
        guard !textView.attributedString().isEqual(to: content) else { return }
        textView.textStorage?.setAttributedString(content)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private static func rendered(_ blocks: [ScratchpadMarkdownBlock]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            if index > 0 {
                let sameContainer = block.containerID != nil && block.containerID == blocks[index - 1].containerID
                result.append(NSAttributedString(string: sameContainer ? "\n" : "\n\n"))
            }
            result.append(rendered(block))
        }
        return result
    }

    private static func rendered(_ block: ScratchpadMarkdownBlock) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        var font = NSFont.systemFont(ofSize: 12.5)
        var color = NSColor.labelColor
        var prefix = ""
        var text = block.text
        text.presentationIntent = nil

        switch block.kind {
        case .heading(let level):
            let size: CGFloat = level == 1 ? 15 : (level == 2 ? 13.5 : 12.5)
            font = .systemFont(ofSize: size, weight: .semibold)
        case .unorderedListItem(let depth):
            prefix = String(repeating: "  ", count: depth - 1) + "• "
        case .orderedListItem(let ordinal, let depth):
            prefix = String(repeating: "  ", count: depth - 1) + "\(ordinal). "
        case .quote(let depth):
            prefix = String(repeating: "  ", count: depth - 1) + "▏ "
            color = .secondaryLabelColor
        case .code:
            font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        case .thematicBreak:
            text = AttributedString(String(repeating: "─", count: 20))
            color = .secondaryLabelColor
        case .paragraph:
            break
        }

        let result = NSMutableAttributedString()
        if !prefix.isEmpty {
            result.append(NSAttributedString(string: prefix, attributes: [
                .font: font,
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph
            ]))
        }

        let content = NSMutableAttributedString(attributedString: NSAttributedString(text))
        let fullRange = NSRange(location: 0, length: content.length)
        content.removeAttribute(NSAttributedString.Key("NSPresentationIntent"), range: fullRange)
        content.addAttributes([
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ], range: fullRange)
        if block.kind == .code {
            content.addAttribute(.backgroundColor, value: NSColor.labelColor.withAlphaComponent(0.07), range: fullRange)
        }
        applyInlineFormatting(to: content, baseFont: font)
        result.append(content)
        return result
    }

    private static func applyInlineFormatting(to content: NSMutableAttributedString, baseFont: NSFont) {
        let fullRange = NSRange(location: 0, length: content.length)
        var intents: [(InlinePresentationIntent, NSRange)] = []
        content.enumerateAttribute(.inlinePresentationIntent, in: fullRange) { value, range, _ in
            guard let rawValue = (value as? NSNumber)?.uintValue else { return }
            intents.append((InlinePresentationIntent(rawValue: rawValue), range))
        }
        for (intent, range) in intents {
            var font = intent.contains(.code)
                ? NSFont.monospacedSystemFont(ofSize: max(11, baseFont.pointSize - 1), weight: .regular)
                : baseFont
            if intent.contains(.stronglyEmphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
            if intent.contains(.emphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            content.addAttribute(.font, value: font, range: range)
            if intent.contains(.code) {
                content.addAttribute(.backgroundColor, value: NSColor.labelColor.withAlphaComponent(0.07), range: range)
            }
            if intent.contains(.strikethrough) {
                content.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL else { return false }
            return NSWorkspace.shared.open(url)
        }
    }
}
