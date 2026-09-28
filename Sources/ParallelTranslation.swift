import Foundation
import AppKit

enum ReserveContinuation {
    static func serviceHasPositiveQuota(_ snapshot: QuotaSnapshot, now: Date = Date()) -> Bool {
        guard snapshot.decision(reserve: 0, now: now) == .allowed else { return false }
        return [snapshot.bucket.primary, snapshot.bucket.secondary].compactMap { $0 }.allSatisfy { ($0.remaining ?? 0) > 0 }
    }
}

enum ParallelStopPriority {
    static func shouldReplace(_ current: TranslationFailure?, with incoming: TranslationFailure) -> Bool {
        priority(incoming) > priority(current)
    }

    private static func priority(_ failure: TranslationFailure?) -> Int {
        switch failure {
        case .quotaSafetyStop?: return 3
        case .quotaUnavailable?: return 2
        case .quota?, .quotaWithProgress?: return 1
        default: return 0
        }
    }
}

extension TranslatorModel {
    var requestedRunCap: Int {
        ConcurrencyPolicy.schedulingCeiling(quota: quota, override: runtimePreferences.concurrencyOverride)
    }
    func setActivePhase(_ phase: String?, for jobID: UUID) {
        guard activePhases[jobID] != phase else { return }
        activePhases[jobID] = phase
    }

    func recordParallelStop(_ failure: TranslationFailure) {
        // Already-running answers are still saved; only the strongest reason
        // controls whether the queue may resume automatically after they finish.
        if ParallelStopPriority.shouldReplace(parallelStop, with: failure) { parallelStop = failure }
    }

    func readSharedQuota(force: Bool) async throws -> QuotaSnapshot {
        if let quotaReadOverride { return try await quotaReadOverride() }
        return try await quotaService.read(force: force)
    }

    /// One main-actor admission section for EVERY draft and Sol request.
    /// The awaited service read is protected too; ten callers cannot all see an
    /// empty in-flight ledger and claim the same remaining allowance.
    func acquireRequest(jobID: UUID, controller: RequestControl) async throws {
        while true {
            if Task.isCancelled || state.manuallyPaused || controller.isCancelled { throw TranslationFailure.stopped }
            if let parallelStop { throw parallelStop }
            if let resume = state.resumeAt, resume > Date() {
                setActivePhase("Ожидание лимита до \(resume.formatted(date: .abbreviated, time: .shortened))", for: jobID)
                try await Task.sleep(nanoseconds: 200_000_000)
                continue
            }
            if admissionBusy {
                try await Task.sleep(nanoseconds: 100_000_000)
                continue
            }
            admissionBusy = true
            var ownsAdmission = true
            do {
                let generation = quotaGeneration
                let snapshot = try await readSharedQuota(force: quotaMustRefresh)
                if generation != quotaGeneration {
                    admissionBusy = false
                    ownsAdmission = false
                    quotaMustRefresh = true
                    continue // An answer finished during this read; fetch a post-completion snapshot.
                }
                quota = snapshot; quotaMustRefresh = false; quotaServiceFailures = 0
                guard !Task.isCancelled, !state.manuallyPaused, !controller.isCancelled else {
                    throw TranslationFailure.stopped
                }
                if let parallelStop { throw parallelStop }
                let requested = min(ConcurrencyPolicy.hardMaximum, max(1, runRequestedParallelism))
                switch snapshot.decision(reserve: state.settings.reserve) {
                case .unknown:
                    throw TranslationFailure.quotaUnavailable("Codex не предоставил достоверные окна лимита. Новые запросы не запускаются.")
                case .waiting(let reset):
                    showBudgetNotice("Остаток достиг резерва \(Int(state.settings.reserve))%. Уже выполняющиеся запросы ещё могут пересечь резерв; их ответы будут сохранены.", key: "reserve")
                    // Reserve gates admissions; it does not rewrite the user's chosen cap.
                    effectiveParallelism = requested
                    guard ReserveContinuation.serviceHasPositiveQuota(snapshot) else {
                        throw TranslationFailure.quotaUnavailable("Лимит неизвестен или исчерпан. Продолжение ниже резерва запрещено.")
                    }
                    guard reserveContinuationConfirmed || confirmReserveContinuation() else {
                        let delay = reset.map { max(0, $0.timeIntervalSinceNow) }
                            ?? QuotaRecovery.delay(snapshot: nil, reserve: state.settings.reserve, now: Date(), failureCount: max(1, quotaServiceFailures + 1))
                        state.resumeAt = Date().addingTimeInterval(delay)
                        try store.save(state)
                        throw TranslationFailure.quota
                    }
                    reserveContinuationConfirmed = true
                    effectiveParallelism = min(ConcurrencyPolicy.hardMaximum, max(1, runRequestedParallelism))
                    if requestsInFlight.count < effectiveParallelism {
                        requestsInFlight.insert(jobID); admissionBusy = false; ownsAdmission = false; return
                    }
                case .allowed:
                    let allowed = requested
                    effectiveParallelism = allowed
                    if [snapshot.bucket.primary, snapshot.bucket.secondary].compactMap({ $0 }).contains(where: { ($0.remaining ?? 100) <= state.settings.reserve + 5 }) {
                        showBudgetNotice("Остаток близок к резерву \(Int(state.settings.reserve))%. Выбранный предел не снижается; активные запросы могут пересечь резерв.", key: "near-reserve")
                    }
                    if requestsInFlight.count < allowed {
                        requestsInFlight.insert(jobID)
                        admissionBusy = false
                        ownsAdmission = false
                        return
                    }
                }
                admissionBusy = false
                ownsAdmission = false
                setActivePhase("Ожидает свободного места / запаса лимита", for: jobID)
                try await Task.sleep(nanoseconds: 200_000_000)
            } catch {
                if ownsAdmission { admissionBusy = false }
                if error is CancellationError || controller.isCancelled || state.manuallyPaused || Task.isCancelled {
                    throw TranslationFailure.stopped
                }
                if let known = error as? TranslationFailure { throw known }
                quotaServiceFailures += 1
                quota = nil; quotaMustRefresh = true
                let unavailable = TranslationFailure.quotaUnavailable(CodexQuotaProbe.diagnostic(error.localizedDescription))
                if quotaServiceFailures >= 3 {
                    recordParallelStop(unavailable)
                    throw unavailable
                }
                setActivePhase("Ожидание повторной проверки лимита", for: jobID)
                // The global admission is released, but no model is called on an unknown quota.
                let delay = QuotaRecovery.delay(snapshot: nil, reserve: state.settings.reserve, now: Date(), failureCount: quotaServiceFailures)
                state.resumeAt = Date().addingTimeInterval(delay)
                try store.save(state)
                recordParallelStop(unavailable)
                throw unavailable
            }
        }
    }

