import XCTest
import CoreLocation
@testable import WatchCoach

final class GoalTests: XCTestCase {
    func testDurationProgressAndRemaining() {
        let g = SessionGoal(kind: .duration, target: 1800)
        let p = g.progress(elapsed: 900, distance: nil)
        XCTAssertEqual(p.fraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(p.remaining, "15:00 restantes")
        XCTAssertFalse(g.isReached(elapsed: 1799, distance: nil))
        XCTAssertTrue(g.isReached(elapsed: 1800, distance: nil))
    }

    func testDistanceGoal() {
        let g = SessionGoal(kind: .distance, target: 5000)
        XCTAssertEqual(g.label, "5.00 km")
        XCTAssertTrue(g.isReached(elapsed: 0, distance: 5000))
        XCTAssertEqual(g.progress(elapsed: 0, distance: 2500).remaining, "2.50 km restants")
    }

    func testFreeGoalNeverReached() {
        XCTAssertFalse(SessionGoal.free.isReached(elapsed: 99_999, distance: 99_999))
        XCTAssertNil(SessionGoal.free.progress(elapsed: 10, distance: 10).remaining)
    }
}

final class ZoneAndFormatTests: XCTestCase {
    func testZones() {
        XCTAssertEqual(HeartRateZone.zone(for: 100, maxHR: 180), .z1)
        XCTAssertEqual(HeartRateZone.zone(for: 117, maxHR: 180), .z2)
        XCTAssertEqual(HeartRateZone.zone(for: 135, maxHR: 180), .z3)
        XCTAssertEqual(HeartRateZone.zone(for: 150, maxHR: 180), .z4)
        XCTAssertEqual(HeartRateZone.zone(for: 170, maxHR: 180), .z5)
        XCTAssertEqual(HeartRateZone.zone(for: 170, maxHR: 0), .z1)
    }

    func testFormatters() {
        XCTAssertEqual(Formatters.elapsed(65), "1:05")
        XCTAssertEqual(Formatters.elapsed(3661), "1:01:01")
        XCTAssertEqual(Formatters.distance(999), "999 m")
        XCTAssertEqual(Formatters.distance(1234), "1.23 km")
        XCTAssertEqual(Formatters.pace(speedMetersPerSecond: 3.0), "5:33 /km")
        XCTAssertNil(Formatters.pace(speedMetersPerSecond: 0.1))
        XCTAssertEqual(Formatters.humanDuration(45 * 60), "45 min")
        XCTAssertEqual(Formatters.humanDuration(77 * 60), "1 h 17")
    }
}

final class ReferenceRouteTests: XCTestCase {
    /// Tracé synthétique : 1 km plein nord, montée de 40 m entre 300 et 600 m, à 3 m/s.
    private func makeRoute() -> ReferenceRoute {
        var locs: [CLLocation] = []
        let start = Date(timeIntervalSince1970: 1_000_000)
        for i in 0...100 {
            let d = Double(i) * 10
            let lat = 48.85 + d / 111_000
            let alt: Double = d < 300 ? 50 : (d < 600 ? 50 + (d - 300) / 300 * 40 : 90)
            locs.append(CLLocation(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: 2.35), altitude: alt,
                                   horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: start.addingTimeInterval(d / 3)))
        }
        return ReferenceRoute.make(name: "test", date: start, locations: locs)!
    }

    func testMakeComputesDistanceAndGain() {
        let r = makeRoute()
        XCTAssertEqual(r.totalDistance, 1000, accuracy: 15)
        XCTAssertEqual(r.totalGain, 40, accuracy: 6)
    }

    func testTrackerSeesUpcomingClimbAndGhost() {
        let r = makeRoute()
        let t = ReferenceTracker(route: r)
        // À 100 m sur le tracé, après 40 s (référence : 33 s) → 7 s de retard, montée à venir dans la fenêtre de 500 m.
        let here = CLLocation(latitude: 48.85 + 100 / 111_000, longitude: 2.35)
        let s = t.update(location: here, elapsed: 40)
        XCTAssertFalse(s.offRoute)
        XCTAssertEqual(s.covered, 100, accuracy: 12)
        XCTAssertGreaterThan(s.gainNext, 20)
        XCTAssertEqual(s.ghostDelta ?? 0, -7, accuracy: 3)
        // Loin du tracé : hors parcours, pas de fantôme.
        let far = CLLocation(latitude: 48.86, longitude: 2.40)
        let off = t.update(location: far, elapsed: 60)
        XCTAssertTrue(off.offRoute)
        XCTAssertNil(off.ghostDelta)
    }
}

final class MemoryAndSessionTests: XCTestCase {
    @MainActor func testMemoryReplaceGuardAgainstTruncation() {
        let m = JeffreyMemory.shared
        // Isolation : on part d'une mémoire vide.
        try? FileManager.default.removeItem(at: m.testFileURL)
        m.load()
        m.replace(with: [])
        ["a", "b", "c", "d", "e", "f"].forEach { m.add($0) }
        XCTAssertEqual(m.notes.count, 6)
        m.replace(with: ["a"])                 // liste amputée → refusée
        XCTAssertEqual(m.notes.count, 6)
        m.replace(with: ["a", "b", "c", "z"])  // fusion acceptée
        XCTAssertEqual(m.notes.count, 4)
        XCTAssertTrue(m.notes.contains { $0.text == "z" })
    }

