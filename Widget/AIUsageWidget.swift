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
        let useStored = stored.map { !$0.providers.isEmpty } ?? false
        completion(UsageEntry(date: Date(), snapshot: useStored ? stored! : (context.isPreview ? .preview : .empty)))
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
        if s.providers.isEmpty {
            EmptyProvidersView()
        } else {
            switch family {
            case .systemSmall:
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(s.providers.prefix(2))) { provider in
                        CompactProvider(provider: provider)
                    }
                    Spacer(minLength: 0)
                    UpdatedFooter(snapshot: s)
                }
            case .systemMedium:
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(s.providers.prefix(3))) { provider in
                        ProviderRow(provider: provider, maxWindows: 2)
                    }
                    Spacer(minLength: 0)
                }
            default:
                UsageDashboard(snapshot: s, maxProviders: s.providers.count > 4 ? 6 : 4,
                               maxWindows: 2, showChart: s.providers.count <= 4)
            }
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
        .description("自動偵測 Claude、Codex、Cursor、Copilot、Gemini、Antigravity 的額度和重置時間")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

#Preview(as: .systemLarge) {
    AIUsageWidget()
} timeline: {
    UsageEntry(date: .now, snapshot: .preview)
}

#Preview(as: .systemMedium) {
    AIUsageWidget()
} timeline: {
    UsageEntry(date: .now, snapshot: .preview)
}
