import AppKit
import MancoraFiji
import Observation
import SwiftUI

// First use of Fiji. Mancora does not ship Fiji: when a command needs the Java
// bridge and no Fiji is installed, this sheet explains that and downloads it
// (about 700 MB, once). It stays on the window the command came from, shows
// the download as it goes, and gives the command back to whoever asked when
// Fiji is there. Settings and the welcome window offer the same sheet.

/// Asks for Fiji, and downloads it. One sheet at a time, on the window in front.
@Observable
final class FijiSetup {
    static let shared = FijiSetup()

    enum Outcome {
        /// Fiji is installed; the command that asked can go on.
        case installed
        case cancelled
    }

    /// Why Fiji is wanted, in a sentence: "This command needs Fiji."
    private(set) var reason: String?
    /// Why the last download failed.
    private(set) var failure: String?
    /// A download has been asked for (it may not have reported anything yet).
    private(set) var isDownloading = false
    /// Cancel was pressed and the download is stopping.
    private(set) var isCancelling = false
    /// A progress to show instead of a real one, for the screenshot run (nothing is downloaded).
    private(set) var previewProgress: FijiProgress?

    @ObservationIgnored private var installTask: Task<Void, Never>?
    @ObservationIgnored private var waiting: [CheckedContinuation<Outcome, Never>] = []
    @ObservationIgnored private var sheet: NSWindow?

    /// What the download has reached, from the manager (a download started anywhere shows here).
    var progress: FijiProgress? {
        if let previewProgress { return previewProgress }
        if case .installing(let progress) = FijiState.shared.status { return progress }
        return nil
    }

    // MARK: Asking

    /// Shows the sheet on the window in front, unless Fiji is installed, and returns when Fiji is
    /// (`.installed`) or the person turned it down (`.cancelled`). Asked again while the sheet is up,
    /// it waits for the same answer.
    func request(reason: String?) async -> Outcome {
        if FijiManager.shared.isInstalled { return .installed }
        if sheet == nil { self.reason = reason }
        presentSheet()
        return await withCheckedContinuation { continuation in
            waiting.append(continuation)
        }
    }

    /// The screenshot run's sheet, on `window`: the offer, or a download that is part done, which does not exist.
    func showPreview(reason: String?, progress: FijiProgress?, on window: NSWindow) {
        self.reason = reason
        previewProgress = progress
        presentSheet(on: window)
    }

    func endPreview() {
        finish(.cancelled)
    }

    // MARK: Downloading

    func download() {
        guard installTask == nil else { return }
        failure = nil
        isDownloading = true
        installTask = Task {
            let result: Result<Void, any Error>
            do {
                try await FijiManager.shared.install()
                result = .success(())
            } catch {
                result = .failure(error)
            }
            installTask = nil
            isDownloading = false
            switch result {
            case .success:
                await FijiState.shared.refresh()
                finish(.installed)
            case .failure(let error):
                // Cancelling the task stops the download with whatever error that gives.
                if Task.isCancelled || error is CancellationError {
                    finish(.cancelled)
                } else {
                    failure = FijiText.describe(error)
                }
            }
        }
    }

    /// Stops a download in progress, or turns the offer down.
    func cancel() {
        if let installTask {
            isCancelling = true
            installTask.cancel()
        } else {
            finish(.cancelled)
        }
    }

    private func finish(_ outcome: Outcome) {
        reason = nil
        failure = nil
        isCancelling = false
        previewProgress = nil
        dismissSheet()
        let continuations = waiting
        waiting = []
        for continuation in continuations { continuation.resume(returning: outcome) }
    }

    // MARK: The sheet

    private func presentSheet(on host: NSWindow? = nil) {
        guard sheet == nil else { return }
        let window = NSWindow(contentViewController: NSHostingController(rootView: FijiSetupView(setup: self)))
        window.styleMask = [.titled]
        window.title = "Download Fiji"
        window.isReleasedWhenClosed = false
        sheet = window
        var parent = host ?? NSApp.keyWindow ?? NSApp.mainWindow ?? (NSApp.windows.first { $0.isVisible && $0.canBecomeMain })
        // A sheet that is up already (Find Command, a command's dialog) gets this one on top of it.
        while let attached = parent?.attachedSheet { parent = attached }
        if let parent {
            parent.beginSheet(window, completionHandler: nil)
        } else {
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func dismissSheet() {
        guard let window = sheet else { return }
        sheet = nil
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.orderOut(nil)
        }
    }
}

// MARK: The view

/// The sheet: what Fiji is and why it's downloaded, then the download.
struct FijiSetupView: View {
    let setup: FijiSetup

