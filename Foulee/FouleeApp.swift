import SwiftUI
import SwiftData
import BackgroundTasks

@main
struct FouleeApp: App {
    /// Tâche de fond qui recopie les pas de l'iPhone dans l'archive, même sans ouvrir l'appli.
    static let archiveTaskID = "app.foulee.perso.k7r2.archive"

    @State private var tracker = RunTracker()
    @State private var activity = ActivityStore()
    @Environment(\.scenePhase) private var scenePhase
    private let container: ModelContainer

    init() {
        UserDefaults.standard.register(defaults: ["voice": true, "stepGoal": 10_000])
        do {
            container = try ModelContainer(for: Run.self, DaySummary.self)
        } catch {
            fatalError("Impossible d'ouvrir les données : \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(tracker)
                .environment(activity)
                .tint(.orange)
        }
        .modelContainer(container)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { Self.scheduleArchive() }
        }
        .backgroundTask(.appRefresh(Self.archiveTaskID)) {
            await Self.runArchive(container: container)
        }
    }

    /// Demande à iOS de relancer l'archivage dans quelques heures (iOS choisit le moment exact).
    static func scheduleArchive() {
        let request = BGAppRefreshTaskRequest(identifier: archiveTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 4 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }

    @MainActor
    static func runArchive(container: ModelContainer) async {
        scheduleArchive()
        let context = ModelContext(container)
        await ActivityArchiver.archive(in: context)
    }
}

struct ContentView: View {
    enum Tab: Hashable { case today, record, history, stats }

    @State private var tab: Tab = .today
    @State private var demoRun: Run?
    @State private var demoFlyover: DemoFlyover?
    @State private var showRecovered = false
    @Environment(\.modelContext) private var context
    @Environment(RunTracker.self) private var tracker

    var body: some View {
        TabView(selection: $tab) {
            TodayView()
                .tabItem { Label("Aujourd'hui", systemImage: "shoeprints.fill") }
                .tag(Tab.today)
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
        .fullScreenCover(item: $demoFlyover) { item in
            FlyoverView(run: item.run, start: item.start)
        }
        .alert("Course récupérée", isPresented: $showRecovered) {
            Button("Voir l'historique") { tab = .history }
            Button("OK", role: .cancel) {}
        } message: {
            Text("L'appli s'était fermée pendant ta dernière course. Ce qui avait été enregistré a été sauvegardé dans l'historique.")
        }
        .task {
            if tracker.recoverInterruptedRun(in: context) != nil {
                showRecovered = true
            }
            await setUpDemo()
        }
    }

    /// Mode démo pour les captures dans le simulateur (builds Debug uniquement).
    @MainActor
    private func setUpDemo() async {
        #if DEBUG
        // -screen fonctionne aussi sans -demo, pour tester le tout premier lancement (aucune course)
        guard DemoData.isEnabled || !DemoData.screen.isEmpty else { return }
        DemoData.seedIfNeeded(context)
        // La plus récente course « de démo » (on ignore les petites courses créées par les tests)
        var descriptor = FetchDescriptor<Run>(predicate: #Predicate { $0.distance > 2000 },
                                              sortBy: [SortDescriptor(\.startDate, order: .reverse)])
        descriptor.fetchLimit = 1
        let latest = try? context.fetch(descriptor).first

        switch DemoData.screen {
        case "today":
            tab = .today
        case "history":
            tab = .history
        case "detail":
            demoRun = latest
            tab = .history
        case "stats":
            tab = .stats
        case "flyover":
            demoFlyover = latest.map { DemoFlyover(run: $0, start: .play) }
        case "flyoverStill":
            demoFlyover = latest.map { DemoFlyover(run: $0, start: .still) }
        case "export":
            demoFlyover = latest.map { DemoFlyover(run: $0, start: .export) }
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

/// Survol ouvert automatiquement en mode démo, avec la façon de le démarrer.
struct DemoFlyover: Identifiable {
    let run: Run
    let start: FlyoverView.Start
    var id: PersistentIdentifier { run.persistentModelID }
}
