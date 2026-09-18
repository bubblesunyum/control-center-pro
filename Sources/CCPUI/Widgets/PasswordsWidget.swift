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
            VStack(alignment: .leading, spacing: Space.half) {
                TextField("Site", text: $site)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .textContentType(.URL)
                    .accessibilityLabel("Site")
                TextField("Username", text: $username)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .textContentType(.username)
                    .accessibilityLabel("Username")
                HStack(spacing: Space.half) {
                    SecureField("Password", text: $password)
                        .textFieldStyle(.plain)
                        .font(.body)
                        .textContentType(.newPassword)
                        .accessibilityLabel("Password")
                    Button {
                        password = PasswordsAdapter.generatePassword()
                    } label: {
                        Image(systemName: "dice")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Generate a strong password")
                    .accessibilityLabel("Generate a strong password")
                }
                Button("Save to Passwords") {
                    Task {
                        if await adapter.save(site: site, username: username, password: password) {
                            password = ""
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(site.isEmpty || username.isEmpty || password.isEmpty)
                if let notice = adapter.notice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }
}
