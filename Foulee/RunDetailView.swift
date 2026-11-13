import SwiftUI
import MapKit
import Charts
import SwiftData

struct RunDetailView: View {
    @Bindable var run: Run
    @State private var points: [TrackPoint]
    @State private var splits: [Split]
    @State private var showFlyover = false

    init(run: Run) {
        self.run = run
        _points = State(initialValue: run.points)
        _splits = State(initialValue: run.splits)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if points.count > 1 {
                    VStack(spacing: 12) {
                        routeMap
                        Button {
                            showFlyover = true
                        } label: {
                            Label("Revivre en 3D", systemImage: "mountain.2.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 46)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    TextField("Titre", text: $run.title)
                        .font(.title2.bold())
                        .submitLabel(.done)
                    Text(Fmt.capitalizedFirst(run.startDate.formatted(date: .complete, time: .shortened)))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                statsGrid

                if !splits.isEmpty { splitsSection }
                if points.count > 1 { elevationSection }
                if !run.bestEfforts.isEmpty { effortsSection }

                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle("Notes")
                    TextField("Sensations, météo, parcours…", text: $run.notes, axis: .vertical)
                        .lineLimit(3...8)
                        .padding(12)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
        .onDisappear {
            // Un titre effacé reprend le titre automatique
            if run.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                run.title = RunAnalysis.defaultTitle(for: run.startDate)
            }
        }
        .fullScreenCover(isPresented: $showFlyover) {
            FlyoverView(run: run)
        }
        .navigationTitle(run.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if points.count > 1 {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: GPXFile(name: run.title, points: points),
                              preview: SharePreview("\(run.title).gpx")) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
    }

    // MARK: - Carte

    private var routeMap: some View {
        Map(initialPosition: .automatic, interactionModes: [.pan, .zoom]) {
            ForEach(Array(points.coordinateSegments.enumerated()), id: \.offset) { _, segment in
                MapPolyline(coordinates: segment)
                    .stroke(.orange, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            if let first = points.first {
                Annotation("Départ", coordinate: first.coordinate) {
                    // Plus gros que l'arrivée : sur une boucle, les deux restent visibles
                    Circle().fill(.green).frame(width: 22, height: 22)
                        .overlay(Circle().stroke(.white, lineWidth: 3))
                }
                .annotationTitles(.hidden)
            }
            if let last = points.last {
                Annotation("Arrivée", coordinate: last.coordinate) {
                    Circle().fill(.red).frame(width: 12, height: 12)
                        .overlay(Circle().stroke(.white, lineWidth: 2.5))
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .frame(height: 280)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: - Stats

    private var statsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                  alignment: .leading, spacing: 18) {
            StatCell(title: "Distance", value: Fmt.km(run.distance), unit: "km")
            StatCell(title: "Allure moy.", value: Fmt.pace(run.averagePace), unit: "/km")
            StatCell(title: "Temps", value: Fmt.duration(run.movingTime), unit: nil)
            StatCell(title: "Dénivelé +", value: "\(Int(run.elevationGain.rounded()))", unit: "m")
            StatCell(title: "Vitesse moy.", value: speed, unit: "km/h")
            StatCell(title: "Temps total", value: Fmt.duration(run.elapsedTime), unit: nil)
            if run.steps > 0 {
                StatCell(title: "Pas", value: Fmt.steps(run.steps), unit: nil)
                StatCell(title: "Cadence moy.", value: Fmt.cadence(run.averageCadence), unit: "pas/min")
                StatCell(title: "Foulée moy.",
                         value: run.strideLength.formatted(.number.precision(.fractionLength(2))),
                         unit: "m")
            }
        }
    }

    private var speed: String {
        guard run.movingTime > 0 else { return "–" }
        return (run.distance / run.movingTime * 3.6).formatted(.number.precision(.fractionLength(1)))
    }

    // MARK: - Temps intermédiaires

    private var splitsSection: some View {
        let fastest = splits.map(\.pace).filter { $0 > 0 }.min() ?? 1
        // Grille : les colonnes s'élargissent toutes seules si le texte est agrandi
        return VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Temps intermédiaires")
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Km")
                    Text("Allure")
                    Color.clear.frame(height: 1)
                    Text("Dén.").gridColumnAlignment(.trailing)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

                ForEach(splits) { split in
                    GridRow {
                        Text(split.distance < 999
                             ? (split.distance / 1000).formatted(.number.precision(.fractionLength(1)))
                             : "\(split.index)")
                        Text(Fmt.pace(split.pace))
                        ProgressView(value: split.pace > 0 ? min(1, fastest / split.pace) : 0)
                            .tint(split.pace == fastest ? Color.orange : Color.orange.opacity(0.55))
                        Text("+\(Int(split.elevationGain.rounded()))")
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline.monospacedDigit())
                    .lineLimit(1)
                }
            }
        }
    }

    // MARK: - Altitude

    private var elevationSection: some View {
        let step = max(1, points.count / 300)
        let sampled = stride(from: 0, to: points.count, by: step).map { points[$0] }
        let low = (sampled.map(\.alt).min() ?? 0) - 5
        let high = (sampled.map(\.alt).max() ?? 0) + 5
        return VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Altitude")
            Chart {
                ForEach(Array(sampled.enumerated()), id: \.offset) { _, p in
                    AreaMark(x: .value("Distance", p.distance / 1000),
                             yStart: .value("Base", low),
                             yEnd: .value("Altitude", p.alt))
                        .foregroundStyle(Color.orange.opacity(0.25))
                    LineMark(x: .value("Distance", p.distance / 1000),
                             y: .value("Altitude", p.alt))
                        .foregroundStyle(Color.orange)
                }
            }
            .chartYScale(domain: low...high)
            .chartXAxisLabel("km")
            .chartYAxisLabel("m")
            .frame(height: 160)
        }
    }

    // MARK: - Meilleurs efforts

    private var effortsSection: some View {
        let efforts = run.bestEfforts
        return VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Meilleurs efforts")
            ForEach(RunAnalysis.efforts) { effort in
                if let time = efforts[effort.meters] {
                    HStack {
                        Text(effort.label)
                        Spacer()
                        Text(Fmt.duration(time)).bold()
                            .fixedSize()
                        Text("\(Fmt.pace(time / Double(effort.meters) * 1000)) /km")
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .frame(minWidth: 80, alignment: .trailing)
                    }
                    .monospacedDigit()
                }
            }
        }
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.headline)
    }
}

struct StatCell: View {
    let title: String
    let value: String
    let unit: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .monospacedDigit()
                if let unit {
                    Text(unit).font(.caption).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        }
    }
}
