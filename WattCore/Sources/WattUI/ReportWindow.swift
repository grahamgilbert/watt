import SwiftData
import SwiftUI
import Textual
import UniformTypeIdentifiers
import WattAI
import WattAnalysis
import WattModels
import WattSampling

public struct ReportWindow: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \DrainEpisode.startedAt, order: .reverse) private var episodes: [DrainEpisode]
    @State private var selectedEpisodeID: PersistentIdentifier?

    let coordinator: SamplingCoordinator
    let progress: ReportProgress
    let onRecordNote: (String) -> Void
    let onRegenerate: (PersistentIdentifier) -> Void
    let onAdHocReport: (TimeInterval) -> Void

    public init(
        coordinator: SamplingCoordinator,
        progress: ReportProgress,
        onRecordNote: @escaping (String) -> Void,
        onRegenerate: @escaping (PersistentIdentifier) -> Void,
        onAdHocReport: @escaping (TimeInterval) -> Void = { _ in }
    ) {
        self.coordinator = coordinator
        self.progress = progress
        self.onRecordNote = onRecordNote
        self.onRegenerate = onRegenerate
        self.onAdHocReport = onAdHocReport
    }

    public var body: some View {
        NavigationSplitView {
            EpisodeListView(episodes: episodes, selection: $selectedEpisodeID)
                .frame(minWidth: 220)
        } detail: {
            VStack(spacing: 0) {
                LiveStatsHeader(coordinator: coordinator)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                ReportProgressBanner(progress: progress)
                if let id = selectedEpisodeID,
                   let episode = episodes.first(where: { $0.persistentModelID == id }) {
                    ReportDetailView(
                        episode: episode,
                        onRecordNote: onRecordNote,
                        onRegenerate: { onRegenerate(id) },
                        onAdHocReport: onAdHocReport
                    )
                } else {
                    VStack(spacing: 12) {
                        ContentUnavailableView(
                            "No episode selected",
                            systemImage: "battery.0",
                            description: Text("Drain episodes will appear here as Watt observes them.")
                        )
                        AdHocReportMenu(onAdHocReport: onAdHocReport)
                    }
                    .frame(maxHeight: .infinity)
                }
            }
        }
        .navigationTitle("Watt — Reports")
        .frame(minWidth: 920, minHeight: 620)
        .onAppear {
            if selectedEpisodeID == nil { selectedEpisodeID = episodes.first?.persistentModelID }
            coordinator.activateFastUpdates()
        }
        .onDisappear {
            coordinator.deactivateFastUpdates()
        }
        .onChange(of: progress.pendingSelection) { _, newValue in
            if let id = newValue {
                selectedEpisodeID = id
                progress.pendingSelection = nil
            }
        }
    }
}

/// Inline banner that surfaces "generating…" / "ready" / "failed" feedback.
/// Bound directly to `ReportProgress`; auto-hides when phase is `.idle`.
public struct ReportProgressBanner: View {
    let progress: ReportProgress

    public init(progress: ReportProgress) { self.progress = progress }

    public var body: some View {
        Group {
            switch progress.phase {
            case .idle:
                EmptyView()
            case .generating(let label):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(label)
                        .font(.caption)
                    Spacer()
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .background(Color.accentColor.opacity(0.12))
            case .finished(let label, _):
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(label).font(.caption)
                    Spacer()
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .background(Color.green.opacity(0.12))
            case .failed(let label, let message):
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(label).font(.caption).bold()
                        Text(message).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .background(Color.orange.opacity(0.12))
            }
        }
        .animation(.default, value: progress.phase)
    }
}

/// Compact live snapshot of the system right now. Updates every second while
/// the report window is open thanks to `activateFastUpdates()`.
public struct LiveStatsHeader: View {
    let coordinator: SamplingCoordinator

