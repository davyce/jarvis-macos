import Charts
import SwiftUI

/// Renders a parsed `ChartSpec` as an interactive bar/line/pie chart or a
/// styled table, in the same dark-card chrome as `CodeBlockView`
/// (`MarkdownMessageContent.swift`). "mono" and "dither" both use Swift
/// `Charts` marks for layout/axes/legend/hover -- they differ only in fill:
/// mono is a flat cyan accent (matching `thinkingIndicator`), dither paints
/// with a small pre-rendered dot-pattern tile (`DitherTile`) instead of a
/// solid color.
struct ChartBlockView: View {
    let spec: ChartSpec

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title = spec.title, !title.isEmpty {
                Text(title)
                    .font(.caption2.weight(.bold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.05))
                Divider().overlay(.white.opacity(0.08))
            }
            content.padding(16)
        }
        .background(Color.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.08), lineWidth: 1))
    }

    @ViewBuilder
    private var content: some View {
        switch spec.data {
        case .points(let points):
            switch spec.type {
            case .bar: BarChartCard(points: points, style: spec.style)
            case .line: LineChartCard(points: points, style: spec.style)
            case .pie: PieChartCard(points: points, style: spec.style)
            case .radar: RadarChartCard(points: points, style: spec.style)
            case .radial: RadialChartCard(points: points, style: spec.style)
            case .funnel: FunnelChartCard(points: points, style: spec.style)
            case .treemap: TreemapChartCard(points: points, style: spec.style)
            case .stream: StreamChartCard(points: points, style: spec.style)
            case .gauge: GaugeChartCard(points: points, style: spec.style)
            case .waterfall: WaterfallChartCard(points: points, style: spec.style)
            case .polar: PolarChartCard(points: points, style: spec.style)
            case .table, .heatmap, .sparkline, .bubble, .range:
                Text("Donnees de graphique illisibles.").font(.caption).foregroundStyle(.secondary)
            }
        case .table(let table):
            TableChartCard(table: table, style: spec.style)
        case .heatmap(let heatmap):
            HeatmapChartCard(heatmap: heatmap, style: spec.style)
        case .sparkline(let rows):
            SparklineChartCard(rows: rows, style: spec.style)
        case .bubble(let points):
            BubbleChartCard(points: points, style: spec.style)
        case .range(let points):
            RangeChartCard(points: points, style: spec.style)
        }
    }
}

// MARK: - Bar

private struct BarChartCard: View {
    let points: [ChartSpec.Point]
    let style: ChartSpec.Style
    @State private var hovered: ChartSpec.Point?

    private var isMultiSeries: Bool { orderedUnique(points.map { $0.series ?? "" }).count > 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart(Array(points.enumerated()), id: \.offset) { _, point in
                if isMultiSeries {
                    BarMark(x: .value("Categorie", point.label), y: .value("Valeur", point.value))
                        .foregroundStyle(by: .value("Serie", point.series ?? ""))
                        .cornerRadius(4)
                        .opacity(hovered == nil || hovered == point ? 1 : 0.5)
                } else {
                    BarMark(x: .value("Categorie", point.label), y: .value("Valeur", point.value))
                        .foregroundStyle(style == .mono ? AnyShapeStyle(Color.cyan) : AnyShapeStyle(ChartFill.dither))
                        .cornerRadius(4)
                        .opacity(hovered == nil || hovered == point ? 1 : 0.5)
                }
            }
            .chartLegend(isMultiSeries ? .visible : .hidden)
            .chartOverlay { proxy in hoverOverlay(proxy: proxy) }
            .frame(height: 180)
            if let hovered { ChartTooltip(point: hovered) }
        }
    }

    private func hoverOverlay(proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            Rectangle().fill(.clear).contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        hovered = closestPoint(to: location, proxy: proxy, geo: geo)
                    case .ended:
                        hovered = nil
                    }
                }
        }
    }

    /// Picks the hovered point among ALL series sharing the nearest x
    /// label, not just the first one in `points` -- a multi-series chart
    /// needs the point closest to the cursor vertically too, or every
    /// series but the first is permanently unreachable by hover regardless
    /// of where the mouse is.
    private func closestPoint(to location: CGPoint, proxy: ChartProxy, geo: GeometryProxy) -> ChartSpec.Point? {
        closestPointByLabelAndValue(
            among: points, label: { $0.label }, value: { $0.value },
            to: location, proxy: proxy, geo: geo
        )
    }
}

// MARK: - Line

private struct LineChartCard: View {
    let points: [ChartSpec.Point]
    let style: ChartSpec.Style
    @State private var hovered: ChartSpec.Point?

