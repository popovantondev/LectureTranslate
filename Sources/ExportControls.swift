import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SRTExportReport: Identifiable {
    let id = UUID()
    struct Row: Identifiable {
        let id = UUID()
        let title: String
        let path: String?
        let message: String
        let saved: Bool
        let issues: Int
        var backup: URL? = nil
        var sourcePath: String? = nil
        var outcome: Outcome = .failed
    }
    enum Outcome { case written, skipped, inProject, failed }
    var rows: [Row] = []
    var cancelled = false
    var savedCount: Int { rows.filter(\.saved).count }
    var summary: String {
        L10n.currentFormat("export.summary", rows.filter { $0.outcome == .written }.count, rows.filter { $0.outcome == .skipped }.count, rows.filter { $0.outcome == .inProject }.count, rows.filter { $0.outcome == .failed }.count) + (cancelled ? L10n.current("export.stopped") : "")
    }
}

private enum ExportConflictChoice { case replace, skip, folder(URL), cancel }
private enum BatchNameCollisionChoice { case separate, keep(UUID), cancel }

@MainActor
extension TranslatorModel {
    var readyExportJobs: [JobSummary] {
        state.jobs.filter { !$0.isArchivedRevision && [.translated, .needsReview, .exported].contains($0.status) && $0.completedCues > 0 }
    }

    func saveAllTranslations() { saveTranslations(jobIDs: readyExportJobs.map(\.id)) }

    func saveTranslation() {
        guard let selectedJob, !selectedJob.isArchivedRevision else { return }
        saveTranslations(jobIDs: [selectedJob.id], chooseSingleDestination: true)
    }