    func releaseRequest(jobID: UUID) {
        if requestsInFlight.remove(jobID) != nil {
            quotaGeneration += 1; quotaMustRefresh = true
        }
    }

    func showBudgetNotice(_ message: String, key: String) {
        guard key != lastBudgetNoticeKey else { return }
        lastBudgetNoticeKey = key
        budgetNotice = message
        banner = message
    }

    func confirmReserveContinuation() -> Bool {
        if let reserveConfirmationOverride { return reserveConfirmationOverride() }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.current("reserve.continue_title")
        alert.informativeText = L10n.current("reserve.continue_body")
        alert.addButton(withTitle: L10n.current("reserve.wait"))
        alert.addButton(withTitle: L10n.current("reserve.continue_run"))
        return alert.runModal() == .alertSecondButtonReturn
    }

    func runRequest(prompt: String, model: String, effort: String, root: URL,
                    controller: RequestControl, memory: Bool) async throws -> ModelResult {
        let fast = runFast
        if let requestRunOverride {
            return try await requestRunOverride(prompt, model, effort, root, controller, memory, fast)
        }
        return try await Task.detached {
            try CodexTranslationClient.run(prompt: prompt, model: model, effort: effort, root: root,
                                           control: controller, memoryOutput: memory, fast: fast)
        }.value
    }

