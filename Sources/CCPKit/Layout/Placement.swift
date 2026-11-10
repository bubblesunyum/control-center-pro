// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

/// One widget's place in a lane: which widget, plus its size and whether it
/// is minimized.
///
/// `customSize` is the only thing a resize stores, and it travels with the
/// widget — dragging a resized note to another lane lands it at its size,
/// because the size describes the widget rather than the slot it sat in.
/// Minimized travels the same way. `span` is what resizes stored before they
/// were free; it is still read (a file from then keeps its look) and kept on
/// disk, but nothing writes a new one. A placement without either is just the id, on disk as well as in
/// memory: it encodes as the bare string a build from before resizes existed
/// wrote, so an old build reads a file back as long as nothing in it was ever
/// resized or minimized. A file containing either is a file with a shape the
/// old build never knew — it fails that whole file the way any schema change
/// does, and the store sets it aside rather than overwriting it.
public struct Placement: Codable, Hashable, Sendable {
    public var id: WidgetID
    public var span: WidgetSpan
    public var isMinimized: Bool
    /// The size in points the user dragged this card to; `nil` until the
    /// first resize. Wins over `span` whenever both are present.
    public var customSize: CustomWidgetSize?

    public init(id: WidgetID, span: WidgetSpan = .unit, isMinimized: Bool = false, customSize: CustomWidgetSize? = nil) {
        self.id = id
        self.span = span
        self.isMinimized = isMinimized
        self.customSize = customSize
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case span
        case isMinimized
        case customSize
    }

    public init(from decoder: any Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let id = try? single.decode(WidgetID.self) {
            self = Placement(id: id)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = Placement(
            id: try container.decode(WidgetID.self, forKey: .id),
            span: try container.decodeIfPresent(WidgetSpan.self, forKey: .span) ?? .unit,
            isMinimized: try container.decodeIfPresent(Bool.self, forKey: .isMinimized) ?? false,
            customSize: try container.decodeIfPresent(CustomWidgetSize.self, forKey: .customSize)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        if span == .unit, !isMinimized, customSize == nil {
            var container = encoder.singleValueContainer()
            try container.encode(id)
        } else {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(span, forKey: .span)
            if isMinimized {
                try container.encode(isMinimized, forKey: .isMinimized)
            }
            try container.encodeIfPresent(customSize, forKey: .customSize)
        }
    }
}