    func saveTranslations(jobIDs: [UUID], chooseSingleDestination: Bool = false) {
        guard writable, !busy, !closing else { return }
        let jobs = state.jobs.filter { jobIDs.contains($0.id) && !$0.isArchivedRevision }
        guard !jobs.isEmpty else { return }
        let settings = state.settings, checkpointStore = store
        let queueSnapshot = state
        let protected = state.jobs.map { URL(fileURLWithPath: $0.sourcePath) }
        busy = true; exporting = true; exportCancelRequested = false
        preparationTotal = jobs.count; finishedPreparation = 0
        banner = L10n.current("export.preparing")
        work = Task {
            defer { busy = false; exporting = false; activeJob = nil; work = nil; loadSelection() }
            var report = SRTExportReport(), candidates: [SRTExportCandidate] = []
            var reportedJobIDs = Set<UUID>()
            let reservations = await Task.detached { SRTExport.reservations(state: queueSnapshot, store: checkpointStore) }.value
            for job in jobs {
                if Task.isCancelled || exportCancelRequested { report.cancelled = true; break }
                activeJob = job.title
                do {
                    let candidate = try await Task.detached { try SRTExport.prepare(job: job, settings: settings, store: checkpointStore) }.value
                    candidates.append(candidate)
                } catch {
                    report.rows.append(.init(title: job.title, path: nil, message: L10n.errorPresentation(error), saved: false, issues: 0,
                                             sourcePath: job.sourcePath, outcome: .failed))
                    reportedJobIDs.insert(job.id)
                }
                finishedPreparation += 1
            }
            let warned = candidates.filter { $0.issueCount > 0 }
            if !warned.isEmpty {
                if let decision = exportWarningsDecisionOverride {
                    if !decision() { report.cancelled = true }
                } else {
                    let alert = NSAlert()
                    alert.messageText = L10n.current("export.warnings_title")
                    alert.informativeText = warned.map {
                        L10n.currentFormat("export.warning_row", $0.job.title, $0.issueCount) + ($0.speechIssueCount > 0 ? ", " + L10n.currentFormat("export.warning_speech", $0.speechIssueCount) : "")
                    }.joined(separator: "\n") + "\n\n" + L10n.current("export.warning_limit")
                    alert.addButton(withTitle: L10n.current("export.save_with_notes"))
                    alert.addButton(withTitle: L10n.current("export.cancel"))
                    if alert.runModal() != .alertFirstButtonReturn { report.cancelled = true }
                }
            }
            if report.cancelled {
                for candidate in candidates where !reportedJobIDs.contains(candidate.job.id) {
                    report.rows.append(.init(title: candidate.job.title, path: nil, message: L10n.current("export.cancelled_kept"), saved: false, issues: candidate.issueCount, sourcePath: candidate.job.sourcePath, outcome: .inProject))
                    reportedJobIDs.insert(candidate.job.id)
                }
            }
            // Resolve every duplicate target before publishing any file. A cancelled
            // chooser therefore cannot leave a half-written collision group.
            var destinations: [UUID: URL] = [:]
            var keptInProject = Set<UUID>()
            for group in SRTExport.collisions(candidates) {
                guard !report.cancelled, !Task.isCancelled, !exportCancelRequested else { report.cancelled = true; break }
                switch chooseBatchNameCollision(group) {
                case .cancel: report.cancelled = true
                case .keep(let id):
                    do {
                        let resolution = try SRTExport.resolve(group, decision: .keep(id))
                        keptInProject.formUnion(resolution.keptInProject)
                    } catch { report.cancelled = true }
                case .separate:
                    var selected: [UUID: URL] = [:]
                    for candidate in group.candidates {
                        guard let destination = chooseSeparateCollisionDestination(candidate) else { report.cancelled = true; break }
                        let key = SRTExport.key(destination)
                        guard selected.values.allSatisfy({ SRTExport.key($0) != key }) else {
                            banner = L10n.current("export.distinct_paths")
                            report.cancelled = true; break
                        }
                        selected[candidate.job.id] = destination
                    }
                    if !report.cancelled {
                        do {
                            let resolution = try SRTExport.resolve(group, decision: .separate(selected))
                            destinations.merge(resolution.destinations) { _, new in new }
                        } catch { report.cancelled = true }
                    }
                }
            }
            var exportReservations = reservations
            if !keptInProject.isEmpty {
                for path in Array(exportReservations.keys) {
                    exportReservations[path]?.removeAll { keptInProject.contains($0.jobID) }
                }
            }
            var singleDestination: URL?
            if chooseSingleDestination, let candidate = candidates.first, !report.cancelled {
                let panel = NSSavePanel()
                panel.title = L10n.current("export.single_title")
                panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
                panel.directoryURL = candidate.destination.deletingLastPathComponent()
                panel.nameFieldStringValue = candidate.destination.lastPathComponent
                panel.message = L10n.current("export.single_message")
                if panel.runModal() == .OK { singleDestination = panel.url }
                else { report.cancelled = true }
            }
            var sharedChoice: ExportConflictChoice?
            var outputFolder: URL?
            var occupiedTargets = Set<String>()
            for candidate in candidates {
                if report.cancelled || Task.isCancelled || exportCancelRequested { report.cancelled = true; break }
                activeJob = candidate.job.title
                if keptInProject.contains(candidate.job.id) {
                    report.rows.append(.init(title: candidate.job.title, path: nil,
                        message: L10n.current("export.kept_in_project"), saved: false, issues: candidate.issueCount, sourcePath: candidate.job.sourcePath, outcome: .inProject))
                    reportedJobIDs.insert(candidate.job.id); continue
                }
                var destination = singleDestination ?? destinations[candidate.job.id] ?? outputFolder?.appendingPathComponent(candidate.destination.lastPathComponent) ?? candidate.destination
                var completed = false
                while !completed && !report.cancelled {
                    do {
                        try SRTExport.validateDestination(destination, for: candidate.job.id, reservations: exportReservations)
                        let canonical = SRTExport.key(destination)
                        guard !occupiedTargets.contains(canonical) else {
                            throw TranslatorError.invalid(L10n.current("export.duplicate_target"))
                        }
                        let inspectedDestination = destination
                        let existing = try await Task.detached { try FilePublication.inspect(inspectedDestination, protectedSources: protected) }.value
                        var replacement: FilePublication.Existing?
                        var alreadyMatches = false
                        if existing != nil {
                            alreadyMatches = try await Task.detached { try SRTExport.matchingOutput(bytes: candidate.bytes, at: inspectedDestination, protectedSources: protected) }.value
                        }
                        if let existing, !alreadyMatches {
                            let chosen: ExportConflictChoice
                            if let sharedChoice { chosen = sharedChoice }
                            else {
                                let answer = chooseExportConflict(destination: destination, count: candidates.count)
                                chosen = answer.0
                                if answer.1 { sharedChoice = chosen }
                            }
                            switch chosen {
                            case .cancel: report.cancelled = true; continue
                            case .skip:
                                report.rows.append(.init(title: candidate.job.title, path: destination.path,
                                                         message: L10n.current("export.skipped_existing"), saved: false, issues: candidate.issueCount, sourcePath: candidate.job.sourcePath, outcome: .skipped))
                                completed = true; continue
                            case .folder(let directory):
                                let newDestination = directory.appendingPathComponent(candidate.destination.lastPathComponent)
                                guard newDestination.standardizedFileURL != destination.standardizedFileURL else {
                                    sharedChoice = nil
                                    throw TranslatorError.invalid(L10n.current("export.same_folder"))
                                }
                                if sharedChoice != nil { outputFolder = directory }
                                destination = newDestination
                                // A different folder can contain files too; never silently consent to replace them.
                                sharedChoice = nil; continue
                            case .replace: replacement = existing
                            }
                        }
                        var backup: URL?
                        if !alreadyMatches {
                            let target = destination, permission = replacement
                            backup = try await Task.detached {
                                try SRTExport.publish(candidate, to: target, store: checkpointStore,
                                                      replacing: permission, protectedSources: protected)
                            }.value
                        } else {
                            try TranslationPipeline.verifySource(candidate.job, lecture: candidate.lecture)
                        }
                        occupiedTargets.insert(canonical)
                        var saved = candidate.journal; saved.exportedPath = destination.path
                        // Publish each checkpoint before advancing; stopping never repeats a model call.
                        do {
                            if let override = exportJournalSaveOverride { try override(saved, candidate.job.id, checkpointStore) }
                            else { try checkpointStore.saveJournal(saved, id: candidate.job.id) }
                        }
                        catch {
                            report.rows.append(.init(title: candidate.job.title, path: destination.path,
                                                     message: L10n.currentFormat("export.journal_warning", L10n.errorPresentation(error)),
                                                     saved: true, issues: candidate.issueCount, backup: backup, sourcePath: candidate.job.sourcePath, outcome: .written))
                            completed = true; continue
                        }
                        if let index = state.jobs.firstIndex(where: { $0.id == candidate.job.id }) {
                            let status = SRTExport.status(issueCount: candidate.issueCount, path: destination.path)
                            state.jobs[index].status = status.0; state.jobs[index].message = status.1
                        }
                        var queueWarning = ""
                        do { try checkpointStore.save(state) }
                        catch { queueWarning = L10n.currentFormat("export.queue_warning", L10n.errorPresentation(error)) }
                        report.rows.append(.init(title: candidate.job.title, path: destination.path,
                                                 message: (alreadyMatches ? L10n.current("export.already_current") : L10n.current("export.saved")) + queueWarning,
                                                 saved: true, issues: candidate.issueCount, backup: backup, sourcePath: candidate.job.sourcePath, outcome: .written))
                        exportDidPublishOverride?()
                        completed = true
                    } catch {
                        report.rows.append(.init(title: candidate.job.title, path: destination.path, message: L10n.errorPresentation(error),
                                                 saved: false, issues: candidate.issueCount, sourcePath: candidate.job.sourcePath, outcome: .failed))
                        completed = true
                    }
                }
                if completed { reportedJobIDs.insert(candidate.job.id) }
            }
            if report.cancelled {
                for job in jobs where !reportedJobIDs.contains(job.id) {
                    report.rows.append(.init(title: job.title, path: nil, message: L10n.current("export.stopped_in_project"), saved: false, issues: 0, sourcePath: job.sourcePath, outcome: .inProject))
                }
            }
            banner = report.summary + L10n.current("export.report_kept_in_app")
            if !closing { exportReport = report }
        }
    }