    func startTranslation(automatic: Bool = false) {
        let activeJobs = state.jobs.filter { !$0.isArchivedRevision }
        guard writable, !busy, !closing, !activeJobs.isEmpty else { return }
        let settings = state.settings
        guard (0...1).contains(settings.maxRepairPasses), settings.maxReviewPassesPerPart == 1,
              (1...10).contains(settings.maxReviewCallsPerLecture),
              settings.reserve.isFinite, (0...99).contains(settings.reserve),
              ["spoken", "display"].contains(settings.outputStyle) else {
            error = "Некорректные настройки или предохранители расхода. Перевод не запускался."; return
        }
        state.manuallyPaused = false; state.translationPending = true
        do { try store.save(state) } catch { self.error = error.localizedDescription; return }
        cancelAutomaticResume()
        busy = true; translating = true; parallelStop = nil
        automaticExportConflicts = []
        requestControl = RequestControl(); requestControls = [:]; requestsInFlight = []
        admissionBusy = false; quotaMustRefresh = true; lastBudgetNoticeKey = nil; quotaServiceFailures = 0
        reserveContinuationConfirmed = false
        runFast = fastSession.isEnabled
        let jobs = activeJobs, profile = self.profile
        runRequestedParallelism = requestedRunCap
        work = Task {
            defer {
                busy = false; translating = false; activeJob = nil; phase = ""; work = nil
                activePhases = [:]; requestControls = [:]; requestsInFlight = []; loadSelection()
                // One conflict flow after all workers have finished; never one modal per worker.
                let conflicts = automaticExportConflicts
                automaticExportConflicts = []
                if !conflicts.isEmpty && !state.manuallyPaused && !closing && NSApp?.isRunning == true {
                    Task { @MainActor in self.saveTranslations(jobIDs: conflicts) }
                }
            }
            // Work-group lifetime includes all child tasks, so Pause/Close cannot
            // finish while a worker is still saving its answer.
            await withTaskGroup(of: Void.self) { group in
                var next = 0, running = 0
                while next < jobs.count || running > 0 {
                    runRequestedParallelism = requestedRunCap
                    while running < runRequestedParallelism && next < jobs.count &&
                          !state.manuallyPaused && parallelStop == nil && !Task.isCancelled {
                        let job = jobs[next]; next += 1; running += 1
                        group.addTask { @MainActor in
                            await self.translateJob(job, settings: settings, profile: profile, automatic: automatic)
                        }
                    }
                    guard running > 0 else { break }
                    _ = await group.next(); running -= 1
                }
            }
            for index in state.jobs.indices where state.jobs[index].status == .translating {
                state.jobs[index].status = .paused
            }
            if let failure = parallelStop {
                banner = failure.localizedDescription
                switch failure {
                case .quota, .quotaUnavailable:
                    state.translationPending = settings.autoResumeAfterLimits && !state.manuallyPaused
                    if state.translationPending == true {
                        state.resumeAt = state.resumeAt ?? Date().addingTimeInterval(
                            QuotaRecovery.delay(snapshot: nil, reserve: settings.reserve, now: Date(), failureCount: max(1, quotaServiceFailures)))
                        scheduleAutomaticResume(after: max(1, state.resumeAt!.timeIntervalSinceNow))
                    }
                case .quotaSafetyStop:
                    state.manuallyPaused = true; state.translationPending = false
                default:
                    state.translationPending = false
                }
            } else {
                state.translationPending = false; state.resumeAt = nil
                banner = state.manuallyPaused ? "Пауза. Все завершённые ответы сохранены."
                    : "Очередь обработана. Проверьте замечания; сомнительные места не скрыты."
            }
            save()
        }
    }