    func testSessionMatchingByOverlap() {
        let start = Date(timeIntervalSince1970: 2_000_000)
        let coached = SessionSummary(id: "x", date: start.addingTimeInterval(120), kind: .running, elapsed: 1500,
                                     distance: nil, averageHeartRate: nil, maxHeartRate: nil, feeling: nil, lastCoachLine: nil)
        XCTAssertNotNil(SessionSummary.matching(start: start, end: start.addingTimeInterval(1800), in: [coached]))
        XCTAssertNil(SessionSummary.matching(start: start.addingTimeInterval(7200), end: start.addingTimeInterval(9000), in: [coached]))
    }

    func testCoachMirrorRoundTrip() throws {
        var m = CoachMirror.idle
        m.phase = "live"; m.timerLabel = "sprint"; m.timerEndsAt = Date()
        let data = try WCCodec.encoder.encode(m)
        let back = try WCCodec.decoder.decode(CoachMirror.self, from: data)
        XCTAssertEqual(back.phase, "live")
        XCTAssertEqual(back.timerLabel, "sprint")
    }
}

final class WorkoutLibraryTests: XCTestCase {
    func testEverySportAndLevelHasWorkouts() {
        for kind in WorkoutKind.allCases {
            for level in AthleteLevel.allCases {
                let list = WorkoutLibrary.workouts(kind: kind, level: level)
                XCTAssertFalse(list.isEmpty, "\(kind) \(level)")
                for w in list {
                    XCTAssertFalse(w.blocks.isEmpty, w.id)
                    XCTAssertGreaterThanOrEqual(w.totalSeconds, WorkoutLibrary.minimumSeconds, "\(w.id) dure moins de 30 minutes")
                    XCTAssertLessThan(w.totalSeconds, 3 * 3600, w.id)
                    XCTAssertEqual(WorkoutLibrary.workout(id: w.id)?.id, w.id)
                }
            }
        }
        XCTAssertEqual(Set(WorkoutLibrary.all.map(\.id)).count, WorkoutLibrary.all.count, "identifiants uniques")
    }

    func testIntervalBlockSummaryAndTotal() {
        let b = WorkoutBlock(label: "vite", seconds: 30, repeats: 8, restSeconds: 30)
        XCTAssertEqual(b.totalSeconds, 30 * 8 + 30 * 7)
        XCTAssertEqual(b.summary, "8 × (vite 30 s / récup 30 s)")
        let w = WorkoutLibrary.workout(id: "run-a2")!
        XCTAssertEqual(w.toolPayload["minutes"] as? Int, Int((Double(w.totalSeconds) / 60).rounded()))
    }
}

final class SessionCheckpointTests: XCTestCase {
    private func sample(savedAt: Date) -> SessionCheckpoint {
        SessionCheckpoint(
            kind: .running, mode: .companion, goal: SessionGoal(kind: .duration, target: 1500, note: "test"),
            goalReached: false, halfwayAnnounced: true, startedAt: savedAt.addingTimeInterval(-420), savedAt: savedAt,
            transcript: [.init(role: "coach", text: "Salut Hervé.", at: savedAt.addingTimeInterval(-400)),
                         .init(role: "user", text: "On y va.", at: savedAt.addingTimeInterval(-390))],
            hrSamples: [120, 130, 140], zoneSeconds: [10, 20, 30, 0, 0], lastKmAnnounced: 1,
            timer: .init(label: "échauffement 1/3", baseLabel: "échauffement", index: 1, endsAt: savedAt.addingTimeInterval(60),
                         workSeconds: 300, restSeconds: 0, repeatsLeft: 1, phaseIsWork: true),
            plan: .init(title: "Reprise douce", queue: [WorkoutBlock(label: "footing", seconds: 600)], total: 3, index: 1),
            routeID: "2026-09-19T09-10-00Z", walkingSeconds: 30, runningSeconds: 380, stationarySeconds: 10, climbingSeconds: 45,
            ascent: 12, descent: 3)
    }

    func testRoundTripThroughDisk() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("checkpoint-\(UUID().uuidString).json")
        defer { SessionCheckpoint.clear(at: url) }
        let original = sample(savedAt: Date())
        original.save(to: url)
        let back = SessionCheckpoint.load(from: url)
        XCTAssertNotNil(back)
        XCTAssertEqual(back?.kind, .running)
        XCTAssertEqual(back?.goal.target, 1500)
        XCTAssertEqual(back?.transcript.count, 2)
        XCTAssertEqual(back?.timer?.label, "échauffement 1/3")
        XCTAssertEqual(back?.plan?.queue.first?.label, "footing")
        XCTAssertEqual(back?.hrSamples, [120, 130, 140])
        XCTAssertEqual(back?.routeID, "2026-09-19T09-10-00Z")
        SessionCheckpoint.clear(at: url)
        XCTAssertNil(SessionCheckpoint.load(from: url))
    }

    func testResumableOnlyWhenRecent() {
        XCTAssertTrue(sample(savedAt: Date().addingTimeInterval(-5 * 60)).isResumable)
        XCTAssertFalse(sample(savedAt: Date().addingTimeInterval(-45 * 60)).isResumable)
    }
}

