import Foundation
import CoreLocation
import MapKit

// Le survol est entièrement déterministe : pour un instant t donné, on sait exactement
// où est la caméra et où est le point. La lecture en direct et la création de la vidéo
// (image par image) utilisent donc le même calcul.

enum Geo {
    static func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Écart signé le plus court entre deux caps, en degrés (-180…180).
    static func angleDelta(from a: Double, to b: Double) -> Double {
        var d = (b - a).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 } else if d < -180 { d += 360 }
        return d
    }

    static func lerpAngle(_ a: Double, _ b: Double, _ t: Double) -> Double {
        let h = (a + angleDelta(from: a, to: b) * t).truncatingRemainder(dividingBy: 360)
        return h < 0 ? h + 360 : h
    }

    static func offset(_ c: CLLocationCoordinate2D, meters: Double, bearing: Double) -> CLLocationCoordinate2D {
        let earth = 6_371_000.0
        let b = bearing * .pi / 180
        let dLat = meters * cos(b) / earth
        let dLon = meters * sin(b) / (earth * max(0.01, cos(c.latitude * .pi / 180)))
        return CLLocationCoordinate2D(latitude: c.latitude + dLat * 180 / .pi,
                                      longitude: c.longitude + dLon * 180 / .pi)
    }

    static func meters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
}

/// Réglages du survol.
enum FlyoverTuning {
    /// Vrai si MapKit mesure la distance caméra depuis le niveau de la mer plutôt que depuis le relief.
    /// Dans ce cas on recule et on décale la caméra de l'altitude du terrain.
    static var compensateTerrain: Bool {
        #if DEBUG
        if UserDefaults.standard.object(forKey: "terrainComp") != nil {
            return UserDefaults.standard.bool(forKey: "terrainComp")
        }
        #endif
        return false
    }
}

/// Position de caméra, indépendante de MapKit.
struct FlyCam {
    var lat: Double
    var lon: Double
    /// Distance entre la caméra et le point regardé (m)
    var distance: Double
    /// Inclinaison : 0 = vue du dessus
    var pitch: Double
    var heading: Double
    /// Altitude du terrain au point regardé (m)
    var groundAltitude: Double

    static func blend(_ a: FlyCam, _ b: FlyCam, _ u: Double) -> FlyCam {
        FlyCam(lat: a.lat + (b.lat - a.lat) * u,
               lon: a.lon + (b.lon - a.lon) * u,
               distance: exp(log(a.distance) + (log(b.distance) - log(a.distance)) * u),
               pitch: a.pitch + (b.pitch - a.pitch) * u,
               heading: Geo.lerpAngle(a.heading, b.heading, u),
               groundAltitude: a.groundAltitude + (b.groundAltitude - a.groundAltitude) * u)
    }

    var mapCamera: MKMapCamera {
        var center = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        var d = distance
        if FlyoverTuning.compensateTerrain, groundAltitude > 0 {
            let p = min(80, max(0, pitch)) * .pi / 180
            d += groundAltitude / cos(p)
            center = Geo.offset(center, meters: groundAltitude * tan(p), bearing: heading)
        }
        return MKMapCamera(lookingAtCenter: center, fromDistance: d, pitch: CGFloat(pitch), heading: heading)
    }
}

/// Le parcours préparé pour l'animation : tracé allégé, trajectoire de caméra lissée, profil.
struct FlyoverRoute {
    struct Sample: Equatable {
        var lat = 0.0
        var lon = 0.0
        var altitude = 0.0
        var distance = 0.0
        var movingTime = 0.0
        var gain = 0.0
        /// Part du tracé déjà parcourue (0…1), mesurée le long de la ligne dessinée
        var stroke = 0.0

        var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
    }

    let points: [TrackPoint]
    let total: Double
    let overview: FlyCam
    let followDistance: Double
    let playDuration: Double
    /// Profil d'altitude normalisé (x et y entre 0 et 1)
    let profileX: [Double]
    let profileY: [Double]

    private let gains: [Double]
    private let strokes: [Double]
    private let camLat: [Double]
    private let camLon: [Double]
    private let camAlt: [Double]
    private let camHeading: [Double]
    private let lowAltitude: Double
    private let highAltitude: Double