    private var isMultiSeries: Bool { orderedUnique(points.map { $0.series ?? "" }).count > 1 }
    private var soloColor: Color { style == .mono ? .cyan : .white.opacity(0.85) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart(Array(points.enumerated()), id: \.offset) { _, point in
                // Dithered area fill under the curve is what actually
                // distinguishes "dither" from "mono" for line charts (a
                // dotted stroke on a ~2pt-wide line reads as broken dashes,
                // not a texture -- so the stroke itself stays a plain
                // color in both styles). Only drawn for a single series:
                // an area per series would need its own baseline-stitching
                // Charts doesn't give us cheaply, so multi-series dither
                // falls back to a plain multi-color line, same as mono.
                if style == .dither, !isMultiSeries {
                    AreaMark(x: .value("Categorie", point.label), y: .value("Valeur", point.value))
                        .foregroundStyle(ChartFill.dither)
                        .opacity(0.5)
                }
                if isMultiSeries {
                    LineMark(x: .value("Categorie", point.label), y: .value("Valeur", point.value))
                        .foregroundStyle(by: .value("Serie", point.series ?? ""))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    PointMark(x: .value("Categorie", point.label), y: .value("Valeur", point.value))
                        .foregroundStyle(by: .value("Serie", point.series ?? ""))
                        .symbolSize(point == hovered ? 90 : 28)
                } else {
                    LineMark(x: .value("Categorie", point.label), y: .value("Valeur", point.value))
                        .foregroundStyle(soloColor)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    PointMark(x: .value("Categorie", point.label), y: .value("Valeur", point.value))
                        .foregroundStyle(soloColor)
                        .symbolSize(point == hovered ? 90 : 28)
                }
            }
            .chartLegend(isMultiSeries ? .visible : .hidden)
            .chartOverlay { proxy in hoverOverlay(proxy: proxy) }
            .frame(height: 180)
            if let hovered { ChartTooltip(point: hovered) }
        }
    }

    private func hoverOverlay(proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            Rectangle().fill(.clear).contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        hovered = closestPoint(to: location, proxy: proxy, geo: geo)
                    case .ended:
                        hovered = nil
                    }
                }
        }
    }

    /// Picks the hovered point among ALL series sharing the nearest x
    /// label, not just the first one in `points` -- a multi-series chart
    /// needs the point closest to the cursor vertically too, or every
    /// series but the first is permanently unreachable by hover regardless
    /// of where the mouse is.
    private func closestPoint(to location: CGPoint, proxy: ChartProxy, geo: GeometryProxy) -> ChartSpec.Point? {
        closestPointByLabelAndValue(
            among: points, label: { $0.label }, value: { $0.value },
            to: location, proxy: proxy, geo: geo
        )
    }
}

// MARK: - Pie

private struct PieChartCard: View {
    let points: [ChartSpec.Point]
    let style: ChartSpec.Style
    @State private var hovered: ChartSpec.Point?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart(Array(points.enumerated()), id: \.offset) { index, point in
                SectorMark(angle: .value("Valeur", max(point.value, 0)), innerRadius: .ratio(0.55), angularInset: 1.5)
                    .foregroundStyle(fill(for: point, index: index))
                    .opacity(hovered == nil || hovered == point ? 1 : 0.5)
            }
            .chartLegend(position: .bottom, alignment: .leading, spacing: 6)
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                hovered = sector(at: location, proxy: proxy, geo: geo)
                            case .ended:
                                hovered = nil
                            }
                        }
                }
            }
            .frame(height: 200)
            if let hovered { ChartTooltip(point: hovered) }
        }
    }

    private func fill(for point: ChartSpec.Point, index: Int) -> AnyShapeStyle {
        switch style {
        case .mono: return AnyShapeStyle(ChartFill.mono(index: index, of: points.count))
        case .dither: return AnyShapeStyle(ChartFill.dither)
        }
    }

    /// `SectorMark` has no cartesian x/y to query via `ChartProxy`, so the
    /// hovered slice is found by re-deriving each slice's cumulative angle
    /// range from the same data order Charts uses to lay them out (starts
    /// at 12 o'clock, sweeps clockwise), then comparing the hover point's
    /// angle around the plot area's center.
    private func sector(at location: CGPoint, proxy: ChartProxy, geo: GeometryProxy) -> ChartSpec.Point? {
        let frame = geo[proxy.plotAreaFrame]
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let dx = location.x - center.x
        let dy = location.y - center.y
        let distance = (dx * dx + dy * dy).squareRoot()
        let radius = min(frame.width, frame.height) / 2
        guard distance <= radius, distance >= radius * 0.55 else { return nil }

        var angle = atan2(dx, -dy) * 180 / .pi
        if angle < 0 { angle += 360 }

        let total = points.reduce(0) { $0 + max($1.value, 0) }
        guard total > 0 else { return nil }
        var cumulative = 0.0
        for point in points {
            let sweep = max(point.value, 0) / total * 360
            if angle < cumulative + sweep { return point }
            cumulative += sweep
        }
        return points.last
    }
}

// MARK: - Radar

private struct RadarChartCard: View {
    let points: [ChartSpec.Point]
    let style: ChartSpec.Style
    @State private var hovered: ChartSpec.Point?

