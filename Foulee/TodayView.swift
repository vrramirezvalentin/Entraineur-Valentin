import SwiftUI
import SwiftData
import Charts
import UIKit

/// Page « Aujourd'hui » : pas, distance et temps en mouvement de la journée, comme dans Santé,
/// plus la semaine, les moyennes, le record et les courses du jour.
struct TodayView: View {
    @Environment(ActivityStore.self) private var activity
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Query(sort: \DaySummary.day, order: .reverse) private var days: [DaySummary]
    @Query(sort: \Run.startDate, order: .reverse) private var runs: [Run]

    private var today: Date { Calendar.current.startOfDay(for: Date()) }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    if activity.access == .denied {
                        accessCard(denied: true)
                    } else if activity.access == .unavailable {
                        accessCard(denied: false)
                    }
                    hero
                    cards
                    hourlyChart
                    weekChart.id("semaine")
                    summary
                    todayRuns
                    history.id("jours")
                    Text("Les chiffres viennent du podomètre de l'iPhone, qui compte même quand l'appli est fermée. L'iPhone ne garde que 7 jours : l'appli les recopie à chaque ouverture pour garder tout l'historique.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            #if DEBUG
            .task {
                // Captures du simulateur : -scrollTo semaine|jours
                if let target = UserDefaults.standard.string(forKey: "scrollTo") {
                    try? await Task.sleep(for: .seconds(2))
                    proxy.scrollTo(target, anchor: .top)
                }
            }
            #endif
            }
            .navigationTitle("Aujourd'hui")
            .refreshable { await activity.refresh(in: context) }
        }
        .task { await activity.refresh(in: context) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                activity.resetIfNewDay()
                Task { await activity.refresh(in: context) }
            } else if phase == .background {
                activity.stopLive()
            }
        }
        .onDisappear { activity.stopLive() }
    }

    // MARK: - Pas du jour

    private var hero: some View {
        VStack(spacing: 4) {
            Text(Fmt.capitalizedFirst(Date().formatted(.dateTime.weekday(.wide).day().month(.wide))))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Image(systemName: "shoeprints.fill")
                .font(.title)
                .foregroundStyle(.orange)
                .padding(.vertical, 6)
            Text(activity.steps.formatted(.number))
                .font(.system(size: 64, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText())
                .animation(.easeOut, value: activity.steps)
            Text("pas aujourd'hui")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Chiffres du jour

    private var cards: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            TodayCard(icon: "point.topleft.down.to.point.bottomright.curvepath", title: "Distance",
                      value: Fmt.km(activity.distance), unit: "km")
            TodayCard(icon: "figure.walk.motion", title: "En mouvement",
                      value: "\(Int(activity.activeMinutes.rounded()))", unit: "min")
        }
    }

    // MARK: - Heure par heure

    private var hourlyChart: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Heure par heure")
            Chart {
                ForEach(Array(activity.hourly.enumerated()), id: \.offset) { hour, steps in
                    BarMark(x: .value("Heure", hour), y: .value("Pas", steps), width: .ratio(0.7))
                        .foregroundStyle(Color.orange.gradient)
                        .cornerRadius(2)
                }
            }
            .chartXScale(domain: -0.5...23.5)
            .chartXAxis {
                AxisMarks(values: [0, 6, 12, 18]) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let h = value.as(Int.self) { Text("\(h) h") }
                    }
                }
            }
            .frame(height: 140)
        }
    }

    // MARK: - Semaine

    private struct DayBar: Identifiable {
        let day: Date
        let steps: Int
        var id: Date { day }
    }

    private var lastSevenDays: [DayBar] {
        let calendar = Calendar.current
        let byDay = Dictionary(days.map { ($0.day, $0.steps) }, uniquingKeysWith: max)
        return (0..<7).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let steps = offset == 0 ? max(activity.steps, byDay[day] ?? 0) : (byDay[day] ?? 0)
            return DayBar(day: day, steps: steps)
        }
    }

    private var weekChart: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("7 derniers jours")
            Chart {
                ForEach(lastSevenDays) { bar in
                    BarMark(x: .value("Jour", bar.day, unit: .day), y: .value("Pas", bar.steps))
                        .foregroundStyle(Color.orange.gradient)
                        .cornerRadius(5)
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated), centered: true)
                }
            }
            .frame(height: 170)
        }
    }

    // MARK: - Moyennes, record, série

    private func average(over count: Int) -> Int? {
        let calendar = Calendar.current
        guard let from = calendar.date(byAdding: .day, value: -(count - 1), to: today) else { return nil }
        let selected = days.filter { $0.day >= from && $0.day < today }   // jours complets seulement
        guard !selected.isEmpty else { return nil }
        return selected.reduce(0) { $0 + $1.steps } / selected.count
    }

    private var record: DaySummary? {
        days.max { $0.steps < $1.steps }
    }

    /// Distance marchée et courue sur les 7 derniers jours (aujourd'hui compris)
    private var weekDistance: Double {
        let calendar = Calendar.current
        guard let from = calendar.date(byAdding: .day, value: -6, to: today) else { return 0 }
        let past = days.filter { $0.day >= from && $0.day < today }.reduce(0.0) { $0 + $1.distance }
        let todayArchived = days.first { $0.day == today }?.distance ?? 0
        return past + max(activity.distance, todayArchived)
    }

    private var summary: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            TodayCard(icon: "calendar", title: "Moyenne 7 jours",
                      value: average(over: 7).map { $0.formatted(.number) } ?? "–", unit: "pas")
            TodayCard(icon: "calendar.badge.clock", title: "Moyenne 30 jours",
                      value: average(over: 30).map { $0.formatted(.number) } ?? "–", unit: "pas")
            TodayCard(icon: "trophy.fill", title: "Record",
                      value: record.map { $0.steps.formatted(.number) } ?? "–",
                      unit: nil,
                      detail: record.map { $0.day.formatted(.dateTime.day().month(.abbreviated)) })
            TodayCard(icon: "point.topleft.down.to.point.bottomright.curvepath", title: "Distance 7 jours",
                      value: Fmt.km(weekDistance, decimals: 1), unit: "km")
        }
    }

    // MARK: - Courses du jour

    private var todayRunsList: [Run] {
        runs.filter { Calendar.current.isDateInToday($0.startDate) }
    }

    @ViewBuilder
    private var todayRuns: some View {
        if !todayRunsList.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle("Courses d'aujourd'hui")
                ForEach(todayRunsList) { run in
                    NavigationLink {
                        RunDetailView(run: run)
                    } label: {
                        HStack {
                            RunRow(run: run)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(12)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Jours précédents

    @ViewBuilder
    private var history: some View {
        let previous = days.filter { $0.day < today }
        if !previous.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                SectionTitle("Jours précédents")
                    .padding(.bottom, 6)
                ForEach(previous) { day in
                    DayRow(summary: day)
                    Divider()
                }
            }
        }
    }

    // MARK: - Accès

    private func accessCard(denied: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(denied ? "Accès aux mouvements refusé" : "Podomètre indisponible",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(denied
                 ? "Pour voir tes pas, autorise « Mouvements et forme » dans les Réglages de l'appli."
                 : "Cet appareil ne compte pas les pas.")
                .font(.subheadline)
            if denied {
                Button("Ouvrir les Réglages") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .font(.subheadline.weight(.semibold))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct TodayCard: View {
    let icon: String
    let title: String
    let value: String
    let unit: String?
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .monospacedDigit()
                if let unit {
                    Text(unit).font(.caption).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct DayRow: View {
    let summary: DaySummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(Fmt.capitalizedFirst(summary.day.formatted(.dateTime.weekday(.wide).day().month(.wide))))
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(summary.steps.formatted(.number)) pas")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
            Text("\(Fmt.km(summary.distance, decimals: 1)) km · \(Int(summary.activeMinutes.rounded())) min en mouvement")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }
}
