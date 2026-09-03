import XCTest
@testable import Jarvis

final class ChartSpecTests: XCTestCase {

    // MARK: - Valid charts

    func testParsesValidBarChart() {
        let json = """
        {"type": "bar", "style": "mono", "title": "Repartition des couts",
         "data": [{"label": "Hebergement", "value": 420}, {"label": "API", "value": 180}]}
        """
        guard let spec = ChartSpec.parse(from: json) else { return XCTFail("expected a parsed spec") }
        XCTAssertEqual(spec.type, .bar)
        XCTAssertEqual(spec.style, .mono)
        XCTAssertEqual(spec.title, "Repartition des couts")
        guard case .points(let points) = spec.data else { return XCTFail("expected points data") }
        XCTAssertEqual(points, [
            .init(label: "Hebergement", value: 420, series: nil),
            .init(label: "API", value: 180, series: nil)
        ])
    }

    func testParsesValidLineChartWithSeries() {
        let json = """
        {"type": "line", "style": "dither",
         "data": [{"label": "Jan", "value": 10, "series": "Ventes"}, {"label": "Fev", "value": 14, "series": "Ventes"}]}
        """
        guard let spec = ChartSpec.parse(from: json) else { return XCTFail("expected a parsed spec") }
        XCTAssertEqual(spec.type, .line)
        guard case .points(let points) = spec.data else { return XCTFail("expected points data") }
        XCTAssertEqual(points.map(\.series), ["Ventes", "Ventes"])
    }

    func testParsesValidPieChart() {
        let json = """
        {"type": "pie", "style": "mono",
         "data": [{"label": "iOS", "value": 60}, {"label": "macOS", "value": 40}]}
        """
        XCTAssertNotNil(ChartSpec.parse(from: json))
    }

    func testParsesValidTable() {
        let json = """
        {"type": "table", "style": "mono", "title": "Comparatif",
         "data": {"columns": ["Fichier", "Lignes", "Statut"], "rows": [["Main.swift", "120", "OK"], ["short"]]}}
        """
        guard let spec = ChartSpec.parse(from: json) else { return XCTFail("expected a parsed spec") }
        guard case .table(let table) = spec.data else { return XCTFail("expected table data") }
        XCTAssertEqual(table.columns, ["Fichier", "Lignes", "Statut"])
        XCTAssertEqual(table.rows.count, 2)
        XCTAssertEqual(table.rows[1], ["short"]) // jagged row decodes without crashing
    }

    // MARK: - New chart types

    func testParsesValidRadar() {
        let json = """
        {"type": "radar", "style": "mono", "title": "Score",
         "data": [{"label": "Speed", "value": 80, "series": "A"}, {"label": "Memory", "value": 60, "series": "A"}]}
        """
        guard let spec = ChartSpec.parse(from: json) else { return XCTFail("expected a parsed spec") }
        guard case .points(let points) = spec.data else { return XCTFail("expected points data") }
        XCTAssertEqual(points.count, 2)
    }

    func testParsesValidRadial() {
        let json = """
        {"type": "radial", "style": "mono",
         "data": [{"label": "CPU", "value": 90}, {"label": "GPU", "value": 45}]}
        """
        XCTAssertNotNil(ChartSpec.parse(from: json))
    }

    func testParsesValidFunnel() {
        let json = """
        {"type": "funnel", "style": "mono",
         "data": [{"label": "Visits", "value": 1000}, {"label": "Signup", "value": 400}]}
        """
        XCTAssertNotNil(ChartSpec.parse(from: json))
    }

    func testParsesValidHeatmap() {
        let json = """
        {"type": "heatmap", "style": "mono", "title": "Activity",
         "data": {"rows": ["Mon", "Tue"], "columns": ["9h", "10h"], "values": [[1, 2], [3, 4]]}}
        """
        guard let spec = ChartSpec.parse(from: json) else { return XCTFail("expected a parsed spec") }
        guard case .heatmap(let heatmap) = spec.data else { return XCTFail("expected heatmap data") }
        XCTAssertEqual(heatmap.rows, ["Mon", "Tue"])
        XCTAssertEqual(heatmap.values, [[1, 2], [3, 4]])
    }

    func testHeatmapWithMismatchedRowWidthReturnsNil() {
        let json = """
        {"type": "heatmap", "style": "mono",
         "data": {"rows": ["Mon"], "columns": ["9h", "10h"], "values": [[1]]}}
        """
        XCTAssertNil(ChartSpec.parse(from: json))
    }

    func testHeatmapWithMismatchedRowCountReturnsNil() {
        let json = """
        {"type": "heatmap", "style": "mono",
         "data": {"rows": ["Mon", "Tue"], "columns": ["9h"], "values": [[1]]}}
        """
        XCTAssertNil(ChartSpec.parse(from: json))
    }

