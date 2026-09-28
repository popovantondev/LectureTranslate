import Foundation

@main
enum ProjectControlTests {
    private static var passed = 0
    private static func check(_ condition: Bool, _ message: String) {
        guard condition else { fputs("FAIL: \(message)\n", stderr); exit(1) }
        passed += 1
    }
    private static func rejects(_ message: String, _ body: () throws -> Void) {
        do { try body(); fputs("FAIL: \(message) did not reject\n", stderr); exit(1) }
        catch { passed += 1 }
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value)
    }

    @MainActor static func main() async throws {
        let fm = FileManager.default
        let testDefaultName: (UILanguage) -> String = { language in
            switch language { case .de: "Vorlesungen"; case .ru: "Лекции"; case .en: "Lectures" }
        }
        check(ProjectSavePanelName.seed(currentPath: nil, language: .de, localizedDefaultName: testDefaultName) == "Vorlesungen", "German new save panel default name")
        check(ProjectSavePanelName.seed(currentPath: nil, language: .ru, localizedDefaultName: testDefaultName) == "Лекции", "Russian new save panel default name")
        check(ProjectSavePanelName.seed(currentPath: nil, language: .en, localizedDefaultName: testDefaultName) == "Lectures", "English new save panel default name")
        check(ProjectSavePanelName.seed(currentPath: "/isolated/Проверка.lectureproject", language: .de) == "Проверка", "Save As does not seed an already-applied extension")
        check(ProjectSavePanelName.seed(currentPath: "/isolated/Проверка.lectureproject.LECTUREPROJECT", language: .de) == "Проверка", "Save As strips repeated case-insensitive trailing extensions")
        check(ProjectSavePanelName.seed(currentPath: "/isolated/Глава.lectureproject.notes.lectureproject", language: .de) == "Глава.lectureproject.notes", "embedded extension-like text in the filename is preserved")
        check(ProjectSavePanelName.seed(currentPath: "/isolated/.lectureproject.lectureproject", language: .de, localizedDefaultName: testDefaultName) == "Vorlesungen", "empty normalized panel name has a localized readable fallback")
        check(ProjectSavePanelName.seed(currentPath: "/isolated/Лекция о шалфее — часть 2.lectureproject", language: .de) == "Лекция о шалфее — часть 2", "Unicode and spaces survive panel filename normalization")
        let root = fm.temporaryDirectory.appendingPathComponent("LectureProjectControlTests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) } // Only this test-owned UUID directory.
        let liveRoot = root.appendingPathComponent("live")
        setenv("LECTURE_TRANSLATOR_STATE_DIR", liveRoot.path, 1)
        let model = TranslatorModel()
        defer { model.shutdown(); unsetenv("LECTURE_TRANSLATOR_STATE_DIR") }
        check(model.writable, "isolated model acquires its own queue lock")
        let source = root.appendingPathComponent("Первая.de.srt")
        let original = "41\n00:00:00,000 --> 00:00:05,000\nGuten Morgen.\n\n92\n00:00:05,000 --> 00:00:10,000\nBis zum nächsten Mal.\n"
        try Data(original.utf8).write(to: source)
        let output = root.appendingPathComponent("Первая.ru.srt")
        let outputBytes = Data("READY_RUSSIAN_SUBTITLE_MUST_STAY".utf8)
        try outputBytes.write(to: output)
        let lecture = try PreparedLecture.prepare(url: source, profile: .builtIns[0], settings: TranslationSettings())
        var job = JobSummary(sourcePath: source.path)
        job.sourceHash = lecture.document.sourceHash; job.status = .translated
        job.cueCount = 2; job.completedCues = 2; job.partCount = 1
        var journal = TranslationJournal(sourceHash: lecture.document.sourceHash, settings: lecture.settings, profile: lecture.profile)
        let reply = TranslationReply(translations: [.init(id: 41, text: "Доброе утро."), .init(id: 92, text: "До следующего раза.")], issues: [])
        let result = ModelResult(reply: reply, usage: .init(input_tokens: 35, output_tokens: 10), model: "gpt-5.6-terra", effort: "medium", elapsed: 1)
        journal.parts[1] = .init(draftAttempts: 1, reviewAttempts: 1, draft: result, review: result, done: true)
        try model.store.save(lecture, id: job.id); try model.store.saveJournal(journal, id: job.id)
        var current = ProjectState(); current.jobs = [job]
        current.projectFilePath = root.appendingPathComponent("Предыдущая очередь.lectureproject").path
        current.settings.outputLocation = "custom"; current.settings.customOutputDirectory = root.appendingPathComponent("Результаты").path
        current.profiles.append(.init(id: "books", name: "Книги", subject: "Учебная литература", glossary: ""))
        current.manuallyPaused = false; current.translationPending = true; current.resumeAt = Date().addingTimeInterval(300)
        model.state = current; model.selection = job.id; model.loadSelection(); try model.store.save(current)
        let checkpointBefore = try Data(contentsOf: model.store.jobURL(job.id))
        let journalBefore = try Data(contentsOf: model.store.journalURL(job.id))
        let queueURL = liveRoot.appendingPathComponent("queue.json")
        let queueBefore = try Data(contentsOf: queueURL)

        model.busy = true
        rejects("busy queue cannot be cleared") { try model.clearQueue() }
        check(model.state.jobs.map(\.id) == [job.id], "busy rejection preserves visible queue")
        check(try Data(contentsOf: queueURL) == queueBefore, "busy rejection preserves durable queue")
        model.busy = false; model.writable = false
        rejects("unreadable queue cannot be cleared") { try model.clearQueue() }
        check(try Data(contentsOf: queueURL) == queueBefore, "read-only rejection preserves durable queue")
        model.writable = true

        model.scheduleAutomaticResume(after: 0.03)
        try model.clearQueue()
        let cleared = try model.store.load()
        check(model.state.jobs.isEmpty && cleared.jobs.isEmpty, "clear atomically empties visible and durable queue")
        check(cleared.manuallyPaused && cleared.translationPending == false && cleared.resumeAt == nil, "clear removes pending automatic run")
        check(model.selection == nil && model.lecture == nil && model.journal == nil, "clear deselects stale details")
        check(cleared.settings == current.settings && cleared.profiles == current.profiles, "clear retains settings and custom profiles")
        check(cleared.projectFilePath == nil && model.state.projectFilePath == nil, "clear detaches the old project path")
        check(try Data(contentsOf: source) == Data(original.utf8), "clear retains source SRT")
        check(try Data(contentsOf: output) == outputBytes, "clear retains ready Russian SRT")
        check(try Data(contentsOf: model.store.jobURL(job.id)) == checkpointBefore, "clear retains prepared checkpoint")
        check(try Data(contentsOf: model.store.journalURL(job.id)) == journalBefore, "clear retains paid translation journal")
        let backupDirectory = liveRoot.appendingPathComponent("queue-backups")
        let backups = try fm.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil)
        check(backups.count == 1, "clear writes one non-overwriting queue backup")
        let backup = try JSONDecoder().decode(ProjectState.self, from: Data(contentsOf: backups[0]))
        check(backup.jobs.map(\.id) == [job.id] && backup.manuallyPaused && backup.translationPending == false && backup.resumeAt == nil, "backup references retained results without auto-resume")
        check(backup.projectFilePath == current.projectFilePath, "clear backup retains previous project reference")
        // If the stale timer is not cancelled, this missing source will fail local preparation.
        // It cannot reach a quota or translation call, even when the assertion regresses.
        let missing = JobSummary(sourcePath: root.appendingPathComponent("missing.srt").path)
        model.state.jobs = [missing]; model.state.manuallyPaused = false; model.state.translationPending = true
        try await Task.sleep(nanoseconds: 100_000_000)
        check(model.state.jobs[0].status == .queued && model.state.translationPending == true && !model.busy, "clear cancels stale resume timer")

        model.state = current; model.selection = job.id; model.loadSelection(); try model.store.save(current)
        let savedBackups = liveRoot.appendingPathComponent("saved-backups")
        try fm.moveItem(at: backupDirectory, to: savedBackups)
        try Data("backup location occupied".utf8).write(to: backupDirectory)
        rejects("backup failure aborts clear") { try model.clearQueue() }
        check(try encode(model.state) == encode(current), "failed clear does not mutate visible state")
        check(try Data(contentsOf: queueURL) == queueBefore, "failed backup preserves durable queue")
        try fm.removeItem(at: backupDirectory); try fm.moveItem(at: savedBackups, to: backupDirectory)

        // Keep jobs and backups writable, but deny atomic replacement in their parent.
        // This exercises the final publish failure rather than merely a failing backup.
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: liveRoot.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: liveRoot.path) }
        rejects("atomic queue publication failure aborts clear") { try model.clearQueue() }
        check(try Data(contentsOf: queueURL) == queueBefore, "failed clear publication leaves old queue bytes intact")
        check(try encode(model.state) == encode(current), "failed clear publication leaves visible queue intact")
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: liveRoot.path)

        let incomingStore = CheckpointStore(root: root.appendingPathComponent("incoming"))
        let incomingSource = root.appendingPathComponent("Вторая.srt")
        try Data(original.replacingOccurrences(of: "Guten Morgen", with: "Guten Abend").utf8).write(to: incomingSource)
        var incomingSettings = TranslationSettings(); incomingSettings.outputLocation = "downloads"
        let incomingLecture = try PreparedLecture.prepare(url: incomingSource, profile: .builtIns[0], settings: incomingSettings)
        var incomingJob = JobSummary(sourcePath: incomingSource.path)
        incomingJob.sourceHash = incomingLecture.document.sourceHash; incomingJob.cueCount = 2; incomingJob.partCount = 1
        incomingJob.completedCues = 2; incomingJob.status = .translated
        var incomingJournal = TranslationJournal(sourceHash: incomingLecture.document.sourceHash, settings: incomingSettings, profile: incomingLecture.profile)
        incomingJournal.parts[1] = .init(draftAttempts: 1, reviewAttempts: 1, draft: result, review: result, done: true)
        var incomingState = ProjectState(); incomingState.jobs = [incomingJob]; incomingState.settings = incomingSettings
        try incomingStore.save(incomingLecture, id: incomingJob.id); try incomingStore.saveJournal(incomingJournal, id: incomingJob.id)
        let incomingJournalBefore = try Data(contentsOf: incomingStore.journalURL(incomingJob.id))
        let projectURL = root.appendingPathComponent("Второй проект.lectureproject")
        try ProjectArchive.save(state: incomingState, store: incomingStore, to: projectURL)
        let beforeJobs = try fm.contentsOfDirectory(atPath: liveRoot.appendingPathComponent("jobs").path).sorted()
        model.busy = true
        rejects("busy queue cannot import a project") { try model.importProject(from: projectURL) }
        model.busy = false; model.writable = false
        rejects("read-only queue cannot import a project") { try model.importProject(from: projectURL) }
        model.writable = true
        let invalidProject = root.appendingPathComponent("Битый.lectureproject")
        try Data("{broken".utf8).write(to: invalidProject)
        rejects("invalid project does not replace queue") { try model.importProject(from: invalidProject) }
        check(try encode(model.state) == encode(current) && Data(contentsOf: queueURL) == queueBefore, "invalid import preserves visible and durable queue")
        check(try fm.contentsOfDirectory(atPath: liveRoot.appendingPathComponent("jobs").path).sorted() == beforeJobs, "invalid import creates no jobs")

        try fm.moveItem(at: backupDirectory, to: savedBackups)
        try Data("backup location occupied".utf8).write(to: backupDirectory)
        rejects("failed backup rolls back a staged import") { try model.importProject(from: projectURL) }
        check(try fm.contentsOfDirectory(atPath: liveRoot.appendingPathComponent("jobs").path).sorted() == beforeJobs, "backup failure removes only newly imported jobs")
        check(try Data(contentsOf: queueURL) == queueBefore, "backup failure does not replace queue")
        try fm.removeItem(at: backupDirectory); try fm.moveItem(at: savedBackups, to: backupDirectory)
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: liveRoot.path)
        rejects("failed queue publication rolls back staged import") { try model.importProject(from: projectURL) }
        check(try fm.contentsOfDirectory(atPath: liveRoot.appendingPathComponent("jobs").path).sorted() == beforeJobs, "publish failure removes only newly imported jobs")
        check(try Data(contentsOf: queueURL) == queueBefore && encode(model.state) == encode(current), "publish failure leaves queue intact")
        check(try Data(contentsOf: model.store.journalURL(job.id)) == journalBefore, "failed imports retain old paid results")
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: liveRoot.path)

        model.scheduleAutomaticResume(after: 0.03)
        try model.importProject(from: projectURL)
        let importedState = try model.store.load()
        check(importedState.jobs.count == 1 && importedState.jobs[0].sourcePath == incomingSource.path, "successful import replaces rather than appends queue")
        check(importedState.jobs[0].id != incomingJob.id && importedState.jobs[0].id != job.id, "imported queue has fresh checkpoint identity")
        check(importedState.manuallyPaused && importedState.translationPending == false && importedState.resumeAt == nil, "imported project stays paused")
        check(importedState.settings == incomingSettings, "project settings restored")
        check(importedState.projectFilePath == projectURL.path && model.state.projectFilePath == projectURL.path,
              "import remembers the actually opened project in visible and durable state")
        check(model.selection == importedState.jobs[0].id && model.journal?.translated[41] == "Доброе утро.", "selected imported result loads immediately")
        check(try Data(contentsOf: model.store.journalURL(job.id)) == journalBefore && Data(contentsOf: model.store.jobURL(job.id)) == checkpointBefore,
              "successful import retains previous queue checkpoints")
        check(try Data(contentsOf: incomingStore.journalURL(incomingJob.id)) == incomingJournalBefore,
              "import does not mutate archived source journal")
        model.state.jobs = [missing]; model.state.manuallyPaused = false; model.state.translationPending = true
        try await Task.sleep(nanoseconds: 100_000_000)
        check(model.state.jobs[0].status == .queued && model.state.translationPending == true && !model.busy, "import cancels stale resume timer")
        model.state = importedState; model.selection = importedState.jobs[0].id; model.loadSelection()

        let paidBeforeLocation = try Data(contentsOf: model.store.journalURL(importedState.jobs[0].id))
        model.state.settings.outputLocation = "custom"; model.state.settings.customOutputDirectory = root.appendingPathComponent("Другой результат").path
        model.save()
        check(model.state.settings.translationCompatible(with: incomingSettings), "only output destination differs without invalidating paid results")
        let relocatedLecture = try PreparedLecture.prepare(url: incomingSource, profile: incomingLecture.profile, settings: model.state.settings)
        let relocatedJournal = try model.store.journal(importedState.jobs[0].id, lecture: relocatedLecture)
        check(relocatedJournal.translated == incomingJournal.translated, "saved paid journal validates against a different output folder")
        check(try Data(contentsOf: model.store.journalURL(importedState.jobs[0].id)) == paidBeforeLocation, "saving output folder does not rewrite paid journal")
        check(TranslationPipeline.destination(source: incomingSource, settings: model.state.settings).deletingLastPathComponent().path == model.state.settings.customOutputDirectory,
              "new output destination is used for subsequent exports")
        var changedMeaning = model.state.settings; changedMeaning.outputStyle = "display"
        check(!changedMeaning.translationCompatible(with: incomingSettings), "text mode still requires a distinct translation contract")

        let savedProject = root.appendingPathComponent("Сохранённый проект.lectureproject")
        model.busy = true
        rejects("project save waits for paused checkpoints") { try model.saveProject(to: savedProject) }
        model.busy = false
        check(try model.saveProject(to: savedProject) == nil, "first project save does not replace a file")
        let savedProjectState = try model.store.load()
        check(model.state.projectFilePath == savedProject.path && savedProjectState.projectFilePath == savedProject.path,
              "successful project save remembers path in visible and durable queue")
        let savedBytes = try Data(contentsOf: savedProject)
        let afterSaveQueue = try Data(contentsOf: queueURL)
        rejects("backend default save still requires explicit overwrite consent") { try model.saveProject(to: savedProject) }
        check(try Data(contentsOf: savedProject) == savedBytes && Data(contentsOf: queueURL) == afterSaveQueue,
              "refused replacement leaves project and queue intact")
        let consent = try FilePublication.inspect(savedProject)!
        let savedBackup = try model.saveProject(to: savedProject, replacing: consent)!
        check(try Data(contentsOf: savedBackup) == savedBytes, "ordinary Save replacement retains previous project")
        check(try Data(contentsOf: model.store.journalURL(importedState.jobs[0].id)) == paidBeforeLocation,
              "project Save never mutates paid journal")
        let secondProject = root.appendingPathComponent("Сохранить как.lectureproject")
        let previousProjectBytes = try Data(contentsOf: savedProject)
        try model.saveProject(to: secondProject)
        check(try Data(contentsOf: savedProject) == previousProjectBytes && model.state.projectFilePath == secondProject.path,
              "Save As changes current location without mutating the old project")

        // A successfully published project remains useful even if queue persistence fails.
        let retainedQueue = liveRoot.appendingPathComponent("queue-test-retained.json")
        try fm.moveItem(at: queueURL, to: retainedQueue)
        try fm.createDirectory(at: queueURL, withIntermediateDirectories: false)
        let independentlySaved = root.appendingPathComponent("Проект сохранён очередь недоступна.lectureproject")
        model.error = nil
        try model.saveProject(to: independentlySaved)
        check(fm.fileExists(atPath: independentlySaved.path) && model.state.projectFilePath == independentlySaved.path,
              "queue persistence failure does not hide successfully saved project")
        let warningKey = "project.saved_path_warning"
        let warningTemplate = L10n.current(warningKey)
        if warningTemplate == warningKey {
            // This standalone test binary has no copied .lproj resources; L10n
            // deliberately returns the stable key when a localized bundle is absent.
            check(model.error == warningKey, "resource-free test keeps the stable save warning fallback")
        } else {
            let expectedPrefix = L10n.currentFormat(warningKey, independentlySaved.path, "TEST_DETAIL")
                .components(separatedBy: "TEST_DETAIL").first ?? ""
            check(model.error?.hasPrefix(expectedPrefix) == true
                  && model.error?.contains(independentlySaved.path) == true,
                  "localized partial-save warning retains the saved path and explanation")
        }
        try fm.removeItem(at: queueURL); try fm.moveItem(at: retainedQueue, to: queueURL)
        try model.store.save(model.state)

        check(try Data(contentsOf: source) == Data(original.utf8) && Data(contentsOf: output) == outputBytes, "all controls preserve original and exported files")
        check(!fm.fileExists(atPath: liveRoot.appendingPathComponent("requests").path), "control tests never launch a model")
        print("PASS: \(passed) project lifecycle checks. Isolated state; no GUI, quota calls or model requests.")
    }
}
