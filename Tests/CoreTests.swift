import Foundation

@main
enum CoreTests {
    static var passed = 0
    static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else { fputs("FAIL: \(name)\n", stderr); exit(1) }
        passed += 1
    }
    static func rejects(_ name: String, _ body: () throws -> Void) {
        do { try body(); fputs("FAIL: \(name) did not reject\n", stderr); exit(1) }
        catch { passed += 1 }
    }
    static func main() throws {
        let original = "42\n00:00:01,123 --> 00:00:05,456\nDie erste Zeile.\n\n105\n00:00:05,500 --> 00:00:09,000\nNicht verwenden.\n"
        let document = try SRTDocument.parse(Data(original.utf8))
        check(document.cues.map(\.id) == [42, 105], "nonconsecutive IDs preserved")
        check(document.cues[0].startMS == 1123, "milliseconds")
        check(abs(document.cues[0].seconds - 4.333) < 0.0001, "precise duration")
        let windows = try SRTDocument.parse(Data(("\u{FEFF}" + original.replacingOccurrences(of: "\n", with: "\r\n")).utf8))
        check(windows.cues == document.cues, "BOM and CRLF")
        let spaces = try SRTDocument.parse(Data(original.replacingOccurrences(of: "\n\n", with: "\n  \n\n").utf8))
        check(spaces.cues == document.cues, "blank space separator")
        rejects("empty source") { _ = try SRTDocument.parse(Data()) }
        rejects("bad encoding") { _ = try SRTDocument.parse(Data([0xFF, 0xAB, 0xFE])) }
        rejects("bad minute") { _ = try SRTDocument.parse(Data(original.replacingOccurrences(of: "00:00:01,123", with: "00:60:01,123").utf8)) }
        rejects("bad second") { _ = try SRTDocument.parse(Data(original.replacingOccurrences(of: "00:00:01,123", with: "00:00:61,123").utf8)) }
        let negativeWindow = try SRTDocument.parse(Data(original.replacingOccurrences(of: "00:00:05,456", with: "00:00:00,000").utf8))
        check(SRTTimingRepair.diagnose(negativeWindow.cues).contains { $0.kind == .negativeDuration }, "negative duration diagnosed without discarding source")
        rejects("duplicate ID") { _ = try SRTDocument.parse(Data(original.replacingOccurrences(of: "105\n", with: "42\n").utf8)) }
        let outOfOrder = try SRTDocument.parse(Data(original.replacingOccurrences(of: "00:00:05,500", with: "00:00:00,999").utf8))
        check(SRTTimingRepair.diagnose(outOfOrder.cues).contains { $0.kind == .outOfOrder }, "out-of-order source diagnosed")
        let overlapText = "7\n00:00:01,000 --> 00:00:05,000\nText A.\n\n11\n00:00:04,000 --> 00:00:06,000\nText B.\n"
        let overlapData = Data(overlapText.utf8), overlapDoc = try SRTDocument.parse(overlapData)
        let overlapProblem = SRTTimingRepair.diagnose(overlapDoc.cues).first { $0.kind == .overlap }!
        check(overlapProblem.newEndMS == 4000 && overlapProblem.previousID == 7, "overlap offers only previous end clamped to next start")
        let repairedTiming = try SRTTimingRepair.repairData(overlapData, problem: overlapProblem)
        let repairedDoc = try SRTDocument.parse(repairedTiming)
        check(repairedDoc.cues.map(\.id) == overlapDoc.cues.map(\.id) && repairedDoc.cues.map(\.text) == overlapDoc.cues.map(\.text), "timing repair preserves IDs and text")
        check(repairedDoc.cues[0].endMS == 4000 && SRTTimingRepair.diagnose(repairedDoc.cues).isEmpty, "minimal overlap repair reparses cleanly")
        let crlfOverlap = Data(overlapText.replacingOccurrences(of: "\n", with: "\r\n").utf8)
        let crlfProblem = SRTTimingRepair.diagnose(try SRTDocument.parse(crlfOverlap).cues).first { $0.kind == .overlap }!
        let crlfRepair = try SRTTimingRepair.repairData(crlfOverlap, problem: crlfProblem)
        check(String(decoding: crlfRepair, as: UTF8.self).contains("\r\n") && !String(decoding: crlfRepair, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "").contains("\n"), "CRLF repair preserves line endings")
        let staleProblem = TimingProblem(kind: .overlap, cueIndex: overlapProblem.cueIndex, cueID: overlapProblem.cueID,
            previousID: overlapProblem.previousID, oldStartMS: overlapProblem.oldStartMS, oldEndMS: 7000,
            newStartMS: nil, newEndMS: overlapProblem.newEndMS)
        rejects("stale preview boundaries are rejected") { _ = try SRTTimingRepair.repairData(overlapData, problem: staleProblem) }
        let equalStarts = try SRTDocument.parse(Data("1\n00:00:01,000 --> 00:00:05,000\nA.\n\n2\n00:00:01,000 --> 00:00:06,000\nB.\n".utf8))
        check(SRTTimingRepair.diagnose(equalStarts.cues).first(where: { $0.kind == .overlap })?.newEndMS == nil, "equal starts are ambiguous and never repaired")
        let zeroDoc = try SRTDocument.parse(Data("1\n00:00:02,000 --> 00:00:02,000\nText.\n".utf8))
        check(SRTTimingRepair.diagnose(zeroDoc.cues).first?.kind == .zeroDuration && SRTTimingRepair.diagnose(zeroDoc.cues).first?.newEndMS == nil, "zero duration reported without guessed fix")
        rejects("empty cue text") { _ = try SRTDocument.parse(Data("1\n00:00:01,000 --> 00:00:02,000\n<i></i>".utf8)) }
        let translated = try document.render(translations: [42: "Первая строка.", 105: "Не использовать."])
        let rendered = try SRTDocument.parse(Data(translated.utf8))
        check(rendered.cues.map(\.timingLine) == document.cues.map(\.timingLine), "timestamps identical after rendering")
        check(rendered.cues.map(\.id) == [42, 105], "rendered IDs identical")
        rejects("missing translation") { _ = try document.render(translations: [42: "Текст"]) }
        rejects("extra translation") { _ = try document.render(translations: [42: "Текст", 105: "Текст", 106: "Лишнее"]) }
        rejects("empty translation") { _ = try document.render(translations: [42: " ", 105: "Текст"]) }
        check(SRTDocument.wrap(String(repeating: "слово ", count: 60)).split(separator: "\n").count > 2, "wrapping never truncates")
        check(document.sourceHash != SRTDocument.hash(Data((original + "\n").utf8)), "exact source hash")

        let cues = (1...800).map { i in Cue(id: i * 2, startMS: i * 3000, endMS: i * 3000 + 2800,
            timingLine: "", text: String(repeating: "Eine längere Aussage ", count: 4) + (i % 4 == 0 ? "." : ",")) }
        let parts = PreparedLecture.split(cues)
        check(parts.count > 1, "large lecture splits")
        check(parts.flatMap(\.cueIDs) == cues.map(\.id), "no duplicate or dropped IDs in parts")
        check(parts.allSatisfy { !$0.cueIDs.isEmpty }, "no empty parts")
        check(parts.dropLast().allSatisfy { !$0.boundaryWarning }, "sentence boundaries preferred")
        let noPunctuation = cues.map { Cue(id: $0.id, startMS: $0.startMS, endMS: $0.endMS, timingLine: "", text: String(repeating: "Wort ", count: 40)) }
        check(PreparedLecture.split(noPunctuation).dropLast().allSatisfy(\.boundaryWarning), "unpunctuated boundaries flagged")
        let context = PreparedLecture.context(cues, backwards: true, sentences: 4, maxCharacters: 2600)
        check(context.map(\.id) == context.map(\.id).sorted(), "backward context returns source order")
        check(context.reduce(0) { $0 + $1.text.count } <= 2600, "context cap")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lecture-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) } // Only this test-owned UUID directory.
        let source = root.appendingPathComponent("Лекция.srt")
        try Data(original.utf8).write(to: source)
        let repairSource = root.appendingPathComponent("repair.srt")
        try overlapData.write(to: repairSource)
        let backup = try SRTTimingRepair.replaceSource(repairSource, with: repairedTiming, expectedHash: overlapDoc.sourceHash)
        let backupBytes = try Data(contentsOf: backup)
        let replacedSource = try SRTDocument.parse(Data(contentsOf: repairSource))
        check(backupBytes == overlapData, "source bytes retained in recoverable timing backup")
        check(replacedSource.cues[0].endMS == 4000, "confirmed source replacement writes reparsable repaired SRT")
        rejects("changed source is not replaced") { _ = try SRTTimingRepair.replaceSource(repairSource, with: repairedTiming, expectedHash: overlapDoc.sourceHash) }
        let changedAfterPreview = root.appendingPathComponent("changed-after-preview.srt")
        try overlapData.write(to: changedAfterPreview)
        try Data((overlapText + "\n").utf8).write(to: changedAfterPreview)
        rejects("source changed after preview remains untouched") { _ = try SRTTimingRepair.replaceSource(changedAfterPreview, with: repairedTiming, expectedHash: overlapDoc.sourceHash) }
        let changedAfterPreviewBytes = try Data(contentsOf: changedAfterPreview)
        check(changedAfterPreviewBytes == Data((overlapText + "\n").utf8), "post-preview external edit preserved")
        let failedWrite = root.appendingPathComponent("failed-write.srt")
        try overlapData.write(to: failedWrite)
        rejects("write failure is reported") {
            _ = try SRTTimingRepair.replaceSource(failedWrite, with: repairedTiming, expectedHash: overlapDoc.sourceHash) { _, _ in
                throw TranslatorError.invalid("injected write failure")
            }
        }
        let failureFiles = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let failedBackup = failureFiles.first { $0.lastPathComponent.hasPrefix("failed-write.srt.timing-backup-") }
        let failedWriteBytes = try Data(contentsOf: failedWrite)
        let failedBackupBytes = try failedBackup.map { try Data(contentsOf: $0) }
        check(failedWriteBytes == overlapData, "write failure leaves source intact")
        check(failedBackupBytes == overlapData, "write failure retains recoverable backup")
        try FileManager.default.removeItem(at: repairSource)
        let scannerRoot = root.appendingPathComponent("scanner-fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: scannerRoot, withIntermediateDirectories: false)
        let scannerSource = scannerRoot.appendingPathComponent("Лекция.srt")
        try Data(original.utf8).write(to: scannerSource)
        try Data().write(to: scannerRoot.appendingPathComponent("Лекция.mp4"))
        try Data().write(to: scannerRoot.appendingPathComponent("Лекция.ru.srt"))
        try Data().write(to: scannerRoot.appendingPathComponent("Лекция.part-01.srt"))
        try Data().write(to: scannerRoot.appendingPathComponent("Лекция_RU.srt"))
        check(SourceScanner.scan([scannerRoot, scannerSource], recursive: true).count == 1, "scanner excludes generated SRT and duplicate paths")
        check(PreparedLecture.matchingVideos(scannerSource).count == 1, "video matching")
        try Data().write(to: scannerRoot.appendingPathComponent("Лекция.mkv"))
        check(PreparedLecture.matchingVideos(scannerSource).count == 2, "ambiguous video not guessed")
        let lecture = try PreparedLecture.prepare(url: source, profile: .builtIns[0], settings: TranslationSettings())
        let prompt = lecture.prompt(for: lecture.parts[0])
        check(prompt.contains("42|4.333|Die erste Zeile."), "compact duration input")
        check(!prompt.contains("00:00:01,123"), "full timestamps not sent")
        check(prompt.contains("Числа, единицы"), "spoken numbers instruction")
        check(lecture.issues.contains { $0.cueID == 105 }, "source negation flags independent of model")
        let overlap = [Cue(id: 1, startMS: 0, endMS: 5000, timingLine: "", text: "Ja."), Cue(id: 2, startMS: 3000, endMS: 6000, timingLine: "", text: "Ja.")]
        check(PreparedLecture.inspect(overlap).contains( where: \.critical), "overlap flagged")
        let store = CheckpointStore(root: root.appendingPathComponent("state"))
        let emptyState = try store.load()
        check(emptyState.jobs.isEmpty, "new queue")
        var state = ProjectState(); state.manuallyPaused = true; state.jobs = [JobSummary(sourcePath: source.path)]
        try store.save(state); try store.save(lecture, id: state.jobs[0].id)
        let restored = try store.load()
        check(restored.manuallyPaused, "manual pause persisted")
        check(restored.settings.reserve == 15, "15 percent reserve default")
        check(restored.settings.model == "gpt-6-luna" && restored.settings.effort == "medium", "GPT-6 Luna Medium is the new default")
        check(restored.settings.reviewModel == "gpt-6-sol" && restored.settings.reviewEffort == "medium", "GPT-6 Sol Medium is the new risk-review default")
        let restoredLecture = try store.loadLecture(state.jobs[0].id)
        check(restoredLecture.document == document, "source mapping survives restart")
        check(restoredLecture.completedTranslations.isEmpty, "preparation is not fake translation")
        let encodedOldShape = try JSONEncoder().encode(JobSummary(sourcePath: "/tmp/old.srt"))
        var oldJobObject = try JSONSerialization.jsonObject(with: encodedOldShape) as! [String: Any]
        oldJobObject["message"] = "Original saved error"
        oldJobObject.removeValue(forKey: "messagePresentation")
        let legacyJobJSON = try JSONSerialization.data(withJSONObject: oldJobObject)
        let legacyJob = try JSONDecoder().decode(JobSummary.self, from: legacyJobJSON)
        check(legacyJob.messagePresentation == nil && legacyJob.message == "Original saved error", "old job JSON without presentation retains its exact legacy message")
        var newJob = JobSummary(sourcePath: "/tmp/new.srt"); newJob.message = "Legacy fallback"; newJob.messagePresentation = StatusMessagePresentation(key: "status.queued")
        let newJobRoundTrip = try JSONDecoder().decode(JobSummary.self, from: JSONEncoder().encode(newJob))
        check(newJobRoundTrip.messagePresentation == newJob.messagePresentation && newJobRoundTrip.message == newJob.message, "new presentation round trips without replacing message")
        let sourceAfter = try Data(contentsOf: source)
        check(sourceAfter == Data(original.utf8), "source remains untouched")
        try Data("broken".utf8).write(to: root.appendingPathComponent("state/queue.json"))
        rejects("damaged checkpoint") { _ = try store.load() }

        let now = Date(timeIntervalSince1970: 2_000_000_000)
        func quota(_ primary: String, _ secondary: String, reached: String = "null") throws -> QuotaSnapshot {
            let json = "{\"rateLimitsByLimitId\":{\"codex\":{\"primary\":\(primary),\"secondary\":\(secondary),\"rateLimitReachedType\":\(reached)}}}"
            return try QuotaSnapshot.decodeResult(Data(json.utf8), now: now)
        }
        func window(_ used: Int, _ minutes: Int, _ after: Int) -> String {
            "{\"usedPercent\":\(used),\"windowDurationMins\":\(minutes),\"resetsAt\":\(2_000_000_000 + after)}"
        }
        let normal = try quota(window(10, 300, 3000), window(40, 10080, 10000))
        check(normal.decision(reserve: 15, now: now) == .allowed, "quota available")
        let weeklyBlocked = try quota(window(4, 300, 3000), window(93, 10080, 10000))
        check(weeklyBlocked.decision(reserve: 15, now: now) == .waiting(now.addingTimeInterval(10060)), "weekly reserve blocks")
        let fiveBlocked = try quota(window(85, 300, 3000), window(40, 10080, 10000))
        check(fiveBlocked.decision(reserve: 15, now: now) == .waiting(now.addingTimeInterval(3060)), "15 percent inclusive threshold")
        let bothBlocked = try quota(window(100, 300, 3000), window(100, 10080, 10000))
        check(bothBlocked.decision(reserve: 15, now: now) == .waiting(now.addingTimeInterval(10060)), "wait for both limiting windows")
        check(normal.decision(reserve: 15, now: now.addingTimeInterval(121)) == .unknown, "stale quota cannot authorize")
        check(normal.decision(reserve: 15, now: now.addingTimeInterval(-30)) == .unknown, "clock rollback cannot authorize")
        let missing = try quota("null", window(0, 10080, 10000))
        check(missing.decision(reserve: 15, now: now) == .unknown, "missing is not zero")
        let wrongRange = try quota(window(-1, 300, 3000), window(0, 10080, 10000))
        check(wrongRange.decision(reserve: 15, now: now) == .unknown, "invalid percent cannot authorize")
        let serverBlocked = try quota(window(0, 300, 3000), window(0, 10080, 10000), reached: "\"usage_limit\"")
        check(serverBlocked.decision(reserve: 15, now: now) == .unknown, "server limit takes precedence")
        rejects("unknown bucket") { _ = try QuotaSnapshot.decodeResult(Data("{\"rateLimitsByLimitId\":{\"other\":{}}}".utf8)) }
        let rpcServer = #"""
        while IFS= read -r request; do
          case "$request" in
            *'"method":"initialize"'*) printf '%s\n' '{"id":1,"result":{}}' ;;
            *'rateLimits'*) printf '%s\n' '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":4,"windowDurationMins":300,"resetsAt":2100000000},"secondary":{"usedPercent":93,"windowDurationMins":10080,"resetsAt":2100001000}}}}'; exit 0 ;;
          esac
        done
        """#
        let rpcSnapshot = try CodexQuotaProbe.read(testExecutable: "/bin/sh", testArguments: ["-c", rpcServer], timeoutSeconds: 3)
        check(rpcSnapshot.weekly?.remaining == 7, "streamed small RPC response does not deadlock")
        let brokenServer = #"""
        IFS= read -r request
        exec 0<&-
        printf '%s\n' '{"id":1,"result":{}}'
        sleep 0.1
        """#
        rejects("child closing input does not kill caller with SIGPIPE") {
            _ = try CodexQuotaProbe.read(testExecutable: "/bin/sh", testArguments: ["-c", brokenServer], timeoutSeconds: 2)
        }
        for (name, server) in [
            ("SIGTERM ignored", "trap '' TERM; while :; do :; done"),
            ("descendant retains stdout", "sleep 1 & exit 0"),
            ("incomplete JSON line", "printf '{\"id\":'; exec sleep 2"),
            ("blocked request pipe", "trap '' TERM; while :; do printf '{\"id\":1,\"result\":{}}\\n'; done")
        ] {
            let started = ProcessInfo.processInfo.systemUptime
            rejects("quota deadline: \(name)") {
                _ = try CodexQuotaProbe.read(testExecutable: "/bin/sh", testArguments: ["-c", server], timeoutSeconds: 0.15)
            }
            check(ProcessInfo.processInfo.systemUptime - started < 1.25, "bounded quota I/O: \(name)")
        }
        let cancelAt = ProcessInfo.processInfo.systemUptime + 0.15
        do {
            _ = try CodexQuotaProbe.read(testExecutable: "/bin/sh", testArguments: ["-c", "trap '' TERM; while :; do :; done"], timeoutSeconds: 4,
                                        isCancelled: { ProcessInfo.processInfo.systemUptime >= cancelAt })
            check(false, "cancelled quota must stop")
        } catch is CancellationError { check(true, "quota cancellation propagated") }
        check(ProcessInfo.processInfo.systemUptime - cancelAt < 1, "quota cancellation does not wait for deadline")
        rejects("zero quota timeout rejected") { _ = try CodexQuotaProbe.read(testExecutable: "/bin/false", timeoutSeconds: 0) }
        rejects("infinite quota timeout rejected") { _ = try CodexQuotaProbe.read(testExecutable: "/bin/false", timeoutSeconds: .infinity) }
        rejects("cancelled quota does not launch") { _ = try CodexQuotaProbe.read(testExecutable: "/does-not-exist", isCancelled: { true }) }
        let proJSON = "{\"rateLimits\":{\"planType\":\"prolite\",\"primary\":\(window(10, 10080, 10000)),\"secondary\":null}}"
        let pro = try QuotaSnapshot.decodeResult(Data(proJSON.utf8), now: now)
        check(pro.weeklyOnly && pro.decision(reserve: 15, now: now) == .allowed, "Pro weekly-only quota authorizes without invented five-hour allowance")
        let proLow = try QuotaSnapshot.decodeResult(Data(proJSON.replacingOccurrences(of: "\"usedPercent\":10", with: "\"usedPercent\":99").utf8), now: now)
        check(proLow.decision(reserve: 15, now: now) == .waiting(now.addingTimeInterval(10060)), "Pro weekly-only reserve enforced")
        let plusMissing = try QuotaSnapshot.decodeResult(Data(proJSON.replacingOccurrences(of: "prolite", with: "plus").utf8), now: now)
        check(plusMissing.decision(reserve: 15, now: now) == .unknown, "Plus missing five-hour stays unknown")
        let reply = TranslationReply(translations: [.init(id: 42, text: "Первая строка."), .init(id: 105, text: "Не использовать.")], issues: [])
        let rows = try reply.validated(ids: [42, 105])
        check(rows.count == 2, "strict translation reply validation")
        rejects("duplicated model ID") { _ = try TranslationReply(translations: [.init(id: 42, text: "Один"), .init(id: 42, text: "Два")], issues: []).validated(ids: [42, 105]) }
        rejects("missing model ID") { _ = try reply.validated(ids: [42, 105, 106]) }
        rejects("foreign issue ID") { _ = try TranslationReply(translations: reply.translations, issues: [.init(ids: [999], reason: "Неясно", critical: true)]).validated(ids: [42, 105]) }
        rejects("empty model text") { _ = try TranslationReply(translations: [.init(id: 42, text: " ")], issues: []).validated(ids: [42]) }
        rejects("timing injected in text") { _ = try TranslationReply(translations: [.init(id: 42, text: "--> тест")], issues: []).validated(ids: [42]) }
        var journal = TranslationJournal(sourceHash: document.sourceHash, settings: lecture.settings, profile: lecture.profile)
        let result = ModelResult(reply: reply, usage: nil, model: "gpt-5.6-terra", effort: "medium", elapsed: 0)
        if case .draft(let part) = TranslationPipeline.next(lecture: lecture, journal: journal) { check(part.id == 1, "new part drafts") }
        else { check(false, "new part should draft") }
        journal.parts[1] = PartProgress(draftAttempts: 1, draft: result)
        if case .review = TranslationPipeline.next(lecture: lecture, journal: journal) { check(true, "risk or independent sample requires review") }
        else { check(false, "review missing") }
        journal.parts[1]!.review = result
        if case .finalize = TranslationPipeline.next(lecture: lecture, journal: journal) { check(true, "saved review not repeated") }
        else { check(false, "review should finalize") }
        journal.parts[1]!.done = true
        if case .complete = TranslationPipeline.next(lecture: lecture, journal: journal) { check(true, "finished parts skipped") }
        else { check(false, "finished journal should complete") }
        try journal.validate(lecture: lecture)
        rejects("incomplete output cannot export") { _ = try TranslationPipeline.export(lecture: lecture, journal: TranslationJournal(sourceHash: document.sourceHash, settings: lecture.settings, profile: lecture.profile), to: root.appendingPathComponent("incomplete.srt")) }
        let translatedURL = root.appendingPathComponent("output.ru.srt")
        try TranslationPipeline.export(lecture: lecture, journal: journal, to: translatedURL)
        let produced = try SRTDocument.parse(Data(contentsOf: translatedURL))
        check(produced.cues.map(\.timingLine) == document.cues.map(\.timingLine), "pipeline export preserves exact timings")
        rejects("existing output never overwritten") { try TranslationPipeline.export(lecture: lecture, journal: journal, to: translatedURL) }
        let originalBytes = try Data(contentsOf: source)
        rejects("original cannot be overwritten through export") { try TranslationPipeline.export(lecture: lecture, journal: journal, to: source) }
        let bytesAfterExport = try Data(contentsOf: source)
        check(bytesAfterExport == originalBytes, "export collision preserves source bytes")
        let journalStore = CheckpointStore(root: root.appendingPathComponent("journal-state"))
        let jobID = UUID()
        try journalStore.saveJournal(journal, id: jobID)
        let restoredJournal = try journalStore.journal(jobID, lecture: lecture)
        check(restoredJournal.parts[1]?.done == true && restoredJournal.translated[105] == "Не использовать.", "translation resumes from disk")
        check(restoredJournal.parts[1]?.draftAttempts == 1, "attempt budget persists")
        let changedSource = SRTDocument(sourceHash: "different", cues: document.cues)
        let changed = PreparedLecture(version: 1, document: changedSource, parts: lecture.parts, issues: [], videoPaths: [], profile: lecture.profile, settings: lecture.settings)
        rejects("changed source cannot reuse translation") { try journal.validate(lecture: changed) }
        journal.parts[1]!.review = nil; journal.parts[1]!.reviewSkipped = true
        check(journal.issues(for: lecture).contains(where: { $0.reason.contains("предел") }), "review cap does not silently declare quality")
        check(TranslationPipeline.destination(source: root.appendingPathComponent("file.de.srt")).lastPathComponent == "file.ru.srt", "canonical output naming")
        let cancelled = RequestControl(); cancelled.cancel()
        rejects("cancelled request does not launch") { _ = try CodexTranslationClient.run(prompt: "test", model: "gpt-5.6-terra", effort: "medium", root: root, control: cancelled, testExecutable: "/bin/false") }
        let mockAnswer = #"{"translations":[{"id":42,"text":"Первая строка."},{"id":105,"text":"Не использовать."}],"issues":[]}"#
        let mockEvent = try JSONSerialization.data(withJSONObject: ["type":"item.completed", "item":["type":"agent_message", "text":mockAnswer]])
        let mockLines = String(data: mockEvent, encoding: .utf8)! + "\n{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":20,\"cached_input_tokens\":5,\"output_tokens\":10}}\n"
        let mockFile = root.appendingPathComponent("events.jsonl"); try Data(mockLines.utf8).write(to: mockFile)
        let mocked = try CodexTranslationClient.run(prompt: "test", model: "gpt-5.6-terra", effort: "medium", root: root, control: RequestControl(), testExecutable: "/bin/cat", testArguments: [mockFile.path])
        check(mocked.usage?.input_tokens == 20, "streamed completion records actual usage")
        let mockRows = try mocked.reply.validated(ids: [42, 105])
        check(mockRows.count == 2, "mock CLI roundtrip")
        let recoveredStream = root.appendingPathComponent("recovered-stream.jsonl")
        try Data(("{\"type\":\"error\",\"message\":\"Stream disconnected, reconnecting\"}\n" + mockLines).utf8).write(to: recoveredStream)
        let recoveredResult = try CodexTranslationClient.run(prompt: "test", model: "gpt-5.6-terra", effort: "medium", root: root, control: RequestControl(), testExecutable: "/bin/cat", testArguments: [recoveredStream.path])
        check(recoveredResult.reply.translations.count == 2, "successful stream recovery does not repeat a valid answer")
        let failedFile = root.appendingPathComponent("failed.jsonl")
        try Data("{\"type\":\"turn.failed\",\"error\":{\"message\":\"usage limit reached\"}}\n".utf8).write(to: failedFile)
        do {
            _ = try CodexTranslationClient.run(prompt: "test", model: "gpt-5.6-terra", effort: "medium", root: root, control: RequestControl(), testExecutable: "/bin/cat", testArguments: [failedFile.path])
            check(false, "quota error must propagate")
        } catch TranslationFailure.quota { check(true, "CLI quota error distinguished") }
        let partialFile = root.appendingPathComponent("partial.jsonl"); try mockEvent.write(to: partialFile)
        rejects("unfinished CLI turn not accepted") { _ = try CodexTranslationClient.run(prompt: "test", model: "gpt-5.6-terra", effort: "medium", root: root, control: RequestControl(), testExecutable: "/bin/cat", testArguments: [partialFile.path]) }
        let suspicious = Cue(id: 1, startMS: 0, endMS: 3000, timingLine: "", text: "1000 Kilogramm Paracetamol")
        check(PreparedLecture.inspect([suspicious]).contains(where: \.critical), "kilograms flagged independently of model confidence")
        let dose = Cue(id: 1, startMS: 0, endMS: 3000, timingLine: "", text: "60 Milligramm Extrakt")
        check(!PreparedLecture.inspect([dose]).isEmpty, "spelled German units recognized")
        journal.parts[1]!.draft = ModelResult(reply: TranslationReply(translations: [.init(id: 42, text: "Суставные Beschwerden"), .init(id: 105, text: "Не использовать.")], issues: []), usage: nil, model: "gpt-5.6-luna", effort: "medium", elapsed: 0)
        check(journal.issues(for: lecture).contains(where: { $0.reason.contains("немецкое слово") }), "observed untranslated German flagged locally")
        let args = CodexTranslationClient.arguments(model: "gpt-5.6-terra", effort: "medium", directory: root)
        check(args.contains(where: { $0.hasPrefix("model_instructions_file=") }), "translation-specific instructions replace coding instructions")
        check(args.contains("read-only") && args.contains("shell_tool") && args.contains("--ignore-user-config"), "model sandbox and unnecessary tools restricted")
        var firstLock: TranslationStateLock? = try TranslationStateLock(root: root.appendingPathComponent("locked"))
        check(firstLock != nil, "queue lock acquired")
        rejects("second process/window cannot share writable queue") { _ = try TranslationStateLock(root: root.appendingPathComponent("locked")) }
        firstLock = nil
        let nextLock = try TranslationStateLock(root: root.appendingPathComponent("locked"))
        withExtendedLifetime(nextLock) { check(true, "queue lock released on close") }
        journal.parts[1]!.draftAttempts = -1
        rejects("corrupt attempt counter") { try journal.validate(lecture: lecture) }
        let toolFile = root.appendingPathComponent("tool.jsonl")
        try Data("{\"type\":\"item.started\",\"item\":{\"type\":\"command_execution\"}}\n".utf8).write(to: toolFile)
        rejects("unexpected tool call cannot become translated result") { _ = try CodexTranslationClient.run(prompt: "test", model: "gpt-5.6-terra", effort: "medium", root: root, control: RequestControl(), testExecutable: "/bin/cat", testArguments: [toolFile.path]) }
        let many = (1...30).map { Cue(id: $0, startMS: $0 * 5000, endMS: $0 * 5000 + 4500, timingLine: "", text: "Die Pflanze ist grün.") }
        let onePart = TranslationPart(id: 1, cueIDs: many.map(\.id), startMS: 5000, endMS: 154500, characters: 800, boundaryWarning: false)
        let selectiveLecture = PreparedLecture(version: 1, document: SRTDocument(sourceHash: "sample", cues: many), parts: [onePart],
            issues: [.init(cueID: 3, reason: "Dose", critical: false)], videoPaths: [], profile: lecture.profile, settings: lecture.settings)
        var selective = TranslationJournal(sourceHash: "sample", settings: lecture.settings, profile: lecture.profile)
        let selectedIDs = TranslationPipeline.reviewSelection(lecture: selectiveLecture, journal: selective, part: onePart).cueIDs
        check(selectedIDs.contains(3) && !selectedIDs.contains(16), "risk-selected first part does not duplicate a preventive sample")
        check(selectedIDs.count < 30 && selectedIDs.contains(2) && selectedIDs.contains(4), "review sends neighboring context instead of whole part")
        let allRows = many.map { TranslationReply.Row(id: $0.id, text: "Растение зелёное.") }
        let draftWithIssues = ModelResult(reply: TranslationReply(translations: allRows, issues: [.init(ids: [3, 25], reason: "Неясно", critical: true)]), usage: nil, model: "gpt-5.6-terra", effort: "medium", elapsed: 0)
        let smallReview = ModelResult(reply: TranslationReply(translations: [.init(id: 3, text: "Зелёное растение.")], issues: []), usage: nil, model: "gpt-5.6-sol", effort: "medium", elapsed: 0)
        selective.parts[1] = PartProgress(draftAttempts: 1, reviewAttempts: 1, draft: draftWithIssues, review: smallReview, done: true, reviewedIDs: [3])
        try selective.validate(lecture: selectiveLecture)
        check(selective.translated.count == 30 && selective.translated[3] == "Зелёное растение.", "partial review merges without losing untouched translations")
        check(selective.issues(for: selectiveLecture).contains { $0.cueID == 25 }, "partial review cannot erase outside uncertainty")
        selective.parts[1]!.reviewedIDs = [3, 4]
        rejects("partial review missing requested ID") { try selective.validate(lecture: selectiveLecture) }
        let doseIssue = LocalIssue(cueID: 42, reason: "Уточните дозу по записи", critical: true)
        let otherIssue = LocalIssue(cueID: 105, reason: "Уточните название", critical: true)
        let manualLecture = PreparedLecture(version: lecture.version, document: lecture.document, parts: lecture.parts,
            issues: [doseIssue, otherIssue], videoPaths: [], profile: lecture.profile, settings: lecture.settings)
        var edited = restoredJournal
        rejects("blank manual edit") { try edited.edit(cueID: 42, text: " ", confirming: nil, sourceChecked: false, lecture: manualLecture) }
        rejects("unknown manual ID") { try edited.edit(cueID: 999, text: "Текст", confirming: nil, sourceChecked: false, lecture: manualLecture) }
        try edited.edit(cueID: 42, text: "Уточнённая формулировка.", confirming: nil, sourceChecked: false, lecture: manualLecture)
        check(edited.translated[42] == "Уточнённая формулировка." && edited.parts[1]?.draft?.reply.translations.first?.text == "Первая строка.", "manual edit overlays without deleting model response")
        check(edited.issues(for: manualLecture).contains(doseIssue), "editing alone cannot silently clear medical uncertainty")
        check(edited.version == 2 && restoredJournal.version == 1, "manual journals protected from older apps, legacy journals still accepted")
        rejects("confirmation requires source check") { try edited.edit(cueID: 42, text: "Уточнённая формулировка.", confirming: doseIssue, sourceChecked: false, lecture: manualLecture) }
        try edited.edit(cueID: 42, text: "Уточнённая формулировка.", confirming: doseIssue, sourceChecked: true, lecture: manualLecture)
        check(!edited.issues(for: manualLecture).contains(doseIssue) && edited.issues(for: manualLecture).contains(otherIssue), "confirmation closes only the selected issue")
        check(edited.manualHistory?.count == 2 && edited.manualHistory?.last?.confirmedReason == doseIssue.reason, "local edit history records explicit confirmation")
        let roundtripEdited = try JSONDecoder().decode(TranslationJournal.self, from: JSONEncoder().encode(edited))
        try roundtripEdited.validate(lecture: manualLecture)
        check(roundtripEdited.translated[42] == edited.translated[42] && !roundtripEdited.issues(for: manualLecture).contains(doseIssue), "manual review survives restart")
        try edited.edit(cueID: 42, text: "Другая формулировка.", confirming: nil, sourceChecked: false, lecture: manualLecture)
        check(edited.issues(for: manualLecture).contains(doseIssue), "changing confirmed text invalidates that confirmation")
        let manualOutput = root.appendingPathComponent("manual.ru.srt")
        try TranslationPipeline.export(lecture: manualLecture, journal: edited, to: manualOutput)
        let manualDocument = try SRTDocument.parse(Data(contentsOf: manualOutput))
        check(manualDocument.cues.map(\.timingLine) == document.cues.map(\.timingLine) && manualDocument.cues.first?.text == "Другая формулировка.", "manual export preserves timestamps and uses edited text")
        check(edited.parts[1]?.draftAttempts == restoredJournal.parts[1]?.draftAttempts, "manual editing does not consume model attempts")
        edited.parts[1]!.done = false
        rejects("unfinished lecture cannot be edited") { try edited.edit(cueID: 42, text: "Текст", confirming: nil, sourceChecked: false, lecture: manualLecture) }
        let previewRange = try ListeningRange(cue: document.cues[0], padding: 3, mediaDuration: 100)
        check(previewRange.start == 0 && abs(previewRange.end - 8.456) < 0.0001, "audio preview clamps start and preserves milliseconds")
        let endingRange = try ListeningRange(cue: document.cues[1], padding: 8, mediaDuration: 8)
        check(endingRange.end == 8, "audio preview clamps end to video duration")
        rejects("preview outside video") { _ = try ListeningRange(cue: document.cues[1], padding: 3, mediaDuration: 4) }
        rejects("unknown preview duration") { _ = try ListeningRange(cue: document.cues[0], padding: 3, mediaDuration: .nan) }
        rejects("unbounded preview padding") { _ = try ListeningRange(cue: document.cues[0], padding: 3000, mediaDuration: 9000) }
        let enormousCue = Cue(id: 1, startMS: 0, endMS: 300000, timingLine: "", text: "Text")
        rejects("preview over two minutes") { _ = try ListeningRange(cue: enormousCue, padding: 0, mediaDuration: 1000) }
        let mediaJSON = Data(#"{"streams":[{"index":1,"tags":{"language":"rus"}},{"index":2,"tags":{"language":"deu"}}],"format":{"duration":"100.12"}}"#.utf8)
        let previewMedia = try JSONDecoder().decode(ListeningMedia.self, from: mediaJSON)
        check(previewMedia.onlyTrack == nil && previewMedia.streams[1].label.contains("deu"), "multiple audio tracks require explicit selection")
        let oneTrack = try JSONDecoder().decode(ListeningMedia.self, from: Data(#"{"streams":[{"index":5}],"format":{"duration":"10"}}"#.utf8))
        check(oneTrack.onlyTrack == 5 && oneTrack.streams[0].label.contains("язык не указан"), "single unnamed stream not mislabeled German")
        let dangerousName = root.appendingPathComponent("quote' $(echo BAD).mkv")
        let audioArguments = ListeningOperation.clipArguments(source: dangerousName, track: 2, range: previewRange, destination: root.appendingPathComponent("output.wav"))
        check(audioArguments.contains(dangerousName.path) && audioArguments.contains("0:2") && audioArguments.contains("-n"), "preview paths remain literal arguments, exact selected stream and no overwrite")
        check(audioArguments.contains("file,pipe") && audioArguments.contains("8.456"), "preview denies network protocols and keeps precise duration")
        rejects("remote preview rejected") { try ListeningOperation.validateSource(URL(string: "https://example.com/a.mp4")!) }
        rejects("missing preview rejected") { try ListeningOperation.validateSource(dangerousName) }
        let localOperation = try ListeningOperation()
        localOperation.cancel()
        rejects("cancelled decoder never starts") { _ = try localOperation.run(URL(fileURLWithPath: "/usr/bin/true"), []) }
        check(!TermText.contains("Teebaum", term: "Tee") && TermText.contains("Mit Weißdorn-Tee.", term: "Weißdorn"), "glossary matches whole terms not arbitrary substrings")
        var memoryJournal = try journalStore.journal(UUID(), lecture: lecture)
        check(memoryJournal.version == 4 && memoryJournal.memoryEnabled == true && memoryJournal.reviewStrategy == ReviewPlanning.strategy, "new jobs enable memory and global review while legacy journal remains unchanged")
        var metadataReply = TranslationReply(translations: [.init(id: 42, text: "Первая строка."), .init(id: 105, text: "Не использовать.")], issues: [])
        metadataReply.memory = [.init(ids: [42], text: "Обсуждается первая строка."), .init(ids: [999], text: "Чужая память")]
        metadataReply.terms = [.init(ids: [42], german: "erste Zeile", russian: "первая строка", reason: "Учебный пример"), .init(ids: [42], german: "Ausgedacht", russian: "выдуманный", reason: "Не в источнике")]
        check(metadataReply.safeNotes(cues: document.cues, allowed: [42,105]).count == 1, "memory with invented IDs discarded locally")
        check(metadataReply.safeTerms(cues: document.cues, allowed: [42,105]).count == 1, "invented German term rejected without repeating translation")
        let metadataResult = ModelResult(reply: metadataReply, usage: nil, model: "test", effort: "medium", elapsed: 0)
        memoryJournal.parts[1] = PartProgress(draftAttempts: 1, draft: metadataResult, done: true)
        let laterPart = TranslationPart(id: 2, cueIDs: [105], startMS: 5500, endMS: 9000, characters: 20, boundaryWarning: false)
        let memoryPrompt = memoryJournal.memoryContext(lecture: lecture, before: laterPart)
        check(memoryPrompt.contains("Обсуждается первая строка") && memoryPrompt.contains("DE: 42:Die erste Zeile."), "memory carries original evidence and ID")
        check(memoryJournal.memoryContext(lecture: lecture, before: lecture.parts[0]).isEmpty, "memory never leaks future parts")
        let blockedLecture = PreparedLecture(version: lecture.version, document: document, parts: lecture.parts, issues: [doseIssue], videoPaths: [], profile: lecture.profile, settings: lecture.settings)
        check(memoryJournal.memoryContext(lecture: blockedLecture, before: laterPart).isEmpty, "unresolved source risk excluded from memory")
        var library = TermLibrary()
        library.collect(lecture: lecture, journal: memoryJournal, sourcePath: source.path)
        library.collect(lecture: lecture, journal: memoryJournal, sourcePath: source.path)
        check(library.entries.count == 1 && library.entries[0].evidence.count == 1, "candidate harvesting idempotent after restart")
        check(library.confirmed(profile: lecture.profile).isEmpty, "candidate not automatically trusted")
        let candidateID = library.entries[0].id
        rejects("term confirmation requires checking") { try library.confirm(id: candidateID, russian: "первая строка", checked: false) }
        try library.confirm(id: candidateID, russian: "первая строка", checked: true)
        try journalStore.saveTerms(library)
        check(try! journalStore.termLibrary().confirmed(profile: lecture.profile).count == 1, "confirmed term survives local storage")
        let frozenJournal = try journalStore.journal(UUID(), lecture: lecture)
        check(frozenJournal.confirmedTerms?.count == 1 && memoryJournal.confirmedTerms?.count == 0, "new lecture snapshots glossary, ongoing lecture unchanged")
        check(library.confirmed(profile: .builtIns[1]).isEmpty, "terms do not leak across profiles")
        var manualProfile = lecture.profile; manualProfile.glossary = "erste Zeile => ручная пара"
        check(library.confirmed(profile: manualProfile).isEmpty, "manual profile glossary wins over library")
        try library.setStatus(id: candidateID, status: .deferred)
        check(library.confirmed(profile: lecture.profile).isEmpty && frozenJournal.confirmedTerms?.count == 1, "withdrawal affects future jobs only")
        try memoryJournal.edit(cueID: 42, text: "Ручная формулировка.", confirming: nil, sourceChecked: false, lecture: lecture)
        check(memoryJournal.version == 4 && memoryJournal.memoryContext(lecture: lecture, before: laterPart).isEmpty, "manual edit invalidates machine memory without downgrading journal")
        check(TranslationReply.memorySchema.contains("memory") && !TranslationReply.schema.contains("memory"), "legacy response schema unchanged")
        let newPrompt = TranslationPipeline.prompt(lecture: lecture, journal: frozenJournal, part: lecture.parts[0], review: false)
        check(newPrompt.contains("FROZEN_CONFIRMED_TERMS") && newPrompt.contains("erste Zeile => первая строка"), "confirmed terms enter actual translation prompt")
        var conflictLibrary = try journalStore.termLibrary()
        conflictLibrary.entries.append(.init(id: "conflict", profileID: lecture.profile.id, german: "erste Zeile", russian: "другой перевод", evidence: []))
        rejects("conflicting term cannot overwrite confirmed translation") { try conflictLibrary.confirm(id: "conflict", russian: "другой перевод", checked: true) }
        try conflictLibrary.setStatus(id: candidateID, status: .proposed)
        try conflictLibrary.confirm(id: "conflict", russian: "другой перевод", checked: true)
        check(conflictLibrary.confirmed(profile: lecture.profile).first?.russian == "другой перевод", "explicit withdrawal permits replacement")
        try journalStore.saveTerms(conflictLibrary)
        check(frozenJournal.confirmedContext(lecture: lecture, part: lecture.parts[0]).contains("первая строка"), "snapshot remains stable after shared dictionary update")
        var reviewedMemory = frozenJournal
        reviewedMemory.parts[1] = PartProgress(draftAttempts: 1, reviewAttempts: 1, draft: metadataResult,
            review: ModelResult(reply: TranslationReply(translations: [.init(id: 42, text: "Первая строка.")], issues: []), usage: nil, model: "test", effort: "medium", elapsed: 0), done: true, reviewedIDs: [42])
        check(reviewedMemory.partMetadata(lecture.parts[0], lecture: lecture).notes.isEmpty, "reviewed source excludes stale draft memory")
        check(TranslationPipeline.restoredStatus(lecture: manualLecture, journal: restoredJournal).0 == .needsReview, "local reprepare cannot erase review status")
        var partialJournal = restoredJournal; partialJournal.parts[1]!.done = false
        check(TranslationPipeline.restoredStatus(lecture: lecture, journal: partialJournal).0 == .paused, "local reprepare preserves partial translated progress")
        var largeQueue = ProjectState()
        largeQueue.jobs = (0..<1000).map { index in
            var job = JobSummary(sourcePath: root.appendingPathComponent("lecture-\(index).srt").path)
            job.status = index % 3 == 0 ? .needsReview : (index % 3 == 1 ? .paused : .queued)
            job.completedCues = index % 3 == 2 ? 0 : 117
            return job
        }
        largeQueue.manuallyPaused = true; largeQueue.translationPending = false
        let queueStore = CheckpointStore(root: root.appendingPathComponent("large-queue"))
        try queueStore.save(largeQueue)
        let reloadedQueue = try queueStore.load()
        check(reloadedQueue.jobs.count == 1000 && reloadedQueue.jobs.map(\.status) == largeQueue.jobs.map(\.status), "1000-item queue roundtrip preserves statuses")
        check(reloadedQueue.manuallyPaused && reloadedQueue.jobs.map(\.completedCues) == largeQueue.jobs.map(\.completedCues), "1000-item queue preserves pause and progress without models")
        try conflictLibrary.setStatus(id: "conflict", status: .proposed)
        try conflictLibrary.confirm(id: "conflict", german: "korrektes Wort", russian: "правильное слово", checked: true)
        check(conflictLibrary.entries.first { $0.id == "conflict" }?.german == "korrektes Wort", "German ASR spelling editable before term confirmation")
        rejects("empty corrected German term") { try conflictLibrary.confirm(id: "conflict", german: " ", russian: "слово", checked: true) }
        let ledgerCues = (1...20).map { Cue(id: $0, startMS: $0 * 10000, endMS: $0 * 10000 + 9000, timingLine: "", text: "Das Thema ist Pflanze \($0).") }
        let ledgerParts = ledgerCues.map { TranslationPart(id: $0.id, cueIDs: [$0.id], startMS: $0.startMS, endMS: $0.endMS, characters: 30, boundaryWarning: false) }
        let ledgerLecture = PreparedLecture(version: 1, document: .init(sourceHash: "ledger", cues: ledgerCues), parts: ledgerParts, issues: [], videoPaths: [], profile: lecture.profile, settings: lecture.settings)
        var ledger = TranslationJournal(sourceHash: "ledger", settings: lecture.settings, profile: lecture.profile)
        ledger.version = 3; ledger.memoryEnabled = true
        for cue in ledgerCues {
            let reply = TranslationReply(translations: [.init(id: cue.id, text: "Тема — растение.")], issues: [], memory: [.init(ids: [cue.id], text: "Заметка \(cue.id).")])
            ledger.parts[cue.id] = PartProgress(draftAttempts: 1, draft: .init(reply: reply, usage: nil, model: "test", effort: "medium", elapsed: 0), done: true)
        }
        let bounded = ledger.memoryContext(lecture: ledgerLecture, before: .init(id: 21, cueIDs: [], startMS: 0, endMS: 0, characters: 0, boundaryWarning: false))
        check(bounded.count <= 2200 && bounded.contains("Заметка 1.") && bounded.contains("Заметка 20."), "memory bounds retain opening anchor and recent notes")
        let groupCues = [7, 11, 15, 20].map { Cue(id: $0, startMS: $0 * 1000, endMS: $0 * 1000 + 900, timingLine: "", text: "Text") }
        let grouped = IssueGroup.grouped([7, 11, 20].map { LocalIssue(cueID: $0, reason: "Сомнение", critical: true) }, cues: groupCues)
        check(grouped.map { $0.issues.map(\.cueID) } == [[7, 11], [20]], "issue grouping uses source adjacency, not numeric IDs")
        check(IssueGroup.grouped([.init(cueID: 7, reason: "Сомнение", critical: true), .init(cueID: 11, reason: "Сомнение", critical: false)], cues: groupCues).count == 2, "grouping preserves severity distinction")
        check(LocalIssue(cueID: 7, reason: "Плотная реплика: 25", critical: false).category == "Плотность для озвучки", "density warning is not a semantic error label")
        check(ServiceLimit.recognized(["type": "turn.failed", "error": ["code": "usage_limit_exceeded", "message": "Blocked"]]), "structured usage limit recognised")
        check(!ServiceLimit.recognized(["type": "item.completed", "item": ["text": "usage limit reached"]]), "subtitle text cannot trigger quota recovery")
        check(!ServiceLimit.recognized(["type": "error", "message": "Unable to read quota configuration"]), "quota configuration error is not an exhausted limit")
        let partialQuota = root.appendingPathComponent("partial-quota.jsonl")
        try Data((String(data: mockEvent, encoding: .utf8)! + "\n{\"type\":\"turn.failed\",\"error\":{\"code\":\"usage_limit_exceeded\",\"message\":\"Blocked\"}}\n").utf8).write(to: partialQuota)
        do {
            _ = try CodexTranslationClient.run(prompt: "test", model: "gpt-5.6-terra", effort: "medium", root: root, control: RequestControl(), testExecutable: "/bin/cat", testArguments: [partialQuota.path])
            check(false, "partial answer followed by limit must fail")
        } catch TranslationFailure.quotaWithProgress { check(true, "partial quota answer cannot refund retry budget") }
        let reasoningQuota = root.appendingPathComponent("reasoning-quota.jsonl")
        try Data("{\"type\":\"item.started\",\"item\":{\"type\":\"reasoning\"}}\n{\"type\":\"error\",\"message\":\"usage limit reached\"}\n".utf8).write(to: reasoningQuota)
        do {
            _ = try CodexTranslationClient.run(prompt: "test", model: "gpt-5.6-terra", effort: "medium", root: root, control: RequestControl(), testExecutable: "/bin/cat", testArguments: [reasoningQuota.path])
            check(false, "reasoning before quota must retain budget")
        } catch TranslationFailure.quotaWithProgress { check(true, "reasoning activity counts as partial generation") }
        var recovery = TranslationJournal(sourceHash: lecture.document.sourceHash, settings: lecture.settings, profile: lecture.profile)
        recovery.parts[1] = PartProgress()
        for _ in 0..<3 {
            recovery.parts[1]!.draftAttempts += 1
            recovery.recordQuotaRefusal(partID: 1, reviewing: false, hasPartialResult: false)
            recovery = try JSONDecoder().decode(TranslationJournal.self, from: JSONEncoder().encode(recovery))
        }
        check(recovery.version == 4 && recovery.quotaPaused && recovery.parts[1]!.draftAttempts == 3, "three quota refusals persist across restarts and stop automation")
        check(recovery.parts[1]!.chargedDraftAttempts == 0, "quota refusal is not a translation repair attempt")
        try recovery.validate(lecture: lecture)
        recovery.resumeAfterQuotaPause()
        check(!recovery.quotaPaused, "explicit continuation resets circuit but keeps request history")
        recovery.parts[1]!.draftAttempts += 1
        recovery.recordQuotaRefusal(partID: 1, reviewing: false, hasPartialResult: true)
        check(recovery.parts[1]!.chargedDraftAttempts == 1, "partially generated quota answer retains charged attempt")
        recovery.acceptServiceResult()
        check(recovery.consecutiveQuotaRefusals == 0, "successful response clears consecutive refusal streak")
        recovery.parts[1]!.reviewAttempts = 1
        recovery.recordQuotaRefusal(partID: 1, reviewing: true, hasPartialResult: false)
        check(recovery.totalReviews == 0 && recovery.parts[1]!.chargedReviewAttempts == 0, "refused review remains eligible without consuming Sol budget")
        recovery.parts[1]!.reviewAttempts += 1
        check(recovery.totalReviews == 1, "subsequent actual review consumes one Sol slot")
        var brokenRecovery = recovery; brokenRecovery.parts[1]!.draftQuotaDeferrals = 900
        rejects("invalid quota accounting rejected") { try brokenRecovery.validate(lecture: lecture) }

        let riskCues = (1...6).map { id in Cue(id: id, startMS: id * 10000, endMS: id * 10000 + 9000, timingLine: "", text: id == 6 ? "Fünf Milligramm. Nicht in der Schwangerschaft einnehmen." : "Wir sprechen heute über Pflanzen.") }
        let riskParts = riskCues.map { TranslationPart(id: $0.id, cueIDs: [$0.id], startMS: $0.startMS, endMS: $0.endMS, characters: $0.text.count, boundaryWarning: false) }
        var riskSettings = lecture.settings; riskSettings.maxReviewCallsPerLecture = 1
        let riskLecture = PreparedLecture(version: 1, document: .init(sourceHash: "risk", cues: riskCues), parts: riskParts, issues: [], videoPaths: [], profile: lecture.profile, settings: riskSettings)
        var global = TranslationJournal(sourceHash: "risk", settings: riskSettings, profile: lecture.profile)
        global.version = 4; global.memoryEnabled = true; global.reviewStrategy = ReviewPlanning.strategy
        for cue in riskCues {
            if case .draft(let next) = TranslationPipeline.next(lecture: riskLecture, journal: global) { check(next.id == cue.id, "global review waits for draft \(cue.id)") }
            else { check(false, "draft was skipped") }
            let reply = TranslationReply(translations: [.init(id: cue.id, text: "Русская фраза.")], issues: [], memory: [.init(ids: [cue.id], text: "Тема — растения.")])
            global.parts[cue.id] = PartProgress(draftAttempts: 1, draft: .init(reply: reply, usage: nil, model: "test", effort: "medium", elapsed: 0))
        }
        check(!global.memoryContext(lecture: riskLecture, before: riskParts[1]).isEmpty, "draft-only memory is available before global review")
        if case .planReviews(let plan) = TranslationPipeline.next(lecture: riskLecture, journal: global) {
            check(plan == [6], "late contraindication and dose outrank opening sample")
            global.reviewPlan = plan
        } else { check(false, "review plan expected") }
        global = try JSONDecoder().decode(TranslationJournal.self, from: JSONEncoder().encode(global))
        try global.validate(lecture: riskLecture)
        if case .review(let selected) = TranslationPipeline.next(lecture: riskLecture, journal: global) { check(selected.id == 6, "review plan survives restart") }
        check(TranslationPipeline.reviewSelection(lecture: riskLecture, journal: global, part: riskParts[5]).cueIDs == [6], "review includes safety cue even if no model issues")
        global.parts[6]!.review = global.parts[6]!.draft; global.parts[6]!.reviewAttempts = 1
        for part in riskParts {
            if case .finalize(let next) = TranslationPipeline.next(lecture: riskLecture, journal: global) { check(next.id == part.id, "finalize after global review without repeating drafts") }
            else { check(false, "unexpected repeated model request") }
            global.parts[part.id]!.done = true
        }
        if case .complete = TranslationPipeline.next(lecture: riskLecture, journal: global) { check(true, "new strategy completes all parts") } else { check(false, "global strategy did not finish") }
        var corruptPlan = global; corruptPlan.reviewPlan = [6, 6]
        rejects("duplicate review plan rejected") { try corruptPlan.validate(lecture: riskLecture) }
        print("PASS: \(passed) local checks. No model requests.")
    }
}
