import SwiftUI

struct ObjectiveView: View {
    @Environment(\.dismiss) private var dismiss
    let kind: WorkoutKind
    var initial: SessionGoal? = nil
    var onStart: (SessionGoal) -> Void

    @State private var goalKind: SessionGoal.Kind = .duration
    @State private var minutes: Double = 30
    @State private var km: Double = 5
    @State private var note: String = ""

    private var goal: SessionGoal {
        switch goalKind {
        case .duration: return SessionGoal(kind: .duration, target: minutes * 60, note: note)
        case .distance: return SessionGoal(kind: .distance, target: km * 1000, note: note)
        case .free: return SessionGoal(kind: .free, target: 0, note: note)
        }
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                Button { dismiss() } label: {
                    HStack(spacing: 6) { JIcon("retour", size: 14); Text("Retour") }.font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.muted)
                }
                Text("On vise quoi\naujourd'hui ?").font(.display(30, weight: .black)).foregroundStyle(.white)
                HStack { Spacer(); JeffreyMark(state: .listening, size: 44); Spacer() }
                JeffreyBubble(text: kind.usesDistance ? "Tu veux \(kind.coachLabel.contains("vélo") ? "rouler" : "courir") combien de temps, ou quelle distance ?" : "On part sur combien de temps ?")
                HStack(spacing: 8) {
                    ForEach(SessionGoal.Kind.allCases) { k in
                        if k != .distance || kind.usesDistance {
                            let selected = goalKind == k
                            Button { withAnimation(.snappy) { goalKind = k } } label: {
                                HStack(spacing: 6) { JIcon(k.icon, size: 16); Text(k.label) }
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(selected ? Theme.background : .white)
                                    .frame(maxWidth: .infinity).frame(height: 44)
                                    .background(Capsule().fill(selected ? Theme.lime : Theme.surface))
                            }
                        }
                    }
                }
                Group {
                    switch goalKind {
                    case .duration:
                        valueRow(text: "\(Int(minutes)) min", minus: { minutes = max(5, minutes - 5) }, plus: { minutes = min(240, minutes + 5) })
                    case .distance:
                        valueRow(text: String(format: "%.1f km", km).replacingOccurrences(of: ".0", with: ""), minus: { km = max(0.5, km - 0.5) }, plus: { km = min(100, km + 0.5) })
                    case .free:
                        Text("Sortie libre : Jeffrey t'accompagne sans compter.").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.muted)
                    }
                }
                TextField("Une précision pour Jeffrey (ex. tranquille, fractionné, je suis fatigué)", text: $note, axis: .vertical)
                    .lineLimit(1...3)
                    .font(.system(size: 14, weight: .medium))
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface))
                JeffreyBubble(text: goalKind == .free ? "Ça marche. On part à ton rythme." : "Ça marche. On part pour \(goal.label) à ton rythme.")
                Spacer()
                PrimaryButton(title: "C'est parti") { onStart(goal) }
            }
            .padding(20)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if let initial {
                goalKind = initial.kind
                if initial.kind == .duration { minutes = initial.target / 60 }
                if initial.kind == .distance { km = initial.target / 1000 }
                note = initial.note
            } else if !kind.usesDistance {
                goalKind = .duration
            }
        }
    }

    private func valueRow(text: String, minus: @escaping () -> Void, plus: @escaping () -> Void) -> some View {
        HStack {
            roundButton("minus", minus)
            Spacer()
            Text(text).font(.display(40, weight: .black).monospacedDigit()).foregroundStyle(.white)
            Spacer()
            roundButton("plus", plus)
        }
        .padding(.horizontal, 8)
    }

    private func roundButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 18, weight: .black)).foregroundStyle(Theme.creme)
                .frame(width: 50, height: 50).background(Circle().fill(Theme.surfaceRaised))
        }
    }
}
