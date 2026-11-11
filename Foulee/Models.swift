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
    @Attribute(.externalStorage) var pointsData: Data = Data()
    var splitsData: Data = Data()
    var bestEffortsData: Data = Data()

    init(startDate: Date, title: String, distance: Double, movingTime: Double,
         elapsedTime: Double, elevationGain: Double,
         pointsData: Data, splitsData: Data, bestEffortsData: Data) {
        self.startDate = startDate
        self.title = title
        self.distance = distance
        self.movingTime = movingTime
        self.elapsedTime = elapsedTime
        self.elevationGain = elevationGain
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
}
