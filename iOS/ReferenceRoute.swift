import Foundation
import CoreLocation

/// Parcours de référence (une séance précédente) pour comparer la séance en cours et anticiper le relief.
struct ReferenceRoute: Codable {
    struct Point: Codable {
        var lat: Double
        var lon: Double
        var alt: Double        // altitude lissée (m)
        var elapsed: Double    // secondes depuis le départ de la séance de référence
        var cum: Double        // distance cumulée (m)
    }
    var name: String
    var date: Date
    var points: [Point]
    var totalDistance: Double
    var totalGain: Double

    static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("reference-route.json")
    }

    static func load() -> ReferenceRoute? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try? d.decode(ReferenceRoute.self, from: data)
    }

    func save() {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        if let data = try? e.encode(self) { try? data.write(to: ReferenceRoute.fileURL, options: .atomic) }
    }

    static func clear() { try? FileManager.default.removeItem(at: fileURL) }

    /// Construit la référence à partir de positions horodatées (Santé ou tracé iPhone).
    static func make(name: String, date: Date, locations: [CLLocation]) -> ReferenceRoute? {
        let good = locations.filter { $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= 60 }.sorted { $0.timestamp < $1.timestamp }
        guard good.count >= 2, let first = good.first else { return nil }
        // Lissage de l'altitude sur une fenêtre glissante : le GPS est bruité de plusieurs mètres.
        let alts = good.map(\.altitude)
        let window = 5
        var smoothed: [Double] = []
        for i in alts.indices {
            let lo = max(0, i - window), hi = min(alts.count - 1, i + window)
            smoothed.append(alts[lo...hi].reduce(0, +) / Double(hi - lo + 1))
        }
        var pts: [Point] = []
        var cum = 0.0
        var gain = 0.0
        for (i, l) in good.enumerated() {
            if i > 0 {
                cum += l.distance(from: good[i - 1])
                if smoothed[i] > smoothed[i - 1] { gain += smoothed[i] - smoothed[i - 1] }
            }
            pts.append(Point(lat: l.coordinate.latitude, lon: l.coordinate.longitude, alt: smoothed[i],
                             elapsed: l.timestamp.timeIntervalSince(first.timestamp), cum: cum))
        }
        return ReferenceRoute(name: name, date: date, points: pts, totalDistance: cum, totalGain: gain)
    }
}

/// Position de la séance en cours par rapport au parcours de référence.
struct ReferenceStatus: Equatable {
    var covered: Double         // m parcourus le long de la référence
    var total: Double
    var offRoute: Bool
    var gainNext: Double        // D+ sur les 500 m à venir
    var lossNext: Double        // D- sur les 500 m à venir
    var gradeNext: Double       // pente moyenne des 500 m à venir (%)
    var ghostDelta: Double?     // secondes d'avance (+) ou de retard (−) sur la référence au même endroit

    var progressText: String { "\(Formatters.distance(covered)) / \(Formatters.distance(total))" }
    var reliefText: String {
        if gainNext >= 8 { return String(format: "montée +%.0f m (%.0f %%)", gainNext, gradeNext) }
        if lossNext >= 8 { return String(format: "descente −%.0f m (%.0f %%)", lossNext, gradeNext) }
        return "plat"
    }
    var ghostText: String? {
        guard let g = ghostDelta else { return nil }
        let s = Int(abs(g).rounded())
        return g >= 0 ? "\(s) s d'avance" : "\(s) s de retard"
    }
}

final class ReferenceTracker {
    let route: ReferenceRoute
    private var lastIndex = 0
    private let lookAhead: Double = 500

    init(route: ReferenceRoute) { self.route = route }

    /// Recale la position courante sur la référence (recherche autour du dernier point pour rester rapide).
    func update(location: CLLocation, elapsed: TimeInterval) -> ReferenceStatus {
        let pts = route.points
        let lo = max(0, lastIndex - 150), hi = min(pts.count - 1, lastIndex + 400)
        var best = lastIndex, bestD = Double.greatestFiniteMagnitude
        for i in lo...hi {
            let d = location.distance(from: CLLocation(latitude: pts[i].lat, longitude: pts[i].lon))
            if d < bestD { bestD = d; best = i }
        }
        if bestD > 80 {
            // Peut-être un saut : recherche globale grossière (1 point sur 10).
            for i in stride(from: 0, to: pts.count, by: 10) {
                let d = location.distance(from: CLLocation(latitude: pts[i].lat, longitude: pts[i].lon))
                if d < bestD { bestD = d; best = i }
            }
        }
        lastIndex = best
        let here = pts[best]
        var gain = 0.0, loss = 0.0
        var j = best
        while j + 1 < pts.count, pts[j + 1].cum - here.cum <= lookAhead {
            let dz = pts[j + 1].alt - pts[j].alt
            if dz > 0 { gain += dz } else { loss -= dz }
            j += 1
        }
        let horiz = max(1, pts[j].cum - here.cum)
        let grade = (pts[j].alt - here.alt) / horiz * 100
        let ghost = bestD <= 60 ? here.elapsed - elapsed : nil
        return ReferenceStatus(covered: here.cum, total: route.totalDistance, offRoute: bestD > 60,
                               gainNext: gain, lossNext: loss, gradeNext: grade, ghostDelta: ghost)
    }
}