    init(points raw: [TrackPoint]) {
        // 1. Tracé allégé à 800 points
        let step = max(1, raw.count / 800)
        var pts = stride(from: 0, to: raw.count, by: step).map { raw[$0] }
        if let last = raw.last, let kept = pts.last, kept.distance < last.distance { pts.append(last) }
        points = pts
        let totalDistance = pts.last?.distance ?? 0
        total = totalDistance

        // 2. Dénivelé cumulé et avancement le long de la ligne dessinée
        var g: [Double] = []
        var gain = 0.0
        var anchor = pts.first?.alt ?? 0
        var s: [Double] = []
        var length = 0.0
        var previous: MKMapPoint?
        for p in pts {
            let diff = p.alt - anchor
            if diff >= 3 { gain += diff; anchor = p.alt } else if diff <= -3 { anchor = p.alt }
            g.append(gain)
            let mp = MKMapPoint(p.coordinate)
            if let previous { length += hypot(mp.x - previous.x, mp.y - previous.y) }
            previous = mp
            s.append(length)
        }
        let strokeValues = length > 0 ? s.map { $0 / length } : s
        gains = g
        strokes = strokeValues

        // 3. Profil d'altitude
        let alts = pts.map(\.alt)
        let low = (alts.min() ?? 0) - 5
        let high = max((alts.max() ?? 0) + 5, low + 25)
        lowAltitude = low
        highAltitude = high
        let profileStep = max(1, pts.count / 200)
        var profile = stride(from: 0, to: pts.count, by: profileStep).map { pts[$0] }
        if let last = pts.last { profile.append(last) }
        let span = max(1, totalDistance)
        profileX = profile.map { min(1, max(0, $0.distance / span)) }
        profileY = profile.map { ($0.alt - low) / (high - low) }

        // 4. Vue d'ensemble : tout le parcours, caméra inclinée, nord en haut
        let lats = pts.map(\.lat), lons = pts.map(\.lon)
        let minLat = lats.min() ?? 0, maxLat = lats.max() ?? 0
        let minLon = lons.min() ?? 0, maxLon = lons.max() ?? 0
        let diagonal = Geo.meters(CLLocationCoordinate2D(latitude: minLat, longitude: minLon),
                                  CLLocationCoordinate2D(latitude: maxLat, longitude: maxLon))
        let meanAlt = alts.isEmpty ? 0 : alts.reduce(0, +) / Double(alts.count)
        overview = FlyCam(lat: (minLat + maxLat) / 2, lon: (minLon + maxLon) / 2,
                          distance: max(2500, diagonal * 3.6), pitch: 45, heading: 0,
                          groundAltitude: meanAlt)
        followDistance = min(4500, max(1800, totalDistance * 0.35))
        playDuration = min(35, max(12, 10 + totalDistance / 1000 * 1.5))

        // 5. Trajectoire de la caméra : positions régulières le long du parcours, puis lissage,
        //    pour que la caméra glisse au lieu de suivre chaque tremblement du GPS.
        let n = 240
        var la: [Double] = [], lo: [Double] = [], al: [Double] = []
        for i in 0..<n {
            let d = totalDistance * Double(i) / Double(n - 1)
            let sample = Self.interpolate(pts, gains: g, strokes: strokeValues, at: d)
            la.append(sample.lat)
            lo.append(sample.lon)
            al.append(sample.altitude)
        }
        la = Self.smooth(la, radius: 5)
        lo = Self.smooth(lo, radius: 5)
        al = Self.smooth(al, radius: 8)

        // Cap : on regarde vers là où le parcours va, un peu plus loin devant.
        let ahead = 14
        var headings: [Double] = []
        var current = 0.0
        var firstValid: Int?
        for i in 0..<n {
            let j = min(n - 1, i + ahead)
            let a = CLLocationCoordinate2D(latitude: la[i], longitude: lo[i])
            let b = CLLocationCoordinate2D(latitude: la[j], longitude: lo[j])
            if j - i >= ahead / 2, Geo.meters(a, b) > 3 {
                let h = Geo.bearing(a, b)
                // cap « déroulé » : on ajoute l'écart au cap précédent, sans saut à 360°
                current = firstValid == nil ? h : current + Geo.angleDelta(from: current, to: h)
                if firstValid == nil { firstValid = i }
            }
            headings.append(current)
        }
        if let firstValid, firstValid > 0 {
            for i in 0..<firstValid { headings[i] = headings[firstValid] }
        }
        camLat = la
        camLon = lo
        camAlt = al
        camHeading = Self.smooth(headings, radius: 8)
    }

    /// Position exacte du point à `s` mètres du départ.
    func sample(atDistance s: Double) -> Sample {
        Self.interpolate(points, gains: gains, strokes: strokes, at: s)
    }

