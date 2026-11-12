import Foundation
import SwiftData
import CoreLocation

/// Un point GPS enregistré pendant une course.
struct TrackPoint: Codable, Sendable {
    var lat: Double
    var lon: Double
    var alt: Double
    var time: Date
    /// Distance cumulée depuis le départ (m)
    var distance: Double
    /// Temps en mouvement cumulé, pauses exclues (s)
    var movingTime: Double
    /// Numéro de tronçon (change à chaque reprise après une pause)
    var segment: Int

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

/// Temps intermédiaire (un par kilomètre).
struct Split: Codable, Identifiable, Sendable {
    var index: Int
    var distance: Double
    var duration: Double
    var elevationGain: Double

    var id: Int { index }
    /// Allure en secondes par km
    var pace: Double { distance > 0 ? duration / distance * 1000 : 0 }
}

@Model
final class Run {
    var startDate: Date = Date()
    var title: String = ""
    var notes: String = ""
    /// mètres
    var distance: Double = 0
    /// secondes, pauses exclues
    var movingTime: Double = 0
    /// secondes, du départ à l'arrivée
    var elapsedTime: Double = 0
    /// mètres de dénivelé positif
    var elevationGain: Double = 0
    /// nombre de pas (0 si le podomètre n'était pas disponible)
    var steps: Int = 0
    @Attribute(.externalStorage) var pointsData: Data = Data()
    var splitsData: Data = Data()
    var bestEffortsData: Data = Data()

    init(startDate: Date, title: String, distance: Double, movingTime: Double,
         elapsedTime: Double, elevationGain: Double, steps: Int = 0,
         pointsData: Data, splitsData: Data, bestEffortsData: Data) {
        self.startDate = startDate
        self.title = title
        self.distance = distance
        self.movingTime = movingTime
        self.elapsedTime = elapsedTime
        self.elevationGain = elevationGain
        self.steps = steps
        self.pointsData = pointsData
        self.splitsData = splitsData
        self.bestEffortsData = bestEffortsData
    }

    var points: [TrackPoint] {
        (try? JSONDecoder().decode([TrackPoint].self, from: pointsData)) ?? []
    }

    var splits: [Split] {
        (try? JSONDecoder().decode([Split].self, from: splitsData)) ?? []
    }

    /// Meilleurs temps (s) par distance en mètres : 1000, 5000, 10000…
    var bestEfforts: [Int: Double] {
        (try? JSONDecoder().decode([Int: Double].self, from: bestEffortsData)) ?? [:]
    }

    /// Allure moyenne en s/km
    var averagePace: Double { distance > 0 ? movingTime / distance * 1000 : 0 }

    /// Cadence moyenne en pas par minute (0 si inconnue)
    var averageCadence: Double { steps > 0 && movingTime > 0 ? Double(steps) / movingTime * 60 : 0 }

    /// Longueur moyenne d'une foulée en mètres (0 si inconnue)
    var strideLength: Double { steps > 0 ? distance / Double(steps) : 0 }
}

extension Array where Element == TrackPoint {
    /// Coordonnées découpées par tronçon, pour ne pas relier deux points séparés par une pause.
    var coordinateSegments: [[CLLocationCoordinate2D]] {
        var result: [[CLLocationCoordinate2D]] = []
        var current = Int.min
        for p in self {
            if p.segment != current {
                result.append([])
                current = p.segment
            }
            result[result.count - 1].append(p.coordinate)
        }
        return result
    }

    /// Même découpage, allégé à environ `maxPoints` points pour rester fluide sur les longues sorties.
    func coordinateSegments(maxPoints: Int) -> [[CLLocationCoordinate2D]] {
        let step = Swift.max(1, count / Swift.max(1, maxPoints))
        guard step > 1 else { return coordinateSegments }
        var result: [[CLLocationCoordinate2D]] = []
        var current = Int.min
        for (i, p) in enumerated() {
            let isNewSegment = p.segment != current
            if isNewSegment {
                result.append([])
                current = p.segment
            }
            if isNewSegment || i % step == 0 || i == count - 1 {
                result[result.count - 1].append(p.coordinate)
            }
        }
        return result
    }
}
