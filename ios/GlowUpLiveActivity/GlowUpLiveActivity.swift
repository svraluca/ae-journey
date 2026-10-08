import ActivityKit
import SwiftUI
import WidgetKit

private let appGroupId = "group.com.svapps.aestheticpass"

struct LiveActivitiesAppAttributes: ActivityAttributes, Identifiable {
    public typealias LiveDeliveryData = ContentState

    public struct ContentState: Codable, Hashable {}

    var id = UUID()
}

extension LiveActivitiesAppAttributes {
    func prefixedKey(_ key: String) -> String {
        "\(id)_\(key)"
    }
}

private struct GlowUpLiveActivityView: View {
    let context: ActivityViewContext<LiveActivitiesAppAttributes>

    private var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupId) ?? .standard
    }

    private func text(_ key: String, fallback: String) -> String {
        defaults.string(forKey: context.attributes.prefixedKey(key)) ?? fallback
    }

    private var progress: Int {
        defaults.integer(forKey: context.attributes.prefixedKey("progress"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(text("brand", fallback: "Glow Up AI"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(text("eta", fallback: ""))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color(red: 0.09, green: 0.56, blue: 0.70))
            }

            Text(text("headline", fallback: "Creating your glow-up"))
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
                .lineLimit(2)

            Text(text("detail", fallback: "Analyzing your face"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            ProgressView(value: Double(max(progress, 0)), total: 100)
                .tint(Color(red: 0.13, green: 0.83, blue: 0.93))
        }
        .padding(16)
        .activityBackgroundTint(Color.white)
        .activitySystemActionForegroundColor(Color.black)
    }
}

@available(iOS 16.1, *)
struct GlowUpLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LiveActivitiesAppAttributes.self) { context in
            GlowUpLiveActivityView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(text("brand", fallback: "Glow Up", context: context))
                        .font(.caption.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(text("eta", fallback: "", context: context))
                        .font(.caption.weight(.bold))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(text("headline", fallback: "Glow-up", context: context))
                        .font(.caption)
                        .lineLimit(1)
                }
            } compactLeading: {
                Image(systemName: "sparkles")
            } compactTrailing: {
                Text("\(progress(context: context))%")
                    .font(.caption2.weight(.bold))
            } minimal: {
                Image(systemName: "sparkles")
            }
        }
    }

    private func text(_ key: String, fallback: String, context: ActivityViewContext<LiveActivitiesAppAttributes>) -> String {
        let defaults = UserDefaults(suiteName: appGroupId) ?? .standard
        return defaults.string(forKey: context.attributes.prefixedKey(key)) ?? fallback
    }

    private func progress(context: ActivityViewContext<LiveActivitiesAppAttributes>) -> Int {
        let defaults = UserDefaults(suiteName: appGroupId) ?? .standard
        return defaults.integer(forKey: context.attributes.prefixedKey("progress"))
    }
}

@main
struct GlowUpLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        if #available(iOS 16.1, *) {
            GlowUpLiveActivity()
        }
    }
}
