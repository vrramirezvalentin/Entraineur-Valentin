#if DEBUG
import Foundation
import SwiftData

/// Données de démonstration, uniquement dans les builds Debug (simulateur).
/// Lancement : -demo YES  [-screen record|running|history|detail|stats|flyover]
enum DemoData {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "demo") }
    static var screen: String { UserDefaults.standard.string(forKey: "screen") ?? "" }

    @MainActor
    static func seedIfNeeded(_ context: ModelContext) {
        guard isEnabled else { return }
        let count = (try? context.fetchCount(FetchDescriptor<Run>())) ?? 0
        guard count == 0 else { return }

        let cal = Calendar.current
        let now = Date()
        func day(_ offset: Int, _ hour: Int, _ minute: Int) -> Date {
            let d = cal.date(byAdding: .day, value: -offset, to: now) ?? now
            return cal.date(bySettingHour: hour, minute: minute, second: 0, of: d) ?? d
        }

        let specs: [(Date, String, Double, Double, Double)] = [
            // date, titre, distance (m), allure (s/km), échelle du relief
            (day(1, 7, 12), "Tour du lac au lever du soleil", 8420, 320, 1.0),
            (day(3, 18, 40), "Course du soir", 5030, 311, 0.4),
            (day(5, 9, 5), "Sortie longue", 15600, 334, 1.3),
            (day(8, 12, 20), "Course du midi", 6200, 321, 0.6),
            (day(10, 18, 15), "Fractionné", 7850, 304, 0.5),
            (day(17, 7, 30), "Course du matin", 10020, 320, 0.9),
            (day(24, 8, 0), "Course du matin", 7400, 326, 0.7),
            (day(31, 18, 30), "Course du soir", 6100, 318, 0.5),
            (day(38, 9, 15), "Sortie longue", 13200, 338, 1.1),
            (day(45, 7, 10), "Course du matin", 5500, 317, 0.4),
            (day(52, 18, 0), "Course du soir", 8000, 323, 0.8),
            (day(60, 9, 30), "Semi d'entraînement", 21300, 337, 1.2),
        ]

        for (i, spec) in specs.enumerated() {
            let run = makeRun(start: spec.0, title: spec.1, distance: spec.2,
                              pace: spec.3, relief: spec.4, seed: Double(i))
            if i == 0 {
                run.notes = "Bonnes jambes, un peu de vent au bord du lac. La montée du 6e km pique !"
            }
            context.insert(run)
        }
        try? context.save()
    }

    /// Fabrique une boucle réaliste autour du lac d'Annecy.
    private static func makeRun(start: Date, title: String, distance: Double,
                                pace: Double, relief: Double, seed: Double) -> Run {
        let centerLat = 45.8890 + 0.004 * sin(seed)
        let centerLon = 6.1650 + 0.004 * cos(seed)
        let radius = distance / (2 * .pi)                  // m
        let mPerDegLat = 111_320.0
        let mPerDegLon = 111_320.0 * cos(centerLat * .pi / 180)

        // Point de la boucle à l'angle t (0…2π), forme irrégulière
        func position(_ t: Double) -> (Double, Double) {
            let r = radius * (1 + 0.22 * sin(2 * t + seed) + 0.10 * sin(5 * t + 2 * seed))
            let x = r * cos(t) * 1.25
            let y = r * sin(t) * 0.8
            return (centerLat + y / mPerDegLat, centerLon + x / mPerDegLon)
        }
        func altitude(_ t: Double) -> Double {
            450 + relief * (45 * (1 - cos(t)) + 12 * sin(3 * t + seed) + 4 * sin(11 * t))
        }

        // Échantillonnage fin pour mesurer la longueur réelle de la boucle
        let fine = 4000
        var cumulative: [Double] = [0]
        var prev = position(0)
        for k in 1...fine {
            let p = position(Double(k) / Double(fine) * 2 * .pi)
            let dy = (p.0 - prev.0) * mPerDegLat
            let dx = (p.1 - prev.1) * mPerDegLon
            cumulative.append(cumulative[k - 1] + (dx * dx + dy * dy).squareRoot())
            prev = p
        }
        let loopLength = cumulative[fine]

        // Un point toutes les ~2 s
        let totalTime = distance / 1000 * pace
        let n = Int(totalTime / 2)
        var points: [TrackPoint] = []
        var splits: [Split] = []
        var elevationGain = 0.0
        var anchor = altitude(0)
        var lastSplitTime = 0.0, lastSplitGain = 0.0
        var j = 0
        for k in 0...n {
            let time = Double(k) / Double(n) * totalTime
            // légère variation d'allure
            let progress = time / totalTime
            let d = distance * (progress + 0.006 * sin(progress * 40 + seed))
            let target = min(max(0, d), distance) / distance * loopLength
            while j < fine - 1 && cumulative[j + 1] < target { j += 1 }
            let t = Double(j) / Double(fine) * 2 * .pi
            let pos = position(t)
            let alt = altitude(t)
            let diff = alt - anchor
            if diff >= 3 { elevationGain += diff; anchor = alt } else if diff <= -3 { anchor = alt }

            let dist = max(points.last?.distance ?? 0, min(max(0, d), distance))
            points.append(TrackPoint(lat: pos.0, lon: pos.1, alt: alt,
                                     time: start.addingTimeInterval(time),
                                     distance: dist, movingTime: time, segment: 0))

            while dist >= Double(splits.count + 1) * 1000 {
                splits.append(Split(index: splits.count + 1, distance: 1000,
                                    duration: time - lastSplitTime,
                                    elevationGain: elevationGain - lastSplitGain))
                lastSplitTime = time
                lastSplitGain = elevationGain
            }
        }
        let rest = distance - Double(splits.count) * 1000
        if rest >= 50 {
            splits.append(Split(index: splits.count + 1, distance: rest,
                                duration: totalTime - lastSplitTime,
                                elevationGain: elevationGain - lastSplitGain))
        }

        var efforts: [Int: Double] = [:]
        for effort in RunAnalysis.efforts {
            if let best = RunAnalysis.bestTime(for: Double(effort.meters), in: points) {
                efforts[effort.meters] = best
            }
        }

        let encoder = JSONEncoder()
        return Run(startDate: start, title: title, distance: distance,
                   movingTime: totalTime, elapsedTime: totalTime + 95,
                   elevationGain: elevationGain,
                   pointsData: (try? encoder.encode(points)) ?? Data(),
                   splitsData: (try? encoder.encode(splits)) ?? Data(),
                   bestEffortsData: (try? encoder.encode(efforts)) ?? Data())
    }
}
#endif
