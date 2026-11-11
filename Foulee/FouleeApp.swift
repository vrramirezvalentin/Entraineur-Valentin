import SwiftUI
import SwiftData

@main
struct FouleeApp: App {
    @State private var tracker = RunTracker()

    init() {
        UserDefaults.standard.register(defaults: ["voice": true])
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(tracker)
                .tint(.orange)
        }
        .modelContainer(for: Run.self)
    }
}

struct ContentView: View {
    enum Tab: Hashable { case record, history, stats }

    @State private var tab: Tab = .record
    @State private var demoRun: Run?
    @State private var demoFlyover: Run?
    @Environment(\.modelContext) private var context
    @Environment(RunTracker.self) private var tracker

    var body: some View {
        TabView(selection: $tab) {
            RecordView()
                .tabItem { Label("Courir", systemImage: "figure.run") }
                .tag(Tab.record)
            Group {
                if let run = demoRun {
                    NavigationStack { RunDetailView(run: run) }
                } else {
                    HistoryView()
                }
            }
            .tabItem { Label("Historique", systemImage: "list.bullet") }
            .tag(Tab.history)
            StatsView()
                .tabItem { Label("Stats", systemImage: "chart.bar.fill") }
                .tag(Tab.stats)
        }
        .fullScreenCover(item: $demoFlyover) { run in
            FlyoverView(run: run)
        }
        .task { await setUpDemo() }
    }

    /// Mode démo pour les captures dans le simulateur (builds Debug uniquement).
    @MainActor
    private func setUpDemo() async {
        #if DEBUG
        guard DemoData.isEnabled else { return }
        DemoData.seedIfNeeded(context)
        var descriptor = FetchDescriptor<Run>(sortBy: [SortDescriptor(\.startDate, order: .reverse)])
        descriptor.fetchLimit = 1
        let latest = try? context.fetch(descriptor).first

        switch DemoData.screen {
        case "history":
            tab = .history
        case "detail":
            demoRun = latest
            tab = .history
        case "stats":
            tab = .stats
        case "flyover":
            demoFlyover = latest
        case "running":
            tab = .record
            try? await Task.sleep(for: .seconds(4))
            tracker.start()
        default:
            tab = .record
        }
        #endif
    }
}
