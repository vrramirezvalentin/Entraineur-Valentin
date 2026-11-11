import SwiftUI
import MapKit
import Charts
import ReplayKit
import AVKit
import Photos
import UIKit

// MARK: - Données du parcours pour l'animation

/// Version allégée du tracé (≤ 800 points) avec le dénivelé cumulé, pour animer en fluidité.
struct FlyoverRoute {
    let points: [TrackPoint]
    let gains: [Double]
    let total: Double
    let minAlt: Double
    let maxAlt: Double

    init(points raw: [TrackPoint]) {
        let step = max(1, raw.count / 800)
        var pts = stride(from: 0, to: raw.count, by: step).map { raw[$0] }
        if let last = raw.last, pts.last?.time != last.time { pts.append(last) }
        points = pts

        var g: [Double] = []
        var total = 0.0
        var anchor = pts.first?.alt ?? 0
        for p in pts {
            let diff = p.alt - anchor
            if diff >= 3 { total += diff; anchor = p.alt } else if diff <= -3 { anchor = p.alt }
            g.append(total)
        }
        gains = g
        self.total = pts.last?.distance ?? 0
        minAlt = pts.map(\.alt).min() ?? 0
        maxAlt = pts.map(\.alt).max() ?? 0
    }

    struct Sample {
        var coordinate: CLLocationCoordinate2D
        var altitude: Double
        var distance: Double
        var movingTime: Double
        var gain: Double
        var index: Int
    }

    /// Position interpolée à `s` mètres du départ.
    func sample(atDistance s: Double) -> Sample {
        guard !points.isEmpty else {
            return Sample(coordinate: .init(), altitude: 0, distance: 0, movingTime: 0, gain: 0, index: 0)
        }
        let target = min(max(0, s), total)
        var lo = 0, hi = points.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if points[mid].distance <= target { lo = mid } else { hi = mid - 1 }
        }
        let a = points[lo]
        guard lo + 1 < points.count else {
            return Sample(coordinate: a.coordinate, altitude: a.alt, distance: a.distance,
                          movingTime: a.movingTime, gain: gains[lo], index: lo)
        }
        let b = points[lo + 1]
        let span = b.distance - a.distance
        let t = span > 0 ? (target - a.distance) / span : 0
        return Sample(coordinate: CLLocationCoordinate2D(latitude: a.lat + (b.lat - a.lat) * t,
                                                         longitude: a.lon + (b.lon - a.lon) * t),
                      altitude: a.alt + (b.alt - a.alt) * t,
                      distance: target,
                      movingTime: a.movingTime + (b.movingTime - a.movingTime) * t,
                      gain: gains[lo],
                      index: lo)
    }

    /// Caméra vue d'ensemble, inclinée, cadrant tout le parcours.
    var overviewCamera: MapCamera {
        let lats = points.map(\.lat), lons = points.map(\.lon)
        let minLat = lats.min() ?? 0, maxLat = lats.max() ?? 0
        let minLon = lons.min() ?? 0, maxLon = lons.max() ?? 0
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let diag = CLLocation(latitude: minLat, longitude: minLon)
            .distance(from: CLLocation(latitude: maxLat, longitude: maxLon))
        return MapCamera(centerCoordinate: center, distance: max(1500, diag * 2.4), heading: 0, pitch: 50)
    }

    /// Distance de la caméra en mode suivi, adaptée à la longueur du parcours.
    var followDistance: Double { min(2600, max(700, total * 0.12)) }

    /// Durée de la phase de suivi : ~12 s pour 1 km, 35 s max.
    var playDuration: Double { min(35, max(12, 10 + total / 1000 * 1.5)) }
}

enum Geo {
    static func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    static func lerpAngle(_ a: Double, _ b: Double, _ t: Double) -> Double {
        var d = (b - a).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 } else if d < -180 { d += 360 }
        return (a + d * t + 360).truncatingRemainder(dividingBy: 360)
    }
}

// MARK: - Écran de survol 3D

struct FlyoverView: View {
    let run: Run
    @Environment(\.dismiss) private var dismiss

    @State private var route: FlyoverRoute
    @State private var camera: MapCameraPosition
    @State private var distance: Double = 0
    @State private var heading: Double = 0
    @State private var isPlaying = false
    @State private var isRecording = false
    @State private var satellite = true
    @State private var task: Task<Void, Never>?
    @State private var video: VideoItem?
    @State private var errorMessage: String?

    init(run: Run) {
        self.run = run
        let r = FlyoverRoute(points: run.points)
        _route = State(initialValue: r)
        _camera = State(initialValue: .camera(r.overviewCamera))
    }

    private var current: FlyoverRoute.Sample { route.sample(atDistance: distance) }

