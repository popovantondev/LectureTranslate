import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class TranslatorModel: ObservableObject {
    private enum PreparationOutcome {
        case prepared(PreparedLecture)
        case timingMigration(SourceRevisionMigration.Candidate)
        case rejectedSourceChange(String)
    }
    @Published var state: ProjectState
    @Published var selection: UUID?
    @Published var lecture: PreparedLecture?
    @Published var busy = false
    @Published var quotaBusy = false
    @Published var quota: QuotaSnapshot?
    @Published var banner = L10n.current("welcome.initial_status")
    @Published var journal: TranslationJournal?
    @Published var translating = false
    @Published var phase = ""
    @Published var error: String?
    @Published var activeJob: String?
    @Published var finishedPreparation = 0
    @Published var preparationTotal = 0
    @Published var closing = false
    @Published var exporting = false
    @Published var exportReport: SRTExportReport?
    var exportCancelRequested = false
    var exportWarningsDecisionOverride: (() -> Bool)?
    var exportDidPublishOverride: (() -> Void)?
    var exportJournalSaveOverride: ((TranslationJournal, UUID, CheckpointStore) throws -> Void)?
    var automaticExportConflicts: [UUID] = []
    @Published var queueAccessProblem: QueueAccessProblem?
    @Published var locatingOwner = false
    @Published var otherInstance: ExistingTranslator?
    @Published var startupDetail = ""
    var work: Task<Void, Never>?
    private var automaticResumeTask: Task<Void, Never>?
    @Published var writable = true
    var requestControl = RequestControl()
    var requestControls: [UUID: RequestControl] = [:]
    let quotaService = SharedQuotaService()
    var quotaReadOverride: (() async throws -> QuotaSnapshot)?
    var reserveConfirmationOverride: (() -> Bool)?
    @Published var reserveContinuationConfirmed = false
    var requestRunOverride: ((String, String, String, URL, RequestControl, Bool, Bool) async throws -> ModelResult)?
    @Published var activePhases: [UUID: String] = [:]
    @Published var requestsInFlight: Set<UUID> = []
    @Published var effectiveParallelism = 0
    @Published var runtimePreferences = RuntimePreferences()
    @Published var fastSession = FastSessionState(preferences: RuntimePreferences())
    @Published var budgetNotice: String?
    @Published var showRuntimeSettings = false
    var parallelStop: TranslationFailure?
    var admissionBusy = false
    var quotaGeneration = 0
    var quotaServiceFailures = 0
    var quotaMustRefresh = true
    var runFast = false
    var runRequestedParallelism = 1
    var lastBudgetNoticeKey: String?
    var stateLock: TranslationStateLock?
    let store: CheckpointStore

    func diagnoseSelectedTiming() {
        guard !busy, let job = selectedJob else { return }
        let url = URL(fileURLWithPath: job.sourcePath)
        do {
            let data = try Data(contentsOf: url)
            let document = try SRTDocument.parse(data)
            let problems = SRTTimingRepair.diagnose(document.cues)
            guard !problems.isEmpty else {
                banner = L10n.current("timing.none")
                return
            }
            func stamp(_ ms: Int) -> String { String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000) }
            let details = problems.map { problem -> String in
                let cue = document.cues[problem.cueIndex]
                let previous = problem.cueIndex > 0 ? document.cues[problem.cueIndex - 1] : nil
                let next = document.cues.indices.contains(problem.cueIndex + 1) ? document.cues[problem.cueIndex + 1] : nil
                let candidate = problem.newEndMS.flatMap { newEnd in previous.map { prev in
                    "\n" + L10n.currentFormat("timing.suggestion", prev.id, stamp(prev.startMS), stamp(newEnd), cue.id, stamp(cue.startMS), stamp(cue.endMS))
                }} ?? "\n" + L10n.current("timing.no_suggestion")
                return L10n.currentFormat("timing.problem", problem.cueID, problem.kind.rawValue, previous?.id.description ?? "—", previous.map { stamp($0.startMS) + " → " + stamp($0.endMS) } ?? "—", cue.id, stamp(cue.startMS), stamp(cue.endMS), next?.id.description ?? "—", next.map { stamp($0.startMS) + " → " + stamp($0.endMS) } ?? "—", candidate)
            }.joined(separator: "\n\n")
            guard problems.count == 1, problems[0].newEndMS != nil else {
                let alert = NSAlert(); alert.messageText = L10n.currentFormat("timing.errors_title", problems.count); alert.informativeText = details + "\n\n" + L10n.current("timing.source_unchanged"); alert.alertStyle = .warning; alert.addButton(withTitle: L10n.current("common.close")); alert.runModal()
                return
            }
            let problem = problems[0]
            let repaired = try SRTTimingRepair.repairData(data, problem: problem)
            let alert = NSAlert(); alert.messageText = L10n.current("timing.confirm_title")
            alert.informativeText = details + "\n\n" + L10n.current("timing.confirm_body")
            alert.alertStyle = .warning; alert.addButton(withTitle: L10n.current("timing.repair_backup")); alert.addButton(withTitle: L10n.current("common.cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let backup = try SRTTimingRepair.replaceSource(url, with: repaired, expectedHash: document.sourceHash)
            if let index = state.jobs.firstIndex(where: { $0.id == job.id }) {
                state.jobs[index].status = .sourceChanged
                state.jobs[index].message = "Таймкод исправлен локально. Резерв: \(backup.lastPathComponent). Старые переводы сохранены, продолжение остановлено до явной повторной подготовки."
            }
            lecture = nil; journal = nil; save()
            banner = "Исходный SRT обновлён атомарно; резерв сохранён рядом. Проверьте результат и подготовьте источник заново."
        } catch {
            banner = "Диагностика/исправление таймкодов: \(error.localizedDescription)"
        }
    }

    init() {
        let base = TranslatorRuntime.stateDirectory()
        store = CheckpointStore(root: base)
        do {
            stateLock = try TranslationStateLock(root: base)
            #if TRANSLATOR_DEMO
            if !FileManager.default.fileExists(atPath: base.appendingPathComponent("queue.json").path) {
                try Self.seedSyntheticDemo(store: store, root: base)
            }
            #endif
            state = try store.load()
        }
        catch TranslationStateLockError.busy {
            state = ProjectState(); writable = false; queueAccessProblem = .inUse
        }
        catch {
            stateLock = nil // A reader that failed must not itself block recovery in another app.
            state = ProjectState(); writable = false; queueAccessProblem = .unreadable(error.localizedDescription)
        }
        selection = state.jobs.first?.id
        if writable { loadRuntimePreferences() }
        loadSelection()
        if state.manuallyPaused {
            let pause = "Сохранённая пауза. Нажмите «Продолжить перевод», когда будете готовы."
            banner = banner.isEmpty ? pause : "\(banner)\n\(pause)"
        }
        #if TRANSLATOR_DEMO
        quota = CodexQuotaProbe.demoSnapshot(); banner = L10n.current("demo.banner")
        #endif
    }

    #if TRANSLATOR_DEMO
    private static func seedSyntheticDemo(store: CheckpointStore, root: URL) throws {
        let fixtures = root.appendingPathComponent("SyntheticLectures", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        var state = ProjectState(); state.manuallyPaused = true; state.translationPending = false
        for number in 1...3 {
            let source = fixtures.appendingPathComponent("Демонстрация \(number).srt")
            let content = "1\n00:00:04,000 --> 00:00:08,000\nGuten Morgen.\n\n2\n00:00:09,000 --> 00:00:13,000\nDas ist ein Beispiel.\n"
            try Data(content.utf8).write(to: source, options: .atomic)
            let video = fixtures.appendingPathComponent("Демонстрация \(number).mp4")
            if !FileManager.default.fileExists(atPath: video.path) { try Data().write(to: video) }
            let lecture = try PreparedLecture.prepare(url: source, profile: .builtIns[0], settings: state.settings)
            var job = JobSummary(sourcePath: source.path)
            job.status = [JobStatus.needsReview, .translating, .queued][number - 1]
            job.sourceHash = lecture.document.sourceHash; job.cueCount = 2; job.completedCues = 2; job.partCount = 1
            var journal = TranslationJournal(sourceHash: lecture.document.sourceHash, settings: lecture.settings, profile: lecture.profile)
            let reply = TranslationReply(translations: [.init(id: 1, text: "Доброе утро."), .init(id: 2, text: "Это пример.")],
                issues: [.init(ids: [1], reason: "Искусственный пример замечания для проверки интерфейса.", critical: false)])
            let result = ModelResult(reply: reply, usage: nil, model: "synthetic-demo", effort: "medium", elapsed: 0)
            journal.parts[1] = .init(draftAttempts: 1, draft: result, done: true)
            try store.save(lecture, id: job.id); try store.saveJournal(journal, id: job.id)
            state.jobs.append(job)
        }
        try store.save(state)
    }
    #endif

    var profile: TranslationProfile { state.profiles.first { $0.id == state.settings.profileID } ?? state.profiles[0] }
    var selectedJob: JobSummary? { state.jobs.first { $0.id == selection } }
    var canPause: Bool { writable && (busy || (state.translationPending == true && !state.manuallyPaused)) }

    func save() {
        guard writable else { return }
        do { try store.save(state) } catch { self.error = "Не удалось сохранить очередь: \(error.localizedDescription)" }
    }

    func choose(folder: Bool) {
        let panel = NSOpenPanel()
        panel.title = L10n.current(folder ? "queue.choose_folder_title" : "queue.choose_files_title")
        panel.canChooseFiles = !folder; panel.canChooseDirectories = folder; panel.allowsMultipleSelection = true
        if !folder { panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText] }
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    func add(_ urls: [URL]) {
        guard writable, !busy, !closing else { return }
        busy = true
        let recursive = state.settings.includeSubfolders
        Task {
            let found = await Task.detached { SourceScanner.scan(urls, recursive: recursive) }.value
            var known = Set(state.jobs.map(\.sourcePath)), added = 0
            for url in found where known.insert(url.path).inserted {
                state.jobs.append(JobSummary(sourcePath: url.path)); added += 1
            }
            state.jobs.sort { $0.sourcePath.localizedStandardCompare($1.sourcePath) == .orderedAscending }
            selection = selection ?? state.jobs.first?.id
            banner = "Добавлено: \(added). Русские SRT, промежуточные части и повторно выбранные пути пропущены."
            save(); busy = false
        }
    }

    func prepare() {
        let activeJobs = state.jobs.filter { !$0.isArchivedRevision }
        guard writable, !busy, !closing, !activeJobs.isEmpty else { return }
        state.manuallyPaused = false; save(); busy = true
        finishedPreparation = 0; preparationTotal = activeJobs.count
        let jobs = activeJobs, profile = self.profile, settings = state.settings
        work = Task {
            defer { busy = false; activeJob = nil; loadSelection(); work = nil }
            for job in jobs {
                if Task.isCancelled || state.manuallyPaused { break }
                activeJob = job.title
                guard let index = state.jobs.firstIndex(where: { $0.id == job.id }) else { continue }
                do {
                    let url = URL(fileURLWithPath: job.sourcePath)
                    let checkpointStore = store
                    let outcome = try await Task.detached { () throws -> PreparationOutcome in
                        let sourceData = try Data(contentsOf: url)
                        let hash = SRTDocument.hash(sourceData)
                        if let old = try? checkpointStore.loadLecture(job.id), old.version == PreparedLecture.pipelineVersion {
                            if old.document.sourceHash == hash,
                               old.settings.translationCompatible(with: settings), old.profile == profile {
                                return .prepared(old)
                            }
                            if old.document.sourceHash != hash {
                                do {
                                    let oldJournal = try checkpointStore.journal(job.id, lecture: old)
                                    let candidate = try SourceRevisionMigration.make(oldLecture: old, oldJournal: oldJournal,
                                        sourceData: sourceData, profile: profile, settings: settings)
                                    return .timingMigration(candidate)
                                } catch {
                                    return .rejectedSourceChange(error.localizedDescription)
                                }
                            }
                        }
                        let prepared = try PreparedLecture.prepare(url: url, profile: profile, settings: settings)
                        _ = try checkpointStore.journal(job.id, lecture: prepared)
                        return .prepared(prepared)
                    }.value
                    if Task.isCancelled { break }
                    if case .timingMigration(let candidate) = outcome {
                        guard confirmTimingMigration(candidate, job: job) else {
                            state.jobs[index].status = .sourceChanged
                            state.jobs[index].message = "Таймкоды изменились; перенос не подтверждён. Старая ревизия и её перевод сохранены. Нажмите «Подготовить локально», чтобы снова увидеть предложение."
                            finishedPreparation += 1; save(); continue
                        }
                        do {
                            try persistTimingMigration(candidate, from: job, at: index)
                        } catch {
                            state.jobs[index].status = .sourceChanged
                            state.jobs[index].message = "Новая ревизия не сохранена; исходная и оплаченные результаты сохранены. \(error.localizedDescription)"
                            self.error = error.localizedDescription
                        }
                        finishedPreparation += 1; save(); continue
                    }
                    if case .rejectedSourceChange(let reason) = outcome {
                        state.jobs[index].status = .sourceChanged
                        state.jobs[index].message = reason
                        finishedPreparation += 1; save(); continue
                    }
                    guard case .prepared(let result) = outcome else { continue }
                    // Preserve a mismatched old checkpoint until an explicit future retranslation action.
                    if let old = try? store.loadLecture(job.id), !old.completedTranslations.isEmpty,
                       old.document.sourceHash != result.document.sourceHash || !old.settings.translationCompatible(with: result.settings) || old.profile != result.profile {
                        state.jobs[index].status = .sourceChanged
                        state.jobs[index].message = "Сохранённые переводы не перезаписаны: изменились исходник или настройки."
                    } else {
                        try store.save(result, id: job.id)
                        let savedProgress = try store.journal(job.id, lecture: result)
                        state.jobs[index].sourceHash = result.document.sourceHash
                        state.jobs[index].cueCount = result.document.cues.count
                        state.jobs[index].completedCues = savedProgress.translated.count
                        state.jobs[index].partCount = result.parts.count
                        let restored = TranslationPipeline.restoredStatus(lecture: result, journal: savedProgress)
                        state.jobs[index].status = restored.0
                        state.jobs[index].message = restored.1
                    }
                } catch {
                    if let old = try? store.loadLecture(job.id),
                       let currentHash = try? SRTDocument.hash(Data(contentsOf: URL(fileURLWithPath: job.sourcePath))),
                       old.document.sourceHash != currentHash {
                        state.jobs[index].status = .sourceChanged
                        state.jobs[index].message = "Исходный SRT изменился. Старая контрольная точка и завершённые переводы сохранены, но продолжение по ним заблокировано. Сверьте источник перед повторной подготовкой."
                    } else {
                        state.jobs[index].status = .invalid
                        state.jobs[index].message = error.localizedDescription
                    }
                }
                finishedPreparation += 1; save()
            }
            banner = state.manuallyPaused ? "Пауза. Подготовленные части сохранены на диске." : "Локальная подготовка завершена. Переводы не выполнялись."
        }
    }

    private func confirmTimingMigration(_ candidate: SourceRevisionMigration.Candidate, job: JobSummary) -> Bool {
        let previous = (try? store.loadLecture(job.id))?.document.cues ?? []
        let next = candidate.lecture.document.cues
        let rows = zip(previous, next).filter { pair in
            pair.0.startMS != pair.1.startMS || pair.0.endMS != pair.1.endMS || pair.0.timingLine != pair.1.timingLine
        }
        func stamp(_ ms: Int) -> String { String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000) }
        let details = rows.prefix(12).map { pair in
            let (old, new) = pair
            return "№ \(old.id): \(stamp(old.startMS)) → \(stamp(old.endMS))  →  \(stamp(new.startMS)) → \(stamp(new.endMS))"
        }.joined(separator: "\n")
        let more = rows.count > 12 ? "\n… и ещё \(rows.count - 12) изменённых реплик." : ""
        let alert = NSAlert()
        alert.messageText = L10n.current("timing.transfer_title")
        alert.informativeText = L10n.currentFormat("timing.transfer_body", candidate.lecture.document.cues.count, details, more, URL(fileURLWithPath: job.sourcePath).lastPathComponent)
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.current("timing.transfer_action"))
        alert.addButton(withTitle: L10n.current("common.cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func persistTimingMigration(_ candidate: SourceRevisionMigration.Candidate, from oldJob: JobSummary, at index: Int) throws {
        let sourceURL = URL(fileURLWithPath: oldJob.sourcePath)
        let current = try SRTDocument.parse(Data(contentsOf: sourceURL))
        guard current.sourceHash == candidate.lecture.document.sourceHash else {
            throw TranslatorError.invalid("Исходный SRT изменился после подтверждения. Ничего не перенесено.")
        }
        let oldState = state
        var newJob = JobSummary(sourcePath: oldJob.sourcePath)
        let newID = newJob.id
        guard !FileManager.default.fileExists(atPath: store.jobURL(newID).path),
              !FileManager.default.fileExists(atPath: store.journalURL(newID).path) else {
            throw TranslatorError.invalid("Не удалось выделить чистый ID для новой ревизии.")
        }
        do {
            try store.save(candidate.lecture, id: newID)
            do { try store.saveJournal(candidate.journal, id: newID) }
            catch { try? FileManager.default.removeItem(at: store.jobURL(newID)); throw error }
            state.jobs[index].archivedRevision = true
            state.jobs[index].status = .sourceChanged
            state.jobs[index].message = "Архивная ревизия. Готовые ответы относятся к прежним таймкодам; исходник и журнал сохранены без изменений."
            newJob.originalVideoPath = oldJob.originalVideoPath
            newJob.sourceHash = candidate.lecture.document.sourceHash
            newJob.cueCount = candidate.lecture.document.cues.count
            newJob.partCount = candidate.lecture.parts.count
            newJob.completedCues = candidate.journal.translated.count
            let restored = TranslationPipeline.restoredStatus(lecture: candidate.lecture, journal: candidate.journal)
            newJob.status = restored.0
            newJob.message = "Перевод перенесён без модельных запросов; времена обновлены. Экспортируйте SRT для новой ревизии. Исходная контрольная сумма: \(candidate.journal.translationOriginSourceHash ?? "не сохранена")."
            state.jobs.insert(newJob, at: index + 1)
            selection = newID
            try store.save(state)
        } catch {
            state = oldState
            try? FileManager.default.removeItem(at: store.jobURL(newID))
            try? FileManager.default.removeItem(at: store.journalURL(newID))
            throw error
        }
    }

    func pause(immediately: Bool) {
        cancelAutomaticResume()
        state.manuallyPaused = true; state.translationPending = false; state.resumeAt = nil; save()
        if exporting {
            exportCancelRequested = true
            banner = "Останавливаю сохранение после текущего файла. Уже записанные SRT и переводы останутся на месте."
            return
        }
        if immediately {
            work?.cancel(); requestControl.cancel()
            requestControls.values.forEach { $0.cancel() }
            Task { await quotaService.shutdown() }
        }
        banner = !busy ? "Пауза. Автоматическое продолжение отменено; готовые части сохранены."
            : immediately ? "Останавливаю активные запросы. Готовые части сохранены." : "Пауза после активных запросов. Полученные результаты будут сохранены."
    }

    func loadSelection() {
        guard let selection else { lecture = nil; journal = nil; return }
        lecture = try? store.loadLecture(selection)
        if let lecture { journal = try? store.journal(selection, lecture: lecture) } else { journal = nil }
    }

    func refreshQuota() {
        #if TRANSLATOR_DEMO
        quota = CodexQuotaProbe.demoSnapshot(); quotaBusy = false; return
        #else
        guard !quotaBusy else { return }
        quotaBusy = true
        Task {
            defer { quotaBusy = false }
            do { quota = try await readSharedQuota(force: true) }
            catch { quota = nil; self.error = error.localizedDescription }
        }
        #endif
    }

    func addProfile(name: String, subject: String, glossary: String) {
        let profile = TranslationProfile(id: UUID().uuidString, name: name.trimmingCharacters(in: .whitespacesAndNewlines), subject: subject, glossary: glossary)
        guard !profile.name.isEmpty else { return }
        state.profiles.append(profile); state.settings.profileID = profile.id; save()
    }

    func exportPrompt(_ text: String) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Пакет для теста моделей.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try text.write(to: url, atomically: true, encoding: .utf8) }
        catch { self.error = error.localizedDescription }
    }

    func restoreAutomaticRun() {
        guard !TranslatorRuntime.isDemoBuild else { return }
        if state.translationPending == true && !state.manuallyPaused && state.settings.autoResumeAfterLimits { startTranslation(automatic: true) }
    }

    func cancelAutomaticResume() {
        automaticResumeTask?.cancel(); automaticResumeTask = nil
    }

    func scheduleAutomaticResume(after seconds: Double = 300) {
        cancelAutomaticResume()
        automaticResumeTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) }
            catch { return }
            guard !Task.isCancelled, let self else { return }
            self.automaticResumeTask = nil
            self.restoreAutomaticRun()
        }
    }

    func shutdown() {
        exportCancelRequested = true
        VideoPreviewWindowController.closeIfOpen()
        cancelAutomaticResume(); requestControl.cancel()
        requestControls.values.forEach { $0.cancel() }
        Task { await quotaService.shutdown() }
    } // Durable journals remain; next launch checks quota and sources again.


    func editTranslation(jobID: UUID, cueID: Int, text: String, confirming issue: LocalIssue?, checked: Bool) -> Bool {
        guard writable, !busy, let job = selectedJob, job.id == jobID, !job.isArchivedRevision, let lecture else { return false }
        do {
            try TranslationPipeline.verifySource(job, lecture: lecture)
            var saved = try store.journal(job.id, lecture: lecture)
            try saved.edit(cueID: cueID, text: text, confirming: issue, sourceChecked: checked, lecture: lecture)
            try store.saveJournal(saved, id: job.id)
            if let index = state.jobs.firstIndex(where: { $0.id == job.id }) {
                let count = saved.issues(for: lecture).count
                state.jobs[index].status = count == 0 ? .translated : .needsReview
                state.jobs[index].message = count == 0 ? "Ручная проверка завершена. Сохраните SRT; замена прежнего файла требует подтверждения." : "Осталось замечаний: \(count). Исправление сохранено внутри программы; обновите SRT."
            }
            try store.save(state); loadSelection()
            banner = "Исправление сохранено локально. Модель не запускалась."
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
}

enum TranslatorTheme {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.24, green: 0.84, blue: 0.77, alpha: 1)
            : NSColor(srgbRed: 0.02, green: 0.43, blue: 0.46, alpha: 1)
    })
    static let wash = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.08, green: 0.12, blue: 0.13, alpha: 1)
            : NSColor(srgbRed: 0.96, green: 0.98, blue: 0.98, alpha: 1)
    })
}