    public init(coordinator: SamplingCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        let s = coordinator.snapshot
        HStack(spacing: 16) {
            stat("Battery", batteryString(s))
            stat("Energy", energyString(s))
            stat("CPU", "\(Int((s.systemCPUUsage * 100).rounded()))%")
            stat("Memory", "\(Int(s.memoryPressurePct.rounded()))%")
            if s.maxFanRPM > 0 {
                stat("Fan", "\(Int(s.maxFanRPM.rounded())) RPM")
            }
            if let temp = s.hottestSensorCelsius, temp > 0 {
                stat("Temp", String(format: "%.1f°C", temp))
            }
            stat("Thermal", thermalLabel(s.thermalState))
            Spacer()
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).foregroundStyle(.secondary).font(.caption2)
            Text(value).fontWeight(.medium)
        }
    }

    private func batteryString(_ s: SamplingCoordinator.Snapshot) -> String {
        guard !s.batteryPercent.isNaN else { return "—" }
        return "\(Int(s.batteryPercent.rounded()))%\(s.isCharging ? " ⚡︎" : "")"
    }

    private func energyString(_ s: SamplingCoordinator.Snapshot) -> String {
        guard s.systemEnergyWatts > 0 else { return "—" }
        return s.systemEnergyWatts < 10
            ? String(format: "%.1f W", s.systemEnergyWatts)
            : "\(Int(s.systemEnergyWatts.rounded())) W"
    }

    private func thermalLabel(_ raw: Int) -> String {
        ["nominal", "fair", "serious", "critical"][min(max(raw, 0), 3)]
    }
}

public struct EpisodeListView: View {
    let episodes: [DrainEpisode]
    @Binding var selection: PersistentIdentifier?

    public var body: some View {
        List(selection: $selection) {
            ForEach(episodes) { episode in
                EpisodeRow(episode: episode)
                    .tag(episode.persistentModelID)
            }
        }
        .listStyle(.sidebar)
    }
}

public struct EpisodeRow: View {
    let episode: DrainEpisode

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(headline)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(2)
            HStack(spacing: 8) {
                Text(timestampLabel)
                    .foregroundStyle(.secondary)
                if episode.endedAt == nil {
                    Text("ongoing")
                        .foregroundStyle(.red)
                }
            }
            .font(.caption2)
        }
        .padding(.vertical, 2)
    }

    private var headline: String {
        let drain = Int(episode.drainPercent.rounded())
        let mins = Int((episode.duration / 60).rounded())
        return "−\(drain)% in \(mins) min"
    }

    private var timestampLabel: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: episode.startedAt)
    }
}

public struct ReportDetailView: View {
    let episode: DrainEpisode
    let onRecordNote: (String) -> Void
    let onRegenerate: () -> Void
    let onAdHocReport: (TimeInterval) -> Void
    @State private var noteText: String = ""
    @State private var showNoteSheet: Bool = false

