import Foundation
import CoreTransferable
import UniformTypeIdentifiers

enum RunAnalysis {
    struct Effort: Identifiable {
        let meters: Int
        let label: String
        var id: Int { meters }
    }

    static let efforts: [Effort] = [
        Effort(meters: 1000, label: "1 km"),
        Effort(meters: 5000, label: "5 km"),
        Effort(meters: 10000, label: "10 km"),
        Effort(meters: 21097, label: "Semi-marathon"),
        Effort(meters: 42195, label: "Marathon"),
    ]

    /// Meilleur temps (s) pour couvrir `target` mètres à l'intérieur d'une course.
    static func bestTime(for target: Double, in points: [TrackPoint]) -> Double? {
        guard let last = points.last, last.distance >= target else { return nil }
        var best = Double.infinity
        var i = 0
        for j in points.indices {
            while i + 1 < j, points[j].distance - points[i + 1].distance >= target {
                i += 1
            }
            let d = points[j].distance - points[i].distance
            if d >= target {
                let t = points[j].movingTime - points[i].movingTime
                best = min(best, t * target / d)
            }
        }
        return best.isFinite ? best : nil
    }

    static func defaultTitle(for date: Date) -> String {
        let h = Calendar.current.component(.hour, from: date)
        switch h {
        case 5..<12: return "Course du matin"
        case 12..<14: return "Course du midi"
        case 14..<18: return "Course de l'après-midi"
        case 18..<22: return "Course du soir"
        default: return "Course de nuit"
        }
    }

    static func gpx(name: String, points: [TrackPoint]) -> String {
        let iso = ISO8601DateFormatter()
        var s = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Entraineur Valentin" xmlns="http://www.topografix.com/GPX/1/1">
        <trk><name>\(escape(name))</name><type>running</type>

        """
        let segments = Dictionary(grouping: points, by: \.segment).sorted { $0.key < $1.key }
        for (_, pts) in segments {
            s += "<trkseg>\n"
            for p in pts {
                s += "<trkpt lat=\"\(p.lat)\" lon=\"\(p.lon)\"><ele>\(String(format: "%.1f", p.alt))</ele><time>\(iso.string(from: p.time))</time></trkpt>\n"
            }
            s += "</trkseg>\n"
        }
        s += "</trk>\n</gpx>\n"
        return s
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// Fichier GPX partageable (Garmin Connect, Komoot, ou même Strava si tu changes d'avis).
struct GPXFile: Transferable, Sendable {
    let name: String
    let points: [TrackPoint]

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: UTType(filenameExtension: "gpx") ?? .xml) { file in
            let unsafe = CharacterSet(charactersIn: "/\\:?%*|\"<>")
            let safe = file.name.components(separatedBy: unsafe).joined()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(safe.isEmpty ? "course" : safe).gpx")
            try RunAnalysis.gpx(name: file.name, points: file.points)
                .write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
    }
}

enum Fmt {
    /// 1:05:32 ou 27:45
    static func duration(_ seconds: Double) -> String {
        let t = max(0, Int(seconds.rounded(.down)))
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Allure 5:32 (par km)
    static func pace(_ secPerKm: Double) -> String {
        guard secPerKm.isFinite, secPerKm > 0, secPerKm < 3600 else { return "–:––" }
        let t = Int(secPerKm.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    /// 5,24 (km)
    static func km(_ meters: Double, decimals: Int = 2) -> String {
        (meters / 1000).formatted(.number.precision(.fractionLength(decimals)))
    }

    static func spokenDuration(_ seconds: Double) -> String {
        let t = max(0, Int(seconds.rounded()))
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        if h > 0 {
            return "\(h) heure\(h > 1 ? "s" : "") \(m) minute\(m > 1 ? "s" : "")"
        }
        if m > 0 {
            return "\(m) minute\(m > 1 ? "s" : "") \(s)"
        }
        return "\(s) secondes"
    }
}
