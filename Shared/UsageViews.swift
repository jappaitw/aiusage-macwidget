import SwiftUI
import Charts
import WidgetKit

enum Brand {
    static func color(for id: String) -> Color {
        switch id {
        case "claude": return Color(red: 0.85, green: 0.47, blue: 0.34)
        case "codex": return Color(red: 0.29, green: 0.56, blue: 0.96)
        case "cursor": return Color(red: 0.55, green: 0.55, blue: 0.60)
        case "copilot": return Color(red: 0.54, green: 0.34, blue: 0.90)
        case "gemini": return Color(red: 0.96, green: 0.71, blue: 0.0)
        case "antigravity": return Color(red: 0.20, green: 0.66, blue: 0.33)
        default: return .teal
        }
    }

    static func level(_ percent: Double, accent: Color) -> Color {
        if percent >= 90 { return .red }
        if percent >= 70 { return .orange }
        return accent
    }
}

/// 桌面 widget 的毛玻璃（vibrant）狀態會把自訂顏色去飽和成幾乎看不見的材質。
/// 這時改用 primary 的不透明度階層（系統內建 widget 的做法），對比交給系統的 vibrant 材質保證；
/// 全彩狀態和選單列面板則照用品牌色。
struct Palette {
    var vibrant: Bool

    init(_ mode: WidgetRenderingMode) { vibrant = mode == .vibrant }

    func brand(_ id: String) -> Color {
        vibrant ? Color.primary.opacity(Self.opacities[id] ?? 0.8) : Brand.color(for: id)
    }

    /// 進度條：全彩時依用量變紅／橘，vibrant 時維持該服務的階層色
    func level(_ percent: Double, id: String) -> Color {
        vibrant ? brand(id) : Brand.level(percent, accent: Brand.color(for: id))
    }

    /// 警示色（爆量的紅色百分比、錯誤的橘色驚嘆號）
    func alert(_ base: Color) -> Color { vibrant ? .primary : base }

    /// 同一張疊加長條圖裡區分服務用的不透明度
    private static let opacities: [String: Double] = [
        "claude": 1.0, "codex": 0.55, "cursor": 0.4,
        "copilot": 0.75, "gemini": 0.6, "antigravity": 0.45,
    ]
}

struct UsageBar: View {
    var fraction: Double
    var color: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let clamped = min(max(fraction, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(color)
                    .frame(width: clamped > 0 ? max(geo.size.width * clamped, height) : 0)
            }
        }
        .frame(height: height)
    }
}

struct ProviderHeader: View {
    var provider: ProviderSnapshot
    var showReset = true
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let palette = Palette(renderingMode)
        HStack(spacing: 5) {
            Circle().fill(palette.brand(provider.id)).frame(width: 7, height: 7)
            Text(provider.name).font(.caption.weight(.semibold)).lineLimit(1)
            if let plan = Format.plan(provider.plan) {
                Text(plan).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 2)
            if provider.error != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(palette.alert(.orange))
            } else if showReset, let reset = provider.windows.first?.resetsAt, reset > Date() {
                (Text("重置 ") + Text(reset, style: .relative))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }
}

