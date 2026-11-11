import Foundation
import CoreLocation
import AVFoundation
import SwiftData
import Observation

/// Enregistre la course : GPS (y compris écran verrouillé), distance, dénivelé,
/// temps intermédiaires et annonces vocales.
@Observable
final class RunTracker: NSObject, CLLocationManagerDelegate, AVSpeechSynthesizerDelegate {
    enum State { case idle, running, paused }

    private(set) var state: State = .idle
    private(set) var points: [TrackPoint] = []
    private(set) var distance: Double = 0
    private(set) var elevationGain: Double = 0
    private(set) var splits: [Split] = []
    /// Allure instantanée (s/km) sur les ~20 dernières secondes
    private(set) var currentPace: Double = 0
    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    /// Précision du dernier fix GPS (m), nil si pas encore de signal
    private(set) var gpsAccuracy: Double? = nil
    private(set) var startDate: Date? = nil

    private let manager = CLLocationManager()
    private let speech = AVSpeechSynthesizer()
    @ObservationIgnored private var lastLocation: CLLocation? = nil
    @ObservationIgnored private var altitudeAnchor: Double? = nil
    @ObservationIgnored private var accumulatedMoving: Double = 0
    @ObservationIgnored private var segmentStart: Date? = nil
    @ObservationIgnored private var segment = 0
    @ObservationIgnored private var lastSplitTime: Double = 0
    @ObservationIgnored private var lastSplitElevation: Double = 0
    @ObservationIgnored private var warmingUp = false

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .fitness
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        speech.delegate = self
        authorization = manager.authorizationStatus
    }

    var isAuthorized: Bool {
        authorization == .authorizedWhenInUse || authorization == .authorizedAlways
    }

    var isDenied: Bool {
        authorization == .denied || authorization == .restricted
    }

    /// Temps en mouvement à l'instant `now` (pauses exclues).
    func movingTime(at now: Date = Date()) -> Double {
        accumulatedMoving + (segmentStart.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    // MARK: - Préparation GPS

    func warmUp() {
        guard state == .idle else { return }
        warmingUp = true
        if authorization == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else if isAuthorized {
            manager.startUpdatingLocation()
        }
    }

    func coolDown() {
        guard state == .idle else { return }
        warmingUp = false
        manager.stopUpdatingLocation()
        gpsAccuracy = nil
    }

    // MARK: - Contrôles

    func start() {
        reset()
        let now = Date()
        state = .running
        startDate = now
        segmentStart = now
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        announce("C'est parti !")
    }

    func pause() {
        guard state == .running else { return }
        if let s = segmentStart { accumulatedMoving += Date().timeIntervalSince(s) }
        segmentStart = nil
        lastLocation = nil
        currentPace = 0
        state = .paused
        announce("Pause")
    }

    func resume() {
        guard state == .paused else { return }
        segment += 1
        segmentStart = Date()
        state = .running
        announce("Reprise")
    }

    /// Enregistre la course. Renvoie nil si elle est trop courte.
    func finish(in context: ModelContext) -> Run? {
        let end = Date()
        if let s = segmentStart { accumulatedMoving += end.timeIntervalSince(s) }
        segmentStart = nil
        defer { discard() }

        guard let start = startDate, points.count >= 2, distance >= 20 else { return nil }

        var allSplits = splits
        let rest = distance - Double(splits.count) * 1000
        if rest >= 50 {
            allSplits.append(Split(index: splits.count + 1,
                                   distance: rest,
                                   duration: accumulatedMoving - lastSplitTime,
                                   elevationGain: elevationGain - lastSplitElevation))
        }

        var efforts: [Int: Double] = [:]
        for effort in RunAnalysis.efforts {
            if let t = RunAnalysis.bestTime(for: Double(effort.meters), in: points) {
                efforts[effort.meters] = t
            }
        }

        let encoder = JSONEncoder()
        let run = Run(startDate: start,
                      title: RunAnalysis.defaultTitle(for: start),
                      distance: distance,
                      movingTime: accumulatedMoving,
                      elapsedTime: end.timeIntervalSince(start),
                      elevationGain: elevationGain,
                      pointsData: (try? encoder.encode(points)) ?? Data(),
                      splitsData: (try? encoder.encode(allSplits)) ?? Data(),
                      bestEffortsData: (try? encoder.encode(efforts)) ?? Data())
        context.insert(run)
        try? context.save()

        announce("Course terminée. \(Fmt.km(distance, decimals: 1)) kilomètres en \(Fmt.spokenDuration(accumulatedMoving)).")
        return run
    }

    /// Arrête et oublie la course en cours.
    func discard() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        state = .idle
        reset()
        if warmingUp && isAuthorized { manager.startUpdatingLocation() }
    }

    private func reset() {
        points = []
        distance = 0
        elevationGain = 0
        splits = []
        currentPace = 0
        startDate = nil
        lastLocation = nil
        altitudeAnchor = nil
        accumulatedMoving = 0
        segmentStart = nil
        segment = 0
        lastSplitTime = 0
        lastSplitElevation = 0
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        if isAuthorized && (warmingUp || state != .idle) {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for location in locations { process(location) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Erreurs transitoires (perte de signal) : on continue simplement.
    }

    private func process(_ loc: CLLocation) {
        if loc.horizontalAccuracy >= 0 { gpsAccuracy = loc.horizontalAccuracy }

        guard state == .running else { return }
        guard loc.horizontalAccuracy >= 0, loc.horizontalAccuracy <= 25 else { return }
        guard abs(loc.timestamp.timeIntervalSinceNow) < 15 else { return }
        if let s = segmentStart, loc.timestamp < s { return }

        if let last = lastLocation {
            let dt = loc.timestamp.timeIntervalSince(last.timestamp)
            guard dt > 0 else { return }
            let d = loc.distance(from: last)
            if d < 3 { return }          // bruit GPS à l'arrêt
            if d / dt > 12 { return }    // saut aberrant (> 43 km/h)
            distance += d
        }

        // Dénivelé positif avec un seuil de 3 m pour filtrer le bruit d'altitude
        if loc.verticalAccuracy >= 0, loc.verticalAccuracy <= 20 {
            if let anchor = altitudeAnchor {
                let diff = loc.altitude - anchor
                if diff >= 3 {
                    elevationGain += diff
                    altitudeAnchor = loc.altitude
                } else if diff <= -3 {
                    altitudeAnchor = loc.altitude
                }
            } else {
                altitudeAnchor = loc.altitude
            }
        }

        let moving = movingTime(at: loc.timestamp)
        points.append(TrackPoint(lat: loc.coordinate.latitude,
                                 lon: loc.coordinate.longitude,
                                 alt: loc.altitude,
                                 time: loc.timestamp,
                                 distance: distance,
                                 movingTime: moving,
                                 segment: segment))
        lastLocation = loc

        updateCurrentPace(now: loc.timestamp)
        checkSplits(moving: moving)
    }

    private func updateCurrentPace(now: Date) {
        guard let latest = points.last else { return }
        var reference = latest
        for p in points.reversed() {
            if p.segment != segment || now.timeIntervalSince(p.time) > 20 { break }
            reference = p
        }
        let dd = latest.distance - reference.distance
        let dt = latest.movingTime - reference.movingTime
        currentPace = (dd > 5 && dt > 3) ? dt / dd * 1000 : 0
    }

    private func checkSplits(moving: Double) {
        while distance >= Double(splits.count + 1) * 1000 {
            let split = Split(index: splits.count + 1,
                              distance: 1000,
                              duration: moving - lastSplitTime,
                              elevationGain: elevationGain - lastSplitElevation)
            splits.append(split)
            lastSplitTime = moving
            lastSplitElevation = elevationGain

            let k = split.index
            announce("\(k) kilomètre\(k > 1 ? "s" : ""). Temps \(Fmt.spokenDuration(moving)). Dernier kilomètre en \(Fmt.spokenDuration(split.duration)).")
        }
    }

    // MARK: - Voix

    private func announce(_ text: String) {
        guard UserDefaults.standard.bool(forKey: "voice") else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .voicePrompt,
                                 options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        try? session.setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "fr-FR")
        speech.speak(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        if !synthesizer.isSpeaking {
            // Rend le volume à la musique
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
