import AppKit
import MancoraFiji
import SwiftUI

/// Settings ▸ Fiji: whether it is installed and which version, where it is, whether it keeps itself up
/// to date, and the buttons to check for updates now and to download or reinstall it.
struct FijiSettingsView: View {
    let bridge: AppBridge
    @State private var confirmsReinstall = false
    @State private var failure: String?

    var body: some View {
        let fiji = FijiState.shared
        Form {
            Section("Installation") {
                LabeledContent("Status") { statusLabel(fiji.status) }
                if let progress = installProgress(fiji.status) {
                    progressRow(progress)
                }
                if let version = fiji.version {
                    LabeledContent("Version", value: FijiText.release(version) ?? "Unknown")
                    LabeledContent("Includes", value: Self.includes(version))
                }
                LabeledContent("Location") {
                    Text(Self.abbreviated(fiji.location))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(fiji.location.path)
                }
                HStack {
                    Spacer()
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([fiji.location]) }
                        .disabled(!fiji.isInstalled)
                }
            }
            Section {
                Toggle(
                    "Keep Fiji up to date automatically",
                    isOn: Binding(get: { fiji.settings.autoUpdate }, set: { fiji.setAutoUpdate($0) })
                )
                LabeledContent("Last checked") { dateText(fiji.settings.lastCheck) }
                LabeledContent("Last updated") { dateText(fiji.settings.lastUpdate) }
                if let error = fiji.settings.lastError {
                    Label {
                        Text(error)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.orange)
                    }
                    .help("Why the last automatic update did not finish. The next check tries again.")
                }
                if fiji.hasStagedUpdate {
                    stagedRow(fiji)
                }
                checkRow(fiji)
            } header: {
                Text("Updates")
            } footer: {
                Text("Fiji checks its update sites once a day and installs what it finds in the background.")
            }
            Section {
                if fiji.isInstalled {
                    Button("Reinstall Fiji…", role: .destructive) { confirmsReinstall = true }
                        .disabled(isBusy(fiji.status))
                } else {
                    Button("Download Fiji…") { Task { await bridge.downloadFiji() } }
                        .disabled(isBusy(fiji.status))
                }
            } footer: {
                Text(
                    fiji.isInstalled
                        ? "Moves Fiji to the Trash and downloads it again, about 700 MB."
                        : "About 700 MB, downloaded once. Mancora does this by itself the first time a command needs Fiji.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 600)
        .confirmationDialog("Reinstall Fiji?", isPresented: $confirmsReinstall, titleVisibility: .visible) {
            Button("Move to Trash and Download Again", role: .destructive) {
                Task { failure = await bridge.reinstallFiji() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Fiji goes to the Trash with the plugins added from update sites. Your images are not touched.")
        }
        .alert(
            "Fiji Couldn’t Be Reinstalled",
            isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(failure ?? "")
        }
    }

    // MARK: Rows

    @ViewBuilder private func statusLabel(_ status: FijiStatus) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Self.color(for: status))
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            switch status {
            case .notInstalled: Text("Not installed")
            case .installing(let progress): Text(FijiText.progress(progress))
            case .installed: Text("Installed")
            case .updating(_, let progress): Text(FijiText.progress(progress))
            }
        }
    }

    private static func color(for status: FijiStatus) -> Color {
        switch status {
        case .notInstalled: Color.secondary
        case .installing, .updating: Color.orange
        case .installed: Color.green
        }
    }

    /// The download's progress while Fiji is being installed.
    private func installProgress(_ status: FijiStatus) -> FijiProgress? {
        if case .installing(let progress) = status { return progress }
        return nil
    }

    private func isBusy(_ status: FijiStatus) -> Bool {
        switch status {
        case .installing, .updating: true
        case .notInstalled, .installed: false
        }
    }

    private func progressRow(_ progress: FijiProgress) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let fraction = progress.fractionCompleted {
                ProgressView(value: fraction)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
            if progress.phase == .downloading {
                Text(FijiText.megabytes(done: progress.completedBytes, of: progress.totalBytes))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    @ViewBuilder private func dateText(_ date: Date?) -> some View {
        if let date {
            Text(date.formatted(.relative(presentation: .named)))
                .help(date.formatted(date: .abbreviated, time: .shortened))
        } else {
            Text("Never")
                .foregroundStyle(.secondary)
        }
    }

    /// An update is ready and goes in when Fiji next starts.
    private func stagedRow(_ fiji: FijiState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text("Updates will be installed the next time Fiji starts.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(Color.accentColor)
            }
            HStack {
                if !fiji.stagedChanges.isEmpty {
                    Text(fiji.stagedChanges.count == 1 ? "1 change" : "\(fiji.stagedChanges.count) changes")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if bridge.isReady || bridge.hasFijiWindows {
                    Button("Restart Fiji Now") { Task { await bridge.restart() } }
                }
            }
        }
    }

    private func checkRow(_ fiji: FijiState) -> some View {
        HStack(spacing: 10) {
            Button("Check for Updates Now") { Task { await fiji.checkForUpdates() } }
                .disabled(!fiji.isInstalled || fiji.isChecking || isBusy(fiji.status))
            if fiji.isChecking || isBusy(fiji.status) && fiji.isInstalled {
                ProgressView()
                    .controlSize(.small)
            }
            resultText(fiji)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private func resultText(_ fiji: FijiState) -> some View {
        switch fiji.checkResult {
        case nil:
            EmptyView()
        case .upToDate:
            Text("Fiji is up to date.")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .available(let count):
            HStack(spacing: 8) {
                Text(count == 1 ? "1 update available." : "\(count) updates available.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Install") { Task { await fiji.installUpdates() } }
            }
        case .updated(let count):
            Text(count == 1 ? "Updated 1 file." : "Updated \(count) files.")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .staged:
            Text("Ready to install.")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .font(.callout)
                .foregroundStyle(Color.red)
                .lineLimit(3)
                .textSelection(.enabled)
        }
    }

    // MARK: Text

    /// `ImageJ 2.16.0 (1.54p) · Java 21.0.7`.
    private static func includes(_ version: FijiVersion) -> String {
        var parts: [String] = []
        if let imageJ2 = version.imageJ2 {
            parts.append("ImageJ \(imageJ2)" + (version.imageJ1.map { " (\($0))" } ?? ""))
        } else if let imageJ1 = version.imageJ1 {
            parts.append("ImageJ \(imageJ1)")
        }
        if let java = version.java { parts.append("Java \(java)") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private static func abbreviated(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}
