import Foundation
import CoreMotion
import SwiftData
import Observation

/// Résumé d'une journée (pas, distance, étages, temps en mouvement), archivé dans l'appli.
///
/// L'iPhone ne garde que 7 jours d'historique du podomètre : chaque jour est donc recopié ici
/// (à chaque ouverture de l'appli et, quand iOS le permet, en arrière-plan) pour ne jamais le perdre.
@Model
final class DaySummary {
    /// Début de la journée (minuit, heure locale)
    @Attribute(.unique) var day: Date = Date.distantPast
    var steps: Int = 0
    /// mètres (marche + course)
    var distance: Double = 0
    var floorsUp: Int = 0
    /// minutes passées à marcher, courir ou pédaler
    var activeMinutes: Double = 0
    var updatedAt: Date = Date()

    init(day: Date) {
        self.day = day
    }
}

/// Valeurs lues dans le podomètre pour une période.
struct PedometerTotals: Sendable {
    var steps = 0
    var distance = 0.0
    var floorsUp = 0
}

enum MotionAccess: Sendable {
    case unknown, available, denied, unavailable
}

/// Lecture du podomètre et de l'activité de l'iPhone, et archivage des journées.
@MainActor
enum ActivityArchiver {
    private static let pedometer = CMPedometer()
    private static let motion = CMMotionActivityManager()

    /// Copie les 7 derniers jours de l'iPhone dans l'archive. Renvoie l'état de l'accès.
    @discardableResult
    static func archive(in context: ModelContext, now: Date = Date()) async -> MotionAccess {
        guard CMPedometer.isStepCountingAvailable() else { return .unavailable }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let access = MotionAccess.available

        // Temps en mouvement, jour par jour, sur la même période
        let weekStart = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let minutes = await activeMinutesPerDay(from: weekStart, to: now)

        for offset in 0..<7 {
            guard let start = calendar.date(byAdding: .day, value: -offset, to: today),
                  let next = calendar.date(byAdding: .day, value: 1, to: start) else { continue }
            let result = await totals(from: start, to: min(next, now))
            switch result {
            case .failure(let failure):
                if failure.denied { return .denied }
                continue
            case .success(let totals):
                upsert(day: start, totals: totals, minutes: minutes[start] ?? 0, in: context)
            }
        }
        try? context.save()
        return access
    }

    /// Pas de chaque heure d'aujourd'hui (24 valeurs).
    static func hourlySteps(now: Date = Date()) async -> [Int] {
        guard CMPedometer.isStepCountingAvailable() else { return Array(repeating: 0, count: 24) }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        var hours = Array(repeating: 0, count: 24)
        for h in 0..<24 {
            guard let start = calendar.date(byAdding: .hour, value: h, to: today), start < now,
                  let end = calendar.date(byAdding: .hour, value: 1, to: start) else { break }
            if case .success(let totals) = await totals(from: start, to: min(end, now)) {
                hours[h] = totals.steps
            }
        }
        return hours
    }

    /// Totaux du podomètre sur une période. En cas d'échec : vrai si l'accès est refusé.
    static func totals(from start: Date, to end: Date) async -> Result<PedometerTotals, AccessFailure> {
        guard end > start else { return .success(PedometerTotals()) }
        return await withCheckedContinuation { continuation in
            pedometer.queryPedometerData(from: start, to: end) { data, error in
                if let error {
                    let code = (error as NSError).code
                    let denied = code == Int(CMErrorMotionActivityNotAuthorized.rawValue)
                        || code == Int(CMErrorMotionActivityNotEntitled.rawValue)
                    continuation.resume(returning: .failure(AccessFailure(denied: denied)))
                    return
                }
                let totals = PedometerTotals(steps: data?.numberOfSteps.intValue ?? 0,
                                             distance: data?.distance?.doubleValue ?? 0,
                                             floorsUp: data?.floorsAscended?.intValue ?? 0)
                continuation.resume(returning: .success(totals))
            }
        }
    }

    struct AccessFailure: Error {
        let denied: Bool
    }

    /// Minutes passées à marcher, courir ou pédaler, par jour.
    static func activeMinutesPerDay(from start: Date, to end: Date) async -> [Date: Double] {
        guard CMMotionActivityManager.isActivityAvailable() else { return [:] }
        let spans: [(Date, Bool)] = await withCheckedContinuation { continuation in
            motion.queryActivityStarting(from: start, to: end, to: .main) { activities, _ in
                let list = (activities ?? []).map { activity in
                    (activity.startDate,
                     (activity.walking || activity.running || activity.cycling) && activity.confidence != .low)
                }
                continuation.resume(returning: list)
            }
        }
        let calendar = Calendar.current
        var result: [Date: Double] = [:]
        for (i, span) in spans.enumerated() where span.1 {
            var from = max(span.0, start)
            let to = min(i + 1 < spans.count ? spans[i + 1].0 : end, end)
            // Une période « active » de plus de 3 h sans changement est sûrement une erreur de détection
            guard to > from, to.timeIntervalSince(from) < 3 * 3600 else { continue }
            while from < to {
                let dayStart = calendar.startOfDay(for: from)
                let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? to
                let pieceEnd = min(to, dayEnd)
                result[dayStart, default: 0] += pieceEnd.timeIntervalSince(from) / 60
                from = pieceEnd
            }
        }
        return result
    }

