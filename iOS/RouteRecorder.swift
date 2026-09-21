import Foundation
import CoreLocation
import Combine

/// Tracé GPS enregistré par l'iPhone pendant une séance, sauvegardé en local (Documents/routes).
struct LocalRoute: Codable, Identifiable {
    struct Point: Codable {
        var lat: Double
        var lon: Double
        var alt: Double
        var hAcc: Double
        var vAcc: Double
        var t: Date
    }
    var id: String
    var start: Date
    var end: Date
    var kind: String
    var points: [Point]

    var locations: [CLLocation] {
        points.map {
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon), altitude: $0.alt,
                       horizontalAccuracy: $0.hAcc, verticalAccuracy: $0.vAcc, timestamp: $0.t)
        }
    }

    static var directory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("routes")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func load(id: String) -> LocalRoute? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("\(id).json")) else { return nil }
        return try? decoder.decode(LocalRoute.self, from: data)
    }

    static func loadAll() -> [LocalRoute] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(LocalRoute.self, from: data)
        }
        .sorted { $0.start > $1.start }
    }

    /// Tracé local dont la période recouvre celle de la séance (tolérance 10 min sur le début).
    static func matching(start: Date, end: Date) -> LocalRoute? {
        loadAll().first { abs($0.start.timeIntervalSince(start)) < 600 && $0.end > start && $0.start < end }
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: LocalRoute.directory.appendingPathComponent("\(id).json"), options: .atomic)
    }
}

@MainActor
final class RouteRecorder: NSObject, ObservableObject {
    @Published private(set) var distance: Double = 0       // mètres cumulés (points fiables)
    @Published private(set) var speed: Double?             // m/s de la dernière position
    @Published private(set) var pointCount: Int = 0
    @Published private(set) var status: String = ""
    @Published private(set) var lastLocation: CLLocation?
    private(set) var startedAt: Date?
    /// En pause : les points sont ignorés, la distance n'avance pas.
    var paused = false
    private var pendingKind: WorkoutKind?

    private let manager = CLLocationManager()
    private var route: LocalRoute?
    private var lastGood: CLLocation?
    private var lastSaveAt: Date = .distantPast

    /// Identifiant du tracé en cours, pour le point de reprise.
    var routeID: String? { route?.id }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
    }

    func requestAuthorization() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
    }

    /// `resuming` : reprise après une mort de l'app, on continue le tracé sauvegardé (points et distance conservés).
    func start(kind: WorkoutKind, resuming routeID: String? = nil) {
        guard route == nil else { return }
        let status = manager.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            pendingKind = kind
            requestAuthorization()
            self.status = "GPS non autorisé"
            return
        }
        pendingKind = nil
        paused = false
        let now = Date()
        if let id = routeID, let saved = LocalRoute.load(id: id) {
            route = saved
            distance = saved.locations.reduce(into: (0.0, nil as CLLocation?)) { acc, l in
                if let p = acc.1 { acc.0 += l.distance(from: p) }
                acc.1 = l
            }.0
            pointCount = saved.points.count
            lastGood = saved.locations.last
            lastLocation = lastGood
            startedAt = saved.start
        } else {
            route = LocalRoute(id: ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-"),
                               start: now, end: now, kind: kind.rawValue, points: [])
            distance = 0
            pointCount = 0
            lastGood = nil
            lastLocation = nil
            startedAt = now
        }
        speed = nil
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        self.status = "GPS actif"
    }

    func stop() {
        guard var r = route else { return }
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        r.end = Date()
        if r.points.count >= 2 { r.save() }
        route = nil
        status = r.points.count >= 2 ? "Tracé enregistré (\(r.points.count) points)" : "Tracé trop court, non enregistré"
    }

    private func ingest(_ locations: [CLLocation]) {
        guard var r = route, !paused else { return }
        for l in locations where l.horizontalAccuracy >= 0 && l.horizontalAccuracy <= 40 {
            if let prev = lastGood {
                let d = l.distance(from: prev)
                // Ignore le bruit à l'arrêt : on n'ajoute que si le déplacement dépasse l'imprécision.
                if d < max(3, min(l.horizontalAccuracy, prev.horizontalAccuracy) * 0.5) { continue }
                distance += d
            }
            lastGood = l
            lastLocation = l
            speed = l.speed >= 0 ? l.speed : nil
            r.points.append(.init(lat: l.coordinate.latitude, lon: l.coordinate.longitude, alt: l.altitude,
                                  hAcc: l.horizontalAccuracy, vAcc: l.verticalAccuracy, t: l.timestamp))
        }
        r.end = Date()
        route = r
        pointCount = r.points.count
        if Date().timeIntervalSince(lastSaveAt) > 30 {
            lastSaveAt = Date()
            r.save()
        }
    }
}

extension RouteRecorder: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in self.ingest(locations) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            // Autorisation accordée après la demande : on démarre l'enregistrement si une séance attend.
            if let kind = self.pendingKind, manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
                self.start(kind: kind)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.status = "GPS : \(error.localizedDescription)" }
    }
}
