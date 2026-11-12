import SwiftUI
import MapKit
import UIKit

// MARK: - Modèle du survol

/// Cadence l'animation en direct sur le rafraîchissement de l'écran.
@MainActor
final class DisplayTicker: NSObject {
    var onTick: (@MainActor () -> Void)?

    @objc func tick() {
        onTick?()
    }
}

@MainActor
@Observable
final class FlyoverModel {
    let title: String
    let date: Date
    let route: FlyoverRoute
    let timeline: FlyoverTimeline
    let map = FlyoverMapController()

    /// Où en est le point (distance, temps, altitude…), pour l'habillage
    private(set) var sample = FlyoverRoute.Sample()
    private(set) var isPlaying = false
    private(set) var isExporting = false
    private(set) var exportProgress = 0.0
    private(set) var satellite = true

    /// Vue capturée pour la vidéo (carte + habillage, sans les boutons)
    @ObservationIgnored weak var captureView: UIView?
    /// Compte rendu de la dernière création de vidéo (durée, images…)
    @ObservationIgnored private(set) var exportReport = ""

    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var ticker = DisplayTicker()
    @ObservationIgnored private var playStart: CFTimeInterval = 0
    @ObservationIgnored private var trustBusyFlag = true
    @ObservationIgnored private var busyTimeouts = 0

    init(run: Run) {
        let prepared = FlyoverRoute(points: run.points)
        title = run.title
        date = run.startDate
        route = prepared
        timeline = FlyoverTimeline(play: prepared.playDuration)
        map.configure()
        map.load(prepared)
        sample = prepared.sample(atDistance: 0)
    }

    /// Affiche le survol à l'instant `time` (en secondes depuis le début).
    func apply(time: Double) {
        let state = timeline.state(at: time, route: route)
        let position = route.sample(atDistance: state.distance)
        map.show(camera: state.camera, runnerAt: position.coordinate, stroke: position.stroke)
        if position != sample { sample = position }
    }

    func toggleSatellite() {
        satellite.toggle()
        map.setSatellite(satellite)
    }

    // MARK: Lecture en direct

