import SwiftUI

/// Le « j » de Jeffrey : un point et une virgule épaisse. Trois états : disponible, à l'écoute, te parle.
enum JeffreyState {
    case available
    case listening
    case speaking
}

struct JeffreyMark: View {
    var state: JeffreyState = .available
    var color: Color = Color(red: 0.78, green: 1.0, blue: 0.22)
    var size: CGFloat = 40

    @State private var pulse = false
    @State private var bars = false

    var body: some View {
        ZStack {
            JeffreyStroke()
                .stroke(color, style: StrokeStyle(lineWidth: size * 0.26, lineCap: .round, lineJoin: .round))
            switch state {
            case .available:
                Circle().fill(color)
                    .frame(width: size * 0.3, height: size * 0.3)
                    .position(x: size * 0.62, y: size * 0.17)
            case .listening:
                // Anneau qui respire autour du point : Jeffrey écoute.
                Circle().fill(color)
                    .frame(width: size * 0.16, height: size * 0.16)
                    .position(x: size * 0.62, y: size * 0.17)
                Circle().stroke(color, lineWidth: size * 0.07)
                    .frame(width: size * 0.36, height: size * 0.36)
                    .scaleEffect(pulse ? 1.25 : 0.9)
                    .opacity(pulse ? 0.5 : 1)
                    .position(x: size * 0.62, y: size * 0.17)
                    .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true } }
            case .speaking:
                // Trois barres qui dansent au-dessus : Jeffrey parle.
                HStack(spacing: size * 0.07) {
                    ForEach(0..<3, id: \.self) { i in
                        Capsule().fill(color)
                            .frame(width: size * 0.12, height: barHeight(i))
                    }
                }
                .frame(height: size * 0.34, alignment: .bottom)
                .position(x: size * 0.62, y: size * 0.2)
                .onAppear { withAnimation(.easeInOut(duration: 0.35).repeatForever(autoreverses: true)) { bars = true } }
            }
        }
        .frame(width: size, height: size)
        .animation(.spring(duration: 0.3), value: stateKey)
    }

    private var stateKey: Int {
        switch state { case .available: return 0; case .listening: return 1; case .speaking: return 2 }
    }

    private func barHeight(_ i: Int) -> CGFloat {
        let base: [CGFloat] = [0.18, 0.34, 0.24]
        let alt: [CGFloat] = [0.3, 0.16, 0.34]
        return size * (bars ? alt[i] : base[i])
    }
}

/// Le trait du « j » : une descente verticale qui se termine en virgule vers la gauche.
struct JeffreyStroke: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width, h = rect.height
        p.move(to: CGPoint(x: w * 0.62, y: h * 0.38))
        p.addLine(to: CGPoint(x: w * 0.62, y: h * 0.62))
        p.addQuadCurve(to: CGPoint(x: w * 0.22, y: h * 0.86), control: CGPoint(x: w * 0.62, y: h * 0.92))
        return p
    }
}

/// Logotype « j jeffrey ».
struct JeffreyWordmark: View {
    var color: Color = .white
    var markColor: Color = Color(red: 0.78, green: 1.0, blue: 0.22)
    var size: CGFloat = 22

    var body: some View {
        HStack(spacing: size * 0.15) {
            JeffreyMark(color: markColor, size: size * 1.3)
            Text("jeffrey")
                .font(.system(size: size, weight: .black, design: .rounded))
                .foregroundStyle(color)
        }
    }
}