private struct TranslatorMark: View {
    var size: CGFloat = 52
    var body: some View {
        Group {
            if let url = Bundle.main.url(forResource: "TranslatorIcon", withExtension: "png"), let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "globe").font(.system(size: size * 0.55)).foregroundStyle(TranslatorTheme.accent)
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct TranslatorContentView: View {
    private enum QueueGroup: String, CaseIterable {
        case ready, inProgress, waiting
        var title: String { L10n.current("queue.group.\(self)") }

        func includes(_ status: JobStatus) -> Bool {
            switch self {
            case .ready: return [.translated, .needsReview, .exported].contains(status)
            case .inProgress: return status == .translating
            case .waiting: return ![.translated, .needsReview, .exported, .translating].contains(status)
            }
        }
    }
    private struct TranscriptRow: Identifiable, Equatable {
        let cue: Cue
        let translation: String
        var id: Int { cue.id }
    }
    private struct EditTarget: Identifiable {
        let id = UUID()
        let jobID: UUID
        let cue: Cue
        let issue: LocalIssue?
    }
    @ObservedObject var model: TranslatorModel
    @State private var partNumber = 1
    @State private var profileSheet = false
    @State private var termsSheet = false
    @State private var profileName = ""
    @State private var profileSubject = ""
    @State private var profileGlossary = ""
    @State private var editTarget: EditTarget?
    @State private var editedText = ""
    @State private var sourceChecked = false

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    TranslatorMark()
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.current("app.subtitle")).font(.title3.bold())
                        Text(L10n.current("app.direction")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button(L10n.current("queue.add_files"), systemImage: "doc.badge.plus") { model.choose(folder: false) }
                    Button(L10n.current("queue.add_folder"), systemImage: "folder.badge.plus") { model.choose(folder: true) }
                }.disabled(model.busy)
                Toggle(L10n.current("queue.include_subfolders"), isOn: $model.state.settings.includeSubfolders).font(.caption).disabled(model.busy)
                HStack {
                    Text(L10n.current("queue.title").uppercased(with: L10n.currentLanguage.locale)).font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
                    Spacer()
                    Text(String(model.state.jobs.count)).font(.caption.monospacedDigit()).foregroundStyle(TranslatorTheme.accent)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(TranslatorTheme.accent.opacity(0.09), in: Capsule())
                }.padding(.top, 10)
                List(selection: $model.selection) {
                    ForEach(QueueGroup.allCases, id: \.self) { group in
                        let jobs = model.state.jobs.filter { group.includes($0.status) }
                        Section {
                        ForEach(jobs) { job in
                        DisclosureGroup {
                            ForEach(0..<job.partCount, id: \.self) { index in
                                Text(L10n.currentFormat("queue.part", index + 1) + (job.id == model.selection && model.journal?.parts[index + 1]?.done == true ? " · \(L10n.current("status.ready"))" : "")).font(.caption).foregroundStyle(.secondary)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(job.title).lineLimit(2)
                                Text(job.isArchivedRevision ? L10n.current("queue.archived_revision") :
                                     job.status == .exported ? L10n.current("queue.exported_status") : L10n.current("status.\(job.status.rawValue)"))
                                    .font(.caption).foregroundStyle(job.status == .invalid ? .red : .secondary).lineLimit(2)
                                if job.cueCount > 0 { Text(L10n.currentFormat("queue.progress", job.completedCues, job.cueCount, 100 * job.completedCues / job.cueCount, job.partCount)).font(.caption2).foregroundStyle(.secondary) }
                                if job.completedCues > 0 { ProgressView(value: Double(job.completedCues), total: Double(max(1, job.cueCount))) }
                            }.padding(.vertical, 4)
                        }.tag(job.id)
                    }
                    } header: {
                        HStack { Text(group.title); Spacer(); Text("\(jobs.count)").monospacedDigit().foregroundStyle(.secondary) }
                            .accessibilityElement(children: .combine)
                    }
                    }
                }.listStyle(.sidebar).scrollContentBackground(.hidden)
                HStack {
                    Text(L10n.currentFormat("queue.items_count", model.state.jobs.count)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.current("queue.remove"), systemImage: "minus.circle") {
                        guard let id = model.selection else { return }
                        model.state.jobs.removeAll { $0.id == id }
                        model.selection = model.state.jobs.first?.id
                        model.loadSelection(); model.save()
                    }.disabled(model.busy || model.selection == nil).help(L10n.current("queue.remove_help"))
                }
                Button(L10n.current("queue.clear"), systemImage: "trash") { model.confirmClearQueue() }
                    .disabled(model.busy || model.closing || model.state.jobs.isEmpty)
                HStack {
                    Button(L10n.current("project.open")) { model.openProject() }
                    Menu {
                        Button(L10n.current("project.save")) { _ = model.saveProject() }
                        Button(L10n.current("project.save_as")) { _ = model.saveProject(asNew: true) }
                    } label: { Text(L10n.current("project.save")) }
                }.disabled(model.busy || model.closing)
            }.padding().background(TranslatorTheme.accent.opacity(0.035)).navigationSplitViewColumnWidth(min: 300, ideal: 330, max: 420)
        } detail: {
            AdaptiveDetailPane {
              VStack(alignment: .leading, spacing: DetailPaneMetrics.sectionSpacing) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.current("page.heading")).font(.system(size: 25, weight: .bold, design: .rounded))
                        Label(L10n.current("page.subtitle"), systemImage: "checkmark.shield").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !TranslatorRuntime.isDemoBuild { quotaPanel.padding(.trailing, 16) }
                }
                settingsPanel
                HStack {
                    Button(L10n.current("action.prepare")) { model.prepare() }.disabled(model.busy || !model.state.jobs.contains(where: { !$0.isArchivedRevision }))
                    Button(L10n.current("action.timing_diagnostics")) { model.diagnoseSelectedTiming() }.disabled(model.busy || model.selectedJob == nil || model.selectedJob?.isArchivedRevision == true)
                    Button(L10n.current("action.pause")) { model.pause(immediately: false) }.disabled(!model.canPause)
                    Button(L10n.current("action.stop_now")) { model.pause(immediately: true) }.disabled(!model.canPause)
                    Spacer()
                    Button(L10n.current(model.state.jobs.contains(where: { $0.completedCues > 0 }) || model.state.manuallyPaused ? "action.resume_translation" : "action.start_translation")) { model.startTranslation() }
                        .buttonStyle(.borderedProminent).disabled(model.busy || model.closing || !model.state.jobs.contains(where: { !$0.isArchivedRevision }))
                        .help(L10n.current("action.start_help"))
                }
                HStack {
                    Button(L10n.currentFormat("action.save_translations_count", model.readyExportJobs.count), systemImage: "square.and.arrow.down.on.square") { model.saveAllTranslations() }
                        .disabled(model.busy || !model.writable || model.readyExportJobs.isEmpty)
                        .help(L10n.current("action.save_translations_help"))
                    Spacer()
                }
                if model.busy {
                    if model.translating {
                        ParallelProgressPanel(model: model)
                    } else {
                        ProgressView(value: Double(model.finishedPreparation), total: Double(max(1, model.preparationTotal)))
                        Text(model.activeJob.map { L10n.currentFormat(model.exporting ? "progress.saving" : "progress.preparing", $0) } ?? L10n.current("progress.reading_files")).font(.caption)
                    }
                }
                Label(model.banner, systemImage: model.busy ? "arrow.triangle.2.circlepath" : "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(TranslatorTheme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                if let lecture = model.lecture, let job = model.selectedJob {
                    HStack {
                        Text(job.title).font(.headline).textSelection(.enabled)
                        Spacer()
                        Button(L10n.current("action.show_srt")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: job.sourcePath)]) }
                        Button(L10n.current("action.save_this_srt")) { model.saveTranslation() }.disabled(model.busy || job.isArchivedRevision || !lecture.parts.allSatisfy { model.journal?.parts[$0.id]?.done == true })
                        if lecture.videoPaths.count == 1 {
                            Button(L10n.current("action.show_video")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: lecture.videoPaths[0])]) }
                        }
                    }
                    if lecture.videoPaths.count > 1 { Text(L10n.current("media.multiple_warning")).foregroundStyle(.orange) }
                    let shownMessage = L10n.jobMessage(key: job.messagePresentation?.key, arguments: job.messagePresentation?.arguments ?? [], legacy: job.message)
                    if !shownMessage.isEmpty { Text(shownMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    if let journal = model.journal {
                        let translated = lecture.document.cues.allSatisfy { journal.translated[$0.id] != nil }
                        let speechIssues = lecture.settings.outputStyle == "spoken"
                            ? journal.translated.flatMap { SpeechText.issues(text: $0.value, cueID: $0.key) } : []
                        let savedCurrent: Bool = {
                            guard let path = journal.exportedPath, let rendered = try? TranslationPipeline.renderedData(lecture: lecture, journal: journal),
                                  let existing = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return false }
                            return rendered == existing
                        }()
                        VStack(alignment: .leading, spacing: 3) {
                            Label(translated ? L10n.current("result.translated") : L10n.currentFormat("result.translated_count", journal.translated.count, lecture.document.cues.count), systemImage: translated ? "checkmark.circle" : "circle")
                            Label(savedCurrent ? L10n.current("result.saved") : L10n.current("result.unsaved"), systemImage: savedCurrent ? "checkmark.circle" : "circle")
                            Label(lecture.settings.outputStyle != "spoken" ? L10n.current("result.speech_not_applicable") : (speechIssues.isEmpty ? L10n.current("result.speech_passed") : L10n.currentFormat("result.speech_issues", speechIssues.count)), systemImage: lecture.settings.outputStyle != "spoken" || speechIssues.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
                                .foregroundStyle(lecture.settings.outputStyle == "spoken" && !speechIssues.isEmpty ? Color.orange : Color.secondary)
                        }.font(.caption)
                        if !speechIssues.isEmpty {
                            Text(speechIssues.map { "№ \($0.cueID) · \($0.reason)" }.joined(separator: "\n"))
                                .font(.caption2).foregroundStyle(.orange).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                        Text(journal.localizedUsageSummary(language: L10n.currentLanguage)).font(.caption2).foregroundStyle(.secondary)
                            .help(L10n.current("usage.help"))
                    }
                }
              }
            } panel: { availableHeight in
                if let lecture = model.lecture, let job = model.selectedJob {
                    TabView {
                        Table(lecture.document.cues.map { TranscriptRow(cue: $0, translation: model.journal?.translated[$0.id] ?? "—") }) {
                            TableColumn(L10n.current("table.number")) { Text(String($0.id)) }.width(45)
                            TableColumn(L10n.current("table.start")) { Text(readableTime($0.cue.startMS)) }.width(80)
                            TableColumn(L10n.current("table.seconds")) { Text(String(format: "%.2f", $0.cue.seconds)) }.width(65)
                            TableColumn(L10n.current("table.german_original")) { Text($0.cue.text).textSelection(.enabled).help($0.cue.text) }
                            TableColumn(L10n.current("table.russian_translation")) { Text($0.translation).textSelection(.enabled).help($0.translation) }
                            TableColumn("") { row in
                                Button { beginEdit(job: job, cue: row.cue, issue: nil) } label: { Image(systemName: "pencil") }
                                    .buttonStyle(.borderless).help(L10n.current("table.edit_help"))
                                    .disabled(!canEdit(lecture))
                            }.width(28)
                        }.id("\(job.id)-manual-\(model.journal?.manualHistory?.count ?? 0)")
                            .tabItem { Text(L10n.current("tab.transcript")) }
                        VStack(alignment: .leading) {
                            HStack {
                            Picker(L10n.current("table.part"), selection: $partNumber) {
                                    ForEach(lecture.parts) { part in Text("\(part.id) · \(readableTime(part.startMS))–\(readableTime(part.endMS))").tag(part.id) }
                                }.frame(maxWidth: 400)
                                Spacer()
                                Button(L10n.current("table.save_package")) { if let part = lecture.parts.first(where: { $0.id == partNumber }) { model.exportPrompt(displayPrompt(lecture, part)) } }
                            }
                            if let part = lecture.parts.first(where: { $0.id == partNumber }) {
                                if part.boundaryWarning { Text(L10n.current("review.boundary_warning")).foregroundStyle(.orange) }
                                ScrollView { Text(displayPrompt(lecture, part)).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }
                            }
                        }.padding(12).tabItem { Text(L10n.current("tab.model_package")) }
                        List {
                            let remaining = model.journal?.issues(for: lecture) ?? lecture.issues
                            let groups = IssueGroup.grouped(remaining, cues: lecture.document.cues)
                            if model.journal?.reviewStrategy == ReviewPlanning.strategy {
                                Text(L10n.currentFormat("review.plan_summary", model.journal?.reviewPlan.map { $0.map(String.init).joined(separator: ", ") } ?? L10n.current("review.plan_pending"))).font(.caption).foregroundStyle(.secondary)
                                if let journal = model.journal {
                                    let outcome = ReviewBatch.outcomes(lecture: lecture, journal: journal)
                                    Text(L10n.currentFormat("review.outcomes", outcome.candidates, outcome.reviewedUnchanged, outcome.changedByReview, outcome.unresolved, outcome.unreviewedDueToBudget)).font(.caption).foregroundStyle(.secondary)
                                    if let reviewPlan = journal.reviewPlan, !reviewPlan.isEmpty {
                                        Text(reviewPlan.map { id in
                                            L10n.currentFormat("review.part_reason", id, journal.parts[id]?.reviewSelectionReason ?? L10n.current("review.reason_missing"))
                                        }.joined(separator: "\n"))
                                        .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                            Text(L10n.current(model.journal == nil ? "review.risk_intro" : "review.notes_intro")).foregroundStyle(.secondary)
                            Text(L10n.currentFormat("review.group_counts", groups.count, remaining.count)).font(.caption).foregroundStyle(.secondary)
                            ForEach(groups) { group in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(group.issues[0].category).font(.caption.bold()).foregroundStyle(.secondary)
                                    Text(group.issues[0].reason).foregroundStyle(group.issues[0].critical ? .red : .primary)
                                    ForEach(group.issues) { issue in
                                    Text("№ \(issue.cueID) · \(lecture.document.cues.first(where: { $0.id == issue.cueID }).map { readableTime($0.startMS) } ?? "")").font(.caption.bold())
                                    Text("DE: \(lecture.document.cues.first(where: { $0.id == issue.cueID })?.text ?? "")").foregroundStyle(.secondary)
                                    Text("RU: \(model.journal?.translated[issue.cueID] ?? "—")")
                                    if let cue = lecture.document.cues.first(where: { $0.id == issue.cueID }) {
                                        Button(L10n.current("action.listen_original"), systemImage: "play.rectangle") { model.showOriginal(jobID: job.id, cue: cue) }
                                            .disabled(model.busy)
                                        Button(L10n.current("action.review_note")) { beginEdit(job: job, cue: cue, issue: issue) }
                                            .disabled(!canEdit(lecture))
                                    }
                                    }
                                }
                            }
                        }.textSelection(.enabled).tabItem { Text(L10n.currentFormat("tab.review_count", model.journal?.issues(for: lecture).count ?? lecture.issues.count)) }
                        LectureMemoryView(lecture: lecture, journal: model.journal).tabItem { Text(L10n.current("tab.memory")) }
                    }.frame(height: availableHeight)
                } else if let job = model.selectedJob, job.status == .invalid {
                    ContentUnavailableView(L10n.current("source.check_title"), systemImage: "exclamationmark.triangle", description: Text(L10n.jobMessage(key: job.messagePresentation?.key, arguments: job.messagePresentation?.arguments ?? [], legacy: job.message)))
                        .frame(minHeight: availableHeight)
                } else {
                    welcomePanel(minHeight: availableHeight)
                }
            }.frame(minWidth: 760, minHeight: 660).background(TranslatorTheme.wash)
        }
        .tint(TranslatorTheme.accent)
        .onChange(of: model.selection) { _, _ in model.loadSelection(); partNumber = 1 }
        .onChange(of: model.state.settings) { _, _ in model.save() }
        .alert(L10n.current("app.subtitle"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button(L10n.current("common.ok"), role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .overlay(alignment: .topTrailing) {
            if let notice = model.budgetNotice {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.shield").foregroundStyle(.orange)
                    Text(notice).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Button { model.budgetNotice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.padding(16).frame(maxWidth: 440).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .shadow(radius: 8).padding(24)
            }
        }
        .sheet(isPresented: $model.showRuntimeSettings) {
            RuntimeSettingsView(preferences: model.runtimePreferences, reserve: model.state.settings.reserve,
                                quota: model.quota, jobs: model.state.jobs.count,
                                onSave: { preferences, reserve in _ = model.applyRuntimeSettings(preferences, reserve: reserve) },
                                onCancel: { model.showRuntimeSettings = false })
        }
        .sheet(isPresented: $profileSheet) { profileEditor }
        .sheet(item: $model.exportReport) { report in
            SRTExportReportView(report: report) { model.exportReport = nil }
        }
        .sheet(isPresented: $termsSheet) { TermsView(store: model.store, profiles: model.state.profiles) }
        .sheet(item: $editTarget) { target in
            VStack(alignment: .leading, spacing: 14) {
                ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                Text(L10n.currentFormat("edit.cue_title", target.cue.id, readableTime(target.cue.startMS))).font(.title2.bold())
                if let issue = target.issue { Text(issue.reason).foregroundStyle(issue.critical ? .red : .orange).fixedSize(horizontal: false, vertical: true) }
                if let job = model.state.jobs.first(where: { $0.id == target.jobID }) {
                    Button(L10n.current("action.listen_open_video"), systemImage: "play.rectangle") {
                        model.showOriginal(jobID: job.id, cue: target.cue)
                    }
                }
                Text(L10n.current("table.german_original")).font(.headline)
                ScrollView { Text(target.cue.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 110)
                if let cues = model.lecture?.document.cues, let index = cues.firstIndex(where: { $0.id == target.cue.id }) {
                    DisclosureGroup("Соседние реплики для контекста") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(cues[max(0, index - 2)...min(cues.count - 1, index + 2)])) { cue in
                                    Text("№ \(cue.id) · DE: \(cue.text)\nRU: \(model.journal?.translated[cue.id] ?? "—")").font(.caption).textSelection(.enabled)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(height: 120)
                    }
                }
                Text(L10n.current("table.russian_translation")).font(.headline)
                TextEditor(text: $editedText).font(.body).frame(height: 100).border(.quaternary)
                if target.issue != nil {
                    if model.lecture?.settings.outputStyle == "spoken" && SpeechText.issues(text: model.journal?.translated[target.cue.id] ?? "", cueID: target.cue.id).contains(where: { $0 == target.issue }) {
                        Text(L10n.current("edit.spoken_help")).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Toggle(L10n.current("edit.source_checked"), isOn: $sourceChecked)
                        Text(L10n.current("edit.review_help")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(L10n.current("edit.footer")).font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button(L10n.current("common.cancel")) { editTarget = nil }
                    Spacer()
                    Button(L10n.current("edit.save")) {
                        if model.editTranslation(jobID: target.jobID, cueID: target.cue.id, text: editedText, confirming: sourceChecked ? target.issue : nil, checked: sourceChecked) { editTarget = nil }
                    }.buttonStyle(.borderedProminent).disabled(editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(24).frame(width: 700, height: min(760, (NSScreen.main?.visibleFrame.height ?? 900) - 100)).tint(TranslatorTheme.accent)
        }
        .task {
            model.refreshQuota()
            if !model.runtimePreferences.reserveConfigured { model.showRuntimeSettings = true }
            else { model.restoreAutomaticRun() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.shutdown() }
    }

    private func canEdit(_ lecture: PreparedLecture) -> Bool {
        !model.busy && lecture.parts.allSatisfy { model.journal?.parts[$0.id]?.done == true }
    }
    private func displayPrompt(_ lecture: PreparedLecture, _ part: TranslationPart) -> String {
        if let journal = model.journal { return TranslationPipeline.prompt(lecture: lecture, journal: journal, part: part, review: false) }
        return lecture.prompt(for: part)
    }
    private func beginEdit(job: JobSummary, cue: Cue, issue: LocalIssue?) {
        editedText = model.journal?.translated[cue.id] ?? ""
        sourceChecked = false
        editTarget = EditTarget(jobID: job.id, cue: cue, issue: issue)
    }

    private func welcomePanel(minHeight: CGFloat) -> some View {
        VStack(spacing: 14) {
            Spacer(minLength: 8)
            TranslatorMark(size: 92)
            Text(L10n.current(model.state.jobs.isEmpty ? "welcome.empty_title" : "welcome.select_title"))
                .font(.system(size: 23, weight: .semibold, design: .rounded))
            Text(L10n.current("welcome.description"))
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 22) {
                workflowStep("1", L10n.current("welcome.step_add_title"), L10n.current("welcome.step_add_detail"))
                workflowStep("2", L10n.current("welcome.step_translate_title"), L10n.current("welcome.step_translate_detail"))
                workflowStep("3", L10n.current("welcome.step_voice_title"), L10n.current("welcome.step_voice_detail"))
            }.padding(.top, 10)
            Spacer(minLength: 8)
            Label(L10n.current("welcome.safety"), systemImage: "lock.shield")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(maxWidth: .infinity, minHeight: minHeight, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(TranslatorTheme.accent.opacity(0.10)))
    }

    private func workflowStep(_ number: String, _ title: String, _ detail: String) -> some View {
        VStack(spacing: 6) {
            Text(number).font(.caption.bold()).foregroundStyle(TranslatorTheme.accent)
                .frame(width: 26, height: 26).background(TranslatorTheme.accent.opacity(0.10), in: Circle())
            Text(title).font(.callout.weight(.medium))
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L10n.current("settings.translation"), systemImage: "slider.horizontal.3").font(.callout.bold()).foregroundStyle(TranslatorTheme.accent)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Picker(L10n.current("settings.profile"), selection: $model.state.settings.profileID) {
                        ForEach(model.state.profiles) { Text($0.name).tag($0.id) }
                    }.frame(maxWidth: 350)
                    Button(L10n.current("settings.create_profile")) { profileSheet = true }
                    Button(L10n.current("settings.glossary")) { termsSheet = true }
                    Spacer()
                    Text(L10n.currentFormat("settings.reserve", Int(model.state.settings.reserve))).font(.callout.bold())
                }
                HStack {
                    Picker(L10n.current("settings.translation_model"), selection: $model.state.settings.model) {
                        Text("GPT-6 Luna").tag("gpt-6-luna")
                        Text("GPT-6 Sol").tag("gpt-6-sol")
                        Text("Terra").tag("gpt-5.6-terra")
                        Text("Luna").tag("gpt-5.6-luna")
                        Text("Sol").tag("gpt-5.6-sol")
                    }.disabled(model.state.jobs.contains { $0.completedCues > 0 })
                        .help(L10n.current("settings.model_help"))
                    Picker(L10n.current("settings.reasoning"), selection: $model.state.settings.effort) {
                        Text(L10n.current("settings.medium")).tag("medium"); Text(L10n.current("settings.high")).tag("high")
                    }.disabled(model.state.jobs.contains { $0.completedCues > 0 })
                    Text(L10n.current("settings.review_model")).foregroundStyle(.secondary)
                }
                HStack(spacing: 16) {
                    Picker(L10n.current("settings.srt_text"), selection: $model.state.settings.outputStyle) {
                        Text(L10n.current("settings.spoken_style")).tag("spoken")
                        Text(L10n.current("settings.display_style")).tag("display")
                    }.disabled(model.state.jobs.contains { $0.completedCues > 0 })
                        .help(L10n.current("settings.style_help"))
                    Picker(L10n.current("settings.save_location"), selection: Binding(get: { model.state.settings.outputLocation ?? "source" }, set: { location in
                        if location == "custom" { model.chooseOutputFolder() }
                        else { model.state.settings.outputLocation = location }
                    })) {
                        Text(L10n.current("settings.next_to_srt")).tag("source")
                        Text(L10n.current("settings.downloads")).tag("downloads")
                        Text(L10n.current("settings.other_folder")).tag("custom")
                    }
                }.font(.callout)
                if model.state.settings.outputLocation == "custom" {
                    Button(model.state.settings.customOutputDirectory ?? L10n.current("settings.other_folder"), systemImage: "folder") { model.chooseOutputFolder() }
                        .font(.caption).lineLimit(1).truncationMode(.middle)
                }
                Text(L10n.current(model.state.settings.outputStyle == "spoken" ? "settings.spoken_help" : "settings.display_help"))
                    .font(.caption).foregroundStyle(model.state.settings.outputStyle == "spoken" ? Color.secondary : Color.orange)
                Divider()
                HStack {
                    Toggle(L10n.current("settings.auto_resume"), isOn: $model.state.settings.autoResumeAfterLimits)
                    Stepper(L10n.currentFormat("settings.sol_reviews", model.state.settings.maxReviewCallsPerLecture), value: $model.state.settings.maxReviewCallsPerLecture, in: 1...10)
                }.font(.caption)
                Divider()
                ParallelRuntimePanel(model: model)
            }
        }.padding(16)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(TranslatorTheme.accent.opacity(0.12)))
            .disabled(model.busy || model.closing)
    }

    private var quotaPanel: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
        VStack(alignment: .trailing, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                quotaWindows(horizontal: true)
                quotaWindows(horizontal: false)
            }
            if let quota = model.quota {
                let checkedAt = quota.checkedAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(L10n.currentLanguage.locale))
                Text(L10n.currentFormat("quota.checked_at", checkedAt)).font(.caption2).foregroundStyle(.secondary)
                switch quota.decision(reserve: model.state.settings.reserve, now: timeline.date) {
                case .allowed: Text(L10n.current("quota.above_reserve")).font(.caption).foregroundStyle(.green)
                case .unknown: Text(L10n.current("quota.refresh_needed")).font(.caption).foregroundStyle(.orange)
                case .waiting(let date): Text(date.map { L10n.currentFormat("quota.check_after", $0.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.currentLanguage.locale))) } ?? L10n.current("quota.waiting")).font(.caption).foregroundStyle(.orange)
                }
            } else { Text(L10n.current(model.quotaBusy ? "quota.checking" : "quota.no_fresh_data")).font(.caption2).foregroundStyle(.secondary) }
        }
        }
    }

    @ViewBuilder private func quotaWindows(horizontal: Bool) -> some View {
        if horizontal {
            HStack(alignment: .top, spacing: 12) { quotaContents }
        } else {
            VStack(alignment: .trailing, spacing: 6) { quotaContents }
        }
    }

    @ViewBuilder private var quotaContents: some View {
        if model.quota?.weeklyOnly != true { quotaWindow(L10n.current("quota.five_hours"), model.quota?.fiveHours) }
        quotaWindow(L10n.current("quota.week"), model.quota?.weekly)
        Button { model.refreshQuota() } label: { Image(systemName: "arrow.clockwise") }
            .accessibilityLabel(L10n.current("quota.refresh"))
            .disabled(model.quotaBusy).help(L10n.current("quota.refresh_help"))
    }

    private func quotaWindow(_ title: String, _ window: LimitWindow?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(window?.remaining.map { L10n.currentFormat("quota.remaining", Int($0)) } ?? "—").font(.callout.bold()).monospacedDigit()
            if let remaining = window?.remaining {
                ProgressView(value: remaining, total: 100).tint(remaining <= model.state.settings.reserve ? .orange : TranslatorTheme.accent).frame(width: 110)
            }
            if let time = window?.resetsAt {
                let resetAt = Date(timeIntervalSince1970: time).formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.currentLanguage.locale))
                Text(resetAt).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var profileEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.current("profile.new_title")).font(.title2.bold())
            TextField("Название, например «Минералы»", text: $profileName)
            TextField("Предмет лекций", text: $profileSubject)
            Text(L10n.current("profile.terms_help")).font(.caption)
            TextEditor(text: $profileGlossary).font(.system(.body, design: .monospaced)).frame(height: 150).border(.quaternary)
            Text(L10n.current("profile.accuracy_help")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(L10n.current("common.cancel")) { profileSheet = false }
                Spacer()
                Button(L10n.current("profile.create")) {
                    model.addProfile(name: profileName, subject: profileSubject, glossary: profileGlossary)
                    profileName = ""; profileSubject = ""; profileGlossary = ""; profileSheet = false
                }.disabled(profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || profileSubject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 520)
    }
}