    func play() {
        guard !isExporting, route.points.count > 1 else { return }
        stopLink()
        isPlaying = true
        map.mapView.isUserInteractionEnabled = false
        UIApplication.shared.isIdleTimerDisabled = true
        apply(time: 0)
        playStart = CACurrentMediaTime()
        ticker.onTick = { [weak self] in self?.tick() }
        let displayLink = CADisplayLink(target: ticker, selector: #selector(DisplayTicker.tick))
        displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        displayLink.add(to: .main, forMode: .common)
        link = displayLink
    }

    /// Arrête la lecture (la carte redevient manipulable au doigt).
    func stop() {
        stopLink()
        if !isExporting {
            map.mapView.isUserInteractionEnabled = true
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private func tick() {
        let elapsed = CACurrentMediaTime() - playStart
        apply(time: elapsed)
        if elapsed >= timeline.duration { stop() }
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
        ticker.onTick = nil
        isPlaying = false
    }

    // MARK: Création de la vidéo

    /// Fabrique la vidéo image par image et renvoie le fichier MP4.
    func exportVideo() async throws -> URL {
        guard let view = captureView, route.points.count > 1 else { throw VideoExportError.noView }
        stopLink()
        isExporting = true
        exportProgress = 0
        map.mapView.isUserInteractionEnabled = false
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            isExporting = false
            map.mapView.isUserInteractionEnabled = true
            UIApplication.shared.isIdleTimerDisabled = false
        }

        let fps = 30
        let frames = Int((timeline.duration * Double(fps)).rounded(.up)) + 1
        let began = CACurrentMediaTime()
        trustBusyFlag = true
        busyTimeouts = 0
        var totalTimeouts = 0

        // La vue d'ensemble doit être nette avant la première image.
        apply(time: 0)
        _ = await settle(minimumTicks: 30, timeout: 8)

        let unsafe = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let safeTitle = title.components(separatedBy: unsafe).joined()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Valentin Entraineur - \(safeTitle.isEmpty ? "course" : safeTitle).mp4")
        let writer = try FrameVideoWriter(view: view, fps: fps, url: url)

        do {
            for frame in 0..<frames {
                try Task.checkCancellation()
                // Rien ne peut être capturé quand l'appli est en arrière-plan : on attend son retour.
                while UIApplication.shared.applicationState != .active {
                    try await Task.sleep(for: .milliseconds(300))
                }
                apply(time: Double(frame) / Double(fps))
                if await settle(minimumTicks: 2, timeout: 1.5) { totalTimeouts += 1 }
                try await writer.append(view)
                exportProgress = Double(frame + 1) / Double(frames)
            }
            try await writer.finish()
        } catch {
            writer.cancel()
            throw error
        }

        let seconds = CACurrentMediaTime() - began
        exportReport = "images=\(frames) fps=\(fps) taille=\(writer.pixelWidth)x\(writer.pixelHeight) "
            + "duree=\(String(format: "%.1f", seconds))s par_image=\(String(format: "%.0f", seconds / Double(frames) * 1000))ms "
            + "attentes_depassees=\(totalTimeouts) drapeau_fiable=\(trustBusyFlag)"
        return url
    }

    /// Laisse la carte dessiner la nouvelle image. Renvoie vrai si on a renoncé à attendre.
    private func settle(minimumTicks: Int, timeout: Double) async -> Bool {
        for _ in 0..<minimumTicks {
            try? await Task.sleep(for: .milliseconds(16))
        }
        guard trustBusyFlag else { return false }
        let began = CACurrentMediaTime()
        while map.isBusy {
            if Task.isCancelled { return false }
            if CACurrentMediaTime() - began > timeout {
                // Si la carte ne signale jamais la fin de son dessin, on arrête de lui faire confiance.
                busyTimeouts += 1
                if busyTimeouts >= 6 { trustBusyFlag = false }
                return true
            }
            try? await Task.sleep(for: .milliseconds(16))
        }
        busyTimeouts = 0
        return false
    }
}

// MARK: - Écran

struct FlyoverView: View {
    enum Start { case play, still, export }

    let run: Run
    let start: Start

    @Environment(\.dismiss) private var dismiss
    @State private var model: FlyoverModel? = nil
    @State private var exportTask: Task<Void, Never>? = nil
    @State private var video: VideoItem? = nil
    @State private var errorMessage: String? = nil

    init(run: Run, start: Start = .play) {
        self.run = run
        self.start = start
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let model {
                CaptureHost(model: model) { FlyoverCanvas(model: model) }
                    .ignoresSafeArea()
                chrome(model)
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .task { await begin() }
        .onDisappear {
            exportTask?.cancel()
            model?.stop()
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

    private func begin() async {
        guard model == nil else { return }
        let created = FlyoverModel(run: run)
        model = created
        // Le temps que la carte prenne place à l'écran
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled else { return }
        switch start {
        case .play: created.play()
        case .still: created.apply(time: created.timeline.midpoint)
        case .export: startExport(created)
        }
    }

    private func startExport(_ model: FlyoverModel) {
        exportTask?.cancel()
        exportTask = Task {
            do {
                let url = try await model.exportVideo()
                #if DEBUG
                DemoData.exportFinished(url: url, report: model.exportReport)
                #endif
                video = VideoItem(url: url)
            } catch is CancellationError {
                // Annulé par l'utilisateur
            } catch {
                #if DEBUG
                DemoData.exportFailed(error)
                #endif
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Boutons (jamais dans la vidéo)

    private func chrome(_ model: FlyoverModel) -> some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                if !model.isExporting {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .frame(width: 36, height: 36)
                            .background(Color(.tertiarySystemFill), in: Circle())
                    }
                    .tint(.primary)
                    .accessibilityLabel("Fermer")
                }
            }
            .frame(height: 36)
            .padding(.top, 20)
            .padding(.trailing, 28)

            Spacer()

            if model.isExporting {
                exportPanel(model)
            } else {
                controls(model)
            }
        }
        .padding(.bottom, 8)
    }

    private func controls(_ model: FlyoverModel) -> some View {
        HStack(spacing: 10) {
            Button {
                model.toggleSatellite()
            } label: {
                Image(systemName: model.satellite ? "map" : "globe.europe.africa.fill")
                    .font(.title3)
                    .frame(width: 52, height: 52)
                    .background(.regularMaterial, in: Circle())
            }
            .tint(.primary)
            .accessibilityLabel(model.satellite ? "Afficher le plan" : "Afficher la vue satellite")

            Button {
                model.play()
            } label: {
                Label(model.isPlaying ? "Lecture…" : "Rejouer", systemImage: "arrow.counterclockwise")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(.regularMaterial, in: Capsule())
            }
            .tint(.primary)
            .disabled(model.isPlaying)

            Button {
                startExport(model)
            } label: {
                Label("Créer la vidéo", systemImage: "video.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Color.orange, in: Capsule())
            }
        }
        .padding(.horizontal, 14)
    }

    private func exportPanel(_ model: FlyoverModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Création de la vidéo… \(Int(model.exportProgress * 100)) %")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Spacer()
                Button("Annuler") { exportTask?.cancel() }
                    .font(.subheadline.weight(.semibold))
            }
            ProgressView(value: model.exportProgress)
                .tint(.orange)
            Text("Garde l'appli ouverte : chaque image est dessinée une à une pour une vidéo bien fluide.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 14)
    }
}

// MARK: - Ce qui apparaît dans la vidéo

/// Héberge la carte et son habillage dans une vue UIKit, pour pouvoir la capturer image par image.
struct CaptureHost<Content: View>: UIViewControllerRepresentable {
    let model: FlyoverModel
    @ViewBuilder let content: () -> Content

    func makeUIViewController(context: Context) -> UIHostingController<Content> {
        let host = UIHostingController(rootView: content())
        host.view.backgroundColor = .black
        model.captureView = host.view
        return host
    }

    func updateUIViewController(_ host: UIHostingController<Content>, context: Context) {}
}

struct FlyoverCanvas: View {
    let model: FlyoverModel

    var body: some View {
        ZStack {
            FlyoverMapView(controller: model.map)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                FlyoverHeader(model: model)
                Spacer(minLength: 0)
                FlyoverProfile(model: model)
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            // Hors vidéo, on laisse la place des boutons sous le profil.
            .padding(.bottom, model.isExporting ? 8 : 70)
        }
        .tint(.orange)
    }
}

private struct FlyoverPanel: ViewModifier {
    let radius: CGFloat

    func body(content: Content) -> some View {
        content.background(Color(.systemBackground).opacity(0.88),
                           in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

struct FlyoverHeader: View {
    let model: FlyoverModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.title)
                        .font(.title3.bold())
                        .lineLimit(2)
                    Text(model.date.formatted(date: .long, time: .omitted))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isExporting {
                    Label("Valentin Entraîneur", systemImage: "figure.run")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                } else {
                    // Place du bouton Fermer, posé par-dessus
                    Color.clear.frame(width: 36, height: 36)
                }
            }
            FlyoverStats(model: model)
        }
        .padding(16)
        .modifier(FlyoverPanel(radius: 22))
    }
}

/// Les chiffres qui défilent pendant le survol.
struct FlyoverStats: View {
    let model: FlyoverModel

    var body: some View {
        let s = model.sample
        HStack {
            OverlayStat(title: "Distance", value: Fmt.km(s.distance), unit: "km")
            OverlayStat(title: "Temps", value: Fmt.duration(s.movingTime), unit: nil)
            OverlayStat(title: "Altitude", value: "\(Int(s.altitude.rounded()))", unit: "m")
            OverlayStat(title: "D+", value: "\(Int(s.gain.rounded()))", unit: "m")
        }
    }
}

private struct OverlayStat: View {
    let title: String
    let value: String
    let unit: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(.headline, design: .rounded).weight(.bold))
                    .monospacedDigit()
                if let unit {
                    Text(unit)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Profil d'altitude, avec un curseur qui suit le point.
struct FlyoverProfile: View {
    let model: FlyoverModel

    var body: some View {
        ZStack {
            ProfileShape(xs: model.route.profileX, ys: model.route.profileY, closed: true)
                .fill(Color.orange.opacity(0.3))
            ProfileShape(xs: model.route.profileX, ys: model.route.profileY, closed: false)
                .stroke(Color.orange, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            ProfileCursor(model: model)
        }
        .frame(height: 64)
        .padding(12)
        .modifier(FlyoverPanel(radius: 18))
    }
}

private struct ProfileCursor: View {
    let model: FlyoverModel

    var body: some View {
        GeometryReader { geo in
            let s = model.sample
            let width = Double(geo.size.width)
            let height = Double(geo.size.height)
            let x: Double = (model.route.total > 0 ? s.distance / model.route.total : 0) * width
            let y: Double = (1 - model.route.profileHeight(of: s.altitude)) * height
            Path { path in
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: height))
            }
            .stroke(Color.primary.opacity(0.4), lineWidth: 1)
            Circle()
                .fill(Color.orange)
                .frame(width: 10, height: 10)
                .position(x: CGFloat(x), y: CGFloat(y))
        }
    }
}

private struct ProfileShape: Shape {
    let xs: [Double]
    let ys: [Double]
    let closed: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard xs.count > 1, xs.count == ys.count else { return path }
        for i in xs.indices {
            let point = CGPoint(x: rect.minX + CGFloat(xs[i]) * rect.width,
                                y: rect.maxY - CGFloat(ys[i]) * rect.height)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        if closed {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}