/// 一個視窗：標籤＋百分比＋進度條
struct MiniWindow: View {
    var window: UsageWindow
    var providerID: String
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let palette = Palette(renderingMode)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Text(window.label).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 2)
                Text(Format.percent(window.usedPercent))
                    .monospacedDigit()
                    .fontWeight(.semibold)
                    .foregroundStyle(window.usedPercent >= 90 ? palette.alert(.red) : Color.primary)
            }
            .font(.caption2)
            UsageBar(fraction: window.usedPercent / 100,
                     color: palette.level(window.usedPercent, id: providerID), height: 5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 一個服務一列：標題＋最多 maxWindows 個視窗（每列兩個）
struct ProviderRow: View {
    var provider: ProviderSnapshot
    var maxWindows = 2
    var showReset = true

    private var rows: [[UsageWindow]] {
        let shown = Array(provider.windows.prefix(maxWindows))
        return stride(from: 0, to: shown.count, by: 2).map { Array(shown[$0..<min($0 + 2, shown.count)]) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProviderHeader(provider: provider, showReset: showReset)
            if provider.windows.isEmpty {
                Text(provider.error ?? "尚無資料")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, pair in
                    HStack(spacing: 12) {
                        ForEach(pair) { window in
                            MiniWindow(window: window, providerID: provider.id)
                        }
                        if pair.count == 1 { Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                    }
                }
            }
        }
    }
}

/// 精簡版（小尺寸 widget）：第一個視窗的大數字＋第二個視窗一行
struct CompactProvider: View {
    var provider: ProviderSnapshot
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let palette = Palette(renderingMode)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Circle().fill(palette.brand(provider.id)).frame(width: 7, height: 7)
                Text(provider.name).font(.caption.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 0)
                if let first = provider.windows.first {
                    Text(Format.percent(first.usedPercent))
                        .font(.title3.weight(.bold).monospacedDigit())
                        .foregroundStyle(first.usedPercent >= 90 ? palette.alert(.red) : Color.primary)
                } else {
                    Image(systemName: provider.error == nil ? "minus" : "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(provider.error == nil ? Color.secondary : palette.alert(.orange))
                }
            }
            if let first = provider.windows.first {
                UsageBar(fraction: first.usedPercent / 100,
                         color: palette.level(first.usedPercent, id: provider.id))
                HStack(spacing: 4) {
                    if let reset = first.resetsAt, reset > Date() {
                        Text(reset, style: .relative)
                    } else {
                        Text(first.label)
                    }
                    Spacer(minLength: 2)
                    if provider.windows.count > 1 {
                        let second = provider.windows[1]
                        Text("\(second.label) \(Format.percent(second.usedPercent))")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
    }
}

struct TokenChart: View {
    var providers: [ProviderSnapshot]
    @Environment(\.widgetRenderingMode) private var renderingMode

    private struct Point: Identifiable {
        var id: String { "\(source)-\(day.timeIntervalSince1970)" }
        let day: Date
        let tokens: Int
        let source: String
    }

    private var withStats: [ProviderSnapshot] { providers.filter(\.hasTokenStats) }

    private var points: [Point] {
        withStats.flatMap { p in p.daily.map { Point(day: $0.day, tokens: $0.tokens, source: p.name) } }
    }

    var body: some View {
        Chart(points) { point in
            BarMark(x: .value("日期", point.day, unit: .day),
                    y: .value("Tokens", point.tokens))
                .foregroundStyle(by: .value("來源", point.source))
                .cornerRadius(2)
        }
        .chartForegroundStyleScale(domain: withStats.map(\.name),
                                   range: withStats.map { Palette(renderingMode).brand($0.id) })
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisValueLabel(format: .dateTime.weekday(.narrow))
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let n = value.as(Int.self) { Text(Format.tokens(n)) }
                }
            }
        }
    }
}

struct TokenSummary: View {
    var providers: [ProviderSnapshot]
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        HStack(spacing: 10) {
            ForEach(providers.filter(\.hasTokenStats)) { p in
                HStack(spacing: 3) {
                    Circle().fill(Palette(renderingMode).brand(p.id)).frame(width: 5, height: 5)
                    Text("今日 \(Format.tokens(p.todayTokens)) · 7天 \(Format.tokens(p.weekTokens))")
                        .monospacedDigit()
                }
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

struct ModelList: View {
    var providers: [ProviderSnapshot]
    var limit = 4
    @Environment(\.widgetRenderingMode) private var renderingMode

    private struct Row: Identifiable {
        var id: String { "\(source)-\(model)" }
        let source: String
        let model: String
        let tokens: Int
    }

    private var rows: [Row] {
        let all = providers.flatMap { p in p.models.map { Row(source: p.id, model: $0.model, tokens: $0.tokens) } }
        return Array(all.sorted { $0.tokens > $1.tokens }.prefix(limit))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(rows) { row in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 1.5).fill(Palette(renderingMode).brand(row.source)).frame(width: 3, height: 10)
                    Text(row.model).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Format.tokens(row.tokens)).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.caption2)
            }
        }
    }
}

struct UpdatedFooter: View {
    var snapshot: UsageSnapshot

    private static let versionSuffix: String =
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            .map { " · v\($0)" } ?? ""

    var body: some View {
        Group {
            if snapshot.generatedAt == .distantPast {
                Text("尚未更新" + Self.versionSuffix)
            } else {
                Text("更新於 ") + Text(snapshot.generatedAt, style: .time) + Text(Self.versionSuffix)
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
}

struct EmptyProvidersView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("AI 用量").font(.caption.weight(.semibold))
            Text("開啟 AI Usage app 後，會自動偵測這台 Mac 上的 Claude Code、Codex、Cursor、Copilot、Gemini、Antigravity")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// 大尺寸 widget 和選單列面板共用
struct UsageDashboard: View {
    var snapshot: UsageSnapshot
    var maxProviders = 6
    var maxWindows = 2
    var showChart = true
    var showModels = false

    var body: some View {
        let shown = Array(snapshot.providers.prefix(maxProviders))
        VStack(alignment: .leading, spacing: 9) {
            if shown.isEmpty {
                EmptyProvidersView()
            } else {
                ForEach(shown) { provider in
                    ProviderRow(provider: provider, maxWindows: maxWindows)
                }
            }
            if showChart, shown.contains(where: \.hasTokenStats) {
                Divider()
                Text("本機 token 統計 · 只含這台 Mac 的 CLI 用量")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                TokenChart(providers: shown).frame(minHeight: 60, maxHeight: 110)
                TokenSummary(providers: shown)
            }
            if showModels { ModelList(providers: shown) }
            Spacer(minLength: 0)
            UpdatedFooter(snapshot: snapshot)
        }
    }
}