#if !TRANSLATOR_MODEL_TESTS
@main
#endif
struct LectureTranslatorApp: App {
    @NSApplicationDelegateAdaptor(TranslatorAppDelegate.self) private var delegate
    @StateObject private var model = TranslatorApplicationSession.model
    @AppStorage("translatorAppearance") private var appearance = "system"
    // A missing preference is the first launch: start in German. AppStorage keeps
    // later choices local to this Mac and outside project files/translation data.
    @AppStorage("translatorLanguage") private var selectedLanguage = "de"

    init() {
        #if TRANSLATOR_DEMO
        // These command-line overrides exist only in the synthetic GUI-test
        // binary. They make the screenshot matrix independent of Accessibility
        // permissions and never ship in the production target.
        let arguments = CommandLine.arguments
        func argument(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        if let language = argument("--demo-language"), ["de", "ru", "en"].contains(language) {
            UserDefaults.standard.set(language, forKey: "translatorLanguage")
        }
        if let appearance = argument("--demo-appearance"), ["light", "dark"].contains(appearance) {
            UserDefaults.standard.set(appearance, forKey: "translatorAppearance")
        }
        #endif
        // Set the app-specific preferred language before SwiftUI builds AppKit's
        // standard menu titles. A changed in-app choice is picked up next launch.
        _ = UILanguage.configureSystemLanguageAtLaunch()
    }

    var body: some Scene {
        Window(TranslatorRuntime.isDemoBuild ? "LectureTranslate · Demo" : "LectureTranslate · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")", id: "main") {
            Group {
                if model.writable { TranslatorContentView(model: model) }
                else { QueueAccessView(model: model) }
            }
                .background(WindowCloseBridge(delegate: delegate))
                .onAppear { delegate.model = model; applyAppearance(); applyDemoWindowSize() }
                .onChange(of: appearance) { _, _ in applyAppearance() }
                .environment(\.locale, UILanguage.activeLanguage(atLaunch: L10n.currentLanguage, selectedPreference: selectedLanguage).locale)
        }
            .defaultSize(width: 1180, height: 800)
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button(L10n.current("menu.settings")) { model.showRuntimeSettings = true }.keyboardShortcut(",")
                        .disabled(!model.writable || model.busy || model.closing)
                }
                CommandGroup(after: .newItem) {
                    Button(L10n.current("project.open")) { model.openProject() }.keyboardShortcut("o")
                        .disabled(!model.writable || model.busy || model.closing)
                    Button(L10n.current("project.save")) { _ = model.saveProject() }.keyboardShortcut("s")
                        .disabled(!model.writable || model.busy || model.closing)
                    Button(L10n.current("project.save_as")) { _ = model.saveProject(asNew: true) }.keyboardShortcut("s", modifiers: [.command, .shift])
                        .disabled(!model.writable || model.busy || model.closing)
                }
                CommandMenu(L10n.current("menu.appearance")) {
                    Picker(L10n.current("menu.theme"), selection: $appearance) {
                        Text(L10n.current("menu.system_appearance")).tag("system")
                        Text(L10n.current("menu.light")).tag("light")
                        Text(L10n.current("menu.dark")).tag("dark")
                    }
                }
                CommandMenu(L10n.current("menu.language")) {
                    Picker(L10n.current("menu.language"), selection: $selectedLanguage) {
                        Text(L10n.current("menu.lang_de")).tag("de")
                        Text(L10n.current("menu.lang_en")).tag("en")
                        Text(L10n.current("menu.lang_ru")).tag("ru")
                    }
                }
                CommandGroup(replacing: .help) {
                    Button(L10n.current("menu.help")) {
                        NSWorkspace.shared.open(URL(string: "https://github.com")!)
                    }
                }
            }
    }

    private func applyDemoWindowSize() {
        #if TRANSLATOR_DEMO
        let arguments = CommandLine.arguments
        func integerArgument(_ name: String) -> Int? {
            guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
            return Int(arguments[index + 1])
        }
        guard let width = integerArgument("--demo-width"), let height = integerArgument("--demo-height"),
              (800...2200).contains(width), (600...1400).contains(height) else { return }
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { $0.title == "LectureTranslate · Demo" }) else { return }
            var frame = window.frame
            if let screen = window.screen?.visibleFrame {
                frame.size = NSSize(width: min(CGFloat(width), screen.width), height: min(CGFloat(height), screen.height))
                frame.origin.x = min(max(screen.minX, frame.origin.x), screen.maxX - frame.width)
                frame.origin.y = min(max(screen.minY, frame.origin.y), screen.maxY - frame.height)
            } else {
                frame.size = NSSize(width: width, height: height)
            }
            window.setFrame(frame, display: true)
        }
        #endif
    }

    private func applyAppearance() {
        // AppKit resets to the live system appearance when nil; SwiftUI's nil
        // preferredColorScheme can leave child controls in the previous theme.
        NSApp.appearance = appearance == "dark" ? NSAppearance(named: .darkAqua)
            : appearance == "light" ? NSAppearance(named: .aqua) : nil
    }

}