    private var axes: [String] { orderedUnique(points.map { $0.label }) }
    private var seriesNames: [String] { orderedUnique(points.map { $0.series ?? "" }) }
    private var maxValue: Double { max(points.map(\.value).max() ?? 1, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                let size = min(geo.size.width, geo.size.height)
                let center = CGPoint(x: geo.size.width / 2, y: size / 2)
                let radius = size / 2 * 0.68
                ZStack {
                    ForEach([0.33, 0.66, 1.0], id: \.self) { fraction in
                        polygonPath(center: center, radius: radius * fraction)
                            .stroke(.white.opacity(0.12), lineWidth: 1)
                    }
                    ForEach(0..<max(axes.count, 1), id: \.self) { index in
                        Path { path in
                            path.move(to: center)
                            path.addLine(to: point(at: index, radius: radius, center: center))
                        }
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                    }
                    ForEach(Array(seriesNames.enumerated()), id: \.offset) { sIndex, series in
                        seriesPath(series: series, center: center, radius: radius)
                            .fill(seriesColor(sIndex).opacity(0.14))
                    }
                    ForEach(Array(seriesNames.enumerated()), id: \.offset) { sIndex, series in
                        seriesPath(series: series, center: center, radius: radius)
                            .stroke(seriesColor(sIndex), lineWidth: 2)
                    }
                    // Hoverable vertex markers -- otherwise the polygon
                    // shape alone conveys relative comparison only, with
                    // no way to actually read an exact value off it.
                    ForEach(Array(seriesNames.enumerated()), id: \.offset) { sIndex, series in
                        ForEach(0..<axes.count, id: \.self) { index in
                            if let vertex = points.first(where: { $0.label == axes[index] && ($0.series ?? "") == series }) {
                                let normalized = CGFloat(max(0, min(vertex.value / maxValue, 1)))
                                Circle()
                                    .fill(seriesColor(sIndex))
                                    .frame(width: hovered == vertex ? 10 : 6, height: hovered == vertex ? 10 : 6)
                                    .position(point(at: index, radius: radius * normalized, center: center))
                                    .onHover { isHovering in hovered = isHovering ? vertex : (hovered == vertex ? nil : hovered) }
                            }
                        }
                    }
                    ForEach(0..<axes.count, id: \.self) { index in
                        Text(axes[index])
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .position(point(at: index, radius: radius + 18, center: center))
                    }
                }
            }
            .frame(height: 220)
            if let hovered { ChartTooltip(point: hovered) }
        }
    }

    private func angle(for index: Int) -> Double {
        let count = max(axes.count, 1)
        return -Double.pi / 2 + Double(index) * (2 * Double.pi / Double(count))
    }

    private func point(at index: Int, radius: CGFloat, center: CGPoint) -> CGPoint {
        let a = angle(for: index)
        return CGPoint(x: center.x + radius * CGFloat(cos(a)), y: center.y + radius * CGFloat(sin(a)))
    }

    private func polygonPath(center: CGPoint, radius: CGFloat) -> Path {
        Path { path in
            guard !axes.isEmpty else { return }
            path.move(to: point(at: 0, radius: radius, center: center))
            for index in 1..<axes.count {
                path.addLine(to: point(at: index, radius: radius, center: center))
            }
            path.closeSubpath()
        }
    }

    private func seriesPath(series: String, center: CGPoint, radius: CGFloat) -> Path {
        Path { path in
            guard !axes.isEmpty else { return }
            func normalizedValue(axis: String) -> CGFloat {
                let raw = points.first(where: { $0.label == axis && ($0.series ?? "") == series })?.value ?? 0
                return CGFloat(max(0, min(raw / maxValue, 1)))
            }
            path.move(to: point(at: 0, radius: radius * normalizedValue(axis: axes[0]), center: center))
            for index in 1..<axes.count {
                path.addLine(to: point(at: index, radius: radius * normalizedValue(axis: axes[index]), center: center))
            }
            path.closeSubpath()
        }
    }

    private func seriesColor(_ index: Int) -> Color {
        style == .mono ? Color.cyan.opacity(index == 0 ? 1 : 0.6) : Color.white.opacity(index == 0 ? 0.9 : 0.55)
    }
}

// MARK: - Radial (concentric rings)

private struct RadialChartCard: View {
    let points: [ChartSpec.Point]
    let style: ChartSpec.Style
    @State private var hovered: ChartSpec.Point?

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            ZStack {
                ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                    let inset = CGFloat(index) * 22
                    let isHovered = hovered == point
                    Circle()
                        .stroke(.white.opacity(0.1), lineWidth: 10)
                        .padding(inset)
                    Circle()
                        .trim(from: 0, to: max(0, min(point.value / 100, 1)))
                        .stroke(ringColor(index), style: StrokeStyle(lineWidth: isHovered ? 13 : 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(inset)
                        .opacity(hovered == nil || isHovered ? 1 : 0.5)
                        .contentShape(Circle())
                        .onHover { isHovering in hovered = isHovering ? point : (hovered == point ? nil : hovered) }
                }
            }
            .frame(width: 160, height: 160)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                    HStack(spacing: 8) {
                        Circle().fill(ringColor(index)).frame(width: 8, height: 8)
                        Text(point.label).font(.caption)
                        Spacer()
                        Text(Self.percentLabel(point.value)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .opacity(hovered == nil || hovered == point ? 1 : 0.5)
                    .onHover { isHovering in hovered = isHovering ? point : (hovered == point ? nil : hovered) }
                }
            }
        }
    }

    private func ringColor(_ index: Int) -> Color {
        let opacities: [Double] = [1.0, 0.65, 0.4, 0.8, 0.5]
        return style == .mono
            ? Color.cyan.opacity(opacities[index % opacities.count])
            : Color.white.opacity(opacities[index % opacities.count] * 0.9)
    }

    private static func percentLabel(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(value))%" : String(format: "%.1f%%", value)
    }
}

