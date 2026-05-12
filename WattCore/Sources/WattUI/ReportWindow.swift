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
    let onRecordNote: (String) -> Void
    let onRegenerate: (PersistentIdentifier) -> Void

    public init(
        coordinator: SamplingCoordinator,
        onRecordNote: @escaping (String) -> Void,
        onRegenerate: @escaping (PersistentIdentifier) -> Void
    ) {
        self.coordinator = coordinator
        self.onRecordNote = onRecordNote
        self.onRegenerate = onRegenerate
    }

    public var body: some View {
        NavigationSplitView {
            EpisodeListView(episodes: episodes, selection: $selectedEpisodeID)
                .frame(minWidth: 220)
        } detail: {
            if let id = selectedEpisodeID, let episode = episodes.first(where: { $0.persistentModelID == id }) {
                ReportDetailView(
                    episode: episode,
                    onRecordNote: onRecordNote,
                    onRegenerate: { onRegenerate(id) }
                )
            } else {
                ContentUnavailableView(
                    "No episode selected",
                    systemImage: "battery.0",
                    description: Text("Drain episodes will appear here as Watt observes them.")
                )
            }
        }
        .navigationTitle("Watt — Reports")
        .frame(minWidth: 920, minHeight: 620)
        .onAppear {
            if selectedEpisodeID == nil { selectedEpisodeID = episodes.first?.persistentModelID }
        }
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
    @State private var noteText: String = ""
    @State private var showNoteSheet: Bool = false

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
            Button {
                showNoteSheet = true
            } label: {
                Label("Add note", systemImage: "note.text.badge.plus")
            }
            Button {
                copyToPasteboard()
            } label: {
                Label("Copy for Slack", systemImage: "doc.on.clipboard")
            }
            .disabled(latestReport == nil)
            Button {
                exportMarkdown()
            } label: {
                Label("Export .md", systemImage: "square.and.arrow.up")
            }
            .disabled(latestReport == nil)
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