    var body: some View {
        let sample = current
        ZStack {
            map(sample)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header(sample)
                Spacer()
                profile(sample)
                if !isRecording { controls }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, isRecording ? 30 : 8)
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear { play(recording: false) }
        .onDisappear {
            task?.cancel()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .sheet(item: $video) { item in
            VideoResultView(url: item.url)
        }
        .alert("Vidéo impossible", isPresented: Binding(get: { errorMessage != nil },
                                                        set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Carte

    private func map(_ sample: FlyoverRoute.Sample) -> some View {
        let all = route.points.map(\.coordinate)
        let traveled = Array(all.prefix(sample.index + 1)) + [sample.coordinate]
        return Map(position: $camera,
                   interactionModes: isPlaying ? MapInteractionModes() : .all) {
            MapPolyline(coordinates: all)
                .stroke(Color.white.opacity(0.55), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            MapPolyline(coordinates: traveled)
                .stroke(Color.orange, style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
            Annotation("", coordinate: sample.coordinate, anchor: .center) {
                ZStack {
                    Circle().fill(Color.orange.opacity(0.3)).frame(width: 38, height: 38)
                    Circle().fill(.white).frame(width: 20, height: 20)
                    Circle().fill(Color.orange).frame(width: 13, height: 13)
                }
                .shadow(radius: 4)
            }
            .annotationTitles(.hidden)
        }
        .mapStyle(satellite ? .imagery(elevation: .realistic) : .standard(elevation: .realistic))
        .mapControlVisibility(.hidden)
    }

    // MARK: Habillage

    private func header(_ s: FlyoverRoute.Sample) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.title).font(.title3.bold())
                    Text(run.startDate.formatted(date: .long, time: .omitted))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !isRecording {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .frame(width: 36, height: 36)
                            .background(.thinMaterial, in: Circle())
                    }
                    .tint(.primary)
                } else {
                    Label("Valentin Entraîneur", systemImage: "figure.run")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                }
            }
            HStack {
                OverlayStat(title: "Distance", value: Fmt.km(s.distance), unit: "km")
                OverlayStat(title: "Temps", value: Fmt.duration(s.movingTime), unit: nil)
                OverlayStat(title: "Altitude", value: "\(Int(s.altitude.rounded()))", unit: "m")
                OverlayStat(title: "D+", value: "\(Int(s.gain.rounded()))", unit: "m")
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.top, 8)
    }

    private func profile(_ s: FlyoverRoute.Sample) -> some View {
        let step = max(1, route.points.count / 200)
        let sampled = stride(from: 0, to: route.points.count, by: step).map { route.points[$0] }
        let low = route.minAlt - 5, high = route.maxAlt + 5
        return Chart {
            ForEach(Array(sampled.enumerated()), id: \.offset) { _, p in
                AreaMark(x: .value("Distance", p.distance / 1000),
                         yStart: .value("Base", low),
                         yEnd: .value("Altitude", p.alt))
                    .foregroundStyle(Color.orange.opacity(0.3))
                LineMark(x: .value("Distance", p.distance / 1000),
                         y: .value("Altitude", p.alt))
                    .foregroundStyle(Color.orange)
            }
            RuleMark(x: .value("Position", s.distance / 1000))
                .foregroundStyle(Color.primary.opacity(0.4))
            PointMark(x: .value("Position", s.distance / 1000),
                      y: .value("Altitude", s.altitude))
                .foregroundStyle(Color.orange)
                .symbolSize(90)
        }
        .chartYScale(domain: low...max(high, low + 20))
        .chartXScale(domain: 0...max(0.1, route.total / 1000))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 70)
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.bottom, 10)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                satellite.toggle()
            } label: {
                Image(systemName: satellite ? "map" : "globe.europe.africa.fill")
                    .font(.title3)
                    .frame(width: 52, height: 52)
                    .background(.regularMaterial, in: Circle())
            }
            .tint(.primary)
            .disabled(isPlaying)

            Button {
                play(recording: false)
            } label: {
                Label(isPlaying ? "Lecture…" : "Rejouer", systemImage: "arrow.counterclockwise")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(.regularMaterial, in: Capsule())
            }
            .tint(.primary)
            .disabled(isPlaying)

