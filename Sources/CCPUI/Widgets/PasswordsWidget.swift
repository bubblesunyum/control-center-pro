// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import SwiftUI

/// Passwords: save a login to the login keychain, where Apple's Passwords
/// app picks it up, with an inline strong-password generator.
///
/// Scoped to logins saved through here — there is no API for reading the
/// rest of Passwords, which is the point of Passwords.
@MainActor
public final class PasswordsWidget: CCPWidget {
    public static let descriptor = WidgetDescriptor(
        id: "passwords",
        title: "Passwords",
        symbolName: "key.fill",
        size: .regular
    )

    private let adapter: PasswordsAdapter

    public init() {
        self.adapter = PasswordsAdapter()
    }

    /// Test seam: a widget backed by fakes.
    init(adapter: PasswordsAdapter) {
        self.adapter = adapter
    }

    public func makeView() -> some View {
        PasswordsContent(adapter: adapter)
    }
}

// MARK: - Content

private struct PasswordsContent: View {
    @Bindable var adapter: PasswordsAdapter
    @State private var site = ""
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        WidgetCard(PasswordsWidget.descriptor) {
            HeaderIconButton(systemImage: "arrow.up.forward", label: "Open Passwords") {
                adapter.openPasswords()
            }
        } content: {
            VStack(alignment: .leading, spacing: Space.one) {
                PasswordFieldRow(label: "Site") {
                    TextField("example.com", text: $site)
                        .font(.body)
                        .textContentType(.URL)
                        .accessibilityLabel("Site")
                }
                PasswordFieldRow(label: "Username") {
                    TextField("you@example.com", text: $username)
                        .font(.body)
                        .textContentType(.username)
                        .accessibilityLabel("Username")
                }
                PasswordFieldRow(label: "Password") {
                    HStack(spacing: Space.half) {
                        SecureField("Required", text: $password)
                            .font(.body)
                            .textContentType(.newPassword)
                            .accessibilityLabel("Password")
                        Button {
                            password = PasswordsAdapter.generatePassword()
                        } label: {
                            Label("Generate", systemImage: "dice")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Generate a strong password")
                    }
                }
                Button("Save to Passwords") {
                    Task {
                        if await adapter.save(site: site, username: username, password: password) {
                            password = ""
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .disabled(site.isEmpty || username.isEmpty || password.isEmpty)
                // Always drawn so a landing notice never grows the card and
                // shoves the fields it reports on.
                Text(adapter.notice ?? " ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(adapter.notice == nil ? 0 : 1)
                    .accessibilityHidden(adapter.notice == nil)
            }
        }
    }
}

/// One labeled field: a small-caps label over a hairline box. The box is
/// drawn in both states so focusing only emphasizes it — a bare `.plain`
/// field gains its ring out of nothing, which reads as the field jumping.
private struct PasswordFieldRow<Field: View>: View {
    let label: String
    @ViewBuilder let field: Field

    var body: some View {
        VStack(alignment: .leading, spacing: Space.half) {
            Text(label.uppercased())
                .sectionCaps()
            field
                .textFieldStyle(.plain)
                .padding(.horizontal, Space.one)
                .padding(.vertical, Space.one)
                .background(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .strokeBorder(Color.cardStroke, lineWidth: Stroke.hairline)
                )
        }
    }
}
