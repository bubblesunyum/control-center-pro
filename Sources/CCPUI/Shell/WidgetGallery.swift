// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import SwiftUI

/// Everything this build offers, and a way to put one on the panel.
///
/// Built from the arrangement's own catalogue, so registering a widget is the
/// whole of adding it to the gallery — there is no second list to keep in step,
/// which is the same promise the registry makes to the lanes.
struct WidgetGallery: View {
    let arrangement: PanelArrangement
    let onAdd: () -> Void
    @State private var showWebsiteSheet = false
    @State private var draftURL = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Widgets")
                .font(.headline)
                .padding(.horizontal, Space.oneHalf)
                .padding(.vertical, Space.one)

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(arrangement.gallery) { entry in
                        GalleryRow(entry: entry) {
                            // The website template mints a fresh website-xxx
                            // id on every tap, so it opens the address sheet
                            // instead of placing anything directly.
                            if entry.id.isWebsiteTemplate {
                                draftURL = ""
                                showWebsiteSheet = true
                            } else {
                                withAnimation(.snappy) { arrangement.add(entry.id) }
                                onAdd()
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 360)
        }
        .frame(width: Layout.laneWidth)
        .padding(.bottom, Space.half)
        .sheet(isPresented: $showWebsiteSheet) {
            WebsiteURLSheet(draftURL: $draftURL) { normalized in
                let newID = WebsiteStore.shared.add(url: normalized)
                withAnimation(.snappy) { arrangement.add(newID) }
                showWebsiteSheet = false
                onAdd()
            }
        }
    }
}

private struct GalleryRow: View {
    let entry: GalleryEntry
    let add: () -> Void

    /// The website template is never "already on the panel": tapping it mints
    /// a new website-xxx id, so it stays addable no matter how many website
    /// cards exist.
    private var isWebsiteTemplate: Bool { entry.id.isWebsiteTemplate }

    private var isPlaced: Bool { entry.isPlaced && !isWebsiteTemplate }

    var body: some View {
        Button(action: add) {
            HStack(spacing: Space.one) {
                Image(systemName: entry.descriptor.symbolName)
                    .frame(width: Space.two)

                VStack(alignment: .leading, spacing: 0) {
                    Text(entry.descriptor.title)
                    // Every permission, in a settled order: they arrive as a
                    // Set, so showing "the first one" would name a different
                    // one run to run once a widget declares two.
                    ForEach(entry.descriptor.requirements, id: \.self) { requirement in
                        Text(requirement)
                            .font(.caption)
                            .foregroundStyle(Color.labelMuted)
                    }
                }

                Spacer(minLength: Space.one)

                if isPlaced {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.labelMuted)
                }
            }
            .contentShape(.rect)
            .padding(.horizontal, Space.oneHalf)
            .padding(.vertical, Space.one)
        }
        .buttonStyle(.plain)
        .disabled(isPlaced)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        if isWebsiteTemplate { return "Add website" }
        if isPlaced { return "\(entry.descriptor.title), already on the panel" }
        return "Add \(entry.descriptor.title)"
    }
}

/// The address a new website card opens. The store's own normalization plus the
/// navigation policy's allow-list is the single rule for what counts as an
/// address — the sheet only refuses what the policy would refuse to load.
private struct WebsiteURLSheet: View {
    @Binding var draftURL: String
    let add: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private var normalized: String {
        WebsiteStore.normalizedURL(draftURL)
    }

    private var isValid: Bool {
        WebsitePolicy.isAllowed(URL(string: normalized))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.two) {
            Text("Add website")
                .font(.headline)
            TextField("Website URL", text: $draftURL)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Website address")
                .onSubmit(submit)
            HStack(spacing: Space.one) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .accessibilityLabel("Cancel adding website")
                Button("Add") { submit() }
                    .accessibilityLabel("Add website")
                    .disabled(!isValid)
            }
        }
        .padding(Space.two)
    }

    private func submit() {
        guard isValid else { return }
        add(normalized)
    }
}

private extension WidgetDescriptor {
    /// What the widget will have to ask the user for, in a stable order.
    /// Whether any of it has been granted is not known here — see ccp-23w.
    var requirements: [String] {
        permissions.map(\.requirement).sorted()
    }
}

private extension WidgetPermission {
    var requirement: String {
        switch self {
        case .audioCapture: "Needs audio recording access"
        case .accessibility: "Needs accessibility access"
        }
    }
}
