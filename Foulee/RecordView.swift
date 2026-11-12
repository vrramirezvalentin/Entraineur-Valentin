import SwiftUI
import MapKit
import SwiftData
import UIKit

struct RecordView: View {
    @Environment(RunTracker.self) private var tracker
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @AppStorage("voice") private var voice = true

    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var confirmFinish = false
    @State private var savedRun: Run?
    @State private var tooShort = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Map(position: $camera) {
                UserAnnotation()
                ForEach(Array(tracker.points.coordinateSegments(maxPoints: 1500).enumerated()), id: \.offset) { _, segment in
                    MapPolyline(coordinates: segment)
                        .stroke(.orange, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                }
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            .mapControls {
                MapUserLocationButton()
                MapCompass()
            }

            panel
        }
        .onAppear { tracker.warmUp() }
        .onDisappear { tracker.coolDown() }
        .confirmationDialog("Terminer la course ?", isPresented: $confirmFinish, titleVisibility: .visible) {
            Button("Enregistrer") {
                if let run = tracker.finish(in: context) {
                    savedRun = run
                } else {
                    tooShort = true
                }
            }
            Button("Supprimer la course", role: .destructive) { tracker.discard() }
            Button("Continuer", role: .cancel) {}
        }
        .alert("Course trop courte", isPresented: $tooShort) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Moins de 20 m enregistrés : rien n'a été sauvegardé.")
        }
        .sheet(item: $savedRun) { run in
            NavigationStack {
                RunDetailView(run: run)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("OK") { savedRun = nil }
                        }
                    }
            }
        }
    }

    // MARK: - Panneau du bas

    private var panel: some View {
        VStack(spacing: 18) {
            HStack {
                gpsBadge
                Spacer()
                Button {
                    voice.toggle()
                } label: {
                    Image(systemName: voice ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.title3)
                        .frame(width: 40, height: 40)
                }
                .accessibilityLabel(voice ? "Couper les annonces vocales" : "Activer les annonces vocales")
            }

            if tracker.state == .idle {
                idleControls
            } else {
                liveStats
                runningControls
            }
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var idleControls: some View {
        if tracker.isDenied {
            VStack(spacing: 10) {
                Text("Valentin Entraîneur a besoin de ta position pour tracer tes courses.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Ouvrir les Réglages") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
        } else {
            Button {
                tracker.start()
            } label: {
                Label("Démarrer", systemImage: "play.fill")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(!tracker.isAuthorized)
        }
    }

    private var liveStats: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let time = tracker.movingTime(at: context.date)
            let average = tracker.distance > 0 ? time / tracker.distance * 1000 : 0
            VStack(spacing: 14) {
                Text(Fmt.duration(time))
                    .font(.system(size: 60, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tracker.state == .paused ? Color.secondary : Color.primary)
                HStack {
                    LiveStat(title: "Distance", value: Fmt.km(tracker.distance), unit: "km")
                    LiveStat(title: "Allure", value: Fmt.pace(tracker.currentPace), unit: "/km")
                    LiveStat(title: "Moyenne", value: Fmt.pace(average), unit: "/km")
                }
                HStack {
                    LiveStat(title: "Pas", value: Fmt.steps(tracker.steps), unit: "pas", small: true)
                    LiveStat(title: "Cadence", value: Fmt.cadence(tracker.cadence), unit: "pas/min", small: true)
                    LiveStat(title: "Dénivelé +", value: "\(Int(tracker.elevationGain.rounded()))", unit: "m", small: true)
                }
                if tracker.isPedometerDenied {
                    Text("Pour compter les pas, autorise « Mouvements et forme » dans les Réglages de l'appli.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    @ViewBuilder
    private var runningControls: some View {
        if tracker.state == .running {
            Button {
                tracker.pause()
            } label: {
                Label("Pause", systemImage: "pause.fill")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
        } else {
            HStack(spacing: 12) {
                Button {
                    tracker.resume()
                } label: {
                    Label("Reprendre", systemImage: "play.fill")
                        .font(.title3.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)

                Button {
                    confirmFinish = true
                } label: {
                    Label("Terminer", systemImage: "flag.checkered")
                        .font(.title3.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
            }
        }
    }

    private var gpsBadge: some View {
        let (text, color): (String, Color) = {
            if tracker.isReducedAccuracy { return ("Active « Position exacte » dans Réglages", .red) }
            guard let acc = tracker.gpsAccuracy else { return ("Recherche GPS…", .gray) }
            if acc <= 10 { return ("GPS excellent", .green) }
            if acc <= 25 { return ("GPS correct", .yellow) }
            return ("GPS faible", .red)
        }()
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(text).font(.footnote.weight(.medium)).foregroundStyle(.secondary)
        }
    }
}

private struct LiveStat: View {
    let title: String
    let value: String
    let unit: String
    var small = false

    var body: some View {
        VStack(spacing: 2) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(small ? .title3 : .title2, design: .rounded).weight(.bold))
                .monospacedDigit()
            Text(unit)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
