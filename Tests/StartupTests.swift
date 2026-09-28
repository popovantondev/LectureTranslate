import Foundation

@main
enum StartupTests {
    @MainActor static func main() async throws {
        var passed = 0
        func check(_ value: Bool, _ name: String) {
            guard value else { fputs("FAIL: \(name)\n", stderr); exit(1) }
            passed += 1
        }
        func inUse(_ model: TranslatorModel) -> Bool {
            if case .inUse? = model.queueAccessProblem { return true }; return false
        }
        func unreadable(_ model: TranslatorModel) -> Bool {
            if case .unreadable(let detail)? = model.queueAccessProblem { return !detail.isEmpty }; return false
        }
        func canonical(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StartupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        #if TRANSLATOR_DEMO
        check(TranslatorRuntime.isDemoBuild, "demo build activates only compile-time demo services")
        check(TranslatorRuntime.stateDirectory(environment: [:], previewDirectoryName: nil, applicationSupport: root) == canonical(root.appendingPathComponent("LectureTranslator2-Demo")), "demo state is isolated from production state")
        check(TranslatorRuntime.stateDirectory(environment: ["LECTURE_TRANSLATOR_STATE_DIR": root.appendingPathComponent("production-override").path], previewDirectoryName: nil, applicationSupport: root) == canonical(root.appendingPathComponent("LectureTranslator2-Demo")), "demo ignores overrides that could expose production state")
        let package = root.appendingPathComponent(".build/package.gui-acceptance", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let demoFixture = package.appendingPathComponent("demo-state", isDirectory: true)
        check(TranslatorRuntime.stateDirectory(environment: ["LECTURE_TRANSLATOR_STATE_DIR": demoFixture.path], previewDirectoryName: nil, applicationSupport: root) == canonical(demoFixture), "demo accepts a disposable fixture only inside a .build/package directory")
        check(TranslatorRuntime.stateDirectory(environment: [:], previewDirectoryName: nil, demoStateDirectory: demoFixture.path, applicationSupport: root) == canonical(demoFixture), "demo bundle metadata can select the same disposable package-local fixture")
        check(TranslatorRuntime.stateDirectory(environment: ["LECTURE_TRANSLATOR_STATE_DIR": root.appendingPathComponent(".build/elsewhere/demo-state").path], previewDirectoryName: nil, applicationSupport: root) == canonical(root.appendingPathComponent("LectureTranslator2-Demo")), "demo rejects fixture paths outside a package directory")
        let externalFixture = root.appendingPathComponent("external-demo-state", isDirectory: true)
        try FileManager.default.createDirectory(at: externalFixture, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: demoFixture, withDestinationURL: externalFixture)
        check(TranslatorRuntime.stateDirectory(environment: ["LECTURE_TRANSLATOR_STATE_DIR": demoFixture.path], previewDirectoryName: nil, applicationSupport: root) == canonical(root.appendingPathComponent("LectureTranslator2-Demo")), "demo rejects package-local symlinks that escape the disposable build state")
        do {
            _ = try CodexQuotaProbe.read(testExecutable: "/bin/false", testArguments: [], timeoutSeconds: 1)
            check(false, "demo quota guard must reject account access")
        } catch {
            check(error.localizedDescription.contains("Демо не читает"), "demo never launches Codex to read account/quota state")
        }
        do {
            _ = try CodexTranslationClient.run(prompt: "synthetic", model: "gpt-5.6-luna", effort: "medium",
                                               root: root, control: RequestControl(), testExecutable: "/bin/false", testArguments: [])
            check(false, "demo translation guard must reject Codex")
        } catch {
            check(error.localizedDescription.contains("В демо перевод отключён"), "demo never launches Codex for translation")
        }
        print("PASS: \(passed) demo isolation checks. No Codex process or account access.")
        return
        #else
        check(!TranslatorRuntime.isDemoBuild, "production test binary cannot activate demo services")
        #endif
        #if !TRANSLATOR_DEMO
        let oldOverride = ProcessInfo.processInfo.environment["LECTURE_TRANSLATOR_STATE_DIR"]
        defer {
            if let oldOverride { setenv("LECTURE_TRANSLATOR_STATE_DIR", oldOverride, 1) }
            else { unsetenv("LECTURE_TRANSLATOR_STATE_DIR") }
            try? FileManager.default.removeItem(at: root) // Only this test-owned UUID tree.
        }
        func isolated(_ name: String) throws -> URL {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            setenv("LECTURE_TRANSLATOR_STATE_DIR", directory.path, 1)
            return directory
        }

        // Pure path selection: no call below touches the real Application Support directory.
        let support = root.appendingPathComponent("simulated-application-support", isDirectory: true)
        let previewName = "LectureTranslator2-Preview"
        let preview = support.appendingPathComponent(previewName, isDirectory: true)
        let explicit = root.appendingPathComponent("explicit-test-override", isDirectory: true)
        let production = TranslatorRuntime.stateDirectory(environment: [:], previewDirectoryName: nil, applicationSupport: support)
        check(production == canonical(support.appendingPathComponent("LectureTranslator2")), "production state resolves inside Application Support")
        check(TranslatorRuntime.stateDirectory(environment: [:], previewDirectoryName: previewName, applicationSupport: support) == canonical(preview), "preview uses a stable app-specific Application Support folder")
        let movedBundleState = TranslatorRuntime.stateDirectory(environment: [:], previewDirectoryName: previewName, applicationSupport: support)
        check(movedBundleState == canonical(preview), "Finder-style relaunch after moving the bundle resolves the same preview state")
        check(TranslatorRuntime.stateDirectory(environment: [:], previewDirectoryName: previewName, applicationSupport: support) != production, "preview state remains separate from the production queue")
        check(TranslatorRuntime.stateDirectory(environment: ["LECTURE_TRANSLATOR_STATE_DIR": explicit.path], previewDirectoryName: previewName, applicationSupport: support) == canonical(explicit), "explicit test environment overrides baked preview destination")
        check(TranslatorRuntime.stateDirectory(environment: ["LECTURE_TRANSLATOR_STATE_DIR": explicit.path], previewDirectoryName: nil, applicationSupport: support) == canonical(explicit), "explicit environment also isolates a release executable")
        check(TranslatorRuntime.stateDirectory(environment: [:], previewDirectoryName: nil, applicationSupport: support) == production, "path selection never changes subsequent production default")
        check(TranslatorRuntime.stateDirectory(environment: ["LECTURE_TRANSLATOR_STATE_DIR": ""], previewDirectoryName: "", applicationSupport: support) == production, "empty overrides cannot redirect state to the working directory")
        check(TranslatorRuntime.stateDirectory(environment: ["LECTURE_TRANSLATOR_STATE_DIR": ""], previewDirectoryName: previewName, applicationSupport: support) == canonical(preview), "empty environment preserves baked preview isolation")
        check(TranslatorRuntime.stateDirectory(environment: [:], previewDirectoryName: "../LectureTranslator2", applicationSupport: support) == production, "invalid preview state name cannot escape Application Support")
        check(!FileManager.default.fileExists(atPath: support.path) && !FileManager.default.fileExists(atPath: preview.path) && !FileManager.default.fileExists(atPath: explicit.path), "stateDirectory path selection does not create directories")
        check(ExistingTranslator.recognizesBundleIdentifier("local.lecturetranslator.v2"), "production owner identity is recognized")
        check(ExistingTranslator.recognizesBundleIdentifier("local.lecturetranslator.v2.preview"), "exact preview bundle identity is recognized")
        check(ExistingTranslator.recognizesBundleIdentifier("local.lecturetranslator.v2.preview.demo"), "namespaced preview owner identity is recognized")
        check(!ExistingTranslator.recognizesBundleIdentifier("local.lecturetranslator.v2.previewish"), "similar but unrelated bundle identity is rejected")
        check(!ExistingTranslator.recognizesBundleIdentifier("local.lecturetranslator.v2.other"), "other bundle identity is rejected")

        do {
            _ = try await CodexQuotaConnection(testExecutable: root.appendingPathComponent("missing-codex").path,
                                               testArguments: [], timeoutSeconds: 1, testEnvironment: ["PATH": ""] ).read()
            check(false, "missing Codex fails safely")
        } catch {
            check(error.localizedDescription.contains("Не удалось запустить Codex CLI"), "missing Codex reports a local launch failure without a model call")
        }

        let shared = try isolated("shared-queue")
        let first = TranslatorModel()
        defer { first.shutdown(); first.stateLock = nil }
        check(first.store.root == canonical(shared), "first model uses only isolated state root")
        check(first.writable && first.queueAccessProblem == nil && first.error == nil && first.stateLock != nil, "first model owns a new queue without error")
        let sourceText = "17\n00:00:01,000 --> 00:00:20,000\nEine erste Aussage.\n\n39\n00:00:21,000 --> 00:00:40,000\nEine zweite Aussage.\n"
        let document = try SRTDocument.parse(Data(sourceText.utf8))
        var settings = TranslationSettings(); settings.model = "gpt-5.6-luna"; settings.effort = "high"
        settings.outputStyle = "display"; settings.reserve = 22; settings.profileID = "nutrition"
        let profile = TranslationProfile.builtIns.first(where: { $0.id == "nutrition" })!
        let parts = document.cues.enumerated().map { index, cue in
            TranslationPart(id: index + 1, cueIDs: [cue.id], startMS: cue.startMS, endMS: cue.endMS, characters: cue.text.count, boundaryWarning: false)
        }
        let lecture = PreparedLecture(version: PreparedLecture.pipelineVersion, document: document, parts: parts, issues: [], videoPaths: [], profile: profile, settings: settings)
        // Deliberately absent source: even an accidental auto-resume cannot reach a model/quota call.
        var job = JobSummary(sourcePath: shared.appendingPathComponent("missing-source.srt").path)
        job.sourceHash = document.sourceHash; job.partCount = 2; job.cueCount = 2; job.completedCues = 1; job.status = .paused
        var journal = TranslationJournal(sourceHash: document.sourceHash, settings: settings, profile: profile)
        journal.parts[1] = .init(draftAttempts: 1, draft: .init(reply: .init(translations: [.init(id: 17, text: "Первое высказывание.")], issues: []),
            usage: nil, model: "local-fixture", effort: "medium", elapsed: 0), done: true)
        first.state.settings = settings; first.state.jobs = [job]; first.state.manuallyPaused = true; first.state.translationPending = false
        try first.store.save(lecture, id: job.id); try first.store.saveJournal(journal, id: job.id)
        first.selection = job.id; first.save(); first.loadSelection()
        let queueURL = shared.appendingPathComponent("queue.json"), journalURL = first.store.journalURL(job.id)
        let savedQueue = try Data(contentsOf: queueURL), savedJournal = try Data(contentsOf: journalURL)

        let second = TranslatorModel()
        defer { second.shutdown(); second.stateLock = nil }
        check(second.store.root == canonical(shared), "second model resolves the same isolated queue")
        check(!second.writable && second.stateLock == nil && inUse(second), "second model displays read-only inUse state")
        check(second.error == nil, "second launch is not shown as a generic failure alert")
        check(second.state.jobs.isEmpty && second.lecture == nil && second.journal == nil, "blocked startup does not invent or load editable translations")
        second.state.settings.reserve = 99; second.state.jobs = [JobSummary(sourcePath: shared.appendingPathComponent("unwanted.srt").path)]
        second.save()
        check(try Data(contentsOf: queueURL) == savedQueue, "read-only save cannot overwrite another owner's queue")
        check(try Data(contentsOf: journalURL) == savedJournal, "read-only startup and save preserve paid journal bytes")
        check(!second.retryOpeningQueue() && !second.writable && inUse(second) && second.error == nil, "retry remains a non-error read-only state while owner is alive")
        check(try Data(contentsOf: queueURL) == savedQueue, "failed retry cannot publish placeholder state")
        first.shutdown(); first.writable = false; first.stateLock = nil
        check(second.retryOpeningQueue(), "retry opens queue after first owner releases its lock")
        check(second.writable && second.queueAccessProblem == nil && second.stateLock != nil && second.error == nil, "successful retry restores writable normal state")
        check(second.state.jobs.count == 1 && second.state.jobs.first?.id == job.id && second.state.jobs.first?.completedCues == 1,
              "successful retry reloads saved job identity and partial progress, not placeholder edits")
        check(second.state.settings == settings, "successful retry reloads saved settings")
        check(second.selection == job.id && second.lecture?.document == document && second.journal?.translated[17] == "Первое высказывание.", "successful retry reloads selected prepared lecture and paid text")
        check(second.journal?.parts[1]?.draftAttempts == 1 && second.journal?.translated.count == 1, "opening does not repeat or invent translation work")
        check(!second.busy && !second.translating && !second.quotaBusy, "retry does not start translation or quota requests")
        check(try Data(contentsOf: journalURL) == savedJournal, "successful retry preserves existing journal bytes")
        check(!FileManager.default.fileExists(atPath: shared.appendingPathComponent("requests").path), "neither startup nor retry creates a model request directory")
        second.shutdown(); second.stateLock = nil; second.writable = false

        let corruptRoot = try isolated("corrupt-queue")
        let badURL = corruptRoot.appendingPathComponent("queue.json")
        let corruptBytes = Data("{\"jobs\": [BROKEN; do not discard this file\n".utf8)
        try corruptBytes.write(to: badURL)
        let broken = TranslatorModel()
        defer { broken.shutdown(); broken.stateLock = nil }
        check(!broken.writable && unreadable(broken) && broken.error == nil, "corrupt queue gets a dedicated read-only recovery state")
        check(broken.stateLock == nil, "failed reader releases its acquired queue lock")
        broken.state.jobs = [JobSummary(sourcePath: corruptRoot.appendingPathComponent("never-save.srt").path)]; broken.save()
        check(try Data(contentsOf: badURL) == corruptBytes, "opening and read-only save preserve corrupt bytes for recovery")
        do { let recoveryLock = try TranslationStateLock(root: corruptRoot); withExtendedLifetime(recoveryLock) {} }
        check(true, "a separate recovery owner can acquire the lock while failed reader still exists")
        check(!broken.retryOpeningQueue() && unreadable(broken) && broken.stateLock == nil, "retrying corrupt data fails safely and releases the lock again")
        check(try Data(contentsOf: badURL) == corruptBytes, "corrupt retry cannot overwrite evidence")
        var restored = ProjectState(); restored.manuallyPaused = true; restored.settings.reserve = 31
        try CheckpointStore(root: corruptRoot).save(restored) // Test-owned repair, no user file involved.
        check(broken.retryOpeningQueue() && broken.writable && broken.queueAccessProblem == nil && broken.state.settings.reserve == 31,
              "reader can recover after the isolated corrupt queue is repaired")
        broken.shutdown(); broken.stateLock = nil; broken.writable = false

        let staleRoot = try isolated("stale-lock")
        let staleURL = staleRoot.appendingPathComponent("queue.lock"), staleBytes = Data("stale owner hint; no process owns this lock".utf8)
        try staleBytes.write(to: staleURL)
        let stale = TranslatorModel()
        defer { stale.shutdown(); stale.stateLock = nil }
        check(stale.writable && stale.queueAccessProblem == nil && stale.error == nil, "stale queue.lock without kernel owner is not an error")
        check(try Data(contentsOf: staleURL) == staleBytes, "startup never truncates or replaces stale lock metadata")
        stale.shutdown(); stale.stateLock = nil; stale.writable = false
        check(!FileManager.default.fileExists(atPath: corruptRoot.appendingPathComponent("requests").path) && !FileManager.default.fileExists(atPath: staleRoot.appendingPathComponent("requests").path), "all startup scenarios stay offline")

        // The delegate and SwiftUI must share this one lazily created session, even
        // if no Window has been mounted. No delegate/UI lifecycle is invoked here.
        let sessionRoot = try isolated("application-session")
        let session = TranslatorApplicationSession.model
        defer { session.shutdown(); session.stateLock = nil; session.writable = false }
        check(session.store.root == canonical(sessionRoot), "lazy application session uses the explicitly isolated environment at first access")
        check(session.writable && session.stateLock != nil && session.error == nil, "application session acquires exactly one usable queue lock")
        session.state.manuallyPaused = true; session.state.translationPending = false
        var sessionJob = JobSummary(sourcePath: sessionRoot.appendingPathComponent("missing-session-source.srt").path)
        sessionJob.status = .paused; sessionJob.cueCount = 7; sessionJob.completedCues = 3
        session.state.jobs = [sessionJob]; session.save()
        let differentRoot = root.appendingPathComponent("must-not-create-another-session")
        setenv("LECTURE_TRANSLATOR_STATE_DIR", differentRoot.path, 1)
        let sameSession = TranslatorApplicationSession.model
        check(session === sameSession, "application session has one model identity per process")
        check(sameSession.store.root == canonical(sessionRoot) && sameSession.state.jobs.first?.completedCues == 3,
              "changing environment after lazy initialization cannot move the session or lose its progress")
        check(!FileManager.default.fileExists(atPath: differentRoot.path), "reaccessing singleton never initializes a second state directory")
        setenv("LECTURE_TRANSLATOR_STATE_DIR", sessionRoot.path, 1)
        let sessionContender = TranslatorModel()
        defer { sessionContender.shutdown(); sessionContender.stateLock = nil }
        check(!sessionContender.writable && inUse(sessionContender) && sessionContender.error == nil,
              "a separate model cannot acquire the singleton's queue lock")
        check(!session.busy && !session.translating && !session.quotaBusy && session.state.manuallyPaused,
              "singleton access does not invoke translation, quota or UI lifecycle")
        check(!FileManager.default.fileExists(atPath: sessionRoot.appendingPathComponent("requests").path),
              "singleton tests create no model requests")
        print("PASS: \(passed) startup checks. Isolated state only; no GUI, model, quota service or production queue.")
        #endif
    }
}