    func translateJob(_ job: JobSummary, settings: TranslationSettings, profile: TranslationProfile, automatic: Bool) async {
        guard !job.isArchivedRevision, let index = state.jobs.firstIndex(where: { $0.id == job.id }),
              !state.jobs[index].isArchivedRevision else { return }
        let controller = RequestControl()
        requestControls[job.id] = controller; setActivePhase("Подготовка", for: job.id)
        defer {
            releaseRequest(jobID: job.id)
            requestControls.removeValue(forKey: job.id); activePhases.removeValue(forKey: job.id)
        }
        do {
            let checkpointStore = store
            let prepared = try await Task.detached {
                let url = URL(fileURLWithPath: job.sourcePath)
                let sourceData = try Data(contentsOf: url)
                if let saved = try checkpointStore.loadPreparedIfCurrent(job.id, sourceData: sourceData, profile: profile, settings: settings) {
                    return saved
                }
                return try PreparedLecture.prepare(url: url, profile: profile, settings: settings)
            }.value
            var progress = try store.journal(job.id, lecture: prepared, migrateReviewBudget: true)
            try store.save(prepared, id: job.id)
            if progress.quotaPaused {
                if automatic { throw TranslationFailure.quotaSafetyStop }
                progress.resumeAfterQuotaPause(); try store.saveJournal(progress, id: job.id)
            }
            state.jobs[index].cueCount = prepared.document.cues.count
            state.jobs[index].partCount = prepared.parts.count
            state.jobs[index].sourceHash = prepared.document.sourceHash
            var complete = false
            while !complete && !state.manuallyPaused && !Task.isCancelled && parallelStop == nil {
                try TranslationPipeline.verifySource(job, lecture: prepared)
                let part: TranslationPart, reviewing: Bool
                switch TranslationPipeline.next(lecture: prepared, journal: progress) {
                case .planReviews(let ids):
                    progress.reviewPlan = ids
                    for id in ids {
                        guard let selected = prepared.parts.first(where: { $0.id == id }) else { continue }
                        var selectedProgress = progress.parts[id] ?? PartProgress()
                        if selectedProgress.reviewSelectionReason == nil {
                            selectedProgress.reviewSelectionReason = ReviewBatch.selectionReason(lecture: prepared, journal: progress, part: selected)
                        }
                        progress.parts[id] = selectedProgress
                    }
                    for candidate in prepared.parts where !ids.contains(candidate.id) && ReviewPlanning.score(candidate, lecture: prepared, journal: progress) > 0 {
                        progress.parts[candidate.id]?.reviewSkipped = true
                    }
                    try store.saveJournal(progress, id: job.id)
                    banner = "Перевод всех частей получен. Проверяю наиболее рискованные части: \(ids.map(String.init).joined(separator: ", "))."
                    continue
                case .complete:
                    try store.collectTerms(lecture: prepared, journal: progress, sourcePath: job.sourcePath)
                    state.jobs[index].completedCues = progress.translated.count
                    let issues = progress.issues(for: prepared)
                    let destination = TranslationPipeline.destination(source: URL(fileURLWithPath: job.sourcePath), settings: settings)
                    let protected = state.jobs.map { URL(fileURLWithPath: $0.sourcePath) }
                    guard SRTExport.shouldAutomaticallySave(issueCount: issues.count) else {
                        // Keep the completed paid result in the journal, but ask
                        // before exporting text with semantic or speech warnings.
                        state.jobs[index].status = .needsReview
                        state.jobs[index].message = "Перевод завершён, но в нём осталось \(issues.count) замечаний. Ничего не сохранено автоматически; используйте «Сохранить все готовые SRT…» и подтвердите экспорт с замечаниями, если он вам нужен."
                        try store.saveJournal(progress, id: job.id); try store.save(state)
                        complete = true; continue
                    }
                    do {
                        try SRTExport.validateDestination(destination, for: job.id, reservations: SRTExport.reservations(state: state, store: store))
                        try TranslationPipeline.verifySource(job, lecture: prepared)
                        let bytes = try TranslationPipeline.renderedData(lecture: prepared, journal: progress)
                        if try !SRTExport.matchingOutput(bytes: bytes, at: destination, protectedSources: protected) {
                            // Automatic export is create-only. Explicit replacement is a separate queue-wide UI flow.
                            try TranslationPipeline.verifySource(job, lecture: prepared)
                            try FilePublication.publish(bytes, to: destination, protectedSources: protected)
                        }
                        progress.exportedPath = destination.path
                        let saved = SRTExport.status(issueCount: issues.count, path: destination.path)
                        state.jobs[index].status = saved.0; state.jobs[index].message = saved.1
                    } catch {
                        state.jobs[index].status = issues.isEmpty ? .translated : .needsReview
                        state.jobs[index].message = "Перевод готов, но SRT ещё не сохранён. «Сохранить все готовые SRT…» позволит выбрать замену или другую папку. \(error.localizedDescription)"
                        if !automaticExportConflicts.contains(job.id) { automaticExportConflicts.append(job.id) }
                    }
                    try store.saveJournal(progress, id: job.id); try store.save(state)
                    complete = true; continue
                case .finalize(let value):
                    var record = progress.parts[value.id] ?? PartProgress(); record.done = true
                    progress.parts[value.id] = record; try store.saveJournal(progress, id: job.id)
                    try store.collectTerms(lecture: prepared, journal: progress, sourcePath: job.sourcePath); continue
                case .draft(let value): part = value; reviewing = false
                case .review(let value): part = value; reviewing = true
                }
                var record = progress.parts[part.id] ?? PartProgress()
                if reviewing && (progress.totalReviews >= settings.maxReviewCallsPerLecture || record.chargedReviewAttempts >= settings.maxReviewPassesPerPart) {
                    record.reviewSkipped = true; progress.parts[part.id] = record
                    try store.saveJournal(progress, id: job.id); continue
                }
                if !reviewing && record.chargedDraftAttempts >= 1 + settings.maxRepairPasses {
                    throw TranslationFailure.failed("Исчерпан предел попыток части \(part.id). Готовые части сохранены. \(record.failure ?? "")")
                }
                try await acquireRequest(jobID: job.id, controller: controller)
                defer { releaseRequest(jobID: job.id) }
                if Task.isCancelled || state.manuallyPaused { break }
                try TranslationPipeline.verifySource(job, lecture: prepared)
                let requestedPart = reviewing ? TranslationPipeline.reviewSelection(lecture: prepared, journal: progress, part: part) : part
                if reviewing {
                    record.reviewedIDs = requestedPart.cueIDs
                    if record.reviewSelectionReason == nil {
                        record.reviewSelectionReason = "Причина отбора не сохранена в старом журнале."
                    }
                }
                if reviewing { record.reviewAttempts += 1 } else { record.draftAttempts += 1 }
                progress.parts[part.id] = record
                try store.saveJournal(progress, id: job.id) // Persist attempt BEFORE incurring usage.
                state.jobs[index].status = .translating
                state.jobs[index].completedCues = progress.translated.count
                try store.save(state)
                setActivePhase("Часть \(part.id)/\(prepared.parts.count) · \(reviewing ? "Sol" : "перевод")", for: job.id)
                banner = "Готовые части сохраняются автоматически. Можно поставить паузу."
                loadSelection()
                let prompt = TranslationPipeline.prompt(lecture: prepared, journal: progress, part: part, review: reviewing)
                let modelName = reviewing ? settings.reviewModel : settings.model
                let effort = reviewing ? settings.reviewEffort : settings.effort
                let requestRoot = store.root.appendingPathComponent("requests")
                let memoryOutput = progress.memoryEnabled == true
                do {
                    let result = try await runRequest(prompt: prompt, model: modelName, effort: effort, root: requestRoot, controller: controller, memory: memoryOutput)
                    let rows = try result.reply.validated(ids: requestedPart.cueIDs)
                    guard rows.count == requestedPart.cueIDs.count else { throw TranslationFailure.failed("Неполный ответ.") }
                    try TranslationPipeline.verifySource(job, lecture: prepared)
                    if reviewing { record.review = result } else { record.draft = result }
                    record.failure = nil
                    progress.acceptServiceResult()
                    progress.parts[part.id] = record; try store.saveJournal(progress, id: job.id)
                    state.jobs[index].completedCues = progress.translated.count
                    try store.save(state); loadSelection()
                } catch {
                    record.failure = error.localizedDescription
                    progress.parts[part.id] = record
                    let quotaFailure: Bool, partialQuota: Bool
                    switch error {
                    case TranslationFailure.quota: quotaFailure = true; partialQuota = false
                    case TranslationFailure.quotaWithProgress: quotaFailure = true; partialQuota = true
                    default: quotaFailure = false; partialQuota = false
                    }
                    if quotaFailure {
                        progress.recordQuotaRefusal(partID: part.id, reviewing: reviewing, hasPartialResult: partialQuota)
                        try store.saveJournal(progress, id: job.id)
                        // Do not immediately repeat an expensive request; consult the service after a cooldown.
                        state.resumeAt = Date().addingTimeInterval(15 * 60); try store.save(state)
                        if progress.quotaPaused { throw TranslationFailure.quotaSafetyStop }
                        throw TranslationFailure.quota
                    }
                    try store.saveJournal(progress, id: job.id)
                    if state.manuallyPaused || Task.isCancelled { throw TranslationFailure.stopped }
                    if reviewing || record.chargedDraftAttempts < 1 + settings.maxRepairPasses { continue }
                    throw error
                }
            }

            if state.jobs[index].status == .translating { state.jobs[index].status = .paused }
        } catch {
            if state.manuallyPaused || Task.isCancelled || controller.isCancelled ||
               (error as? TranslationFailure).map({ if case .stopped = $0 { return true }; return false }) == true {
                state.jobs[index].status = .paused
            } else {
                state.jobs[index].status = .translationError
                state.jobs[index].message = error.localizedDescription
                if let failure = error as? TranslationFailure {
                    switch failure {
                    case .quota, .quotaSafetyStop, .quotaUnavailable:
                        recordParallelStop(failure)
                        state.jobs[index].status = .paused
                    default: break // A single bad source/translation must not abort other lectures.
                    }
                }
            }
            save()
        }
    }
}