            Button {
                play(recording: true)
            } label: {
                Label("Créer la vidéo", systemImage: "video.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Color.orange, in: Capsule())
            }
            .disabled(isPlaying)
        }
    }

    // MARK: Animation

    private func play(recording: Bool) {
        guard route.points.count > 1 else { return }
        task?.cancel()
        task = Task { @MainActor in
            isPlaying = true
            UIApplication.shared.isIdleTimerDisabled = true
            defer {
                isPlaying = false
                UIApplication.shared.isIdleTimerDisabled = false
            }

            distance = 0
            withAnimation(.easeInOut(duration: 1)) { camera = .camera(route.overviewCamera) }

            if recording {
                isRecording = true
                guard await Recorder.start() else {
                    isRecording = false
                    errorMessage = "L'enregistrement de l'écran a été refusé ou n'est pas disponible."
                    return
                }
            }

            // 1. Vue d'ensemble, le temps que le relief se charge
            try? await Task.sleep(for: .seconds(2.5))
            if Task.isCancelled { return await abort(recording) }

            // 2. Plongée vers le départ
            let start = route.sample(atDistance: 0)
            let ahead = route.sample(atDistance: lookAhead)
            heading = Geo.bearing(start.coordinate, ahead.coordinate)
            withAnimation(.easeInOut(duration: 2)) {
                camera = .camera(followCamera(start.coordinate))
            }
            try? await Task.sleep(for: .seconds(2.2))
            if Task.isCancelled { return await abort(recording) }

            // 3. Suivi du point le long du tracé
            let begin = Date()
            let duration = route.playDuration
            while !Task.isCancelled {
                let p = min(1, Date().timeIntervalSince(begin) / duration)
                let eased = p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2   // départ et arrivée en douceur
                distance = route.total * (0.15 * p + 0.85 * eased)
                let here = route.sample(atDistance: distance)
                let target = route.sample(atDistance: distance + lookAhead)
                heading = Geo.lerpAngle(heading, Geo.bearing(here.coordinate, target.coordinate), 0.05)
                camera = .camera(followCamera(here.coordinate))
                if p >= 1 { break }
                try? await Task.sleep(for: .milliseconds(33))
            }
            if Task.isCancelled { return await abort(recording) }

            // 4. Retour à la vue d'ensemble
            withAnimation(.easeInOut(duration: 2.5)) { camera = .camera(route.overviewCamera) }
            try? await Task.sleep(for: .seconds(3))

            if recording {
                isRecording = false
                do {
                    let url = try await Recorder.stop(name: run.title)
                    video = VideoItem(url: url)
                } catch {
                    errorMessage = "La vidéo n'a pas pu être enregistrée."
                }
            }
        }
    }

    private func abort(_ recording: Bool) async {
        if recording {
            isRecording = false
            _ = try? await Recorder.stop(name: "annule")
        }
    }

    private var lookAhead: Double { max(120, route.total * 0.03) }

    private func followCamera(_ c: CLLocationCoordinate2D) -> MapCamera {
        MapCamera(centerCoordinate: c, distance: route.followDistance, heading: heading, pitch: 65)
    }
}

private struct OverlayStat: View {
    let title: String
    let value: String
    let unit: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.system(.headline, design: .rounded).weight(.bold)).monospacedDigit()
                if let unit { Text(unit).font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Enregistrement vidéo (ReplayKit)

enum Recorder {
    static func start() async -> Bool {
        let recorder = RPScreenRecorder.shared()
        guard recorder.isAvailable else { return false }
        recorder.isMicrophoneEnabled = false
        return await withCheckedContinuation { cont in
            recorder.startRecording { error in
                cont.resume(returning: error == nil)
            }
        }
    }

    static func stop(name: String) async throws -> URL {
        let unsafe = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let safe = name.components(separatedBy: unsafe).joined()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Valentin Entraineur - \(safe.isEmpty ? "course" : safe).mp4")
        try? FileManager.default.removeItem(at: url)
        return try await withCheckedThrowingContinuation { cont in
            RPScreenRecorder.shared().stopRecording(withOutput: url) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: url) }
            }
        }
    }
}

struct VideoItem: Identifiable {
    let url: URL
    var id: URL { url }
}

// MARK: - Aperçu et export de la vidéo

struct VideoResultView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer
    @State private var saved = false
    @State private var saveError = false

    init(url: URL) {
        self.url = url
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                VideoPlayer(player: player)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .onAppear { player.play() }

                HStack(spacing: 12) {
                    Button {
                        saveToPhotos()
                    } label: {
                        Label(saved ? "Enregistrée" : "Dans Photos",
                              systemImage: saved ? "checkmark" : "square.and.arrow.down")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .disabled(saved)

                    ShareLink(item: url) {
                        Label("Partager", systemImage: "square.and.arrow.up")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                }
            }
            .padding()
            .navigationTitle("Ta vidéo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
            .alert("Accès à Photos refusé", isPresented: $saveError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Autorise Valentin Entraîneur à ajouter des photos dans Réglages, ou utilise Partager.")
            }
        }
    }

    private func saveToPhotos() {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { saveError = true }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { ok, _ in
                DispatchQueue.main.async {
                    if ok { saved = true } else { saveError = true }
                }
            }
        }
    }
}
