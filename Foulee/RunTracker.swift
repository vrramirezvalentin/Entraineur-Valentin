import Foundation
import CoreLocation
import CoreMotion
import AVFoundation
import SwiftData
import Observation

/// Enregistre la course : GPS (y compris écran verrouillé), distance, dénivelé (baromètre),
/// pas, temps intermédiaires et annonces vocales.
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
    /// Nombre de pas depuis le départ, pauses exclues
    private(set) var steps: Int = 0
    /// Cadence instantanée (pas/min), 0 si inconnue
    private(set) var cadence: Double = 0
    /// Le podomètre existe sur cet appareil mais l'accès « Mouvements et forme » a été refusé
    private(set) var isPedometerDenied = false
    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    /// « Position exacte » désactivée dans les Réglages : le tracé serait inutilisable
    private(set) var isReducedAccuracy = false
    /// Précision du dernier fix GPS (m), nil si pas encore de signal
    private(set) var gpsAccuracy: Double? = nil
    private(set) var startDate: Date? = nil

    private let manager = CLLocationManager()
    private let speech = AVSpeechSynthesizer()
    private let pedometer = CMPedometer()
    private let altimeter = CMAltimeter()
    private let ioQueue = DispatchQueue(label: "run-checkpoint", qos: .utility)

    @ObservationIgnored private var lastLocation: CLLocation? = nil
    @ObservationIgnored private var altitudeAnchor: Double? = nil
    @ObservationIgnored private var lastGoodAltitude: Double? = nil
    // Dénivelé : le baromètre est prioritaire, le GPS sert de secours
    @ObservationIgnored private var gpsGain = 0.0
    @ObservationIgnored private var baroGain = 0.0
    @ObservationIgnored private var usingBarometer = false
    /// Altitude relative donnée par le baromètre depuis le (re)démarrage du capteur
    @ObservationIgnored private var baroRelative: Double? = nil
    @ObservationIgnored private var baroAnchor: Double? = nil
    /// altitude réelle ≈ altitude relative + décalage (recalé doucement sur le GPS)
    @ObservationIgnored private var baroOffset: Double? = nil
    @ObservationIgnored private var altimeterToken = 0
    @ObservationIgnored private var accumulatedMoving: Double = 0
    @ObservationIgnored private var segmentStart: Date? = nil
    @ObservationIgnored private var segment = 0
    @ObservationIgnored private var lastSplitTime: Double = 0
    @ObservationIgnored private var lastSplitElevation: Double = 0
    @ObservationIgnored private var warmingUp = false
    // Pas
    @ObservationIgnored private var movingIntervals: [DateInterval] = []
    @ObservationIgnored private var stepsBeforeSegment = 0
    @ObservationIgnored private var pedometerToken = 0
    @ObservationIgnored private var stepHistory: [(time: Date, steps: Int)] = []
    // Sauvegarde de secours
    @ObservationIgnored private var lastCheckpoint = Date.distantPast

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .fitness
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        speech.delegate = self
        authorization = manager.authorizationStatus
        isReducedAccuracy = isAuthorized && manager.accuracyAuthorization == .reducedAccuracy
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
        guard state == .idle, isAuthorized else { return }
        reset()
        let now = Date()
        state = .running
        startDate = now
        segmentStart = now
        lastCheckpoint = now
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        startPedometer(from: now)
        startAltimeter()
        announce("C'est parti !")
    }

    func pause() {
        guard state == .running else { return }
        let now = Date()
        if let s = segmentStart {
            accumulatedMoving += now.timeIntervalSince(s)
            movingIntervals.append(DateInterval(start: s, end: max(s, now)))
        }
        segmentStart = nil
        lastLocation = nil
        currentPace = 0
        state = .paused
        stopPedometer()
        stopAltimeter()
        // Le podomètre livre ses chiffres avec un léger retard : on relit le total exact.
        let intervals = movingIntervals
        querySteps(intervals) { [weak self] total in
            guard let self, let total, self.state == .paused, self.movingIntervals == intervals else { return }
            self.steps = total
            self.stepsBeforeSegment = total
        }
        saveCheckpoint()
        announce("Pause")
    }

    func resume() {
        guard state == .paused else { return }
        let now = Date()
        segment += 1
        segmentStart = now
        state = .running
        startPedometer(from: now)
        startAltimeter()
        announce("Reprise")
    }

    /// Enregistre la course. Renvoie nil si elle est trop courte.
    func finish(in context: ModelContext) -> Run? {
        let end = Date()
        if let s = segmentStart {
            accumulatedMoving += end.timeIntervalSince(s)
            movingIntervals.append(DateInterval(start: s, end: max(s, end)))
        }
        segmentStart = nil
        let intervals = movingIntervals
        defer { discard() }

        guard let start = startDate, points.count >= 2, distance >= 20 else { return nil }

        let run = Self.makeRun(start: start, end: end, points: points, distance: distance,
                               movingTime: accumulatedMoving, elevationGain: elevationGain,
                               splits: splits, lastSplitTime: lastSplitTime,
                               lastSplitElevation: lastSplitElevation, steps: steps)
        context.insert(run)
        try? context.save()
        refineSteps(of: run, intervals: intervals, in: context)

        announce("Course terminée. \(Fmt.km(distance, decimals: 1)) kilomètres en \(Fmt.spokenDuration(accumulatedMoving)).")
        return run
    }

    /// Arrête et oublie la course en cours.
    func discard() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        stopPedometer()
        stopAltimeter()
        removeCheckpoint()
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
        steps = 0
        cadence = 0
        startDate = nil
        lastLocation = nil
        altitudeAnchor = nil
        lastGoodAltitude = nil
        gpsGain = 0
        baroGain = 0
        usingBarometer = false
        baroRelative = nil
        baroAnchor = nil
        baroOffset = nil
        accumulatedMoving = 0
        segmentStart = nil
        segment = 0
        lastSplitTime = 0
        lastSplitElevation = 0
        movingIntervals = []
        stepsBeforeSegment = 0
        stepHistory = []
    }

    private static func makeRun(start: Date, end: Date, points: [TrackPoint], distance: Double,
                                movingTime: Double, elevationGain: Double, splits: [Split],
                                lastSplitTime: Double, lastSplitElevation: Double, steps: Int) -> Run {
        var allSplits = splits
        let rest = distance - Double(splits.count) * 1000
        if rest >= 50 {
            allSplits.append(Split(index: splits.count + 1,
                                   distance: rest,
                                   duration: max(0, movingTime - lastSplitTime),
                                   elevationGain: max(0, elevationGain - lastSplitElevation)))
        }

        var efforts: [Int: Double] = [:]
        for effort in RunAnalysis.efforts {
            if let t = RunAnalysis.bestTime(for: Double(effort.meters), in: points) {
                efforts[effort.meters] = t
            }
        }

        let encoder = JSONEncoder()
        return Run(startDate: start,
                   title: RunAnalysis.defaultTitle(for: start),
                   distance: distance,
                   movingTime: movingTime,
                   elapsedTime: max(movingTime, end.timeIntervalSince(start)),
                   elevationGain: elevationGain,
                   steps: steps,
                   pointsData: (try? encoder.encode(points)) ?? Data(),
                   splitsData: (try? encoder.encode(allSplits)) ?? Data(),
                   bestEffortsData: (try? encoder.encode(efforts)) ?? Data())
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        isReducedAccuracy = isAuthorized && manager.accuracyAuthorization == .reducedAccuracy
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

        guard state == .running, let segmentStart else { return }
        // Au-delà de 50 m d'incertitude, la position est trop floue pour mesurer une distance.
        guard loc.horizontalAccuracy >= 0, loc.horizontalAccuracy <= 50 else { return }
        // Position gardée en mémoire par l'iPhone avant le départ (ou avant la reprise).
        guard loc.timestamp >= segmentStart else { return }

        if let last = lastLocation {
            let dt = loc.timestamp.timeIntervalSince(last.timestamp)
            guard dt > 0 else { return }
            let d = loc.distance(from: last)
            // À l'arrêt le GPS « tremble » : on ignore les déplacements plus petits que son incertitude.
            let minimumMove = max(3, min(15, loc.horizontalAccuracy * 0.4))
            if d < minimumMove { return }
            if loc.speed >= 0, loc.speed < 0.3, d < 2 * minimumMove { return }
            if d / dt > 12 { return }    // saut aberrant (> 43 km/h)
            distance += d
        }

        // Altitude GPS : sert de secours pour le dénivelé (seuil de 3 m contre le bruit)
        // et à caler l'altitude réelle du baromètre.
        var altitude = lastGoodAltitude ?? loc.altitude
        if loc.verticalAccuracy >= 0, loc.verticalAccuracy <= 20 {
            altitude = loc.altitude
            lastGoodAltitude = altitude
            if let anchor = altitudeAnchor {
                let diff = altitude - anchor
                if diff >= 3 {
                    gpsGain += diff
                    altitudeAnchor = altitude
                } else if diff <= -3 {
                    altitudeAnchor = altitude
                }
            } else {
                altitudeAnchor = altitude
            }
            if usingBarometer, let rel = baroRelative, loc.verticalAccuracy <= 15 {
                let target = loc.altitude - rel
                baroOffset = baroOffset.map { $0 + (target - $0) * 0.02 } ?? target
            }
        }
        if usingBarometer, let rel = baroRelative {
            if baroOffset == nil { baroOffset = altitude - rel }
            altitude = rel + (baroOffset ?? 0)
        } else {
            elevationGain = gpsGain
        }

        let moving = movingTime(at: loc.timestamp)
        points.append(TrackPoint(lat: loc.coordinate.latitude,
                                 lon: loc.coordinate.longitude,
                                 alt: altitude,
                                 time: loc.timestamp,
                                 distance: distance,
                                 movingTime: moving,
                                 segment: segment))
        lastLocation = loc

        updateCurrentPace(now: loc.timestamp)
        checkSplits(moving: moving)

        if Date().timeIntervalSince(lastCheckpoint) >= 20 { saveCheckpoint() }
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

    // MARK: - Dénivelé (baromètre de l'iPhone)

    /// Le baromètre mesure les variations de pression de l'air : il voit une montée de quelques
    /// dizaines de centimètres, là où l'altitude GPS se trompe facilement de 10 m.
    private func startAltimeter() {
        guard CMAltimeter.isRelativeAltitudeAvailable() else { return }
        let status = CMAltimeter.authorizationStatus()
        guard status != .denied, status != .restricted else { return }
        altimeterToken += 1
        let token = altimeterToken
        baroRelative = nil
        baroAnchor = nil
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, error in
            guard let self, self.altimeterToken == token, self.state == .running,
                  let data, error == nil else { return }
            self.handleBarometer(data.relativeAltitude.doubleValue)
        }
    }

    private func stopAltimeter() {
        altimeterToken += 1
        altimeter.stopRelativeAltitudeUpdates()
        baroRelative = nil
        baroAnchor = nil
        // Le capteur repart de zéro à la reprise : le décalage sera recalculé
        // pour que l'altitude continue là où elle s'était arrêtée.
        baroOffset = nil
    }

    private func handleBarometer(_ relative: Double) {
        usingBarometer = true
        if baroOffset == nil, let last = points.last?.alt {
            baroOffset = last - relative
        }
        baroRelative = relative
        // Dénivelé positif : on ne compte une montée qu'au-delà de 1 m, pour ignorer
        // les petites variations de pression (vent, respiration du capteur).
        if let anchor = baroAnchor {
            let diff = relative - anchor
            if diff >= 1 {
                baroGain += diff
                baroAnchor = relative
            } else if diff <= -1 {
                baroAnchor = relative
            }
        } else {
            baroAnchor = relative
        }
        elevationGain = baroGain
    }

    // MARK: - Pas (podomètre de l'iPhone)

    /// Le compte en direct vient du coprocesseur de mouvement de l'iPhone (le même que l'app Santé).
    /// Les pauses sont exclues : on repart d'un nouveau comptage à chaque reprise.
    private func startPedometer(from date: Date) {
        guard CMPedometer.isStepCountingAvailable() else { return }
        pedometerToken += 1
        let token = pedometerToken
        let base = stepsBeforeSegment
        stepHistory = []
        pedometer.startUpdates(from: date) { [weak self] data, error in
            let count = data?.numberOfSteps.intValue
            let liveCadence = data?.currentCadence?.doubleValue
            let stamp = data?.endDate ?? Date()
            let failed = error != nil
            DispatchQueue.main.async {
                guard let self, self.pedometerToken == token, self.state == .running else { return }
                if failed {
                    let status = CMPedometer.authorizationStatus()
                    self.isPedometerDenied = status == .denied || status == .restricted
                    return
                }
                guard let count else { return }
                self.isPedometerDenied = false
                self.steps = max(self.steps, base + count)
                self.updateCadence(steps: base + count, at: stamp, live: liveCadence)
            }
        }
    }

    private func stopPedometer() {
        pedometerToken += 1
        pedometer.stopUpdates()
        cadence = 0
        stepHistory = []
    }

    private func updateCadence(steps: Int, at time: Date, live: Double?) {
        stepHistory.append((time, steps))
        stepHistory.removeAll { time.timeIntervalSince($0.time) > 20 }
        if let live, live > 0 {
            cadence = live * 60        // l'iPhone donne des pas par seconde
        } else if let first = stepHistory.first, time.timeIntervalSince(first.time) >= 5 {
            cadence = Double(steps - first.steps) / time.timeIntervalSince(first.time) * 60
        }
    }

    /// Total exact des pas sur les périodes de course (hors pauses), relu dans l'historique de l'iPhone.
    private func querySteps(_ intervals: [DateInterval], completion: @escaping (Int?) -> Void) {
        guard CMPedometer.isStepCountingAvailable(), !intervals.isEmpty else {
            completion(nil)
            return
        }
        let tally = StepTally()
        let group = DispatchGroup()
        for interval in intervals where interval.duration > 0 {
            group.enter()
            pedometer.queryPedometerData(from: interval.start, to: interval.end) { data, _ in
                tally.add(data?.numberOfSteps.intValue)
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(tally.result) }
    }

    /// Remplace le compte « en direct » par le total exact une fois la course enregistrée.
    private func refineSteps(of run: Run, intervals: [DateInterval], in context: ModelContext) {
        querySteps(intervals) { total in
            guard let total, total > 0 else { return }
            run.steps = total
            try? context.save()
        }
    }

    // MARK: - Sauvegarde de secours

    /// Photo de la course en cours, réécrite toutes les 20 s : si l'appli est fermée par iOS
    /// ou plante, la course est retrouvée au prochain lancement.
    private struct Checkpoint: Codable {
        var startDate: Date
        var savedAt: Date
        var points: [TrackPoint]
        var distance: Double
        var elevationGain: Double
        var splits: [Split]
        var movingTime: Double
        var lastSplitTime: Double
        var lastSplitElevation: Double
        var steps: Int
        var intervals: [DateInterval]
    }

    private static var checkpointURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("course-en-cours.json")
    }

    private func saveCheckpoint() {
        guard state != .idle, let start = startDate, points.count >= 2 else { return }
        let now = Date()
        lastCheckpoint = now
        var intervals = movingIntervals
        if let s = segmentStart { intervals.append(DateInterval(start: s, end: max(s, now))) }
        let checkpoint = Checkpoint(startDate: start, savedAt: now, points: points, distance: distance,
                                    elevationGain: elevationGain, splits: splits,
                                    movingTime: movingTime(at: now),
                                    lastSplitTime: lastSplitTime, lastSplitElevation: lastSplitElevation,
                                    steps: steps, intervals: intervals)
        let url = Self.checkpointURL
        ioQueue.async {
            guard let data = try? JSONEncoder().encode(checkpoint) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    private func removeCheckpoint() {
        let url = Self.checkpointURL
        ioQueue.async { try? FileManager.default.removeItem(at: url) }
    }

    /// À appeler au lancement : si une course a été interrompue par la fermeture de l'appli,
    /// elle est enregistrée dans l'historique et renvoyée.
    func recoverInterruptedRun(in context: ModelContext) -> Run? {
        guard state == .idle else { return nil }
        let url = Self.checkpointURL
        let data: Data? = ioQueue.sync {
            let data = try? Data(contentsOf: url)
            try? FileManager.default.removeItem(at: url)
            return data
        }
        guard let data,
              let saved = try? JSONDecoder().decode(Checkpoint.self, from: data),
              saved.points.count >= 2, saved.distance >= 100 else { return nil }   // pas de course « fantôme » de quelques mètres

        let run = Self.makeRun(start: saved.startDate, end: saved.savedAt, points: saved.points,
                               distance: saved.distance, movingTime: saved.movingTime,
                               elevationGain: saved.elevationGain, splits: saved.splits,
                               lastSplitTime: saved.lastSplitTime,
                               lastSplitElevation: saved.lastSplitElevation, steps: saved.steps)
        run.notes = "Course récupérée automatiquement : l'appli s'est fermée avant la fin."
        context.insert(run)
        try? context.save()
        refineSteps(of: run, intervals: saved.intervals, in: context)
        return run
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
        releaseAudioIfIdle(synthesizer)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        releaseAudioIfIdle(synthesizer)
    }

    private func releaseAudioIfIdle(_ synthesizer: AVSpeechSynthesizer) {
        if !synthesizer.isSpeaking {
            // Rend le volume à la musique
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

/// Additionne les pas de plusieurs périodes, interrogées en parallèle.
private final class StepTally: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0
    private var failed = false

    func add(_ steps: Int?) {
        lock.lock()
        if let steps { total += steps } else { failed = true }
        lock.unlock()
    }

    var result: Int? {
        lock.lock()
        defer { lock.unlock() }
        return failed ? nil : total
    }
}