// MARK: - Funnel

private struct FunnelChartCard: View {
    let points: [ChartSpec.Point]
    let style: ChartSpec.Style
    @State private var hovered: ChartSpec.Point?

    private var maxValue: Double { max(points.map(\.value).max() ?? 1, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                HStack(spacing: 10) {
                    Text(point.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 72, alignment: .leading)
                    GeometryReader { geo in
                        Capsule()
                            .fill(fill(index: index))
                            .frame(width: geo.size.width * CGFloat(point.value / maxValue), height: 20)
                            .opacity(hovered == nil || hovered == point ? 1 : 0.55)
                    }
                    .frame(height: 20)
                }
                .contentShape(Rectangle())
                .onHover { isHovering in hovered = isHovering ? point : (hovered == point ? nil : hovered) }
            }
            if let hovered { ChartTooltip(point: hovered) }
        }
    }

    private func fill(index: Int) -> AnyShapeStyle {
        switch style {
        case .mono: return AnyShapeStyle(Color.cyan.opacity(max(1 - Double(index) * 0.14, 0.3)))
        case .dither: return AnyShapeStyle(ChartFill.dither)
        }
    }
}

// MARK: - Heatmap

private struct HeatmapChartCard: View {
    let heatmap: ChartSpec.Heatmap
    let style: ChartSpec.Style
    @State private var hovered: (row: Int, col: Int)?

    private var maxValue: Double { heatmap.values.flatMap { $0 }.max() ?? 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !heatmap.columns.isEmpty {
                HStack(spacing: 4) {
                    Color.clear.frame(width: 40)
                    ForEach(Array(heatmap.columns.enumerated()), id: \.offset) { _, column in
                        Text(column).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    }
                }
            }
            ForEach(Array(heatmap.rows.enumerated()), id: \.offset) { rowIndex, row in
                HStack(spacing: 4) {
                    Text(row).font(.caption2).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
                    ForEach(Array(heatmap.values[rowIndex].enumerated()), id: \.offset) { colIndex, value in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(cellColor(value))
                            .aspectRatio(1, contentMode: .fit)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(.white, lineWidth: 2)
                                    .opacity(hovered?.row == rowIndex && hovered?.col == colIndex ? 0.8 : 0)
                            )
                            .onHover { isHovering in
                                let key = (rowIndex, colIndex)
                                hovered = isHovering ? key : (hovered?.row == rowIndex && hovered?.col == colIndex ? nil : hovered)
                            }
                    }
                }
            }
            if let hovered {
                let rowLabel = heatmap.rows[hovered.row]
                let colLabel = hovered.col < heatmap.columns.count ? heatmap.columns[hovered.col] : nil
                let title = colLabel.map { "\(rowLabel) \u{2013} \($0)" } ?? rowLabel
                GenericTooltip(label: title, value: formatValue(heatmap.values[hovered.row][hovered.col]))
            }
        }
    }

    private func cellColor(_ value: Double) -> Color {
        let intensity = maxValue > 0 ? value / maxValue : 0
        return style == .mono
            ? Color.cyan.opacity(0.12 + intensity * 0.75)
            : Color.white.opacity(0.1 + intensity * 0.75)
    }
}

// MARK: - Sparkline

private struct SparklineChartCard: View {
    let rows: [ChartSpec.SparklineRow]
    let style: ChartSpec.Style

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.label).font(.caption).foregroundStyle(.secondary)
                        Text(row.value).font(.callout.weight(.semibold))
                    }
                    .frame(width: 90, alignment: .leading)
                    SparklinePath(values: row.trend)
                        .stroke(style == .mono ? Color.cyan : Color.white.opacity(0.85), lineWidth: 2)
                        .frame(height: 30)
                }
            }
        }
    }
}

private struct SparklinePath: Shape {
    let values: [Double]

    func path(in rect: CGRect) -> Path {
        Path { path in
            guard values.count > 1 else { return }
            let minValue = values.min() ?? 0
            let maxValue = values.max() ?? 1
            let range = max(maxValue - minValue, 0.0001)
            let stepX = rect.width / CGFloat(values.count - 1)
            func point(_ index: Int) -> CGPoint {
                let normalized = (values[index] - minValue) / range
                return CGPoint(x: CGFloat(index) * stepX, y: rect.height - CGFloat(normalized) * rect.height)
            }
            path.move(to: point(0))
            for index in 1..<values.count {
                path.addLine(to: point(index))
            }
        }
    }
}