    private func chooseBatchNameCollision(_ group: SRTExport.CollisionGroup) -> BatchNameCollisionChoice {
        let alert = NSAlert()
        alert.messageText = L10n.current("export.collision_title")
        alert.informativeText = L10n.currentFormat("export.collision_body", group.candidates.map { "\($0.job.title)\n\($0.job.sourcePath)" }.joined(separator: "\n\n"))
        let selection = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 440, height: 28), pullsDown: false)
        selection.addItem(withTitle: L10n.current("export.separate"))
        for candidate in group.candidates { selection.addItem(withTitle: L10n.currentFormat("export.keep", candidate.job.title)) }
        alert.accessoryView = selection
        alert.addButton(withTitle: L10n.current("common.continue"))
        alert.addButton(withTitle: L10n.current("export.cancel_batch"))
        guard alert.runModal() == .alertFirstButtonReturn else { return .cancel }
        let index = selection.indexOfSelectedItem
        guard index > 0, group.candidates.indices.contains(index - 1) else { return .separate }
        return .keep(group.candidates[index - 1].job.id)
    }

    private func chooseSeparateCollisionDestination(_ candidate: SRTExportCandidate) -> URL? {
        let panel = NSSavePanel()
        panel.title = L10n.currentFormat("export.separate_title", candidate.job.title)
        panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
        panel.directoryURL = candidate.destination.deletingLastPathComponent()
        panel.nameFieldStringValue = candidate.destination.lastPathComponent
        panel.message = L10n.current("export.separate_message")
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func chooseExportConflict(destination: URL, count: Int) -> (ExportConflictChoice, Bool) {
        let alert = NSAlert()
        alert.messageText = L10n.current("export.exists_title")
        alert.informativeText = L10n.currentFormat("export.exists_body", destination.path)
        alert.addButton(withTitle: L10n.current("export.skip"))
        alert.addButton(withTitle: L10n.current("export.replace"))
        alert.addButton(withTitle: L10n.current("export.other_folder"))
        alert.addButton(withTitle: L10n.current("export.cancel_save"))
        let all = NSButton(checkboxWithTitle: L10n.current("export.apply_all"), target: nil, action: nil)
        all.state = .on; all.isEnabled = count > 1; all.setFrameSize(NSSize(width: 380, height: 26))
        alert.accessoryView = all
        switch alert.runModal() {
        case .alertFirstButtonReturn: return (.skip, all.state == .on)
        case .alertSecondButtonReturn: return (.replace, all.state == .on)
        case .alertThirdButtonReturn:
            let panel = NSOpenPanel(); panel.title = L10n.current("export.folder_title")
            panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
            panel.directoryURL = destination.deletingLastPathComponent()
            if panel.runModal() == .OK, let url = panel.url { return (.folder(url), all.state == .on) }
            return (.cancel, false)
        default: return (.cancel, false)
        }
    }

    func showOriginal(jobID: UUID, cue: Cue) {
        guard let job = state.jobs.first(where: { $0.id == jobID }) else { return }
        VideoPreviewWindowController.show(sourceSRT: URL(fileURLWithPath: job.sourcePath),
                                          preferredVideo: job.originalVideoPath.map { URL(fileURLWithPath: $0) }, cue: cue) { [weak self] url in
            guard let self, self.writable, !self.busy, let index = self.state.jobs.firstIndex(where: { $0.id == jobID }) else { return }
            self.state.jobs[index].originalVideoPath = url.path; self.save()
        }
    }
}

struct SRTExportReportView: View {
    let report: SRTExportReport
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.current("export.report_title")).font(.title2.bold())
            Text(report.summary)
            Text(L10n.current("export.report_note"))
                .font(.callout).foregroundStyle(.secondary)
            List(report.rows) { row in
                VStack(alignment: .leading, spacing: 5) {
                    Label(row.title, systemImage: row.saved ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(row.saved ? Color.primary : Color.orange)
                    Text(row.message).font(.caption)
                    if let source = row.sourcePath { Text(L10n.currentFormat("export.source", source)).font(.caption).textSelection(.enabled) }
                    if row.issues > 0 { Text(L10n.currentFormat("export.issues_left", row.issues)).font(.caption).foregroundStyle(.orange) }
                    if let path = row.path {
                        Text(path).font(.caption).textSelection(.enabled)
                        if row.saved {
                            Button(L10n.current("export.find_srt")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                        }
                    }
                    if let backup = row.backup {
                        Button(L10n.current("export.find_backup")) { NSWorkspace.shared.activateFileViewerSelecting([backup]) }.font(.caption)
                    }
                }.padding(.vertical, 5)
            }
            HStack { Spacer(); Button(L10n.current("export.done"), action: close).keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 720, height: 520)
    }
}
