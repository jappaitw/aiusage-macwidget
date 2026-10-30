import SwiftUI
import Charts

enum Brand {
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)
    static let codex = Color(red: 0.29, green: 0.56, blue: 0.96)

    static func level(_ percent: Double, accent: Color) -> Color {
        if percent >= 90 { return .red }
        if percent >= 70 { return .orange }
        return accent
    }
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

struct WindowRow: View {
    var window: UsageWindow
    var accent: Color
    var showReset = true

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(window.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text(Format.percent(window.usedPercent))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(window.usedPercent >= 90 ? Color.red : Color.primary)
            }
            UsageBar(fraction: window.usedPercent / 100,
                     color: Brand.level(window.usedPercent, accent: accent))
            if showReset, let reset = window.resetsAt, reset > Date() {
                (Text("重置 ") + Text(reset, style: .relative))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }
}

struct ProviderHeader: View {
    var name: String
    var accent: Color
    var snapshot: ProviderSnapshot

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(accent).frame(width: 7, height: 7)
            Text(name).font(.subheadline.weight(.semibold))
            if let plan = Format.plan(snapshot.plan) {
                Text(plan)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if snapshot.error != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }
}

struct ProviderColumn: View {
    var name: String
    var accent: Color
    var snapshot: ProviderSnapshot
    var maxWindows = 3
    var showReset = true
    var showTokens = true

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ProviderHeader(name: name, accent: accent, snapshot: snapshot)
            if snapshot.windows.isEmpty {
                Text(snapshot.error ?? "尚無資料")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            } else {
                ForEach(Array(snapshot.windows.prefix(maxWindows))) { window in
                    WindowRow(window: window, accent: accent, showReset: showReset)
                }
            }
            Spacer(minLength: 0)
            if showTokens {
                HStack(spacing: 4) {
                    Text("今日")
                    Text(Format.tokens(snapshot.todayTokens)).monospacedDigit()
                    Text("· 7天")
                    Text(Format.tokens(snapshot.weekTokens)).monospacedDigit()
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 精簡版：只顯示第一個視窗的大數字＋第二個視窗一行
struct CompactProvider: View {
    var name: String
    var accent: Color
    var snapshot: ProviderSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Circle().fill(accent).frame(width: 7, height: 7)
                Text(name).font(.caption.weight(.semibold))
                Spacer(minLength: 0)
                if let first = snapshot.windows.first {
                    Text(Format.percent(first.usedPercent))
                        .font(.title3.weight(.bold).monospacedDigit())
                        .foregroundStyle(first.usedPercent >= 90 ? Color.red : Color.primary)
                } else {
                    Image(systemName: snapshot.error == nil ? "minus" : "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(snapshot.error == nil ? Color.secondary : Color.orange)
                }
            }
            if let first = snapshot.windows.first {
                UsageBar(fraction: first.usedPercent / 100,
                         color: Brand.level(first.usedPercent, accent: accent))
                HStack(spacing: 4) {
                    if let reset = first.resetsAt, reset > Date() {
                        Text(reset, style: .relative)
                    } else {
                        Text(first.label)
                    }
                    Spacer(minLength: 2)
                    if snapshot.windows.count > 1 {
                        let second = snapshot.windows[1]
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
    var claude: [DayTokens]
    var codex: [DayTokens]

    private struct Point: Identifiable {
        var id: String { "\(source)-\(day.timeIntervalSince1970)" }
        let day: Date
        let tokens: Int
        let source: String
    }

    private var points: [Point] {
        claude.map { Point(day: $0.day, tokens: $0.tokens, source: "Claude") }
            + codex.map { Point(day: $0.day, tokens: $0.tokens, source: "Codex") }
    }

    var body: some View {
        Chart(points) { point in
            BarMark(x: .value("日期", point.day, unit: .day),
                    y: .value("Tokens", point.tokens))
                .foregroundStyle(by: .value("來源", point.source))
                .cornerRadius(2)
        }
        .chartForegroundStyleScale(["Claude": Brand.claude, "Codex": Brand.codex])
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

struct ModelList: View {
    var snapshot: UsageSnapshot
    var limit = 4

    private struct Row: Identifiable {
        var id: String { "\(source)-\(model)" }
        let source: String
        let model: String
        let tokens: Int
        let color: Color
    }

    private var rows: [Row] {
        let all = snapshot.claude.models.map { Row(source: "claude", model: $0.model, tokens: $0.tokens, color: Brand.claude) }
            + snapshot.codex.models.map { Row(source: "codex", model: $0.model, tokens: $0.tokens, color: Brand.codex) }
        return Array(all.sorted { $0.tokens > $1.tokens }.prefix(limit))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(rows) { row in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 1.5).fill(row.color).frame(width: 3, height: 10)
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

    var body: some View {
        Group {
            if snapshot.generatedAt == .distantPast {
                Text("尚未更新")
            } else {
                Text("更新於 ") + Text(snapshot.generatedAt, style: .time)
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
}

/// 大尺寸 widget 和選單列面板共用
struct UsageDashboard: View {
    var snapshot: UsageSnapshot
    var showChart = true
    var showModels = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 16) {
                ProviderColumn(name: "Claude", accent: Brand.claude, snapshot: snapshot.claude)
                ProviderColumn(name: "Codex", accent: Brand.codex, snapshot: snapshot.codex)
            }
            .fixedSize(horizontal: false, vertical: true)
            if showChart {
                VStack(alignment: .leading, spacing: 4) {
                    Text("最近 7 天 tokens").font(.caption2).foregroundStyle(.secondary)
                    TokenChart(claude: snapshot.claude.daily, codex: snapshot.codex.daily)
                        .frame(minHeight: 70)
                }
            }
            if showModels { ModelList(snapshot: snapshot) }
            UpdatedFooter(snapshot: snapshot)
        }
    }
}