// MARK: - Bubble

private struct BubbleChartCard: View {
    let points: [ChartSpec.BubblePoint]
    let style: ChartSpec.Style
    @State private var hovered: ChartSpec.BubblePoint?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart(Array(points.enumerated()), id: \.offset) { _, point in
                PointMark(x: .value("X", point.x), y: .value("Y", point.y))
                    .symbolSize(by: .value("Taille", point.size))
                    .foregroundStyle(style == .mono ? AnyShapeStyle(Color.cyan.opacity(0.7)) : AnyShapeStyle(Color.white.opacity(0.7)))
                    .opacity(hovered == nil || hovered == point ? 1 : 0.4)
            }
            .chartLegend(.hidden)
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                hovered = closestPoint(to: location, proxy: proxy, geo: geo)
                            case .ended:
                                hovered = nil
                            }
                        }
                }
            }
            .frame(height: 200)
            if let hovered {
                GenericTooltip(label: hovered.label, value: "(\(formatValue(hovered.x)), \(formatValue(hovered.y)))")
            }
        }
    }

    private func closestPoint(to location: CGPoint, proxy: ChartProxy, geo: GeometryProxy) -> ChartSpec.BubblePoint? {
        let origin = geo[proxy.plotAreaFrame].origin
        let relativeX = location.x - origin.x
        let relativeY = location.y - origin.y
        guard let x = proxy.value(atX: relativeX, as: Double.self),
              let y = proxy.value(atY: relativeY, as: Double.self) else { return nil }
        return points.min { lhs, rhs in
            let lhsDistance = (lhs.x - x) * (lhs.x - x) + (lhs.y - y) * (lhs.y - y)
            let rhsDistance = (rhs.x - x) * (rhs.x - x) + (rhs.y - y) * (rhs.y - y)
            return lhsDistance < rhsDistance
        }
    }
}

// MARK: - Treemap

private struct TreemapChartCard: View {
    let points: [ChartSpec.Point]
    let style: ChartSpec.Style
    @State private var hovered: ChartSpec.Point?

    private var ordered: [ChartSpec.Point] { points.sorted { $0.value > $1.value } }
    private var total: Double { max(points.reduce(0) { $0 + max($1.value, 0) }, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                let tiles = Self.layout(points: ordered, in: CGRect(origin: .zero, size: geo.size))
                ZStack(alignment: .topLeading) {
                    ForEach(Array(tiles.enumerated()), id: \.offset) { index, tile in
                        tileView(index: index, point: tile.0, rect: tile.1)
                    }
                }
            }
            .frame(height: 220)
            if let hovered { ChartTooltip(point: hovered) }
        }
    }

    @ViewBuilder
    private func tileView(index: Int, point: ChartSpec.Point, rect: CGRect) -> some View {
        let lightBackground = index == 0 && style == .mono
        let isHovered = hovered == point
        VStack(alignment: .leading, spacing: 4) {
            Text(point.label).font(.caption.weight(.semibold))
            Spacer(minLength: 0)
            Text(Self.percentLabel(point.value, total: total)).font(.caption2)
        }
        .foregroundStyle(lightBackground ? .black : .primary)
        .opacity(lightBackground ? 1 : 0.85)
        .padding(10)
        .frame(width: max(rect.width - 4, 0), height: max(rect.height - 4, 0), alignment: .topLeading)
        .background(fill(index: index), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white, lineWidth: 2).opacity(isHovered ? 0.7 : 0))
        .scaleEffect(isHovered ? 1.02 : 1)
        .position(x: rect.midX, y: rect.midY)
        .onHover { isHovering in hovered = isHovering ? point : (hovered == point ? nil : hovered) }
    }

    private func fill(index: Int) -> AnyShapeStyle {
        switch style {
        case .mono: return AnyShapeStyle(ChartFill.mono(index: index, of: ordered.count))
        case .dither: return AnyShapeStyle(ChartFill.dither)
        }
    }

    /// A simple "slice and dice" treemap: peel the largest remaining tile
    /// off the longer axis of what's left, sized to its share of the
    /// remaining total, and recurse -- not squarified, but always produces
    /// non-overlapping tiles proportional to value with no external
    /// dependency.
    private static func layout(points: [ChartSpec.Point], in rect: CGRect) -> [(ChartSpec.Point, CGRect)] {
        guard !points.isEmpty else { return [] }
        var result: [(ChartSpec.Point, CGRect)] = []
        var remaining = points
        var remainingRect = rect
        var remainingTotal = points.reduce(0) { $0 + max($1.value, 0) }
        while remaining.count > 1, remainingTotal > 0 {
            let point = remaining.removeFirst()
            let fraction = CGFloat(max(point.value, 0) / remainingTotal)
            if remainingRect.width >= remainingRect.height {
                let width = remainingRect.width * fraction
                result.append((point, CGRect(x: remainingRect.minX, y: remainingRect.minY, width: width, height: remainingRect.height)))
                remainingRect = CGRect(x: remainingRect.minX + width, y: remainingRect.minY, width: remainingRect.width - width, height: remainingRect.height)
            } else {
                let height = remainingRect.height * fraction
                result.append((point, CGRect(x: remainingRect.minX, y: remainingRect.minY, width: remainingRect.width, height: height)))
                remainingRect = CGRect(x: remainingRect.minX, y: remainingRect.minY + height, width: remainingRect.width, height: remainingRect.height - height)
            }
            remainingTotal -= max(point.value, 0)
        }
        if let last = remaining.first {
            result.append((last, remainingRect))
        }
        return result
    }

    private static func percentLabel(_ value: Double, total: Double) -> String {
        let percent = total > 0 ? value / total * 100 : 0
        return percent.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(percent))%" : String(format: "%.1f%%", percent)
    }
}