    /// Hauteur du point sur le profil (0 = bas, 1 = haut).
    func profileHeight(of altitude: Double) -> Double {
        min(1, max(0, (altitude - lowAltitude) / (highAltitude - lowAltitude)))
    }

    /// Caméra qui suit le point, à `s` mètres du départ.
    func followCamera(atDistance s: Double) -> FlyCam {
        let n = camLat.count
        guard n > 1, total > 0 else { return overview }
        let f = min(1, max(0, s / total)) * Double(n - 1)
        let i = min(n - 2, Int(f))
        let u = f - Double(i)
        func mix(_ v: [Double]) -> Double { v[i] + (v[i + 1] - v[i]) * u }
        let heading = mix(camHeading).truncatingRemainder(dividingBy: 360)
        return FlyCam(lat: mix(camLat), lon: mix(camLon), distance: followDistance, pitch: 60,
                      heading: heading < 0 ? heading + 360 : heading, groundAltitude: mix(camAlt))
    }

    private static func interpolate(_ points: [TrackPoint], gains: [Double], strokes: [Double],
                                    at s: Double) -> Sample {
        guard let last = points.last else { return Sample() }
        let target = min(max(0, s), last.distance)
        var lo = 0, hi = points.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if points[mid].distance <= target { lo = mid } else { hi = mid - 1 }
        }
        let a = points[lo]
        guard lo + 1 < points.count else {
            return Sample(lat: a.lat, lon: a.lon, altitude: a.alt, distance: a.distance,
                          movingTime: a.movingTime, gain: gains[lo], stroke: strokes[lo])
        }
        let b = points[lo + 1]
        let span = b.distance - a.distance
        let t = span > 0 ? (target - a.distance) / span : 0
        return Sample(lat: a.lat + (b.lat - a.lat) * t,
                      lon: a.lon + (b.lon - a.lon) * t,
                      altitude: a.alt + (b.alt - a.alt) * t,
                      distance: target,
                      movingTime: a.movingTime + (b.movingTime - a.movingTime) * t,
                      gain: gains[lo] + (gains[lo + 1] - gains[lo]) * t,
                      stroke: strokes[lo] + (strokes[lo + 1] - strokes[lo]) * t)
    }

    private static func smooth(_ values: [Double], radius: Int) -> [Double] {
        guard values.count > 2, radius > 0 else { return values }
        var out = values
        for i in values.indices {
            let a = max(0, i - radius), b = min(values.count - 1, i + radius)
            var sum = 0.0
            for j in a...b { sum += values[j] }
            out[i] = sum / Double(b - a + 1)
        }
        return out
    }
}

/// Déroulé du survol : vue d'ensemble, plongée vers le départ, suivi du point, retour en hauteur.
struct FlyoverTimeline {
    let hold = 2.0
    let dive = 2.4
    let play: Double
    let rise = 2.6
    let ending = 1.5

    var duration: Double { hold + dive + play + rise + ending }
    /// Instant où le point est à mi-parcours
    var midpoint: Double { hold + dive + play / 2 }

    func state(at time: Double, route: FlyoverRoute) -> (camera: FlyCam, distance: Double) {
        let t = min(max(0, time), duration)
        let diveStart = hold
        let playStart = diveStart + dive
        let riseStart = playStart + play
        let endStart = riseStart + rise

        if t < diveStart {
            return (route.overview, 0)
        }
        if t < playStart {
            let u = Self.ease((t - diveStart) / dive)
            return (FlyCam.blend(route.overview, route.followCamera(atDistance: 0), u), 0)
        }
        if t < riseStart {
            let d = route.total * Self.progress((t - playStart) / play)
            return (route.followCamera(atDistance: d), d)
        }
        if t < endStart {
            let u = Self.ease((t - riseStart) / rise)
            return (FlyCam.blend(route.followCamera(atDistance: route.total), route.overview, u), route.total)
        }
        return (route.overview, route.total)
    }

    /// Accélération et freinage doux
    static func ease(_ x: Double) -> Double {
        let u = min(1, max(0, x))
        return u * u * u * (u * (6 * u - 15) + 10)
    }

    /// Vitesse constante, avec un démarrage et une arrivée progressifs (12 % du trajet chacun)
    static func progress(_ x: Double) -> Double {
        let p = min(1, max(0, x))
        let a = 0.12
        let v = 1 / (1 - a)
        if p < a { return v * p * p / (2 * a) }
        if p <= 1 - a { return v * (p - a / 2) }
        return 1 - v * (1 - p) * (1 - p) / (2 * a)
    }
}
