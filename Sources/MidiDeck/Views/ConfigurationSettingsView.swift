import AppKit
@preconcurrency import ApplicationServices
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct ConfigurationSettingsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var configManager: ConfigManager

    @State private var backupRestoreConfirmation = false
    @State private var importCandidate: URL?
    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var transientMessage: ConfigurationTransientMessage?

    init(appState: AppState) {
        self.appState = appState
        _configManager = ObservedObject(wrappedValue: appState.configManager)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Configuration")
                        .font(.title2.weight(.semibold))
                    Text("Edit visually here, or open the JSON escape hatch. Every structural save creates a rollback copy.")
                        .foregroundStyle(.secondary)
                }

                if let transientMessage {
                    ConfigurationBanner(
                        title: transientMessage.isError ? "Configuration error" : "Configuration",
                        message: transientMessage.message,
                        color: transientMessage.isError ? .red : .green,
                        systemImage: transientMessage.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                    )
                }

                fileCard

                if !configManager.alternativeConfigURLs.isEmpty {
                    alternativeFilesCard
                }

                if !configManager.validationIssues.isEmpty || configManager.configError != nil {
                    diagnosticsCard
                }

                permissionsCard
            }
            .padding(22)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .confirmationDialog("Restore the previous configuration?", isPresented: $backupRestoreConfirmation) {
            Button("Restore Backup", role: .destructive) {
                if configManager.restoreLastBackup() {
                    transientMessage = .success("The previous configuration was restored. Restore again to undo.")
                }
            }
        } message: {
            Text("The current configuration becomes the next backup, so Restore can undo this change.")
        }
        .confirmationDialog(
            "Import this configuration?",
            isPresented: Binding(
                get: { importCandidate != nil },
                set: { if !$0 { importCandidate = nil } }
            )
        ) {
            Button("Import and Back Up Current File") {
                if let url = importCandidate,
                   configManager.importConfiguration(from: url) {
                    transientMessage = .success("Imported \(url.lastPathComponent) into the canonical configuration.")
                }
                importCandidate = nil
            }
        } message: {
            Text("The active file is backed up first. The source file is not changed.")
        }
        .onAppear {
            refreshAccessibilityStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshAccessibilityStatus()
        }
    }

    private var fileCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: configManager.configError == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(configManager.configError == nil ? .green : .red)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(configManager.statusMessage)
                            .font(.body.weight(.medium))
                        Text(configManager.activeConfigURL.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Text("Schema v\(Configuration.currentVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                }

                Divider()

                HStack(spacing: 8) {
                    Button("Open JSON", systemImage: "square.and.pencil") {
                        openConfiguration()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Reveal in Finder", systemImage: "folder") {
                        revealConfiguration()
                    }

                    Button("Copy Path", systemImage: "doc.on.doc") {
                        copyPath()
                    }

                    Button("Import…", systemImage: "square.and.arrow.down") {
                        chooseImportFile()
                    }

                    Spacer()

                    Button("Reload", systemImage: "arrow.clockwise") {
                        if appState.reloadConfiguration() {
                            transientMessage = .success("Reloaded the configuration from disk.")
                        }
                    }
                }

                HStack(spacing: 8) {
                    Button("Export Copy…", systemImage: "square.and.arrow.up") {
                        exportCopy()
                    }
                    Button("Restore Last Backup…", systemImage: "clock.arrow.circlepath") {
                        backupRestoreConfirmation = true
                    }
                    .disabled(configManager.lastBackupURL == nil)

                    Spacer()
                    if let backup = configManager.lastBackupURL {
                        Text("Backup: \(backup.lastPathComponent)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("A backup is created before your first change")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .controlSize(.small)
            }
            .padding(6)
        } label: {
            Label("Active configuration file", systemImage: "doc.text")
                .font(.headline)
        }
    }

    private var alternativeFilesCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                ConfigurationBanner(
                    title: "Another configuration was found",
                    message: "MidiDeck uses the canonical path above every time, so behavior no longer depends on how the app was launched. Import another file only if you choose to.",
                    color: .blue,
                    systemImage: "doc.on.doc.fill"
                )

                ForEach(configManager.alternativeConfigURLs, id: \.path) { url in
                    HStack(spacing: 10) {
                        Image(systemName: "doc.text")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(url.lastPathComponent)
                                .font(.body.weight(.medium))
                            Text(url.path)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Button("Import…") { importCandidate = url }
                        Button("Reveal") {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
            .padding(6)
        } label: {
            Label("Other detected files", systemImage: "rectangle.stack.badge.exclamationmark")
                .font(.headline)
        }
    }

    private var diagnosticsCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 9) {
                if let error = configManager.configError {
                    ConfigurationBanner(
                        title: configManager.isUsingLastKnownGood ? "Last-known-good setup is still active" : "Configuration error",
                        message: error,
                        color: .red,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                }

                ForEach(configManager.validationIssues) { issue in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: issue.severity == .error ? "xmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(issue.severity == .error ? .red : .orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(issue.message)
                            if let location = issue.location {
                                Text(location)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .font(.caption)
                }
            }
            .padding(6)
        } label: {
            Label("Diagnostics", systemImage: "stethoscope")
                .font(.headline)
        }
    }

    private var permissionsCard: some View {
        GroupBox {
            HStack(spacing: 12) {
                Image(systemName: accessibilityGranted ? "checkmark.shield.fill" : "shield.lefthalf.filled")
                    .font(.title2)
                    .foregroundStyle(accessibilityGranted ? .green : .orange)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(accessibilityGranted ? "Accessibility is enabled" : "Accessibility is optional")
                        .font(.body.weight(.medium))
                    Text(accessibilityGranted
                        ? "App window cycling is available."
                        : "Launching and focusing apps still works. Enable access only if you want to cycle an app’s visible windows.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !accessibilityGranted {
                    Button("Request Access") { requestAccessibility() }
                }
                Button("Open Settings") { openAccessibilitySettings() }
            }
            .padding(8)
        } label: {
            Label("Permissions", systemImage: "lock.shield")
                .font(.headline)
        }
    }

    private func openConfiguration() {
        if !FileManager.default.fileExists(atPath: configManager.activeConfigURL.path) {
            guard configManager.save() else { return }
        }
        NSWorkspace.shared.open(configManager.activeConfigURL)
    }

    private func revealConfiguration() {
        if !FileManager.default.fileExists(atPath: configManager.activeConfigURL.path) {
            guard configManager.save() else { return }
        }
        NSWorkspace.shared.activateFileViewerSelecting([configManager.activeConfigURL])
    }

    private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(configManager.activeConfigURL.path, forType: .string)
        transientMessage = .success("Copied the configuration path.")
    }

    private func chooseImportFile() {
        let panel = NSOpenPanel()
        panel.title = "Import MidiDeck Configuration"
        panel.prompt = "Import"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importCandidate = url
    }

    private func exportCopy() {
        if !FileManager.default.fileExists(atPath: configManager.activeConfigURL.path) {
            guard configManager.save() else { return }
        }
        let panel = NSSavePanel()
        panel.title = "Export MidiDeck Configuration"
        panel.nameFieldStringValue = "midideck-config.json"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            let data = try Data(contentsOf: configManager.activeConfigURL)
            try data.write(to: destination, options: .atomic)
            transientMessage = .success("Exported a configuration copy to \(destination.lastPathComponent).")
        } catch {
            transientMessage = .failure("Export failed: \(error.localizedDescription)")
        }
    }

    private func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            refreshAccessibilityStatus()
        }
    }

    private func refreshAccessibilityStatus() {
        accessibilityGranted = AXIsProcessTrusted()
    }

    private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}

private enum ConfigurationTransientMessage {
    case success(String)
    case failure(String)

    var message: String {
        switch self {
        case .success(let message), .failure(let message): return message
        }
    }

    var isError: Bool {
        if case .failure = self { return true }
        return false
    }
}