    func testParsesValidSparkline() {
        let json = """
        {"type": "sparkline", "style": "mono",
         "data": [{"label": "CPU Temp", "value": "42C", "trend": [40, 41, 42]}]}
        """
        guard let spec = ChartSpec.parse(from: json) else { return XCTFail("expected a parsed spec") }
        guard case .sparkline(let rows) = spec.data else { return XCTFail("expected sparkline data") }
        XCTAssertEqual(rows.first?.trend, [40, 41, 42])
    }

    func testParsesValidBubble() {
        let json = """
        {"type": "bubble", "style": "mono",
         "data": [{"label": "A", "x": 10, "y": 20, "size": 5}]}
        """
        guard let spec = ChartSpec.parse(from: json) else { return XCTFail("expected a parsed spec") }
        guard case .bubble(let points) = spec.data else { return XCTFail("expected bubble data") }
        XCTAssertEqual(points.first?.size, 5)
    }

    func testParsesValidTreemap() {
        let json = """
        {"type": "treemap", "style": "mono",
         "data": [{"label": "Storage", "value": 45}, {"label": "Compute", "value": 30}]}
        """
        XCTAssertNotNil(ChartSpec.parse(from: json))
    }

    func testParsesValidStream() {
        let json = """
        {"type": "stream", "style": "mono",
         "data": [{"label": "Jan", "value": 10, "series": "A"}, {"label": "Feb", "value": 14, "series": "A"}]}
        """
        XCTAssertNotNil(ChartSpec.parse(from: json))
    }

    func testParsesValidGauge() {
        let json = """
        {"type": "gauge", "style": "mono", "data": [{"label": "Load", "value": 78}]}
        """
        XCTAssertNotNil(ChartSpec.parse(from: json))
    }

    func testParsesValidWaterfall() {
        let json = """
        {"type": "waterfall", "style": "mono",
         "data": [{"label": "Start", "value": 45}, {"label": "Inflow", "value": 30}, {"label": "Net", "value": 60}]}
        """
        XCTAssertNotNil(ChartSpec.parse(from: json))
    }

    func testParsesValidPolar() {
        let json = """
        {"type": "polar", "style": "mono",
         "data": [{"label": "A", "value": 90}, {"label": "B", "value": 45}]}
        """
        XCTAssertNotNil(ChartSpec.parse(from: json))
    }

    func testParsesValidRange() {
        let json = """
        {"type": "range", "style": "mono",
         "data": [{"label": "Mon", "min": 20, "max": 60}, {"label": "Tue", "min": 25, "max": 70}]}
        """
        guard let spec = ChartSpec.parse(from: json) else { return XCTFail("expected a parsed spec") }
        guard case .range(let points) = spec.data else { return XCTFail("expected range data") }
        XCTAssertEqual(points.first?.min, 20)
        XCTAssertEqual(points.first?.max, 60)
    }

    func testRangeDataMissingMaxReturnsNil() {
        let json = """
        {"type": "range", "style": "mono", "data": [{"label": "Mon", "min": 20}]}
        """
        XCTAssertNil(ChartSpec.parse(from: json))
    }

    func testBubbleDataMissingSizeReturnsNil() {
        // A bubble point without "size" must fail -- confirms "type"
        // (not shape-sniffing) decides which payload shape is expected,
        // since {"label","x","y"} alone would otherwise decode fine as
        // something else entirely.
        let json = """
        {"type": "bubble", "style": "mono", "data": [{"label": "A", "x": 10, "y": 20}]}
        """
        XCTAssertNil(ChartSpec.parse(from: json))
    }

    // MARK: - Graceful failure

    func testMalformedJSONReturnsNil() {
        XCTAssertNil(ChartSpec.parse(from: "{not json"))
        XCTAssertNil(ChartSpec.parse(from: ""))
    }

    func testTypeDataMismatchReturnsNil() {
        let barWithTableData = """
        {"type": "bar", "style": "mono", "data": {"columns": ["a"], "rows": [["1"]]}}
        """
        XCTAssertNil(ChartSpec.parse(from: barWithTableData))

        let tableWithPointsData = """
        {"type": "table", "style": "mono", "data": [{"label": "a", "value": 1}]}
        """
        XCTAssertNil(ChartSpec.parse(from: tableWithPointsData))
    }

    func testMissingRequiredFieldReturnsNil() {
        let missingValue = """
        {"type": "bar", "style": "mono", "data": [{"label": "Hebergement"}]}
        """
        XCTAssertNil(ChartSpec.parse(from: missingValue))

        let missingType = """
        {"style": "mono", "data": [{"label": "Hebergement", "value": 1}]}
        """
        XCTAssertNil(ChartSpec.parse(from: missingType))
    }

    func testUnknownStyleOrTypeReturnsNil() {
        let unknownStyle = """
        {"type": "bar", "style": "neon", "data": [{"label": "Hebergement", "value": 1}]}
        """
        XCTAssertNil(ChartSpec.parse(from: unknownStyle))

        let unknownType = """
        {"type": "scatter", "style": "mono", "data": [{"label": "Hebergement", "value": 1}]}
        """
        XCTAssertNil(ChartSpec.parse(from: unknownType))
    }
}
