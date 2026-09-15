import SwiftUI
import MapKit

struct SessionEndView: View {
    @Environment(\.dismiss) private var dismiss
    @State var summary: SessionSummary
    @AppStorage(Prefs.userName) private var userName: String = ""
    @State private var route: LocalRoute?

    private var coordinates: [CLLocationCoordinate2D] {
        route?.locations.filter { $0.horizontalAccuracy < 60 }.map(\.coordinate) ?? []
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            RadialGradient(colors: [Theme.lime.opacity(0.22), .clear], center: .top, startRadius: 0, endRadius: 380).ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 22) {
                    JeffreyMark(size: 46).padding(.top, 8)
                    VStack(spacing: 6) {
                        (Text("Bien joué, ") + Text(userName.isEmpty ? "champion" : userName).foregroundStyle(Theme.lime) + Text("."))
                            .font(.display(30, weight: .black)).foregroundStyle(.white)
                        Text(Formatters.elapsed(summary.elapsed))
                            .font(.display(64, weight: .black).monospacedDigit()).foregroundStyle(.white)
                        HStack(spacing: 14) {
                            if let d = summary.distance { Text(Formatters.distance(d)) }
                            if let hr = summary.averageHeartRate { Text("\(Int(hr)) bpm moy.") }
                            if let m = summary.maxHeartRate { Text("\(Int(m)) max") }
                        }
                        .font(.system(size: 15, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.muted)
                    }
                    if coordinates.count >= 2 {
                        Map {
                            MapPolyline(coordinates: coordinates)
                                .stroke(Theme.lime, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                        }
                        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
                        .frame(height: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    }
                    VStack(spacing: 14) {
                        Text("Comment tu te sens ?").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                        HStack(spacing: 22) {
                            ForEach(Feeling.allCases) { f in
                                Button {
                                    summary.feeling = f
                                    SessionSummary.upsert(summary)
                                } label: {
                                    VStack(spacing: 8) {
                                        Image(systemName: f.icon)
                                            .font(.system(size: 26, weight: .bold))
                                            .foregroundStyle(summary.feeling == f ? Theme.background : Theme.muted)
                                            .frame(width: 58, height: 58)
                                            .background(Circle().fill(summary.feeling == f ? Theme.lime : Theme.surfaceRaised))
                                        Text(f.label).font(.system(size: 12, weight: .bold))
                                            .foregroundStyle(summary.feeling == f ? Theme.lime : Theme.muted)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.top, 6)
                    if let line = summary.lastCoachLine, !line.isEmpty {
                        HStack(alignment: .top, spacing: 10) {
                            JeffreyMark(size: 22)
                            Text(line).font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
                        }
                        .card()
                    }
                    Button {
                        SessionSummary.upsert(summary)
                        dismiss()
                    } label: {
                        Text("Chaque sortie compte.")
                            .font(.display(16, weight: .black)).foregroundStyle(Theme.background)
                            .frame(maxWidth: .infinity).frame(height: 56)
                            .background(Capsule().fill(Theme.startGradient))
                    }
                    .padding(.top, 4)
                }
                .padding(20)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            route = LocalRoute.matching(start: summary.date, end: summary.date.addingTimeInterval(summary.elapsed + 60))
            SessionSummary.upsert(summary)
        }
    }
}
