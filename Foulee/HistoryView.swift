import SwiftUI
import SwiftData

struct HistoryView: View {
    @Query(sort: \Run.startDate, order: .reverse) private var runs: [Run]
    @Environment(\.modelContext) private var context

    private struct MonthGroup: Identifiable {
        let start: Date
        let runs: [Run]
        var id: Date { start }
    }

    private var months: [MonthGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: runs) { (run: Run) -> Date in
            calendar.dateInterval(of: .month, for: run.startDate)?.start ?? run.startDate
        }
        return grouped
            .map { MonthGroup(start: $0.key, runs: $0.value) }
            .sorted { $0.start > $1.start }
    }

    var body: some View {
        NavigationStack {
            Group {
                if runs.isEmpty {
                    ContentUnavailableView("Aucune course",
                                           systemImage: "figure.run",
                                           description: Text("Tes courses enregistrées apparaîtront ici."))
                } else {
                    List {
                        ForEach(months) { month in
                            Section {
                                ForEach(month.runs) { run in
                                    NavigationLink {
                                        RunDetailView(run: run)
                                    } label: {
                                        RunRow(run: run)
                                    }
                                }
                                .onDelete { offsets in
                                    for i in offsets { context.delete(month.runs[i]) }
                                    try? context.save()
                                }
                            } header: {
                                HStack {
                                    Text(Fmt.capitalizedFirst(month.start.formatted(.dateTime.month(.wide).year())))
                                    Spacer()
                                    Text("\(Fmt.km(month.runs.reduce(0.0) { $0 + $1.distance }, decimals: 1)) km")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Historique")
        }
    }
}

struct RunRow: View {
    let run: Run

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(run.title).font(.headline)
            Text(run.startDate.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Label("\(Fmt.km(run.distance)) km", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                Label(Fmt.duration(run.movingTime), systemImage: "stopwatch")
                Label("\(Fmt.pace(run.averagePace)) /km", systemImage: "speedometer")
            }
            .font(.subheadline.monospacedDigit())
            .labelStyle(CompactLabelStyle())
        }
        .padding(.vertical, 4)
    }
}

private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.foregroundStyle(.orange).font(.caption)
            configuration.title
        }
    }
}
