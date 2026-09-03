import Foundation

/// Parsed contents of a ```chart fenced block Jarvis can emit in a chat
/// reply. Pure `Codable`, no SwiftUI dependency, so parsing is testable in
/// isolation the same way `WorkspaceSyncService`'s payload types are.
///
/// `data`'s shape is driven entirely by `type` (a custom `Decodable` init
/// below), not sniffed from the JSON's own structure -- a naive "try
/// decoding as [Point], else Table" approach silently mis-parses a
/// `sparkline` row (`{"label", "value", "trend"}`) as a valid `Point`
/// (`{"label", "value"}` plus an ignored extra key), so `type` must decide
/// which shape to expect instead of guessing.
struct ChartSpec: Equatable {
    enum Kind: String, Codable {
        case bar, line, pie, table, radar, radial, funnel, heatmap, sparkline, bubble
        case treemap, stream, gauge, waterfall, polar, range
    }

    enum Style: String, Codable {
        case mono, dither
    }

    struct Point: Codable, Equatable {
        let label: String
        let value: Double
        let series: String?
    }

    struct Table: Codable, Equatable {
        let columns: [String]
        let rows: [[String]]
    }

    /// One row of a compact multi-metric sparkline card (e.g. "CPU Temp
    /// 42C" with a small trend line) -- `value` is a display string, not a
    /// number, since units vary per row ("42C", "1.2k RPM") and it's never
    /// computed on, only shown.
    struct SparklineRow: Codable, Equatable {
        let label: String
        let value: String
        let trend: [Double]
    }

    /// One point of a scatter/bubble plot: `size` drives the circle's
    /// radius, independent of `x`/`y` position.
    struct BubblePoint: Codable, Equatable {
        let label: String
        let x: Double
        let y: Double
        let size: Double
    }

    /// A row x column grid of intensity values (e.g. activity by weekday).
    /// `values[r]` must have exactly `columns.count` entries for each of
    /// `rows.count` rows -- validated in `parse(from:)`, not just decoded.
    struct Heatmap: Codable, Equatable {
        let rows: [String]
        let columns: [String]
        let values: [[Double]]
    }

    /// One point of a min-max range band (e.g. a confidence interval or
    /// daily high/low) -- rendered as a shaded area between two smooth
    /// boundary curves, no midline.
    struct RangePoint: Codable, Equatable {
        let label: String
        let min: Double
        let max: Double
    }

    enum DataPayload: Equatable {
        case points([Point])
        case table(Table)
        case sparkline([SparklineRow])
        case bubble([BubblePoint])
        case heatmap(Heatmap)
        case range([RangePoint])
    }

    let type: Kind
    let style: Style
    let title: String?
    let data: DataPayload

    /// Never throws -- malformed, type/data-mismatched, or structurally
    /// inconsistent (e.g. a heatmap row of the wrong width) JSON returns
    /// `nil` so the caller (the chat markdown parser) can fall back to
    /// rendering the fence as a plain code block instead, the same
    /// graceful degradation used elsewhere for AI-generated output.
    static func parse(from json: String) -> ChartSpec? {
        guard let raw = json.data(using: .utf8),
              let spec = try? JSONDecoder().decode(ChartSpec.self, from: raw) else { return nil }
        if case .heatmap(let heatmap) = spec.data {
            guard heatmap.values.allSatisfy({ $0.count == heatmap.columns.count }),
                  heatmap.values.count == heatmap.rows.count else { return nil }
        }
        return spec
    }
}

extension ChartSpec: Decodable {
    private enum CodingKeys: String, CodingKey { case type, style, title, data }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(Kind.self, forKey: .type)
        let style = try container.decode(Style.self, forKey: .style)
        let title = try container.decodeIfPresent(String.self, forKey: .title)
        let data: DataPayload
        switch type {
        case .bar, .line, .pie, .radar, .radial, .funnel, .treemap, .stream, .gauge, .waterfall, .polar:
            data = .points(try container.decode([Point].self, forKey: .data))
        case .table:
            data = .table(try container.decode(Table.self, forKey: .data))
        case .sparkline:
            data = .sparkline(try container.decode([SparklineRow].self, forKey: .data))
        case .bubble:
            data = .bubble(try container.decode([BubblePoint].self, forKey: .data))
        case .heatmap:
            data = .heatmap(try container.decode(Heatmap.self, forKey: .data))
        case .range:
            data = .range(try container.decode([RangePoint].self, forKey: .data))
        }
        self.type = type
        self.style = style
        self.title = title
        self.data = data
    }
}

extension ChartSpec: Encodable {
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(style, forKey: .style)
        try container.encodeIfPresent(title, forKey: .title)
        switch data {
        case .points(let points): try container.encode(points, forKey: .data)
        case .table(let table): try container.encode(table, forKey: .data)
        case .sparkline(let rows): try container.encode(rows, forKey: .data)
        case .bubble(let points): try container.encode(points, forKey: .data)
        case .heatmap(let heatmap): try container.encode(heatmap, forKey: .data)
        case .range(let points): try container.encode(points, forKey: .data)
        }
    }
}