// MARK: - Stream (layered smooth areas)

private struct StreamChartCard: View {
    let points: [ChartSpec.Point]
    let style: ChartSpec.Style
    @State private var hovered: ChartSpec.Point?

    private var seriesNames: [String] { orderedUnique(points.map { $0.series ?? "" }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart(Array(points.enumerated()), id: \.offset) { _, point in
                AreaMark(x: .value("Categorie", point.label), y: .value("Valeur", point.value))
                    .foregroundStyle(by: .value("Serie", point.series ?? ""))
                    .interpolationMethod(.catmullRom)
                    .opacity(hovered == nil || hovered == point ? 0.32 : 0.14)
                LineMark(x: .value("Categorie", point.label), y: .value("Valeur", point.value))
                    .foregroundStyle(by: .value("Serie", point.series ?? ""))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                PointMark(x: .value("Categorie", point.label), y: .value("Valeur", point.value))
                    .foregroundStyle(by: .value("Serie", point.series ?? ""))
                    .symbolSize(point == hovered ? 90 : 0)
            }
            .chartLegend(seriesNames.count > 1 ? .visible : .hidden)
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                hovered = closestPoint(to: location, proxy: proxy, geo: geo)
                            case .ended:
                                hovered = nil
                            }
                        }
                }
            }
            .frame(height: 200)
            if let hovered { ChartTooltip(point: hovered) }
        }
    }

    /// Picks the hovered point among ALL series sharing the nearest x
    /// label, not just the first one in `points` -- a multi-series chart
    /// needs the point closest to the cursor vertically too, or every
    /// series but the first is permanently unreachable by hover regardless
    /// of where the mouse is.
    private func closestPoint(to location: CGPoint, proxy: ChartProxy, geo: GeometryProxy) -> ChartSpec.Point? {
        closestPointByLabelAndValue(
            among: points, label: { $0.label }, value: { $0.value },
            to: location, proxy: proxy, geo: geo
        )
    }
}

// MARK: - Gauge (semi-circle arc meter)

private struct GaugeChartCard: View {
    let points: [ChartSpec.Point]
    let style: ChartSpec.Style
    @State private var hovered: ChartSpec.Point?

    var body: some View {
        HStack(spacing: 24) {
            ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                let isHovered = hovered == point
                VStack(spacing: 8) {
                    let fraction = CGFloat(max(0, min(point.value / 100, 1)))
                    ZStack {
                        Circle()
                            .trim(from: 0.5, to: 1.0)
                            .stroke(.white.opacity(0.1), style: StrokeStyle(lineWidth: 14, lineCap: .round))
                        Circle()
                            .trim(from: 0.5, to: 0.5 + fraction * 0.5)
                            .stroke(color(index), style: StrokeStyle(lineWidth: isHovered ? 17 : 14, lineCap: .round))
                    }
                    .frame(width: 140, height: 140)
                    // The round line cap at each end of the trimmed arc
                    // bulges up to lineWidth/2 past the circle's equator
                    // (worst case right at the 9/3 o'clock ends, where the
                    // cap's tangent is vertical) -- clipping at exactly the
                    // equator (70) cut straight through that cap, leaving a
                    // flat-edged stub visible past the intended arc.
                    // 70 + 14 (full stroke width, generous margin) clears it.
                    .frame(height: 84, alignment: .top)
                    .clipped()
                    VStack(spacing: 2) {
                        Text(Self.percentLabel(point.value)).font(.title3.weight(.bold))
                        Text(point.label).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
                .onHover { isHovering in hovered = isHovering ? point : (hovered == point ? nil : hovered) }
            }
        }
    }

    private func color(_ index: Int) -> Color {
        style == .mono ? .cyan : .white.opacity(0.85)
    }

    private static func percentLabel(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(value))%" : String(format: "%.1f%%", value)
    }
}

// MARK: - Waterfall

private struct WaterfallChartCard: View {
    let points: [ChartSpec.Point]
    let style: ChartSpec.Style
    @State private var hovered: ChartSpec.Point?

