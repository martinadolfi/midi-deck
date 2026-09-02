import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var configManager: ConfigManager
    @State private var selectedTab: SettingsTab = .mappings

    init(appState: AppState) {
        self.appState = appState
        _configManager = ObservedObject(wrappedValue: appState.configManager)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = configManager.configError {
                ConfigurationBanner(
                    title: configManager.isUsingLastKnownGood ? "Using your last working setup" : "Configuration needs attention",
                    message: error,
                    color: .red,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .padding([.horizontal, .top], 12)
            } else if let notice = configManager.migrationNotice {
                ConfigurationBanner(
                    title: "Configuration upgrade available",
                    message: notice,
                    color: .blue,
                    systemImage: "arrow.up.circle.fill"
                )
                .padding([.horizontal, .top], 12)
            }

            TabView(selection: $selectedTab) {
                MappingSettingsView(appState: appState)
                    .tabItem { Label("Mappings", systemImage: "square.grid.3x3") }
                    .tag(SettingsTab.mappings)

                ControllerSettingsView(appState: appState)
                    .tabItem { Label("Controllers", systemImage: "pianokeys") }
                    .tag(SettingsTab.controllers)

                ConfigurationSettingsView(appState: appState)
                    .tabItem { Label("Configuration", systemImage: "doc.text") }
                    .tag(SettingsTab.configuration)
            }
            .padding(.top, 4)
        }
        .frame(minWidth: 760, minHeight: 520)
        .onDisappear {
            appState.endLearning()
        }
    }
}

private enum SettingsTab: Hashable {
    case mappings
    case controllers
    case configuration
}

