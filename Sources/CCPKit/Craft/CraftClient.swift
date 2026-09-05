// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation

/// The space a connection URL was verified against. `serverTime` is Craft's
/// own clock from `utc.time` — conflict comparison uses it, never the Mac's.
/// Nil when the payload did not carry a parseable time; callers that need the
/// clock must treat nil as unknown, not as now.
public struct CraftSpace: Equatable, Sendable {
    public var name: String
    public var serverTime: Date?

    public init(name: String, serverTime: Date? = nil) {
        self.name = name
        self.serverTime = serverTime
    }
}

public enum CraftClientError: Error, Equatable {
    /// Anything that is not a verified space: network failure, non-2xx (a
    /// wrong token's exact behaviour is still unobserved), or a payload that
    /// does not decode. A failed check is "store unreachable", never a reason
    /// to touch local state.
    case unreachable(statusCode: Int?)
}

/// The network boundary. URLSession conforms; tests stub it.
public protocol CraftTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: CraftTransport {
    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request, delegate: nil)
    }
}

/// The smallest useful Craft Connect client: validate a connection URL with
/// `GET /connection`. Push and pull build on the base URL handling here.
public struct CraftClient: Sendable {
    private let baseURL: URL
    private let transport: any CraftTransport

    public init(baseURL: URL, transport: (any CraftTransport)? = nil) {
        self.baseURL = baseURL
        if let transport {
            self.transport = transport
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            self.transport = URLSession(configuration: configuration)
        }
    }

    /// A pasted connection string, normalised to the API base URL. Trims
    /// whitespace, drops a trailing slash. Nil unless it is an https URL on
    /// connect.craft.do under /links/ — anything else is not a Craft
    /// connection, including craft.co links, which are a different company
    /// entirely, and the bare host, which carries no credential.
    public static func baseURL(from raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text),
              url.scheme == "https",
              url.host?.lowercased() == "connect.craft.do",
              url.path.hasPrefix("/links/")
        else { return nil }
        return url
    }

    /// `GET /connection` — the space name on success, `.unreachable`
    /// otherwise. Never throws anything else.
    public func checkConnection() async throws(CraftClientError) -> CraftSpace {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(
                for: URLRequest(url: baseURL.appending(path: "connection")))
        } catch {
            throw CraftClientError.unreachable(statusCode: nil)
        }
        guard let http = response as? HTTPURLResponse else {
            throw CraftClientError.unreachable(statusCode: nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CraftClientError.unreachable(statusCode: http.statusCode)
        }
        guard let space = Self.decodeSpace(from: data) else {
            throw CraftClientError.unreachable(statusCode: http.statusCode)
        }
        return space
    }

    private struct ConnectionPayload: Decodable {
        struct Space: Decodable {
            var name: String?
        }
        struct Clock: Decodable {
            var time: String?
        }
        var space: Space?
        var utc: Clock?
    }

    static func decodeSpace(from data: Data) -> CraftSpace? {
        guard let payload = try? JSONDecoder().decode(ConnectionPayload.self, from: data),
              let name = payload.space?.name, !name.isEmpty
        else { return nil }
        let time = payload.utc?.time.flatMap(Self.parseServerTime)
        return CraftSpace(name: name, serverTime: time)
    }

    private static let serverTimeFormats: [ISO8601DateFormatter] = {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return [fractional, plain]
    }()

    static func parseServerTime(_ raw: String) -> Date? {
        serverTimeFormats.lazy.compactMap { $0.date(from: raw) }.first
    }
}
