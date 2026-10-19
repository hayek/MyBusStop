import SwiftUI

// Throwaway POC screens for exercising the transit service layer. Not the real UI.

struct POCRootView: View {
    @AppStorage("poc.providerId") private var providerId = TransitProviders.all[0].id
    @State private var query = "41117"
    @State private var stops: [TransitStop] = []
    @State private var errorMessage: String?
    @State private var isSearching = false

    private var provider: any TransitProvider { TransitProviders.provider(id: providerId) }

    var body: some View {
        Form {
            Section("Provider (A/B)") {
                Picker("Provider", selection: $providerId) {
                    ForEach(TransitProviders.all, id: \.id) { Text($0.displayName).tag($0.id) }
                }
                Text("Refresh every \(provider.suggestedRefreshInterval.components.seconds)s")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Stop — name or code (e.g. אלנבי ג, 41122)") {
                HStack {
                    TextField("Search", text: $query).onSubmit(search)
                    if isSearching { ProgressView() }
                    Button("Go", action: search)
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.caption) }
            }

            Section("Results") {
                ForEach(stops) { stop in
                    NavigationLink {
                        POCLinesView(provider: provider, stop: stop)
                    } label: {
                        VStack(alignment: .leading) {
                            Text("\(stop.name)  #\(stop.code)")
                            Text(stop.city ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("BusBus POC")
        .onChange(of: providerId) { stops = [] }
    }

    private func search() {
        let provider = provider
        isSearching = true
        errorMessage = nil
        Task {
            defer { isSearching = false }
            do { stops = try await provider.searchStops(query: query) } catch {
                stops = []
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct POCLinesView: View {
    let provider: any TransitProvider
    let stop: TransitStop
    @State private var lines: [TransitLine]?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            if lines == nil, errorMessage == nil { ProgressView("Loading lines…") }
            ForEach(lines ?? []) { line in
                NavigationLink {
                    POCTrackingView(tracker: BusTracker(provider: provider, line: line, stop: stop))
                } label: {
                    VStack(alignment: .leading) {
                        HStack {
                            Text(line.shortName).font(.headline)
                            if line.isAccessible == true { Image(systemName: "figure.roll").foregroundStyle(.blue) }
                            Text(line.agency ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                        Text("\(line.origin ?? "?") → \(line.destination ?? line.headsign ?? "?")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("\(stop.name) #\(stop.code)")
        .task {
            do { lines = try await provider.lines(atStop: stop) } catch { errorMessage = error.localizedDescription }
        }
    }
}

struct POCTrackingView: View {
    @State var tracker: BusTracker
    /// Details show whichever bus is selected, read from the latest refresh — all buses update together.
    @State private var selectedBusID: String?

    var body: some View {
        List {
            Section("\(tracker.line.shortName) → \(tracker.stop.name)") {
                if let progress = tracker.progress, let geometry = tracker.geometry {
                    POCProgressBar(progress: progress, geometry: geometry, selectedBusID: $selectedBusID)
                        .frame(height: 96)
                        .padding(.vertical, 4)
                    POCProgressDetails(progress: progress, geometry: geometry)
                } else if tracker.errorMessage == nil {
                    ProgressView("Loading route & buses…")
                }
                if let error = tracker.errorMessage { Text(error).foregroundStyle(.red) }
            }

            Section("Line \(tracker.line.shortName)") {
                LabeledContent("First stop", value: stopLabel(tracker.geometry?.pattern.firstStop) ?? tracker.line.origin ?? "—")
                LabeledContent("Last stop", value: stopLabel(tracker.geometry?.pattern.lastStop) ?? tracker.line.destination ?? "—")
                LabeledContent("Accessible (line)", value: tracker.line.isAccessible.map { $0 ? "yes" : "no" } ?? "unknown")
            }

            if let progress = tracker.progress, let geometry = tracker.geometry {
                Section("Buses that left the origin (\(progress.buses.count))") {
                    if progress.buses.isEmpty { Text("No buses on the route").foregroundStyle(.secondary) }
                    ForEach(progress.buses.reversed()) { bus in
                        Button { selectedBusID = bus.id } label: {
                            POCBusRow(bus: bus, progress: progress, geometry: geometry)
                        }
                        .tint(.primary)
                    }
                }
            }

            Section("Debug") {
                LabeledContent("Provider", value: tracker.provider.displayName)
                LabeledContent("Line id", value: tracker.line.id)
                if let geometry = tracker.geometry {
                    LabeledContent("Route stops", value: "\(geometry.pattern.stops.count)")
                    LabeledContent("Route length", value: "\(Int(geometry.totalLength)) m")
                }
                if let progress = tracker.progress {
                    LabeledContent("Positions returned", value: "\(progress.allVehicleCount)")
                    LabeledContent("Fetch time", value: progress.fetchDuration.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow)))
                    LabeledContent("Fetched at", value: progress.fetchedAt.formatted(date: .omitted, time: .standard))
                    if let arrivalsError = progress.arrivalsError {
                        Text("Arrivals: \(arrivalsError)").font(.caption).foregroundStyle(.orange)
                    }
                }
                Button("Refresh now") { Task { await tracker.refresh() } }
            }
        }
        .navigationTitle("Tracking")
        .onAppear { tracker.start() }
        .onDisappear { tracker.cancel() }
        .sheet(isPresented: Binding(get: { selectedBusID != nil }, set: { if !$0 { selectedBusID = nil } })) {
            POCBusDetailsSheet(tracker: tracker, busID: selectedBusID ?? "")
                .presentationDetents([.medium, .large])
        }
    }
}

struct POCBusRow: View {
    let bus: TrackedBus
    let progress: BusProgress
    let geometry: RouteGeometry

    var body: some View {
        HStack {
            Image(systemName: "bus.fill").foregroundStyle(bus.isNext ? .blue : .gray)
            VStack(alignment: .leading) {
                Text(bus.vehicle.plateNumber ?? bus.id).font(.body.monospacedDigit())
                Text(POCBusText.position(bus, progress, geometry)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if bus.isNext { Text(verbatim: "NEXT").font(.caption2.bold()).foregroundStyle(.blue) }
        }
    }
}

/// Live details of one bus. Reads the tracker, so it refreshes with everything else.
struct POCBusDetailsSheet: View {
    let tracker: BusTracker
    let busID: String

    var body: some View {
        NavigationStack {
            List {
                if let progress = tracker.progress, let geometry = tracker.geometry,
                   let bus = progress.buses.first(where: { $0.id == busID }) {
                    Section {
                        LabeledContent("Position", value: POCBusText.position(bus, progress, geometry))
                        LabeledContent("Route progress", value: bus.routeFraction.formatted(.percent.precision(.fractionLength(0))))
                        if bus.offRoute > 0 { LabeledContent("Snap offset", value: "\(Int(bus.offRoute)) m") }
                    }
                    Section { POCVehicleDetails(vehicle: bus.vehicle, fetchedAt: progress.fetchedAt) }
                } else {
                    Text("This bus is no longer on the route.").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Line \(tracker.line.shortName) · \(busID)")
        }
    }
}

nonisolated enum POCBusText {
    static func position(_ bus: TrackedBus, _ progress: BusProgress, _ geometry: RouteGeometry) -> String {
        if bus.hasPassedStop(progress) { return "passed the stop \(Int(-bus.metersToStop(progress))) m ago" }
        let stopsAway = progress.targetStopIndex - geometry.lastStopIndex(atDistance: bus.distanceAlongRoute)
        return "\(Int(max(0, bus.metersToStop(progress)))) m · \(stopsAway) stops to your stop"
    }
}

private func stopLabel(_ stop: TransitStop?) -> String? {
    stop.map { [$0.name, $0.city].compactMap { $0 }.joined(separator: ", ") + " #\($0.code)" }
}

/// The fields riders know from SIRI-based apps: departures, plate, accessibility, speed, freshness.
struct POCVehicleDetails: View {
    let vehicle: VehiclePosition
    let fetchedAt: Date

    var body: some View {
        LabeledContent("Aimed departure", value: time(vehicle.aimedDeparture))
        LabeledContent("Actual departure", value: time(vehicle.actualDeparture))
        LabeledContent("Plate number", value: vehicle.plateNumber ?? "—")
        LabeledContent("Accessible (bus)", value: vehicle.isAccessible.map { $0 ? "yes" : "no" } ?? "unknown")
        LabeledContent("Speed", value: vehicle.speedKmh.map { "\(Int($0)) km/h" } ?? "—")
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let recordedAt = vehicle.recordedAt {
                LabeledContent("Updated", value: "\(Int(context.date.timeIntervalSince(recordedAt))) seconds ago")
            } else {
                LabeledContent("Updated", value: "fetched \(Int(context.date.timeIntervalSince(fetchedAt))) s ago (no GPS timestamp)")
            }
        }
    }

    private func time(_ date: Date?) -> String {
        date?.formatted(date: .omitted, time: .shortened) ?? "—"
    }
}

/// Whole route from origin to last stop: a tick per stop, a pin at the rider's stop,
/// and a tappable icon for every bus on the route.
struct POCProgressBar: View {
    let progress: BusProgress
    let geometry: RouteGeometry
    @Binding var selectedBusID: String?

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let trackY = proxy.size.height * 0.62
            let length = max(progress.routeLength, 1)
            ZStack(alignment: .topLeading) {
                Capsule().fill(.gray.opacity(0.2))
                    .frame(width: width, height: 8).offset(y: trackY - 4)
                Capsule().fill(.blue.opacity(0.35))
                    .frame(width: width * (progress.nextBus?.routeFraction ?? 0), height: 8).offset(y: trackY - 4)
                ForEach(geometry.stopDistances.indices, id: \.self) { index in
                    Circle().fill(.secondary).frame(width: 3, height: 3)
                        .offset(x: width * geometry.stopDistances[index] / length - 1.5, y: trackY - 1.5)
                }
                Image(systemName: "mappin.and.ellipse").foregroundStyle(.red)
                    .frame(width: 20, height: 20)
                    .offset(x: width * progress.targetRouteFraction - 10, y: trackY + 8)

                // Alternate two rows so neighbouring buses don't cover each other.
                ForEach(Array(progress.buses.enumerated()), id: \.element.id) { index, bus in
                    Button { selectedBusID = bus.id } label: {
                        Image(systemName: "bus.fill")
                            .foregroundStyle(bus.isNext ? .blue : (bus.hasPassedStop(progress) ? .gray.opacity(0.5) : .gray))
                            .font(bus.isNext ? .title3 : .body)
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .offset(x: width * bus.routeFraction - 15, y: trackY - (index.isMultiple(of: 2) ? 34 : 62))
                    .animation(.easeInOut(duration: 0.6), value: bus.routeFraction)
                }
            }
        }
    }
}

struct POCProgressDetails: View {
    let progress: BusProgress
    let geometry: RouteGeometry

    var body: some View {
        if let next = progress.nextBus {
            LabeledContent("Next bus", value: POCBusText.position(next, progress, geometry))
        } else {
            Text("No approaching bus with a live position.").foregroundStyle(.secondary)
        }

        if let arrival = progress.nextArrival {
            LabeledContent("Next arrival", value: arrival.expectedAt.formatted(date: .omitted, time: .shortened))
            LabeledContent("In", value: "\(Int(arrival.expectedAt.timeIntervalSinceNow / 60)) min · \(arrival.isRealtime ? "realtime" : "scheduled")")
        } else {
            LabeledContent("Next arrival", value: "—")
        }
    }
}

#Preview {
    POCRootView()
}
