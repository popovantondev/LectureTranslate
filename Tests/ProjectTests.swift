import Foundation

@main
enum ProjectTests {
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
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("LectureProjectTests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) } // Only this test-owned UUID directory.
        let original = "42\n00:00:01,123 --> 00:00:05,456\nDie erste Zeile.\n\n105\n00:00:05,500 --> 00:00:09,000\nNicht verwenden.\n"
        let source = root.appendingPathComponent("Лекция.de.srt")
        try Data(original.utf8).write(to: source)
        let store = CheckpointStore(root: root.appendingPathComponent("live"))
        let importedStore = CheckpointStore(root: root.appendingPathComponent("imported"))
        let lecture = try PreparedLecture.prepare(url: source, profile: .builtIns[0], settings: TranslationSettings())
        var job = JobSummary(sourcePath: source.path)
        let video = root.appendingPathComponent("Лекция.mp4")
        try Data("SYNTHETIC_VIDEO_PATH_ONLY".utf8).write(to: video)
        job.originalVideoPath = video.path
        job.sourceHash = lecture.document.sourceHash; job.status = .needsReview
        job.cueCount = 2; job.partCount = 1; job.completedCues = 2
        var state = ProjectState(); state.jobs = [job]; state.translationPending = true
        state.resumeAt = Date().addingTimeInterval(300)
        var journal = TranslationJournal(sourceHash: lecture.document.sourceHash, settings: lecture.settings, profile: lecture.profile)
        journal.version = 4; journal.memoryEnabled = true; journal.reviewStrategy = ReviewPlanning.strategy
        journal.reviewPlan = [1]; journal.confirmedTerms = [.init(german: "Zeile", russian: "строка")]
        let reply = TranslationReply(translations: [.init(id: 42, text: "Первая строка."), .init(id: 105, text: "Не использовать.")],
                                     issues: [], memory: [.init(ids: [42], text: "Начало объяснения.")],
                                     terms: [.init(ids: [42], german: "Zeile", russian: "строка", reason: "Обычное слово.")])
        let result = ModelResult(reply: reply, usage: .init(input_tokens: 100, cached_input_tokens: 20, output_tokens: 15),
                                 model: "gpt-5.6-terra", effort: "medium", elapsed: 3)
        journal.parts[1] = PartProgress(draftAttempts: 2, reviewAttempts: 1, draft: result, review: result, done: true,
                                        draftQuotaDeferrals: 1)
        journal.consecutiveQuotaRefusals = 1
        try journal.edit(cueID: 42, text: "Самая первая строка.", confirming: nil, sourceChecked: false, lecture: lecture)
        try store.save(state); try store.save(lecture, id: job.id); try store.saveJournal(journal, id: job.id)
        let queueBytes = try Data(contentsOf: store.root.appendingPathComponent("queue.json"))
        let journalBytes = try Data(contentsOf: store.journalURL(job.id))
        let secretDirectory = store.root.appendingPathComponent("requests")
        try fm.createDirectory(at: secretDirectory, withIntermediateDirectories: false)
        try Data("PRIVATE_REQUEST_NOT_IN_PROJECT".utf8).write(to: secretDirectory.appendingPathComponent("request.txt"))
        try Data("PRIVATE_AUTH_NOT_IN_PROJECT".utf8).write(to: store.root.appendingPathComponent("auth.json"))
        let archive = root.appendingPathComponent("Моя лекция.lectureproject")
        try ProjectArchive.save(state: state, store: store, to: archive)
        let archiveBytes = try Data(contentsOf: archive)
        let archiveText = String(decoding: archiveBytes, as: UTF8.self)
        check(!archiveText.contains("PRIVATE_REQUEST") && !archiveText.contains("PRIVATE_AUTH"), "no raw requests or authentication in archive")
        check(archiveText.contains("Начало объяснения.") && archiveText.contains("Самая первая строка."), "translation memory and manual revision included")
        check(try Data(contentsOf: store.root.appendingPathComponent("queue.json")) == queueBytes, "saving project does not mutate live queue")
        check(try Data(contentsOf: store.journalURL(job.id)) == journalBytes, "saving project does not mutate journal")
        rejects("existing project never overwritten") { try ProjectArchive.save(state: state, store: store, to: archive) }
        check(try Data(contentsOf: archive) == archiveBytes, "collision preserves project bytes")
        rejects("non-project extension rejected") { try ProjectArchive.save(state: state, store: store, to: source) }
        check(try Data(contentsOf: source) == Data(original.utf8), "source SRT preserved")
        let imported = try ProjectArchive.open(from: archive, into: importedStore)
        check(imported.state.projectFilePath == archive.path, "opened project remembers its actual location")
        check(imported.state.jobs[0].originalVideoPath == video.path, "explicit original-video path survives project round trip")
        let newID = imported.state.jobs[0].id
        check(newID != job.id, "import gives new job ID")
        check(imported.state.manuallyPaused && imported.state.translationPending == false && imported.state.resumeAt == nil, "import never automatically resumes")
        check(imported.state.settings.model == "gpt-6-luna" && imported.state.settings.reviewModel == "gpt-6-sol", "new GPT-6 routing survives project round trip")
        check(!fm.fileExists(atPath: importedStore.root.appendingPathComponent("queue.json").path), "import leaves committing queue to caller")
        let importedLecture = try importedStore.loadLecture(newID)
        let importedJournal = try importedStore.journal(newID, lecture: importedLecture)
        check(importedLecture.document == lecture.document && imported.state.jobs[0].sourcePath == source.path, "source paths hash cues and timings retained")
        check(importedJournal.translated[42] == "Самая первая строка." && importedJournal.manualHistory?.count == 1, "manual translation history retained")
        check(importedJournal.parts[1]?.draftAttempts == 2 && importedJournal.parts[1]?.chargedDraftAttempts == 1, "quota deferrals and attempts retained")
        check(importedJournal.confirmedTerms == journal.confirmedTerms, "frozen glossary retained")
        check(importedJournal.parts[1]?.draft?.reply.memory == journal.parts[1]?.draft?.reply.memory, "previous part context retained")
        check(importedJournal.reviewPlan == [1] && importedJournal.reviewStrategy == ReviewPlanning.strategy, "review plan retained")
        check(imported.warnings.isEmpty, "existing source has no missing-source warning")
        check(!fm.fileExists(atPath: importedStore.root.appendingPathComponent("terms.json").path), "global glossary not replaced")
        try importedStore.save(imported.state)
        let committedQueue = try Data(contentsOf: importedStore.root.appendingPathComponent("queue.json"))
        let second = try ProjectArchive.open(from: archive, into: importedStore)
        check(second.state.jobs[0].id != newID, "reimport creates distinct checkpoint identity")
        second.rollback()
        check(!fm.fileExists(atPath: importedStore.jobURL(second.state.jobs[0].id).path), "rollback removes only its imported lecture")
        check(fm.fileExists(atPath: importedStore.jobURL(newID).path), "rollback preserves earlier jobs")
        check(try Data(contentsOf: importedStore.root.appendingPathComponent("queue.json")) == committedQueue, "rollback does not change live queue")
        second.rollback()
        check(fm.fileExists(atPath: importedStore.journalURL(newID).path), "rollback is safely repeatable")
        let third = try ProjectArchive.open(from: archive, into: importedStore)
        let modifiedURL = importedStore.jobURL(third.state.jobs[0].id)
        try Data("modified".utf8).write(to: modifiedURL)
        third.rollback()
        check(try Data(contentsOf: modifiedURL) == Data("modified".utf8), "rollback does not erase a changed file")

        let empty = root.appendingPathComponent("Пустой.lectureproject")
        try ProjectArchive.save(state: ProjectState(), store: store, to: empty)
        let emptyImport = try ProjectArchive.open(from: empty, into: CheckpointStore(root: root.appendingPathComponent("empty")))
        check(emptyImport.state.jobs.isEmpty && emptyImport.state.manuallyPaused, "empty project supported")
        var displayState = ProjectState()
        displayState.settings.outputStyle = "display"; displayState.settings.outputLocation = "custom"
        displayState.settings.customOutputDirectory = root.appendingPathComponent("Субтитры").path
        let displayArchive = root.appendingPathComponent("Экранные субтитры.lectureproject")
        try ProjectArchive.save(state: displayState, store: store, to: displayArchive)
        let displayImport = try ProjectArchive.open(from: displayArchive, into: importedStore)
        check(displayImport.state.settings == displayState.settings, "text mode and output folder survive project round trip")
        displayState.settings.customOutputDirectory = "../outside"
        rejects("relative custom output path rejected") {
            try ProjectArchive.save(state: displayState, store: store, to: root.appendingPathComponent("Небезопасный.lectureproject"))
        }
        var queuedState = ProjectState()
        queuedState.jobs = [JobSummary(sourcePath: root.appendingPathComponent("Отсутствует.srt").path)]
        let queuedArchive = root.appendingPathComponent("Неподготовленный.lectureproject")
        try ProjectArchive.save(state: queuedState, store: store, to: queuedArchive)
        let queuedImport = try ProjectArchive.open(from: queuedArchive, into: importedStore)
        check(queuedImport.warnings.count == 1 && queuedImport.state.jobs[0].status == .invalid, "missing source is warning not guessed or hard failure")
        check(!fm.fileExists(atPath: importedStore.jobURL(queuedImport.state.jobs[0].id).path), "unprepared job does not get a fabricated checkpoint")

        let decoded = try JSONDecoder().decode(ProjectArchive.Envelope.self, from: archiveBytes)
        func writePayload(_ payload: ProjectArchive.Payload, name: String) throws -> URL {
            let url = root.appendingPathComponent(name + ".lectureproject")
            let envelope = ProjectArchive.Envelope(format: "lecture-translate-project", version: 1, createdAt: Date(),
                                                   payloadHash: SRTDocument.hash(try encode(payload)), payload: payload)
            try encode(envelope).write(to: url)
            return url
        }
        let malformed = root.appendingPathComponent("Повреждён.lectureproject")
        try archiveBytes.dropLast(8).write(to: malformed)
        rejects("truncated archive rejected") { _ = try ProjectArchive.open(from: malformed, into: importedStore) }
        let wrongChecksum = ProjectArchive.Envelope(format: decoded.format, version: decoded.version, createdAt: decoded.createdAt,
                                                    payloadHash: String(repeating: "0", count: 64), payload: decoded.payload)
        try encode(wrongChecksum).write(to: malformed)
        rejects("archive checksum mismatch rejected") { _ = try ProjectArchive.open(from: malformed, into: importedStore) }
        let initialFiles = try fm.contentsOfDirectory(atPath: importedStore.root.appendingPathComponent("jobs").path).sorted()
        let duplicateEntries = ProjectArchive.Payload(state: decoded.payload.state, entries: decoded.payload.entries + decoded.payload.entries)
        let duplicate = try writePayload(duplicateEntries, name: "Дубликаты")
        rejects("duplicate/missing entry rejected before writes") { _ = try ProjectArchive.open(from: duplicate, into: importedStore) }
        var badState = decoded.payload.state; badState.jobs[0].sourceHash = String(repeating: "a", count: 64)
        let mismatch = try writePayload(.init(state: badState, entries: decoded.payload.entries), name: "Неверный исходник")
        rejects("queue source hash mismatch rejected") { _ = try ProjectArchive.open(from: mismatch, into: importedStore) }
        badState = decoded.payload.state; badState.settings.reserve = 100
        let unsafe = try writePayload(.init(state: badState, entries: decoded.payload.entries), name: "Неверный резерв")
        rejects("unsafe settings rejected") { _ = try ProjectArchive.open(from: unsafe, into: importedStore) }
        var badJournal = journal; badJournal.parts[1]!.draftAttempts = -1
        let invalidCounters = try writePayload(.init(state: decoded.payload.state,
                entries: [.init(jobID: job.id, lecture: lecture, journal: badJournal)]), name: "Счётчики")
        rejects("invalid counters rejected without range crash") { _ = try ProjectArchive.open(from: invalidCounters, into: importedStore) }
        let badDocument = SRTDocument(sourceHash: lecture.document.sourceHash, cues: [lecture.document.cues[0], lecture.document.cues[0]])
        let badLecture = PreparedLecture(version: lecture.version, document: badDocument, parts: lecture.parts, issues: [],
                                         videoPaths: [], profile: lecture.profile, settings: lecture.settings)
        let invalidCues = try writePayload(.init(state: decoded.payload.state,
                entries: [.init(jobID: job.id, lecture: badLecture, journal: journal)]), name: "Номера")
        rejects("duplicate source cue IDs rejected before dictionary construction") { _ = try ProjectArchive.open(from: invalidCues, into: importedStore) }
        check(try fm.contentsOfDirectory(atPath: importedStore.root.appendingPathComponent("jobs").path).sorted() == initialFiles, "all invalid imports leave jobs unchanged")

        check(try ProjectArchive.normalizedDestination(root.appendingPathComponent("Лекции.lectureproject.LECTUREPROJECT")).lastPathComponent == "Лекции.lectureproject",
              "Save As normalizes duplicate project extensions")
        check(try ProjectArchive.normalizedDestination(root.appendingPathComponent("Лекции")).lastPathComponent == "Лекции.lectureproject",
              "Save As adds exactly one project extension")
        let chosenDirectory = root.appendingPathComponent("Day_05.lectureproject")
        try fm.createDirectory(at: chosenDirectory, withIntermediateDirectories: false)
        rejects("Save As never treats a chosen directory as a replaceable project") { _ = try ProjectArchive.normalizedDestination(chosenDirectory) }

        var redirectedState = decoded.payload.state
        redirectedState.projectFilePath = root.appendingPathComponent("Не открывался.lectureproject").path
        let relocated = try writePayload(.init(state: redirectedState, entries: decoded.payload.entries), name: "Фактически открыт")
        let relocatedImport = try ProjectArchive.open(from: relocated, into: importedStore)
        check(relocatedImport.state.projectFilePath == relocated.path, "embedded old path cannot redirect future Save")
        relocatedImport.rollback()
        redirectedState.projectFilePath = "relative.lectureproject"
        let badProjectPath = try writePayload(.init(state: redirectedState, entries: decoded.payload.entries), name: "Неверный путь проекта")
        rejects("relative embedded project path rejected") { _ = try ProjectArchive.open(from: badProjectPath, into: importedStore) }
        redirectedState = decoded.payload.state; redirectedState.jobs[0].originalVideoPath = "../video.mp4"
        let badVideoPath = try writePayload(.init(state: redirectedState, entries: decoded.payload.entries), name: "Неверный путь видео")
        rejects("relative embedded video path rejected") { _ = try ProjectArchive.open(from: badVideoPath, into: importedStore) }

        var legacyObject = try JSONSerialization.jsonObject(with: encode(state)) as! [String: Any]
        legacyObject.removeValue(forKey: "projectFilePath")
        var legacyJobs = legacyObject["jobs"] as! [[String: Any]]
        legacyJobs[0].removeValue(forKey: "originalVideoPath"); legacyObject["jobs"] = legacyJobs
        let legacyState = try JSONDecoder().decode(ProjectState.self, from: JSONSerialization.data(withJSONObject: legacyObject))
        check(legacyState.projectFilePath == nil && legacyState.jobs[0].originalVideoPath == nil, "older queues decode missing optional paths")
        legacyObject["projectFilePath"] = NSNull(); legacyJobs[0]["originalVideoPath"] = NSNull(); legacyObject["jobs"] = legacyJobs
        let nullState = try JSONDecoder().decode(ProjectState.self, from: JSONSerialization.data(withJSONObject: legacyObject))
        check(nullState.projectFilePath == nil && nullState.jobs[0].originalVideoPath == nil, "null optional paths decode safely")

        let beforeReplacement = try Data(contentsOf: archive)
        let replacementConsent = try FilePublication.inspect(archive)!
        var changedState = state; changedState.settings.outputLocation = "downloads"
        let archiveBackup = try ProjectArchive.save(state: changedState, store: store, to: archive, replacing: replacementConsent)!
        check(try Data(contentsOf: archiveBackup) == beforeReplacement, "explicit project replacement makes byte-exact service backup")
        let savedReplacement = try JSONDecoder().decode(ProjectArchive.Envelope.self, from: Data(contentsOf: archive))
        check(savedReplacement.payload.state.settings.outputLocation == "downloads", "explicit project replacement publishes changed queue")
        check(archiveBackup.path.hasPrefix(store.root.appendingPathComponent("file-backups").path + "/"), "project backup is not placed beside the lectures")
        rejects("stale project replacement consent rejected") {
            try ProjectArchive.save(state: state, store: store, to: archive, replacing: replacementConsent)
        }
        check(try Data(contentsOf: store.journalURL(job.id)) == journalBytes, "replacement leaves paid journal untouched")
        let videoAlias = root.appendingPathComponent("Видео.lectureproject")
        try fm.linkItem(at: video, to: videoAlias)
        let unsafeVideoConsent = try FilePublication.inspect(videoAlias)!
        rejects("project output cannot replace the selected source video via hard link") {
            try ProjectArchive.save(state: state, store: store, to: videoAlias, replacing: unsafeVideoConsent)
        }

        let hiddenDamage = root.appendingPathComponent("Нельзя скрыть ошибку.lectureproject")
        try Data("{broken".utf8).write(to: store.journalURL(job.id))
        rejects("corrupt existing journal must not export as an empty job") { try ProjectArchive.save(state: state, store: store, to: hiddenDamage) }
        check(!fm.fileExists(atPath: hiddenDamage.path), "corrupt journal leaves no successful-looking project")
        try fm.removeItem(at: store.journalURL(job.id))
        rejects("missing completed journal rejected") { try ProjectArchive.save(state: state, store: store, to: hiddenDamage) }
        try journalBytes.write(to: store.journalURL(job.id))
        let symlink = root.appendingPathComponent("Ссылка.lectureproject")
        try fm.createSymbolicLink(at: symlink, withDestinationURL: archive)
        rejects("symlink destination not overwritten") { try ProjectArchive.save(state: state, store: store, to: symlink) }
        rejects("symlink input rejected") { _ = try ProjectArchive.open(from: symlink, into: importedStore) }
        let oversized = root.appendingPathComponent("Большой.lectureproject")
        fm.createFile(atPath: oversized.path, contents: Data())
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(ProjectArchive.maximumBytes + 1)); try handle.close()
        rejects("oversized sparse input rejected before loading") { _ = try ProjectArchive.open(from: oversized, into: importedStore) }
        let redirectedStore = CheckpointStore(root: root.appendingPathComponent("redirected"))
        try fm.createDirectory(at: redirectedStore.root, withIntermediateDirectories: false)
        try fm.createSymbolicLink(at: redirectedStore.root.appendingPathComponent("jobs"), withDestinationURL: importedStore.root.appendingPathComponent("jobs"))
        rejects("import cannot follow a jobs-directory symlink") { _ = try ProjectArchive.open(from: archive, into: redirectedStore) }
        check(try Data(contentsOf: source) == Data(original.utf8), "all project tests preserve original subtitle")
        print("PASS: \(passed) project archive checks. Isolated temporary state; no model requests.")
    }
}