    public init(
        episode: DrainEpisode,
        onRecordNote: @escaping (String) -> Void,
        onRegenerate: @escaping () -> Void,
        onAdHocReport: @escaping (TimeInterval) -> Void = { _ in }
    ) {
        self.episode = episode
        self.onRecordNote = onRecordNote
        self.onRegenerate = onRegenerate
        self.onAdHocReport = onAdHocReport
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let report = episode.reports.max(by: { $0.generatedAt < $1.generatedAt }) {
                    StructuredText(markdown: report.markdown)
                        .textual.structuredTextStyle(.gitHub)
                        .textual.textSelection(.enabled)
                } else {
                    ContentUnavailableView(
                        "No report yet",
                        systemImage: "doc.text",
                        description: Text("Click ‘Generate report’ to produce a Markdown summary for this episode.")
                    )
                    .frame(minHeight: 300)
                }
            }
            .padding(20)
        }
        .toolbar { toolbar }
        .sheet(isPresented: $showNoteSheet) {
            AddNoteSheet(text: $noteText) {
                if !noteText.isEmpty {
                    onRecordNote(noteText)
                    noteText = ""
                }
                showNoteSheet = false
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Episode \(episode.startedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.title3)
                .bold()
            Text("Drain \(Int(episode.drainPercent.rounded()))% over \(Int((episode.duration / 60).rounded())) min — peak \(Int(episode.peakDrainRatePctPerHour.rounded())) %/h")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                onRegenerate()
            } label: {
                Label("Regenerate", systemImage: "arrow.clockwise")
            }
            .help("Re-run the analysis and AI verdict for this episode. The previous report is kept in history.")

            Button {
                showNoteSheet = true
            } label: {
                Label("Add note", systemImage: "note.text.badge.plus")
            }
            .help("Annotate this point in time (e.g. ‘started a Zoom call’). The note appears in the timeline of any episode that includes this moment.")

            Button {
                copyToPasteboard()
            } label: {
                Label("Copy for Slack", systemImage: "doc.on.clipboard")
            }
            .disabled(latestReport == nil)
            .help("Copy the full Markdown report to the clipboard. Slack renders it natively.")

            Button {
                exportMarkdown()
            } label: {
                Label("Export .md", systemImage: "square.and.arrow.up")
            }
            .disabled(latestReport == nil)
            .help("Save the report to a .md file at a custom location.")

            Button {
                revealReportsDirectory()
            } label: {
                Label("Reports folder", systemImage: "folder")
            }
            .help("Reveal the on-disk Markdown mirror at ~/Library/Application Support/Watt/Reports/ in Finder.")

            Menu {
                Button("Last 15 minutes")  { onAdHocReport(15 * 60) }
                Button("Last 30 minutes")  { onAdHocReport(30 * 60) }
                Button("Last 60 minutes")  { onAdHocReport(60 * 60) }
                Button("Last 2 hours")     { onAdHocReport(2 * 3600) }
            } label: {
                Label("Investigate…", systemImage: "magnifyingglass")
            }
            .help("Generate a one-off report covering recent activity, even if Watt didn’t auto-flag a drain episode.")
        }
    }

    private func revealReportsDirectory() {
        if let url = try? WattStore.reportsDirectory() {
            NSWorkspace.shared.open(url)
        }
    }

    private var latestReport: Report? {
        episode.reports.max(by: { $0.generatedAt < $1.generatedAt })
    }

    private func copyToPasteboard() {
        guard let md = latestReport?.markdown else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(md, forType: .string)
    }

    private func exportMarkdown() {
        guard let md = latestReport?.markdown else { return }
        let panel = NSSavePanel()
        if let mdType = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [mdType]
        }
        panel.nameFieldStringValue = "watt-episode-\(Int(episode.startedAt.timeIntervalSince1970)).md"
        if panel.runModal() == .OK, let url = panel.url {
            try? md.data(using: .utf8)?.write(to: url)
        }
    }
}

/// Empty-state helper that lets the operator say "look back at the last 30
/// minutes" without an automatic episode being open.
public struct AdHocReportMenu: View {
    let onAdHocReport: (TimeInterval) -> Void

    public init(onAdHocReport: @escaping (TimeInterval) -> Void) {
        self.onAdHocReport = onAdHocReport
    }

    public var body: some View {
        VStack(spacing: 6) {
            Text("Or look back at recent activity")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("15 min")  { onAdHocReport(15 * 60) }
                Button("30 min")  { onAdHocReport(30 * 60) }
                Button("60 min")  { onAdHocReport(60 * 60) }
                Button("2 hours") { onAdHocReport(2 * 3600) }
            }
            .controlSize(.small)
        }
    }
}

public struct AddNoteSheet: View {
    @Binding var text: String
    let onSubmit: () -> Void

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a note")
                .font(.headline)
            Text("This will appear in the timeline of any current and future drain episode that includes this moment.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("e.g. ‘Started a Zoom call’", text: $text)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel", action: onSubmit).keyboardShortcut(.cancelAction)
                Button("Save", action: onSubmit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