    private static func upsert(day: Date, totals: PedometerTotals, minutes: Double, in context: ModelContext) {
        var descriptor = FetchDescriptor<DaySummary>(predicate: #Predicate { $0.day == day })
        descriptor.fetchLimit = 1
        let summary: DaySummary
        if let existing = try? context.fetch(descriptor).first {
            summary = existing
        } else {
            summary = DaySummary(day: day)
            context.insert(summary)
        }
        // Le plus ancien jour peut n'être que partiellement disponible dans l'iPhone :
        // on ne remplace jamais une valeur archivée par une plus petite.
        summary.steps = max(summary.steps, totals.steps)
        summary.distance = max(summary.distance, totals.distance)
        summary.floorsUp = max(summary.floorsUp, totals.floorsUp)
        summary.activeMinutes = max(summary.activeMinutes, minutes)
        summary.updatedAt = Date()
    }
}

/// Données de la page « Aujourd'hui », mises à jour en direct pendant qu'elle est affichée.
@MainActor
@Observable
final class ActivityStore {
    private(set) var access: MotionAccess = .unknown
    private(set) var steps = 0
    private(set) var distance = 0.0
    private(set) var floorsUp = 0
    private(set) var activeMinutes = 0.0
    private(set) var hourly: [Int] = Array(repeating: 0, count: 24)
    private(set) var isRefreshing = false

    @ObservationIgnored private let live = CMPedometer()
    @ObservationIgnored private var liveDay: Date?
    @ObservationIgnored private var liveToken = 0

    /// Relit l'iPhone, archive les 7 derniers jours et met à jour la journée en cours.
    func refresh(in context: ModelContext) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        #if DEBUG
        if DemoData.isEnabled {
            let demo = DemoData.seedActivity(context)
            access = .available
            steps = demo.steps
            distance = demo.distance
            floorsUp = demo.floorsUp
            activeMinutes = demo.activeMinutes
            hourly = demo.hourly
            return
        }
        #endif

        let now = Date()
        access = await ActivityArchiver.archive(in: context, now: now)
        guard access == .available else { return }

        let today = Calendar.current.startOfDay(for: now)
        var descriptor = FetchDescriptor<DaySummary>(predicate: #Predicate { $0.day == today })
        descriptor.fetchLimit = 1
        if let summary = try? context.fetch(descriptor).first {
            steps = max(steps, summary.steps)
            distance = max(distance, summary.distance)
            floorsUp = max(floorsUp, summary.floorsUp)
            activeMinutes = summary.activeMinutes
        }
        hourly = await ActivityArchiver.hourlySteps(now: now)
        startLive()
    }

    /// Compte en direct pendant que la page est ouverte.
    func startLive() {
        guard access == .available, CMPedometer.isStepCountingAvailable() else { return }
        let today = Calendar.current.startOfDay(for: Date())
        if liveDay == today { return }
        stopLive()
        liveDay = today
        liveToken += 1
        let token = liveToken
        live.startUpdates(from: today) { [weak self] data, error in
            guard let data, error == nil else { return }
            let totals = PedometerTotals(steps: data.numberOfSteps.intValue,
                                         distance: data.distance?.doubleValue ?? 0,
                                         floorsUp: data.floorsAscended?.intValue ?? 0)
            Task { @MainActor [weak self] in
                guard let self, self.liveToken == token else { return }
                self.steps = max(self.steps, totals.steps)
                self.distance = max(self.distance, totals.distance)
                self.floorsUp = max(self.floorsUp, totals.floorsUp)
                let hour = Calendar.current.component(.hour, from: Date())
                let others = self.hourly.enumerated().reduce(0) { $0 + ($1.offset == hour ? 0 : $1.element) }
                self.hourly[hour] = max(self.hourly[hour], totals.steps - others)
            }
        }
    }

    func stopLive() {
        liveToken += 1
        liveDay = nil
        live.stopUpdates()
    }

    /// Un nouveau jour a commencé pendant que l'appli était ouverte.
    func resetIfNewDay() {
        let today = Calendar.current.startOfDay(for: Date())
        if let liveDay, liveDay != today {
            stopLive()
            steps = 0
            distance = 0
            floorsUp = 0
            activeMinutes = 0
            hourly = Array(repeating: 0, count: 24)
        }
    }
}
