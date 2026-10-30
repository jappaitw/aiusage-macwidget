import SwiftUI
import WidgetKit

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot
}

struct UsageTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: Date(), snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        let stored = SharedStore.load()
        completion(UsageEntry(date: Date(), snapshot: stored ?? (context.isPreview ? .preview : .empty)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        // 平常由 host app 在數字變動時呼叫 reloadAllTimelines；這裡 15 分鐘是保底
        let entry = UsageEntry(date: Date(), snapshot: SharedStore.load() ?? .empty)
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
    }
}

struct UsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: UsageEntry

    var body: some View {
        content.widgetURL(URL(string: "aiusage://refresh"))
    }

    @ViewBuilder
    private var content: some View {
        let s = entry.snapshot
        switch family {
        case .systemSmall:
            VStack(alignment: .leading, spacing: 10) {
                CompactProvider(name: "Claude", accent: Brand.claude, snapshot: s.claude)
                CompactProvider(name: "Codex", accent: Brand.codex, snapshot: s.codex)
                Spacer(minLength: 0)
                UpdatedFooter(snapshot: s)
            }
        case .systemMedium:
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 14) {
                    ProviderColumn(name: "Claude", accent: Brand.claude, snapshot: s.claude, maxWindows: 2)
                    ProviderColumn(name: "Codex", accent: Brand.codex, snapshot: s.codex, maxWindows: 2)
                }
                UpdatedFooter(snapshot: s)
            }
        default:
            UsageDashboard(snapshot: s)
        }
    }
}

@main
struct AIUsageWidget: Widget {
    let kind = "AIUsageWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UsageTimelineProvider()) { entry in
            UsageWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("AI 用量")
        .description("Claude 與 Codex 的額度百分比、重置時間和本機 token 統計")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

#Preview(as: .systemLarge) {
    AIUsageWidget()
} timeline: {
    UsageEntry(date: .now, snapshot: .preview)
}