private struct MappingSettingsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var configManager: ConfigManager
    @ObservedObject private var midiEngine: MIDIEngine

    @State private var selectedProfile: String?
    @State private var searchText = ""
    @State private var editingMapping: Mapping?
    @State private var newMappingDraft: Mapping?
    @State private var showingMIDILearn = false
    @State private var profilePrompt: ProfilePrompt?
    @State private var profileNameDraft = ""
    @State private var profilePromptError: String?
    @State private var profilePendingDeletion: String?
    @State private var mappingPendingDeletion: Mapping?

    init(appState: AppState) {
        self.appState = appState
        _configManager = ObservedObject(wrappedValue: appState.configManager)
        _midiEngine = ObservedObject(wrappedValue: appState.midiEngine)
        _selectedProfile = State(initialValue: appState.configManager.config.activeProfile)
    }

    var body: some View {
        HSplitView {
            profileSidebar
                .frame(minWidth: 180, idealWidth: 205, maxWidth: 240)
            mappingContent
                .frame(minWidth: 510)
        }
        .padding(.top, 8)
        .sheet(item: $editingMapping) { mapping in
            MappingEditor(
                mapping: mapping,
                appState: appState,
                profileName: currentProfileName
            )
        }
        .sheet(item: $newMappingDraft) { mapping in
            MappingEditor(
                mapping: mapping,
                appState: appState,
                profileName: currentProfileName,
                isNew: true
            )
        }
        .sheet(isPresented: $showingMIDILearn) {
            MIDILearnView(appState: appState, profileName: currentProfileName)
        }
        .alert(profilePrompt?.title ?? "Profile", isPresented: Binding(
            get: { profilePrompt != nil },
            set: {
                if !$0 {
                    profilePrompt = nil
                    profilePromptError = nil
                }
            }
        )) {
            TextField("Profile name", text: $profileNameDraft)
            Button("Cancel", role: .cancel) {
                profilePrompt = nil
                profilePromptError = nil
            }
            Button(profilePrompt?.buttonTitle ?? "Save") { completeProfilePrompt() }
                .disabled(profileNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text(profilePromptMessage)
        }
        .confirmationDialog(
            "Delete profile?",
            isPresented: Binding(
                get: { profilePendingDeletion != nil },
                set: { if !$0 { profilePendingDeletion = nil } }
            )
        ) {
            Button("Delete Profile", role: .destructive) {
                if let name = profilePendingDeletion,
                   configManager.removeProfile(named: name) {
                    selectedProfile = configManager.config.activeProfile
                }
                profilePendingDeletion = nil
            }
        } message: {
            Text(profileDeletionMessage)
        }
        .confirmationDialog(
            "Delete mapping?",
            isPresented: Binding(
                get: { mappingPendingDeletion != nil },
                set: { if !$0 { mappingPendingDeletion = nil } }
            )
        ) {
            Button("Delete Mapping", role: .destructive) {
                if let mapping = mappingPendingDeletion {
                    _ = configManager.removeMapping(id: mapping.id, fromProfile: currentProfileName)
                }
                mappingPendingDeletion = nil
            }
        } message: {
            Text("You can restore the previous configuration from the Configuration tab.")
        }
        .onChange(of: configManager.profileNames) { _, names in
            if let selectedProfile, names.contains(selectedProfile) { return }
            selectedProfile = configManager.config.activeProfile
        }
    }

    private var profileSidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Profiles")
                    .font(.headline)
                Spacer()
                Menu {
                    Button("New Profile…", systemImage: "plus") {
                        showProfilePrompt(.add)
                    }
                    if let selectedProfile {
                        Button("Duplicate…", systemImage: "plus.square.on.square") {
                            showProfilePrompt(.duplicate(selectedProfile))
                        }
                        Button("Rename…", systemImage: "pencil") {
                            showProfilePrompt(.rename(selectedProfile))
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .help("Add or duplicate a profile")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            List(selection: $selectedProfile) {
                ForEach(configManager.profileNames, id: \.self) { name in
                    HStack(spacing: 8) {
                        Image(systemName: name == configManager.config.activeProfile ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(name == configManager.config.activeProfile ? .green : .secondary)
                            .accessibilityLabel(name == configManager.config.activeProfile ? "Active" : "Inactive")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(name)
                                .lineLimit(1)
                            Text("\(configManager.config.profiles[name]?.mappings.count ?? 0) mappings")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(Optional(name))
                    .contextMenu {
                        Button("Make Active") {
                            _ = appState.actionExecutor.activateProfile(name)
                        }
                        Button("Rename…") { showProfilePrompt(.rename(name)) }
                        Button("Duplicate…") { showProfilePrompt(.duplicate(name)) }
                        Divider()
                        Button("Delete…", role: .destructive) {
                            profilePendingDeletion = name
                        }
                        .disabled(configManager.profileNames.count <= 1)
                    }
                }
            }
            .listStyle(.sidebar)

            if currentProfileName != configManager.config.activeProfile {
                Button("Make \(currentProfileName) Active") {
                    _ = appState.actionExecutor.activateProfile(currentProfileName)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .padding([.horizontal, .bottom], 10)
            }
        }
        .background(.background.secondary)
    }

    private var mappingContent: some View {
        VStack(spacing: 0) {
            mappingToolbar
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()

            if filteredMappings.isEmpty {
                emptyMappings
            } else {
                List(filteredMappings) { mapping in
                    Button {
                        editingMapping = mapping
                    } label: {
                        MappingRow(mapping: mapping)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Edit…") { editingMapping = mapping }
                        Button("Duplicate") { duplicate(mapping) }
                        Divider()
                        Button("Delete…", role: .destructive) {
                            mappingPendingDeletion = mapping
                        }
                    }
                    .accessibilityHint("Opens this mapping for editing")
                }
                .listStyle(.inset)
            }
        }
    }

    private var mappingToolbar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(currentProfileName)
                    .font(.title3.weight(.semibold))
                Text("Controls and the actions they trigger")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            TextField("Search mappings", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 190)
            Button {
                showingMIDILearn = true
            } label: {
                Label("MIDI Learn", systemImage: "dot.radiowaves.left.and.right")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .help(midiEngine.connectedSources.isEmpty
                ? "Open MIDI Learn, then connect a controller"
                : "Press or move a control to create a mapping")

            Button {
                newMappingDraft = blankMapping()
            } label: {
                Image(systemName: "plus")
            }
            .keyboardShortcut("n", modifiers: .command)
            .help("Add a mapping manually")
        }
    }

    private var emptyMappings: some View {
        ContentUnavailableView {
            Label(searchText.isEmpty ? "No mappings yet" : "No matching mappings", systemImage: "square.grid.3x3")
        } description: {
            Text(searchText.isEmpty
                ? (midiEngine.connectedSources.isEmpty
                    ? "Connect a controller, then create your first mapping."
                    : "MIDI Learn is the quickest way to create your first mapping.")
                : "Try a different search.")
        } actions: {
            if searchText.isEmpty {
                Button("Create with MIDI Learn") { showingMIDILearn = true }
                    .buttonStyle(.borderedProminent)
                Button("Add Manually") { newMappingDraft = blankMapping() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var currentProfileName: String {
        if let selectedProfile, configManager.config.profiles[selectedProfile] != nil {
            return selectedProfile
        }
        return configManager.config.activeProfile
    }

    private var filteredMappings: [Mapping] {
        let mappings = configManager.config.profiles[currentProfileName]?.mappings ?? []
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return mappings }
        return mappings.filter { mapping in
            [mapping.displayTitle, mapping.triggerSummary, mapping.actionSummary, mapping.source?.name ?? mapping.device ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private func duplicate(_ mapping: Mapping) {
        var copy = mapping
        copy.id = UUID()
        copy.description = mapping.displayTitle + " copy"
        newMappingDraft = copy
    }

    private func showProfilePrompt(_ prompt: ProfilePrompt.Kind) {
        profilePromptError = nil
        switch prompt {
        case .add:
            profileNameDraft = uniqueProfileName(base: "New Profile")
        case .rename(let name):
            profileNameDraft = name
        case .duplicate(let name):
            profileNameDraft = uniqueProfileName(base: "\(name) Copy")
        }
        profilePrompt = ProfilePrompt(kind: prompt)
    }

    private func completeProfilePrompt() {
        guard let prompt = profilePrompt else { return }
        let name = profileNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let succeeded: Bool
        switch prompt.kind {
        case .add:
            succeeded = configManager.addProfile(named: name)
        case .rename(let oldName):
            succeeded = configManager.renameProfile(oldName, to: name)
        case .duplicate(let source):
            succeeded = configManager.duplicateProfile(source, as: name)
        }
        if succeeded {
            selectedProfile = name
            profilePrompt = nil
            profilePromptError = nil
        } else {
            profilePromptError = configManager.configError ?? "The profile could not be saved."
        }
    }

    private func blankMapping() -> Mapping {
        Mapping(
            trigger: Trigger(type: .noteOn, channel: 1, note: 36),
            action: Action(type: .openApp),
            led: nil
        )
    }

    private var profilePromptMessage: String {
        let guidance = profilePrompt?.message ?? ""
        guard let profilePromptError else { return guidance }
        return guidance.isEmpty ? profilePromptError : "\(guidance)\n\n\(profilePromptError)"
    }

    private var profileDeletionMessage: String {
        guard let name = profilePendingDeletion,
              let replacement = configManager.profileNames.first(where: { $0 != name }) else {
            return "Its mappings will be removed. A configuration backup is created first."
        }

        let retargetCount = configManager.config.profiles
            .filter { $0.key != name }
            .values
            .reduce(into: 0) { count, profile in
                count += profile.mappings.filter {
                    $0.action.type == .switchProfile && $0.action.profile == name
                }.count
            }

        var consequences = ["All mappings in ‘\(name)’ will be removed."]
        if retargetCount > 0 {
            let noun = retargetCount == 1 ? "mapping" : "mappings"
            consequences.append("\(retargetCount) \(noun) in other profiles will switch to ‘\(replacement)’ instead.")
        }
        if configManager.config.activeProfile == name {
            consequences.append("‘\(replacement)’ will become active.")
        }
        consequences.append("A configuration backup is created first.")
        return consequences.joined(separator: " ")
    }

    private func uniqueProfileName(base: String) -> String {
        guard configManager.config.profiles[base] != nil else { return base }
        var suffix = 2
        while configManager.config.profiles["\(base) \(suffix)"] != nil { suffix += 1 }
        return "\(base) \(suffix)"
    }
}

struct MappingRow: View {
    let mapping: Mapping

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: mapping.action.type.systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(mapping.displayTitle)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 7) {
                    Label(mapping.triggerSummary, systemImage: mapping.trigger.type.systemImage)
                    Text("→")
                    Text(mapping.actionSummary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()

            if let source = mapping.source {
                Text(source.name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            } else if mapping.device != nil {
                Text("Legacy device")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            if let led = mapping.led {
                Circle()
                    .fill(led.color.swiftUIColor)
                    .overlay(Circle().stroke(.secondary.opacity(0.5), lineWidth: led.color == .white ? 1 : 0))
                    .frame(width: 12, height: 12)
                    .accessibilityLabel("LED \(led.color.displayName)")
            }
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}

private struct ProfilePrompt: Identifiable {
    enum Kind {
        case add
        case rename(String)
        case duplicate(String)
    }

    let id = UUID()
    let kind: Kind

    var title: String {
        switch kind {
        case .add: return "New Profile"
        case .rename: return "Rename Profile"
        case .duplicate: return "Duplicate Profile"
        }
    }

    var buttonTitle: String {
        switch kind {
        case .add: return "Create"
        case .rename: return "Rename"
        case .duplicate: return "Duplicate"
        }
    }

    var message: String {
        switch kind {
        case .add: return "Profiles let the same controls perform a different set of actions."
        case .rename: return "Mappings that switch to this profile will be updated too."
        case .duplicate: return "The copy gets independent mappings and IDs."
        }
    }
}

struct ConfigurationBanner: View {
    let title: String
    let message: String
    let color: Color
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(10)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
    }
}
