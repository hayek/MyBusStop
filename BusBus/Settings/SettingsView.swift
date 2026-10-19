#if canImport(HelpView)
import HelpView
#endif
import SwiftUI

/// Ordinary system chrome, deliberately: this screen is settings, not the board.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var settings: SettingsStore

    /// Nil is automatic: setup follows the rider's location. Choosing a provider pins it.
    private var providerChoice: Binding<String?> {
        Binding(
            get: { settings.providerIsAutomatic ? nil : settings.providerID },
            set: { choice in
                if let choice {
                    settings.providerIsAutomatic = false
                    settings.providerID = choice
                } else {
                    settings.providerIsAutomatic = true
                }
            })
    }

    /// Transitous is offered only while its remote flag allows it (its policy forbids commercial
    /// use), or while it is already the one in use.
    private var listedProviders: [any TransitProvider] {
        TransitProviders.all.filter {
            $0.id != TransitousProvider.providerID || settings.transitousIsEnabled() || settings.providerID == $0.id
        }
    }

    /// The licences' credit lines for whatever is on screen: the board's feed and setup's.
    private var credits: [String] {
        var seen = Set<String>()
        return [settings.boardProvider.attribution, settings.provider.attribution]
            .compactMap { $0 }
            .filter { seen.insert($0).inserted }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // A TV is glanced at, not left on the wall: no wall mode and no bus to tap.
                    #if !os(tvOS)
                    Toggle("Wall mode", isOn: $settings.wallMode)
                        .onChange(of: settings.wallMode) { _, on in
                            Telemetry.log("wall_mode", ["on": on ? "yes" : "no"])
                            Telemetry.setUserProperty(on ? "yes" : "no", for: "wall_mode")
                        }
                    #endif
                    #if os(iOS)
                    GuidedAccessGuideLink()
                    #endif
                    Picker("Appearance", selection: $settings.appearance) {
                        ForEach(Appearance.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .disabled(settings.wallMode)
                    .onChange(of: settings.appearance) { _, value in Self.logChange("appearance", value.rawValue) }
                    Picker("Language", selection: $settings.language) {
                        Text("System").tag(String?.none)
                        ForEach(AppLanguage.supported, id: \.self) { Text(verbatim: AppLanguage.name(of: $0)).tag(String?.some($0)) }
                    }
                    .onChange(of: settings.language) { _, value in Self.logChange("language", value ?? "system") }
                    #if !os(tvOS)
                    Picker("Tap a bus", selection: tapBehaviourBinding) {
                        Text("Follow wall mode").tag(TapBehaviour?.none)
                        ForEach(TapBehaviour.allCases, id: \.self) { Text($0.title).tag(TapBehaviour?.some($0)) }
                    }
                    .onChange(of: settings.tapBehaviourOverride) { _, value in
                        Self.logChange("tap_behaviour", value?.rawValue ?? "follow_wall_mode")
                    }
                    #endif
                } header: {
                    Text("Display")
                } footer: {
                    if settings.wallMode {
                        Text("A wall display stays dark and dims at night rather than turning light.")
                    }
                }

                #if !os(tvOS)
                Section {
                    ForEach(settings.wallSchedule.windows) { window in
                        NavigationLink {
                            WallWindowEditor(settings: settings, windowID: window.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: window.daysSummary())
                                Text(verbatim: window.timesSummary())
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { settings.wallSchedule.windows.remove(atOffsets: $0) }
                    Button {
                        settings.wallSchedule.windows.append(.new())
                    } label: {
                        Label("Add Time", systemImage: "plus")
                    }
                } header: {
                    Text("Screen on")
                } footer: {
                    Text(verbatim: settings.wallSchedule.summary())
                }
                .disabled(!settings.wallMode)
                #endif

                #if canImport(HelpView)
                Section {
                    NavigationLink {
                        // The package reads the catalog through the bundle, so the answers follow the
                        // launch language: a language picked above reaches them on the next launch.
                        HelpContentView(named: "app_help", localization: "HelpStrings", appContext: Self.helpContext)
                            .analyticsScreen("help")
                    } label: {
                        Label("Help & FAQ", systemImage: "questionmark.circle")
                    }
                }
                #endif

                // The licences ask for credit wherever the data is shown, so this stays in every build.
                Section {
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(credits, id: \.self) { Text(AttributedString(creditLine: $0)) }
                    }
                }

                #if DEBUG
                Section("Debug") {
                    Picker("Provider", selection: providerChoice) {
                        Text("Automatic (by location)").tag(String?.none)
                        ForEach(listedProviders + TransitProviders.heldBack, id: \.id) {
                            Text(verbatim: $0.displayName).tag(String?.some($0.id))
                        }
                    }
                    Picker("Mock scenario", selection: $settings.mockScenario) {
                        ForEach(MockScenario.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    NavigationLink("Transit POC") { POCRootView() }
                    NavigationLink { RefreshLogView() } label: { Text(verbatim: "Refresh log") }
                    Button {
                        settings.welcomeOnNextLaunch.toggle()
                    } label: {
                        LabeledContent {
                            if settings.welcomeOnNextLaunch { Image(systemName: "checkmark") }
                        } label: {
                            Text(verbatim: "Show onboarding on next launch")
                        }
                    }
                }
                #endif
            }
            // The Mac's default form sets labels in a column of their own, which a sheet this narrow
            // pushes off its left edge; grouped rows read like System Settings instead.
            .formStyle(.grouped)
            #if os(tvOS)
            // Full screen on the TV, where a form as wide as the room reads badly: a column in the
            // middle, as the system's own Settings sets it. Menu closes it, so there is no Done.
            .frame(maxWidth: 1100)
            #endif
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            #if !os(tvOS)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            #endif
        }
        #if os(macOS)
        // A sheet on the Mac takes its content's size, and a form proposes almost none.
        .frame(minWidth: 460, idealWidth: 480, minHeight: 440, idealHeight: 520)
        #endif
        .analyticsScreen("settings")
    }

    /// What the FAQ's Apple Intelligence search is told the app is.
    private static let helpContext = """
        My Bus Stop — a live bus arrivals board for iPhone, iPad, Mac and Apple Watch. The rider picks a stop and up to \
        three lines; the board shows each line's route with the buses on it, minutes to the next arrival and the one after. \
        It has a wall mode for an always-on display, Home Screen and Lock Screen widgets, and watch complications.
        """

    /// A setting the rider changed, and what to: which ones riders reach for, and what they pick.
    private static func logChange(_ setting: String, _ option: String) {
        Telemetry.log("setting_changed", ["setting": setting, "option": option])
    }

    private var tapBehaviourBinding: Binding<TapBehaviour?> {
        Binding(get: { settings.tapBehaviourOverride }, set: { settings.tapBehaviourOverride = $0 })
    }
}

#if !os(tvOS)
/// One window of the wall schedule, found by its id each time rather than held as a binding into
/// the list, so deleting it from here cannot leave the screen reading past the end of the array.
private struct WallWindowEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var settings: SettingsStore
    let windowID: WallWindow.ID

    private var index: Int? { settings.wallSchedule.windows.firstIndex { $0.id == windowID } }

    /// Edits whichever window still has this id; once it is gone, writes go nowhere.
    private func field<Value>(_ keyPath: WritableKeyPath<WallWindow, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: { index.map { settings.wallSchedule.windows[$0][keyPath: keyPath] } ?? fallback },
                set: { value in if let index { settings.wallSchedule.windows[index][keyPath: keyPath] = value } })
    }

    // The schedule is stored as minutes from midnight so it survives a move between time zones;
    // `DatePicker` wants a `Date`, so each end is carried across on the way in and out.
    private func time(_ keyPath: WritableKeyPath<WallWindow, Int>) -> Binding<Date> {
        let minutes = field(keyPath, fallback: 0)
        return Binding(get: { WallSchedule.date(fromMinutes: minutes.wrappedValue) },
                       set: { minutes.wrappedValue = WallSchedule.minutes(from: $0) })
    }

    var body: some View {
        Form {
            Section {
                WeekdayPicker(days: field(\.days, fallback: []))
                DatePicker("From", selection: time(\.startMinutes), displayedComponents: .hourAndMinute)
                DatePicker("Until", selection: time(\.endMinutes), displayedComponents: .hourAndMinute)
            } footer: {
                Text("The same time in both means the whole day.")
            }
            Section {
                Button("Delete Time", role: .destructive) {
                    dismiss()
                    settings.wallSchedule.windows.removeAll { $0.id == windowID }
                }
            }
        }
        .navigationTitle("Screen on")
    }
}
#endif

/// The seven days as a row of toggles, in the order the rider's own calendar puts them.
private struct WeekdayPicker: View {
    @Binding var days: Set<Int>
    private let calendar = Calendar.current

    var body: some View {
        HStack(spacing: 6) {
            ForEach(WallSchedule.orderedWeekdays(calendar: calendar), id: \.self) { weekday in
                let isOn = days.contains(weekday)
                Button {
                    if isOn { days.remove(weekday) } else { days.insert(weekday) }
                } label: {
                    Text(calendar.veryShortWeekdaySymbols[weekday - 1])
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background(isOn ? Color.accentColor : Color.secondary.opacity(0.15),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .foregroundStyle(isOn ? Color.white : Color.primary)
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(calendar.weekdaySymbols[weekday - 1])
                .accessibilityValue(isOn ? "On" : "Off")
                .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Days the screen stays on")
    }
}