    /// First and last points are treated as absolute totals (bar starts at
    /// zero); points in between are deltas, each bar floating from the
    /// running cumulative total before it to the total after it -- the
    /// standard "bridge chart" convention, without an extra per-point
    /// field to mark which points are totals.
    private var bars: [(point: ChartSpec.Point, low: Double, high: Double)] {
        guard points.count > 2 else {
            return points.map { (point: $0, low: 0, high: $0.value) }
        }
        var result: [(point: ChartSpec.Point, low: Double, high: Double)] = []
        var running = 0.0
        for (index, point) in points.enumerated() {
            if index == 0 || index == points.count - 1 {
                result.append((point, 0, point.value))
                running = point.value
            } else {
                let newRunning = running + point.value
                result.append((point, min(running, newRunning), max(running, newRunning)))
                running = newRunning
            }
        }
        return result
    }

    private var maxValue: Double { max(bars.map(\.high).max() ?? 1, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 14) {
                ForEach(Array(bars.enumerated()), id: \.offset) { index, bar in
                    VStack(spacing: 6) {
                        GeometryReader { geo in
                            VStack(spacing: 0) {
                                Spacer(minLength: 0).frame(height: geo.size.height * CGFloat(1 - bar.high / maxValue))
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(fill(index: index))
                                    .frame(height: max(geo.size.height * CGFloat((bar.high - bar.low) / maxValue), 4))
                                    .opacity(hovered == nil || hovered == bar.point ? 1 : 0.55)
                                Spacer(minLength: 0)
                            }
                        }
                        Text(bar.point.label).font(.caption2).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onHover { isHovering in hovered = isHovering ? bar.point : (hovered == bar.point ? nil : hovered) }
                }
            }
            .frame(height: 200)
            if let hovered { ChartTooltip(point: hovered) }
        }
    }

    private func fill(index: Int) -> Color {
        let isEndpoint = index == 0 || index == bars.count - 1
        return style == .mono ? .cyan.opacity(isEndpoint ? 1 : 0.65) : .white.opacity(isEndpoint ? 0.9 : 0.6)
    }
}

// MARK: - Polar (concentric partial-arc bars)

private struct PolarChartCard: View {
    let points: [ChartSpec.Point]
    let style: ChartSpec.Style
    @State private var hovered: ChartSpec.Point?

    private var maxValue: Double { max(points.map(\.value).max() ?? 1, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                    let isHovered = hovered == point
                    Circle()
                        .trim(from: 0, to: max(0, min(point.value / maxValue, 1)))
                        .stroke(color(index), style: StrokeStyle(lineWidth: isHovered ? 15 : 12, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(CGFloat(index) * 20)
                        .opacity(hovered == nil || isHovered ? 1 : 0.5)
                        .contentShape(Circle())
                        .onHover { isHovering in hovered = isHovering ? point : (hovered == point ? nil : hovered) }
                }
            }
            .frame(width: 180, height: 180)
            if let hovered { ChartTooltip(point: hovered) }
        }
    }

    private func color(_ index: Int) -> Color {
        let opacities: [Double] = [1.0, 0.7, 0.45, 0.85, 0.55]
        return style == .mono
            ? Color.cyan.opacity(opacities[index % opacities.count])
            : Color.white.opacity(opacities[index % opacities.count] * 0.9)
    }
}

// MARK: - Range band

private struct RangeChartCard: View {
    let points: [ChartSpec.RangePoint]
    let style: ChartSpec.Style
    @State private var hovered: ChartSpec.RangePoint?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart(Array(points.enumerated()), id: \.offset) { _, point in
                AreaMark(x: .value("Categorie", point.label), yStart: .value("Min", point.min), yEnd: .value("Max", point.max))
                    .foregroundStyle(style == .mono ? AnyShapeStyle(Color.cyan.opacity(0.22)) : AnyShapeStyle(ChartFill.dither))
                    .interpolationMethod(.catmullRom)
                LineMark(x: .value("Categorie", point.label), y: .value("Max", point.max))
                    .foregroundStyle(style == .mono ? Color.cyan : Color.white.opacity(0.85))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                LineMark(x: .value("Categorie", point.label), y: .value("Min", point.min))
                    .foregroundStyle(style == .mono ? Color.cyan.opacity(0.6) : Color.white.opacity(0.5))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                if let hovered, hovered.label == point.label {
                    PointMark(x: .value("Categorie", point.label), y: .value("Max", point.max))
                        .foregroundStyle(style == .mono ? Color.cyan : Color.white)
                        .symbolSize(70)
                    PointMark(x: .value("Categorie", point.label), y: .value("Min", point.min))
                        .foregroundStyle(style == .mono ? Color.cyan.opacity(0.6) : Color.white.opacity(0.6))
                        .symbolSize(70)
                }
            }
            .chartLegend(.hidden)
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                hovered = closestPoint(to: location, proxy: proxy, geo: geo)
                            case .ended:
                                hovered = nil
                            }
                        }
                }
            }
            .frame(height: 200)
            if let hovered {
                GenericTooltip(label: hovered.label, value: "\(formatValue(hovered.min)) - \(formatValue(hovered.max))")
            }
        }
    }

    private func closestPoint(to location: CGPoint, proxy: ChartProxy, geo: GeometryProxy) -> ChartSpec.RangePoint? {
        let origin = geo[proxy.plotAreaFrame].origin
        let relativeX = location.x - origin.x
        guard let label = proxy.value(atX: relativeX, as: String.self) else { return nil }
        return points.first { $0.label == label }
    }
}

