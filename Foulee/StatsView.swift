import SwiftUI
import SwiftData
import Charts

struct StatsView: View {
    @Query(sort: \Run.startDate, order: .reverse) private var runs: [Run]
    @State private var period: Period = .month

    enum Period: String, CaseIterable, Identifiable {
        case week = "Semaine", month = "Mois", year = "Année", all = "Total"
        var id: Self { self }
    }

    private var filtered: [Run] {
        let cal = Calendar.current
        let component: Calendar.Component
        switch period {
        case .week: component = .weekOfYear
        case .month: component = .month
        case .year: component = .year
        case .all: return runs
        }
        guard let interval = cal.dateInterval(of: component, for: Date()) else { return runs }
        return runs.filter { interval.contains($0.startDate) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if runs.isEmpty {
                    ContentUnavailableView("Pas encore de stats",
                                           systemImage: "chart.bar",
                                           description: Text("Enregistre ta première course pour voir tes progrès."))
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            Picker("Période", selection: $period) {
                                ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)

                            summary
                            weeklyChart
                            records
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Statistiques")
        }
    }

    // MARK: - Résumé

    private var summary: some View {
        let list = filtered
        let distance = list.reduce(0.0) { $0 + $1.distance }
        let time = list.reduce(0.0) { $0 + $1.movingTime }
        let elevation = list.reduce(0.0) { $0 + $1.elevationGain }
        let pace = distance > 0 ? time / distance * 1000 : 0
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            SummaryCard(title: "Distance", value: Fmt.km(distance, decimals: 1), unit: "km")
            SummaryCard(title: "Courses", value: "\(list.count)", unit: nil)
            SummaryCard(title: "Temps", value: Fmt.duration(time), unit: nil)
            SummaryCard(title: "Allure moy.", value: Fmt.pace(pace), unit: "/km")
            SummaryCard(title: "Dénivelé +", value: "\(Int(elevation.rounded()))", unit: "m")
            SummaryCard(title: "Plus longue", value: Fmt.km(list.map(\.distance).max() ?? 0, decimals: 1), unit: "km")
        }
    }

    // MARK: - Graphique hebdo

    private struct WeekTotal: Identifiable {
        let start: Date
        let km: Double
        var id: Date { start }
    }

    private var weeks: [WeekTotal] {
        let cal = Calendar.current
        guard let current = cal.dateInterval(of: .weekOfYear, for: Date())?.start else { return [] }
        return (0..<12).reversed().compactMap { (i: Int) -> WeekTotal? in
            guard let start = cal.date(byAdding: .weekOfYear, value: -i, to: current),
                  let end = cal.date(byAdding: .weekOfYear, value: 1, to: start) else { return nil }
            let km = runs
                .filter { $0.startDate >= start && $0.startDate < end }
                .reduce(0.0) { $0 + $1.distance } / 1000
            return WeekTotal(start: start, km: km)
        }
    }

    private var weeklyChart: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("12 dernières semaines")
            Chart(weeks) { week in
                BarMark(x: .value("Semaine", week.start, unit: .weekOfYear),
                        y: .value("km", week.km))
                    .foregroundStyle(Color.orange.gradient)
                    .cornerRadius(4)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .weekOfYear, count: 3)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                }
            }
            .chartYAxisLabel("km")
            .frame(height: 180)
        }
    }

    // MARK: - Records

    private var records: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Records personnels")
            ForEach(RunAnalysis.efforts) { effort in
                if let best = bestRun(for: effort.meters) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(effort.label).font(.body.weight(.semibold))
                            Text(best.run.startDate.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(Fmt.duration(best.time)).font(.body.weight(.bold))
                            Text("\(Fmt.pace(best.time / Double(effort.meters) * 1000)) /km")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .monospacedDigit()
                    .padding(12)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                }
            }
            if !runs.contains(where: { !$0.bestEfforts.isEmpty }) {
                Text("Cours au moins 1 km pour établir ton premier record.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func bestRun(for meters: Int) -> (run: Run, time: Double)? {
        var best: (run: Run, time: Double)?
        for run in runs {
            if let t = run.bestEfforts[meters], t < (best?.time ?? .infinity) {
                best = (run, t)
            }
        }
        return best
    }
}

private struct SummaryCard: View {
    let title: String
    let value: String
    let unit: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                if let unit {
                    Text(unit).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}