    private enum Mode {
        case offer
        case working(FijiProgress?)
        case failed(String)
    }

    private var mode: Mode {
        if let failure = setup.failure { return .failed(failure) }
        if setup.progress != nil || setup.isDownloading { return .working(setup.progress) }
        return .offer
    }

    var body: some View {
        let mode = self.mode
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                icon(for: mode)
                Text(title(for: mode))
                    .font(.title2.weight(.semibold))
                Text(message(for: mode))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(5)
            }
            .padding(.top, 26)
            .padding(.horizontal, 40)
            Spacer(minLength: 12)
            content(for: mode)
                .padding(.horizontal, 40)
            Spacer(minLength: 12)
            HStack(spacing: 12) {
                Spacer()
                buttons(for: mode)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
        }
        .frame(width: 460, height: 380)
    }

    // MARK: Pieces

    @ViewBuilder private func icon(for mode: Mode) -> some View {
        switch mode {
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 42))
                .foregroundStyle(Color.orange)
                .accessibilityHidden(true)
        case .offer, .working:
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 42))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
        }
    }

    private func title(for mode: Mode) -> String {
        switch mode {
        case .offer: "Download Fiji"
        case .working(let progress): progress.map { FijiText.phase($0.phase) + "…" } ?? "Starting the Download…"
        case .failed: "Fiji Couldn’t Be Downloaded"
        }
    }

    private func message(for mode: Mode) -> String {
        switch mode {
        case .offer:
            let why = setup.reason.map { $0 + " " } ?? ""
            return why + "Fiji is the image-processing engine behind ImageJ’s plugins and menus. Mancora downloads it once."
        case .working:
            return "Fiji keeps itself up to date after this. You can turn that off in Settings."
        case .failed(let message):
            return message
        }
    }

    @ViewBuilder private func content(for mode: Mode) -> some View {
        switch mode {
        case .offer:
            VStack(alignment: .leading, spacing: 12) {
                Fact(symbol: "arrow.down.circle", title: "About 700 MB, downloaded once", detail: "Java is included; there is nothing else to install.")
                Fact(symbol: "arrow.triangle.2.circlepath", title: "Fiji keeps itself up to date", detail: "Updates install in the background.")
                Fact(symbol: "puzzlepiece.extension", title: "Fiji’s menus join Mancora’s", detail: "Its plugins, scripts and tools appear in the menu bar.")
            }
        case .working(let progress):
            VStack(spacing: 8) {
                if let fraction = progress?.fractionCompleted {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
                HStack {
                    Text(progress.map { FijiText.phase($0.phase) } ?? "Starting")
                    Spacer()
                    if let progress, progress.phase == .downloading {
                        Text(Self.counts(progress))
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
        case .failed:
            EmptyView()
        }
    }

    /// `412 of 703 MB · 59%`.
    private static func counts(_ progress: FijiProgress) -> String {
        var text = FijiText.megabytes(done: progress.completedBytes, of: progress.totalBytes)
        if let fraction = progress.fractionCompleted { text += " · " + FijiText.percent(fraction) }
        return text
    }

    @ViewBuilder private func buttons(for mode: Mode) -> some View {
        switch mode {
        case .offer:
            Button("Cancel", role: .cancel) { setup.cancel() }
                .keyboardShortcut(.cancelAction)
            Button("Download Fiji") { setup.download() }
                .keyboardShortcut(.defaultAction)
        case .working:
            Button(setup.isCancelling ? "Stopping…" : "Cancel", role: .cancel) { setup.cancel() }
                .keyboardShortcut(.cancelAction)
                .disabled(setup.isCancelling)
        case .failed:
            Button("Cancel", role: .cancel) { setup.cancel() }
                .keyboardShortcut(.cancelAction)
            Button("Try Again") { setup.download() }
                .keyboardShortcut(.defaultAction)
        }
    }

    /// One line of what the download means: a symbol, a title, a line under it.
    private struct Fact: View {
        let symbol: String
        let title: String
        let detail: String

        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
    }
}