// MARK: - Table

private struct TableChartCard: View {
    let table: ChartSpec.Table
    let style: ChartSpec.Style

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(table.columns.enumerated()), id: \.offset) { _, column in
                    Text(column)
                        .font(.caption.weight(.bold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.white.opacity(0.06))

            ForEach(Array(table.rows.enumerated()), id: \.offset) { rowIndex, row in
                HStack(spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(cell)
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(rowBackground(rowIndex))
            }
        }
    }

    @ViewBuilder
    private func rowBackground(_ index: Int) -> some View {
        if index % 2 == 0 {
            switch style {
            case .mono: Color.white.opacity(0.03)
            case .dither: Rectangle().fill(ChartFill.dither).opacity(0.18)
            }
        } else {
            Color.clear
        }
    }
}

// MARK: - Shared helpers

private struct ChartTooltip: View {
    let point: ChartSpec.Point

    var body: some View {
        HStack(spacing: 6) {
            Text(point.label).font(.caption.weight(.medium))
            Text(Self.format(point.value)).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private static func format(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(value)) : String(format: "%.2f", value)
    }
}

/// Same chrome as `ChartTooltip`, for the chart types whose data isn't a
/// `ChartSpec.Point` (a heatmap cell, a range band's min/max, a treemap
/// tile's raw value) -- takes pre-formatted strings instead.
private struct GenericTooltip: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.caption.weight(.medium))
            Text(value).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Shared hover-hit-testing for Bar/Line/Stream charts: several series can
/// share the same x label (e.g. 4 lines all keyed by year), so matching on
/// label alone always resolves to whichever series happens to come first
/// in the source array -- the rest silently never receive a hover point.
/// Breaking the tie by vertical distance to the cursor (via each
/// candidate's actual plotted y-position) makes every series reachable.
private func closestPointByLabelAndValue<Point>(
    among points: [Point],
    label: (Point) -> String,
    value: (Point) -> Double,
    to location: CGPoint,
    proxy: ChartProxy,
    geo: GeometryProxy
) -> Point? {
    let origin = geo[proxy.plotAreaFrame].origin
    let relativeX = location.x - origin.x
    let relativeY = location.y - origin.y
    guard let xLabel = proxy.value(atX: relativeX, as: String.self) else { return nil }
    let candidates = points.filter { label($0) == xLabel }
    guard candidates.count > 1 else { return candidates.first }
    return candidates.min { lhs, rhs in
        let lhsY = proxy.position(forY: value(lhs)) ?? .infinity
        let rhsY = proxy.position(forY: value(rhs)) ?? .infinity
        return abs(lhsY - relativeY) < abs(rhsY - relativeY)
    }
}

private func formatValue(_ value: Double) -> String {
    value.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(value)) : String(format: "%.2f", value)
}

private func orderedUnique(_ values: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for value in values where !seen.contains(value) {
        seen.insert(value)
        result.append(value)
    }
    return result
}

@MainActor
private enum ChartFill {
    static func mono(index: Int, of total: Int) -> Color {
        guard total > 1 else { return .cyan }
        let opacities: [Double] = [1.0, 0.7, 0.5, 0.85, 0.6, 0.4]
        return Color.cyan.opacity(opacities[index % opacities.count])
    }

    static var dither: ImagePaint { ImagePaint(image: DitherTile.image, scale: 0.4) }
}

/// A small halftone-style dot tile, rasterized once and reused as an
/// `ImagePaint` fill -- same `Canvas` dot-drawing technique as
/// `ThinkingOrb` (`context.fill(Path(ellipseIn:), with: .color(...))`),
/// just tiled instead of animated. Dot radius follows a 4x4 Bayer matrix so
/// the pattern reads as an even dither rather than a plain grid of same-
/// size dots.
@MainActor
private enum DitherTile {
    static let image: Image = render()

    private static func render() -> Image {
        let bayer: [[Int]] = [
            [0, 8, 2, 10],
            [12, 4, 14, 6],
            [3, 11, 1, 9],
            [15, 7, 13, 5]
        ]
        let tileSize: CGFloat = 12
        let renderer = ImageRenderer(content:
            Canvas { context, size in
                let cell = size.width / 4
                for row in 0..<4 {
                    for col in 0..<4 {
                        let value = Double(bayer[row][col])
                        let radius = cell * 0.22 * (0.4 + value / 16.0)
                        let cx = (Double(col) + 0.5) * cell
                        let cy = (Double(row) + 0.5) * cell
                        let rect = CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2)
                        context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.45)))
                    }
                }
            }
            .frame(width: tileSize, height: tileSize)
        )
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else { return Image(systemName: "circle.grid.3x3") }
        return Image(decorative: cgImage, scale: 2)
    }
}
