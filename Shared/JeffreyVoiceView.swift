import SwiftUI

/// « Jeffrey parle » : le J citron se transforme en sept barres vocales tant que la voix joue, puis reprend sa forme.
/// Port natif du moteur vectoriel du pack d'animation (aucune bibliothèque) : le retour part de la forme affichée,
/// même au milieu d'une transition. Fonctionne sur iPhone et sur la montre.
struct JeffreyVoiceView: View {
    var speaking: Bool
    var size: CGFloat = 44
    var color: Color = JeffreyPalette.citron

    @StateObject private var engine = JeffreyVoiceEngine()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: engine.isIdle && !speaking)) { ctx in
            Canvas { context, cgSize in
                let shapes = engine.shapes(at: ctx.date)
                let scale = min(cgSize.width, cgSize.height) / JeffreyVoiceGeometry.canvas
                for poly in shapes {
                    var path = Path()
                    for (i, p) in poly.enumerated() {
                        let pt = CGPoint(x: p.x * scale, y: p.y * scale)
                        if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                    }
                    path.closeSubpath()
                    context.fill(path, with: .color(color))
                    // Les 7 tracés se touchent : un trait fin de la même couleur gomme les jointures du J au repos.
                    context.stroke(path, with: .color(color), lineWidth: max(0.8, scale * 1.5))
                }
            }
        }
        .frame(width: size, height: size)
        .onAppear { engine.setSpeaking(speaking, at: Date()) }
        .onChange(of: speaking) { _, s in engine.setSpeaking(s, at: Date()) }
        .accessibilityLabel(speaking ? "Jeffrey te parle" : "Jeffrey")
    }
}

@MainActor
final class JeffreyVoiceEngine: ObservableObject {
    private enum State { case idle, intro, speaking, outro }
    private var state: State = .idle
    private var start = Date()
    private var from: [[CGPoint]]
    private var current: [[CGPoint]]
    private static let rest: [[CGPoint]] = JeffreyVoiceGeometry.sources.map { flat in
        stride(from: 0, to: flat.count, by: 2).map { CGPoint(x: flat[$0], y: flat[$0 + 1]) }
    }

    init() { from = Self.rest; current = Self.rest }

    var isIdle: Bool { state == .idle }

    func setSpeaking(_ s: Bool, at now: Date) {
        switch (s, state) {
        case (true, .speaking), (true, .intro), (false, .idle), (false, .outro): return
        default: break
        }
        from = current
        start = now
        state = s ? .intro : .outro
    }

    func shapes(at now: Date) -> [[CGPoint]] {
        let t = now.timeIntervalSince(start)
        switch state {
        case .idle:
            current = Self.rest
        case .intro:
            let f = min(1, t / JeffreyVoiceGeometry.intro)
            current = Self.mix(from, Self.wave(0), f * f * (3 - 2 * f))
            if f >= 1 { state = .speaking; start = now }
        case .speaking:
            current = Self.wave(t)
        case .outro:
            let f = min(1, t / JeffreyVoiceGeometry.intro)
            current = Self.mix(from, Self.rest, f * f * (3 - 2 * f))
            if f >= 1 { state = .idle }
        }
        return current
    }

    private static func mix(_ a: [[CGPoint]], _ b: [[CGPoint]], _ f: Double) -> [[CGPoint]] {
        zip(a, b).map { pa, pb in zip(pa, pb).map { CGPoint(x: $0.x * (1 - f) + $1.x * f, y: $0.y * (1 - f) + $1.y * f) } }
    }

    /// Les sept barres à l'instant t (cycle de 2,4 s), rééchantillonnées et recalées comme dans le pack.
    private static func wave(_ t: Double) -> [[CGPoint]] {
        let g = JeffreyVoiceGeometry.self
        let n = g.pointCount
        return g.order.enumerated().map { i, k in
            let phase = 2 * Double.pi * t / g.loop
            let base = g.baseHeights[k]
            let h = 34 + base * (0.76 + 0.17 * sin(phase * 2 + Double(k) * 0.83) + 0.07 * sin(phase * 3 - Double(k) * 0.4))
            let x = 100 + 52 * Double(k), r = 14.0
            var p: [CGPoint] = []
            for j in 0...32 {
                let a = -Double.pi + Double(j) * Double.pi / 32
                p.append(CGPoint(x: x + r * cos(a), y: 256 - h / 2 + r + r * sin(a)))
            }
            for j in 0...32 {
                let a = Double(j) * Double.pi / 32
                p.append(CGPoint(x: x + r * cos(a), y: 256 + h / 2 - r + r * sin(a)))
            }
            var d = resample(p, count: n)
            let (rev, shift) = g.align[i]
            if rev { d.reverse() }
            return (0..<n).map { d[($0 + shift) % n] }
        }
    }

    private static func resample(_ p: [CGPoint], count: Int) -> [CGPoint] {
        let q = p + [p[0]]
        var len: [Double] = [0]
        for i in 1..<q.count { len.append(len[i - 1] + hypot(q[i].x - q[i - 1].x, q[i].y - q[i - 1].y)) }
        let total = len[len.count - 1]
        var j = 0
        return (0..<count).map { i in
            let x = Double(i) * total / Double(count)
            while j + 1 < len.count - 1, len[j + 1] < x { j += 1 }
            let seg = len[j + 1] - len[j]
            let f = seg > 0 ? (x - len[j]) / seg : 0
            return CGPoint(x: q[j].x * (1 - f) + q[j + 1].x * f, y: q[j].y * (1 - f) + q[j + 1].y * f)
        }
    }
}
