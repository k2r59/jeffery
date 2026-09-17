import WidgetKit
import SwiftUI
import ActivityKit

@main
struct JeffreyWidgetsBundle: WidgetBundle {
    var body: some Widget {
        JeffreyLiveActivity()
    }
}

private let citron = Color(red: 0.831, green: 1.0, blue: 0.294)
private let creme = Color(red: 0.949, green: 0.941, blue: 0.906)
private let sauge = Color(red: 0.592, green: 0.643, blue: 0.549)
private let encre = Color(red: 0.063, green: 0.078, blue: 0.067)

struct JeffreyLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: JeffreyActivityAttributes.self) { context in
            // Écran verrouillé iPhone, Smart Stack Apple Watch.
            LockView(context: context)
                .activityBackgroundTint(encre)
                .activitySystemActionForegroundColor(citron)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image("jeffrey-symbole-citron").resizable().scaledToFit().frame(width: 28, height: 28)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    timerText(context.state).font(.system(size: 22, weight: .black, design: .rounded).monospacedDigit()).foregroundStyle(creme)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.kindLabel.uppercased()).font(.system(size: 11, weight: .heavy)).foregroundStyle(sauge)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    bottomLine(context)
                }
            } compactLeading: {
                Image("jeffrey-symbole-citron").resizable().scaledToFit().frame(width: 18, height: 18)
            } compactTrailing: {
                timerText(context.state).font(.system(size: 13, weight: .bold).monospacedDigit()).foregroundStyle(citron)
            } minimal: {
                Image("jeffrey-symbole-citron").resizable().scaledToFit().frame(width: 16, height: 16)
            }
        }
        .supplementalActivityFamilies([.small])
    }

    @ViewBuilder
    private func timerText(_ s: JeffreyActivityAttributes.ContentState) -> some View {
        if s.paused {
            Text(formatted(s.elapsedFrozen))
        } else {
            Text(timerInterval: s.startedAt...Date(timeIntervalSinceNow: 12 * 3600), countsDown: false)
        }
    }

    @ViewBuilder
    private func bottomLine(_ context: ActivityViewContext<JeffreyActivityAttributes>) -> some View {
        let s = context.state
        HStack(spacing: 12) {
            if let hr = s.heartRate { Label("\(hr)", systemImage: "heart.fill").foregroundStyle(creme) }
            if let d = s.distanceMeters { Text(String(format: "%.2f km", d / 1000)).foregroundStyle(creme) }
            if let r = s.remaining { Text(r).foregroundStyle(sauge) }
            Spacer()
            Text(stateLabel(s.coachState)).foregroundStyle(citron)
        }
        .font(.system(size: 12, weight: .bold).monospacedDigit())
    }

    private func stateLabel(_ st: String) -> String {
        switch st { case "parle": return "Jeffrey te parle"; case "ecoute": return "Jeffrey écoute"; default: return "Jeffrey arrive" }
    }

    private func formatted(_ t: TimeInterval) -> String {
        let s = Int(t); return String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct LockView: View {
    @Environment(\.activityFamily) private var family
    let context: ActivityViewContext<JeffreyActivityAttributes>

    var body: some View {
        let s = context.state
        if family == .small {
            // Smart Stack de l'Apple Watch : compact.
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image("jeffrey-symbole-citron").resizable().scaledToFit().frame(width: 16, height: 16)
                    Text(context.attributes.kindLabel.uppercased()).font(.system(size: 10, weight: .heavy)).foregroundStyle(sauge)
                    Spacer()
                    if let hr = s.heartRate { Text("\(hr) bpm").font(.system(size: 11, weight: .bold)).foregroundStyle(creme) }
                }
                HStack(alignment: .firstTextBaseline) {
                    timer(s).font(.system(size: 26, weight: .black, design: .rounded).monospacedDigit()).foregroundStyle(creme)
                    Spacer()
                    if let tl = s.timerLabel, let te = s.timerEndsAt {
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(tl).font(.system(size: 9, weight: .bold)).foregroundStyle(sauge)
                            Text(timerInterval: Date()...te, countsDown: true).font(.system(size: 14, weight: .black).monospacedDigit()).foregroundStyle(citron)
                        }
                    } else if let r = s.remaining {
                        Text(r).font(.system(size: 11, weight: .semibold)).foregroundStyle(sauge)
                    }
                }
                if let line = s.lastLine {
                    Text(line).font(.system(size: 10, weight: .medium)).foregroundStyle(creme).lineLimit(2)
                }
            }
            .padding(10)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image("jeffrey-logo-creme").resizable().scaledToFit().frame(height: 18)
                    Spacer()
                    Text(context.attributes.kindLabel.uppercased()).font(.system(size: 11, weight: .heavy)).foregroundStyle(sauge)
                }
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    timer(s).font(.system(size: 40, weight: .black, design: .rounded).monospacedDigit()).foregroundStyle(creme)
                    if let hr = s.heartRate { Label("\(hr) bpm", systemImage: "heart.fill").font(.system(size: 14, weight: .bold)).foregroundStyle(creme) }
                    if let d = s.distanceMeters { Text(String(format: "%.2f km", d / 1000)).font(.system(size: 14, weight: .bold).monospacedDigit()).foregroundStyle(creme) }
                    Spacer()
                }
                if let g = s.goalLabel {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("Objectif · \(g)").font(.system(size: 11, weight: .bold)).foregroundStyle(creme)
                            Spacer()
                            Text(s.remaining ?? "").font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(sauge)
                        }
                        ProgressView(value: min(1, s.progress)).tint(citron)
                    }
                }
                if let tl = s.timerLabel, let te = s.timerEndsAt {
                    HStack {
                        Image(systemName: "timer").foregroundStyle(citron)
                        Text(tl.capitalized).font(.system(size: 12, weight: .bold)).foregroundStyle(creme)
                        Spacer()
                        Text(timerInterval: Date()...te, countsDown: true).font(.system(size: 18, weight: .black).monospacedDigit()).foregroundStyle(citron)
                    }
                }
                if let line = s.lastLine {
                    Text(line).font(.system(size: 12, weight: .medium)).foregroundStyle(creme).lineLimit(2)
                }
            }
            .padding(14)
        }
    }

    @ViewBuilder
    private func timer(_ s: JeffreyActivityAttributes.ContentState) -> some View {
        if s.paused {
            let t = Int(s.elapsedFrozen)
            Text(String(format: "%d:%02d", t / 60, t % 60))
        } else {
            Text(timerInterval: s.startedAt...Date(timeIntervalSinceNow: 12 * 3600), countsDown: false)
        }
    }
}
