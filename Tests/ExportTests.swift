import Foundation

@main enum ExportTests {
    static var passed = 0
    static func check(_ value: Bool, _ label: String) {
        guard value else { fputs("FAIL: \(label)\n", stderr); exit(1) }
        passed += 1
    }
    static func rejects(_ label: String, _ body: () throws -> Void) {
        do { try body(); fputs("FAIL: \(label) accepted\n", stderr); exit(1) }
        catch { passed += 1 }
    }
    @MainActor static func finish(_ model: TranslatorModel) async throws {
        let deadline = Date().addingTimeInterval(20)
        while model.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        check(!model.busy, "local export finishes")
    }
    @MainActor static func main() async throws {
        check(SRTExport.shouldAutomaticallySave(issueCount: 0), "warning-free translation may be saved automatically")
        check(!SRTExport.shouldAutomaticallySave(issueCount: 1), "translation with warnings requires explicit export choice")
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("LectureExportTests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) } // Only this test-owned directory.
        let stateRoot = root.appendingPathComponent("state")
        setenv("LECTURE_TRANSLATOR_STATE_DIR", stateRoot.path, 1)
        let model = TranslatorModel()
        defer { model.shutdown(); unsetenv("LECTURE_TRANSLATOR_STATE_DIR") }
        var modelCalls = 0, quotaCalls = 0
        var warningPrompts = 0
        model.exportWarningsDecisionOverride = { warningPrompts += 1; return true }
        model.requestRunOverride = { _, _, _, _, _, _, _ in modelCalls += 1; throw TranslatorError.invalid("No network in export tests") }
        model.quotaReadOverride = { quotaCalls += 1; throw TranslatorError.invalid("No quota in export tests") }
        var sourceBytes: [String: Data] = [:]
        for index in 1...3 {
            let source = root.appendingPathComponent("Лекция \(index).de.srt")
            let bytes = Data("41\n00:00:03,200 --> 00:00:08,400\nGuten Morgen.\n\n92\n00:00:09,000 --> 00:00:15,000\nDas ist ein Beispiel.\n".utf8)
            try bytes.write(to: source); sourceBytes[source.path] = bytes
            let lecture = try PreparedLecture.prepare(url: source, profile: model.profile, settings: model.state.settings)
            var job = JobSummary(sourcePath: source.path)
            job.sourceHash = lecture.document.sourceHash; job.status = .needsReview
            job.cueCount = 2; job.completedCues = 2; job.partCount = 1
            var journal = TranslationJournal(sourceHash: lecture.document.sourceHash, settings: lecture.settings, profile: lecture.profile)
            let reply = TranslationReply(translations: [.init(id: 41, text: "Доброе утро."), .init(id: 92, text: "Это пример.")],
                                         issues: [.init(ids: [92], reason: "Искусственное замечание для проверки сохранения", critical: true)])
            let result = ModelResult(reply: reply, usage: nil, model: "gpt-5.6-terra", effort: "medium", elapsed: 1)
            journal.parts[1] = .init(draftAttempts: 1, draft: result, done: true)
            try model.store.save(lecture, id: job.id); try model.store.saveJournal(journal, id: job.id)
            model.state.jobs.append(job)
        }
        try model.store.save(model.state)
        model.selection = model.state.jobs.first!.id; model.loadSelection()
        check(model.readyExportJobs.count == 3, "all three reviewed-needed translations can be exported")
        let originalJournals = try model.state.jobs.map { try Data(contentsOf: model.store.journalURL($0.id)) }

        // Completed translations with warnings remain in the project until the user explicitly exports them.
        model.startTranslation()
        try await finish(model)
        check(modelCalls == 0 && quotaCalls == 0, "exporting existing paid results invokes neither model nor quota")
        for job in model.state.jobs {
            let candidate = try SRTExport.prepare(job: job, settings: model.state.settings, store: model.store)
            check(candidate.destination.lastPathComponent == job.title.replacingOccurrences(of: ".de.srt", with: ".ru.srt"), "canonical ru.srt name")
            check(!fm.fileExists(atPath: candidate.destination.path), "automatic completion does not export a translation with warnings")
            check(job.status == .needsReview && candidate.issueCount > 0, "warning-bearing translation remains visibly flagged before export")
            check(candidate.journal.exportedPath == nil, "warning-bearing result is not marked saved before explicit export")
            let parsed = try SRTDocument.parse(candidate.bytes)
            check(parsed.cues.map(\.timingLine) == candidate.lecture.document.cues.map(\.timingLine), "exact original timestamps")
            check(parsed.cues.map(\.id) == [41, 92], "original nonsequential IDs")
            check(try Data(contentsOf: URL(fileURLWithPath: job.sourcePath)) == sourceBytes[job.sourcePath], "original source unchanged")
            check(!fm.fileExists(atPath: candidate.destination.deletingPathExtension().path + ".review.srt"), "no review suffix file")
        }

        // User's one-button bulk flow explicitly confirms exporting all warning-bearing results.
        model.saveAllTranslations()
        try await finish(model)
        check(model.exportReport?.savedCount == 3 && model.exportReport?.rows.count == 3, "bulk reports all three actual destinations")
        check(warningPrompts == 1, "one explicit warning confirmation covers the queue batch")
        check(model.exportReport?.rows.allSatisfy { $0.path?.hasSuffix(".ru.srt") == true && $0.issues > 0 } == true,
              "bulk report preserves unresolved warning count and canonical paths")
        check(model.exportReport?.rows.allSatisfy { $0.backup == nil } == true, "new destinations need no backup")
        check(model.exportReport?.rows.allSatisfy { $0.outcome == .written && $0.sourcePath != nil && $0.path != nil } == true,
              "each written result reports its exact source and destination")
        check(model.exportReport?.summary == L10n.currentFormat("export.summary", 3, 0, 0, 0),
              "batch summary accounts separately for written, skipped, retained and failed results")
        model.exportReport = nil

        let job = model.state.jobs[0]
        let candidate = try SRTExport.prepare(job: job, settings: model.state.settings, store: model.store)
        let protected = model.state.jobs.map { URL(fileURLWithPath: $0.sourcePath) }
        let prior = Data("PREVIOUS RUSSIAN FILE MUST BE BACKED UP".utf8)
        try prior.write(to: candidate.destination, options: .atomic)
        rejects("no implicit replacement") { _ = try SRTExport.publish(candidate, to: candidate.destination, store: model.store, replacing: nil, protectedSources: protected) }
        check(try Data(contentsOf: candidate.destination) == prior, "refused overwrite preserves old Russian file")
        let permission = try FilePublication.inspect(candidate.destination, protectedSources: protected)
        let backup = try SRTExport.publish(candidate, to: candidate.destination, store: model.store, replacing: permission, protectedSources: protected)
        check(backup != nil && backup!.deletingLastPathComponent() == stateRoot.appendingPathComponent("file-backups"), "backup stored outside lecture folder")
        check(try Data(contentsOf: backup!) == prior, "backup has exact original bytes")
        check(try Data(contentsOf: candidate.destination) == candidate.bytes, "approved replacement succeeds")
        rejects("cannot replace source even explicitly") { _ = try SRTExport.publish(candidate, to: URL(fileURLWithPath: job.sourcePath), store: model.store,
                                                                                     replacing: try FilePublication.inspect(URL(fileURLWithPath: job.sourcePath)), protectedSources: protected) }
        rejects("cannot replace another source") { _ = try SRTExport.publish(candidate, to: protected[1], store: model.store, replacing: try FilePublication.inspect(protected[1]), protectedSources: protected) }

        var changed = candidate.journal; changed.parts[1]?.done = false
        try model.store.saveJournal(changed, id: job.id)
        rejects("incomplete translation cannot be exported") { _ = try SRTExport.prepare(job: job, settings: model.state.settings, store: model.store) }
        try model.store.saveJournal(candidate.journal, id: job.id)
        changed = candidate.journal
        changed.manualTranslations = [41: "Исправленное приветствие."]
        try model.store.saveJournal(changed, id: job.id)
        rejects("changed translation invalidates pending save") { _ = try SRTExport.publish(candidate, to: root.appendingPathComponent("Новый.ru.srt"), store: model.store, replacing: nil, protectedSources: protected) }
        try model.store.saveJournal(candidate.journal, id: job.id)
        try Data("source changed".utf8).write(to: URL(fileURLWithPath: job.sourcePath), options: .atomic)
        rejects("changed source invalidates export") { _ = try SRTExport.prepare(job: job, settings: model.state.settings, store: model.store) }
        try sourceBytes[job.sourcePath]!.write(to: URL(fileURLWithPath: job.sourcePath), options: .atomic)

        // Partial queue: a broken checkpoint is reported, but other ready translations still save.
        try Data("broken journal".utf8).write(to: model.store.journalURL(job.id), options: .atomic)
        model.saveAllTranslations(); try await finish(model)
        check(model.exportReport?.savedCount == 2 && model.exportReport?.rows.count == 3, "one bad checkpoint does not block other exports")
        check(model.exportReport?.rows.contains { !$0.saved } == true, "failure shown in queue report")
        try originalJournals[0].write(to: model.store.journalURL(job.id), options: .atomic)
        check(modelCalls == 0 && quotaCalls == 0, "entire export suite has zero model or quota requests")
        check(!fm.fileExists(atPath: stateRoot.appendingPathComponent("requests").path), "no paid-request directory created")
        var collisionState = ProjectState()
        collisionState.settings.outputLocation = "custom"; collisionState.settings.customOutputDirectory = root.path
        let first = JobSummary(sourcePath: root.appendingPathComponent("a/name.srt").path)
        let second = JobSummary(sourcePath: root.appendingPathComponent("b/name.de.srt").path)
        collisionState.jobs = [first, second]
        let reservations = SRTExport.reservations(state: collisionState, store: model.store)
        let collision = root.appendingPathComponent("name.ru.srt")
        rejects("first prospective destination collision is detected before export") { try SRTExport.validateDestination(collision, for: first.id, reservations: reservations) }
        rejects("single-job conflict retry still protects its queued neighbour") { try SRTExport.validateDestination(collision, for: second.id, reservations: reservations) }
        try SRTExport.validateDestination(root.appendingPathComponent("other/same.ru.srt"), for: second.id, reservations: reservations)
        check(true, "a distinct folder resolves queue collision")
        let base = try SRTExport.prepare(job: model.state.jobs[0], settings: model.state.settings, store: model.store)
        let otherJob = model.state.jobs[1]
        let otherCandidate = try SRTExport.prepare(job: otherJob, settings: model.state.settings, store: model.store)
        let untouchedCollisionTarget = root.appendingPathComponent("name.ru.srt")
        let collisionFirst = JobSummary(sourcePath: root.appendingPathComponent("a/name.srt").path)
        let collisionSecond = JobSummary(sourcePath: root.appendingPathComponent("b/name.de.srt").path)
        let colliding = [SRTExportCandidate(job: collisionFirst, lecture: base.lecture, journal: base.journal,
            destination: untouchedCollisionTarget, bytes: base.bytes, issueCount: base.issueCount, speechIssueCount: base.speechIssueCount),
            SRTExportCandidate(job: collisionSecond, lecture: otherCandidate.lecture,
            journal: otherCandidate.journal, destination: untouchedCollisionTarget, bytes: otherCandidate.bytes,
            issueCount: otherCandidate.issueCount, speechIssueCount: otherCandidate.speechIssueCount)]
        let groups = SRTExport.collisions(colliding)
        check(groups.count == 1 && groups[0].candidates.map(\.job.id).count == 2, "pre-write collision identifies and groups both source lectures")
        let cancelledCollision = try SRTExport.resolve(groups[0], decision: .cancel)
        check(cancelledCollision.cancelled && cancelledCollision.destinations.isEmpty, "cancelled collision resolution schedules no writes")
        let oneResult = try SRTExport.resolve(groups[0], decision: .keep(collisionFirst.id))
        check(oneResult.keptInProject == [collisionSecond.id] && oneResult.destinations.isEmpty, "choosing one result keeps the other completed translation in the project")
        let distinctPaths = [collisionFirst.id: root.appendingPathComponent("one/name.ru.srt"),
                             collisionSecond.id: root.appendingPathComponent("two/name.ru.srt")]
        let separate = try SRTExport.resolve(groups[0], decision: .separate(distinctPaths))
        check(separate.destinations.count == 2 && Set(separate.destinations.values.map(SRTExport.key)).count == 2,
              "separate-destination choice maps each source to a distinct compatible SRT path")
        try Data("existing collision target".utf8).write(to: untouchedCollisionTarget)
        check(groups[0].candidates.allSatisfy { $0.destination.lastPathComponent == untouchedCollisionTarget.lastPathComponent } &&
              Set(groups[0].candidates.map { URL(fileURLWithPath: $0.job.sourcePath).lastPathComponent }) == ["name.srt", "name.de.srt"],
              "name.de.srt and name.srt resolve to the same target name before publication")
        check(try Data(contentsOf: untouchedCollisionTarget) == Data("existing collision target".utf8),
              "pre-write collision handling leaves any existing target untouched")
        rejects("separate destinations cannot invent an incompatible suffix") {
            _ = try SRTExport.resolve(groups[0], decision: .separate([collisionFirst.id: root.appendingPathComponent("one/name.review.srt"),
                collisionSecond.id: root.appendingPathComponent("one/name.review.srt")]))
        }
        // Cancellation requested immediately after the first atomic publication must
        // preserve that success and account for the remaining completed results.
        for ready in model.readyExportJobs {
            let prepared = try SRTExport.prepare(job: ready, settings: model.state.settings, store: model.store)
            try fm.removeItem(at: prepared.destination)
        }
        model.exportReport = nil
        var didRequestStop = false
        model.exportDidPublishOverride = {
            guard !didRequestStop else { return }
            didRequestStop = true
            model.exportCancelRequested = true
        }
        model.saveAllTranslations(); try await finish(model)
        model.exportDidPublishOverride = nil
        check(didRequestStop && model.exportReport?.savedCount == 1 && model.exportReport?.rows.count == 3,
              "cancel after first write retains its success and reports all remaining results")
        check(model.exportReport?.rows.filter { $0.outcome == .written }.count == 1 &&
              model.exportReport?.rows.filter { $0.outcome == .inProject }.count == 2 &&
              model.exportReport?.rows.filter { $0.outcome == .failed || $0.outcome == .skipped }.isEmpty == true,
              "post-write cancellation classifies exactly one written and two kept in project")
        let cancelledSummary = model.exportReport?.summary ?? ""
        check(cancelledSummary.hasPrefix(L10n.currentFormat("export.summary", 1, 0, 2, 0)) &&
              cancelledSummary.hasSuffix(L10n.current("export.stopped")),
              "cancelled batch summary reports exact outcomes")
        let retainedSource = model.exportReport!.rows.first(where: { $0.outcome == .inProject })!.sourcePath!
        let remainingJob = model.readyExportJobs.first(where: { $0.sourcePath == retainedSource })!
        model.exportReport = nil
        model.exportJournalSaveOverride = { _, _, _ in throw TranslatorError.invalid("synthetic journal failure") }
        model.saveTranslations(jobIDs: [remainingJob.id]); try await finish(model)
        model.exportJournalSaveOverride = nil
        check(model.exportReport?.rows.count == 1 && model.exportReport?.rows[0].saved == true &&
              model.exportReport?.rows[0].outcome == .written &&
              model.exportReport?.rows[0].message.isEmpty == false,
              "successful SRT remains accounted as written and warning is surfaced when project save marking fails")
        model.state.manuallyPaused = false; model.state.translationPending = true; model.state.resumeAt = Date().addingTimeInterval(300)
        model.exporting = true; model.busy = true
        model.pause(immediately: false)
        let paused = try model.store.load()
        check(paused.manuallyPaused && paused.translationPending == false && paused.resumeAt == nil, "export pause durably cancels automatic translation")
        check(model.exportCancelRequested, "export pause cancels after current atomic publication")
        model.exporting = false; model.busy = false
        print("PASS: \(passed) export checks. Synthetic queue, zero model/quota calls.")
    }
}
