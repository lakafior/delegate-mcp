import AppKit
import DelegateCore
import SwiftUI

/// Zadania w tle wszystkich sesji serwera (`jobs/*.json`): co trwa, co się skończyło, na jakiej gałęzi jest wynik.
struct JobsView: View {
    let model: AppModel
    @State private var filter = Filter.all
    @State private var expanded: Set<String> = []

    enum Filter: Hashable { case all, running, finished }

    private var shown: [JobStore.Stored] {
        model.jobs.filter { stored in
            switch filter {
            case .all: true
            case .running: stored.isActive
            case .finished: !stored.isActive
            }
        }
    }

    var body: some View {
        Group {
            if model.jobs.isEmpty {
                ContentUnavailableView("No jobs", systemImage: "list.bullet.rectangle",
                                       description: Text("Background tasks and agent jobs will appear here. Jobs are kept for 7 days."))
            } else {
                List {
                    ForEach(shown) { stored in
                        JobRow(stored: stored, isExpanded: Binding(
                            get: { expanded.contains(stored.id) },
                            set: { if $0 { expanded.insert(stored.id) } else { expanded.remove(stored.id) } }))
                            .contextMenu {
                                Button("Copy job ID", systemImage: "doc.on.doc") { copy(stored.id) }
                                if !stored.isActive {
                                    Button("Remove from list", systemImage: "trash") { model.removeJob(stored.id) }
                                }
                            }
                    }
                }
            }
        }
        .navigationTitle("Jobs")
        .toolbar {
            ToolbarItem {
                Picker("Show", selection: $filter) {
                    Text("All").tag(Filter.all)
                    Text("Running").tag(Filter.running)
                    Text("Finished").tag(Filter.finished)
                }
                .pickerStyle(.segmented)
            }
            ToolbarItem {
                Button("Clear finished", systemImage: "trash") { model.clearFinishedJobs() }
                    .help("Remove finished and interrupted jobs from the list. Agent branches stay in the repository.")
                    .disabled(!model.jobs.contains { !$0.isActive })
            }
        }
        // Serwer zapisuje zadania w innym procesie; przy otwartym widoku odświeżamy częściej niż timer modelu.
        .task {
            while !Task.isCancelled {
                model.refreshJobs()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

private struct JobRow: View {
    let stored: JobStore.Stored
    @Binding var isExpanded: Bool

    private var job: DelegateJobs.Job { stored.job }
    private var details: DelegateJobs.Details? { job.details }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                if let branch = details?.branch { BranchActions(branch: branch, repo: details?.repo) }
                if let text = resultText {
                    ScrollView {
                        Text(text)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 320)
                    .padding(8)
                    .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
                } else if stored.interrupted {
                    Text("The server restarted while this job ran, so it has no result. Start it again.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Still running. The result appears here when it finishes.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                statusIcon.frame(width: 16)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let branch = details?.branch {
                        Label(branch, systemImage: "arrow.triangle.branch")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    duration
                        .font(.callout.monospacedDigit())
                    Text(job.started, format: .dateTime.day().month(.abbreviated).hour().minute())
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// Etykieta bez prefiksu agenta, który i tak jest w podtytule.
    private var title: String {
        guard let agent = details?.agent, let colon = job.label.firstIndex(of: ":"),
              job.label.hasPrefix(agent) else { return job.label }
        return String(job.label[job.label.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let agent = details?.agent {
            parts.append(agent + (details?.model.map { " · \($0)" } ?? ""))
            parts.append(details?.write == true ? "write" : "read")
        } else if let details {
            // Zapisy sprzed zakładki Jobs nie mają szczegółów; nie zgadujemy, czym były.
            parts.append(details.model ?? "model (auto)")
        }
        if let repo = details?.repo { parts.append((repo as NSString).lastPathComponent) }
        parts.append(job.id)
        return parts.joined(separator: " · ")
    }

    private var resultText: String? {
        switch job.state {
        case .running: nil
        case .done(let text), .failed(let text): text
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch job.state {
        case .running where stored.interrupted:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help("Interrupted")
        case .running:
            ProgressView().controlSize(.small).help("Running")
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Done")
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red).help("Failed")
        }
    }

    @ViewBuilder
    private var duration: some View {
        if let finished = job.finished {
            Text(Duration.seconds(finished.timeIntervalSince(job.started)),
                 format: .units(allowed: [.hours, .minutes, .seconds], width: .narrow))
        } else if stored.interrupted {
            Text("interrupted").foregroundStyle(.orange)
        } else {
            Text(job.started, style: .timer)
        }
    }
}

/// Polecenia do przejrzenia, scalenia albo odrzucenia gałęzi agenta (do skopiowania; apka niczego w repo nie zmienia).
private struct BranchActions: View {
    let branch: String
    let repo: String?

    var body: some View {
        HStack(spacing: 8) {
            Button("Copy review command", systemImage: "doc.on.doc") { copy(command("git diff HEAD...\(branch)")) }
            Button("Copy merge command", systemImage: "arrow.triangle.merge") { copy(command("git merge --squash \(branch)")) }
            Button("Copy discard command", systemImage: "trash") { copy(command("git branch -D \(branch)")) }
            if let repo {
                Button("Show repository", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: repo)])
                }
            }
        }
        .controlSize(.small)
    }

    private func command(_ git: String) -> String {
        guard let repo else { return git }
        return "cd \(shellQuoted(repo)) && \(git)"
    }

    private func shellQuoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

extension JobStore.Stored {
    /// Trwa naprawdę: zapisane jako trwające, a serwer, który je prowadzi, żyje.
    var isActive: Bool {
        if case .running = job.state { !interrupted } else { false }
    }
}