final class SpeechFilterTests: XCTestCase {
    @MainActor func testNoiseIsIgnoredAndSpeechKept() {
        XCTAssertTrue(CoachSession.looksLikeSpeech("OK, c'est parti."))
        XCTAssertTrue(CoachSession.looksLikeSpeech("oui"))
        XCTAssertTrue(CoachSession.looksLikeSpeech("Stop"))
        XCTAssertFalse(CoachSession.looksLikeSpeech("Schock!"))
        XCTAssertFalse(CoachSession.looksLikeSpeech("Lemmonement"))
        XCTAssertFalse(CoachSession.looksLikeSpeech("Пое"))
        XCTAssertFalse(CoachSession.looksLikeSpeech("T"))
    }
}

@MainActor final class EchoFilterTests: XCTestCase {
    func testEchoOfCoachLineIsDetected() {
        let coach = ["Allez Hervé, t'es parti, trouve ton allure douce, et pense à relâcher les épaules."]
        XCTAssertTrue(CoachSession.looksLikeEcho("À allure douce, pense à relâcher les épaules.", of: coach))
        XCTAssertTrue(CoachSession.looksLikeEcho("trouve ton allure douce relâcher les épaules", of: coach))
    }
    func testRealSpeechIsKept() {
        let coach = ["Allez Hervé, t'es parti, trouve ton allure douce, et pense à relâcher les épaules."]
        XCTAssertFalse(CoachSession.looksLikeEcho("J'ai mal au genou droit depuis hier", of: coach))
        XCTAssertFalse(CoachSession.looksLikeEcho("oui", of: coach))
        XCTAssertFalse(CoachSession.looksLikeEcho("on passe à 25 minutes ?", of: coach))
    }
}

final class ShortSessionTests: XCTestCase {
    func testSessionsUnderFiveMinutesAreNotKept() {
        XCTAssertFalse(SessionSummary.counts(elapsed: 299))
        XCTAssertTrue(SessionSummary.counts(elapsed: 300))
        let short = SessionSummary(id: "short-test", date: Date(), kind: .running, elapsed: 120, distance: nil,
                                   averageHeartRate: nil, maxHeartRate: nil, feeling: nil, lastCoachLine: nil)
        SessionSummary.upsert(short)
        XCTAssertFalse(SessionSummary.loadAll().contains { $0.id == "short-test" })
    }
}

@MainActor final class NoiseAndEchoTests: XCTestCase {
    func testShortChoiceAnswersAreKept() {
        // Séance du 22/09 : « Première option » avait été écartée comme un écho.
        let coach = ["Première option : marche 3 min, puis 6 fois 2 min de course et 1 min de récup, total 23 min."]
        XCTAssertTrue(CoachSession.looksLikeSpeech("Première"))
        XCTAssertTrue(CoachSession.looksLikeSpeech("deuxième"))
        XCTAssertFalse(CoachSession.looksLikeEcho("Première option.", of: coach))
        XCTAssertFalse(CoachSession.looksLikeEcho("la deuxième", of: coach))
    }

    func testRepeatedPhraseAndLongRepeatAreEcho() {
        let coach = ["Allez Hervé, trouve ton allure douce, et pense à relâcher les épaules."]
        XCTAssertTrue(CoachSession.looksLikeEcho("Première option. Première option. Première option.", of: coach))
        XCTAssertTrue(CoachSession.looksLikeEcho("trouve ton allure douce et pense à relâcher les épaules", of: coach))
        XCTAssertFalse(CoachSession.looksLikeEcho("j'ai mal au genou droit depuis hier", of: coach))
    }
}

final class SpokenUnitsTests: XCTestCase {
    func testDistancesAreSpelledOut() {
        XCTAssertEqual(Formatters.spokenDistance(2450), "2 virgule 45 kilomètres")
        XCTAssertEqual(Formatters.spokenDistance(1200), "1 virgule 20 kilomètre")
        XCTAssertEqual(Formatters.spokenDistance(450), "450 mètres")
        XCTAssertFalse(Formatters.spokenDistance(5000).contains("km"))
    }

    func testPaceIsSpelledOut() {
        XCTAssertEqual(Formatters.spokenPace(secondsPerKm: 330), "5 minutes 30 par kilomètre")
        XCTAssertEqual(Formatters.spokenPace(secondsPerKm: 360), "6 minutes par kilomètre")
        XCTAssertNil(Formatters.spokenPace(secondsPerKm: 0))
    }
}
