import Foundation

@main
enum SourceRevisionTests {
    private static var passed = 0
    private static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else { fputs("FAIL: \(label)\n", stderr); exit(1) }
        passed += 1
    }
    private static func rejects(_ label: String, _ action: () throws -> Void) {
        do { try action(); fputs("FAIL: \(label) did not reject\n", stderr); exit(1) }
        catch { passed += 1 }
    }
    private static func srt(firstStart: String = "00:00:01,000", firstEnd: String = "00:00:05,000",
                            secondStart: String = "00:00:05,100", secondEnd: String = "00:00:09,000",
                            firstText: String = "Die erste Zeile.", secondText: String = "Nicht verwenden; 2 kg.",
                            firstID: Int = 42, secondID: Int = 105) -> Data {
        Data("\(firstID)\n\(firstStart) --> \(firstEnd)\n\(firstText)\n\n\(secondID)\n\(secondStart) --> \(secondEnd)\n\(secondText)\n".utf8)
    }
    private static func makeJournal(lecture: PreparedLecture) throws -> TranslationJournal {
        var journal = TranslationJournal(sourceHash: lecture.document.sourceHash, settings: lecture.settings, profile: lecture.profile)
        let translated = lecture.document.cues.map { cue in TranslationReply.Row(id: cue.id, text: cue.id == 42 ? "Первая строка с подробным переводом." : "Не применять.") }
        let reply = TranslationReply(translations: translated, issues: [])
        let result = ModelResult(reply: reply, usage: .init(input_tokens: 50, cached_input_tokens: 10, output_tokens: 20),
                                 model: "gpt-6-luna", effort: "medium", elapsed: 2)
        journal.parts[1] = PartProgress(draftAttempts: 1, draft: result, done: true)
        journal.manualTranslations = [42: "Первая строка исправлена вручную."]
        journal.manualHistory = [.init(cueID: 42, previousText: "Первая строка с подробным переводом.",
                                      text: "Первая строка исправлена вручную.", date: Date(), confirmedReason: nil)]
        let acknowledged = lecture.issues.first(where: { $0.cueID == 105 && $0.critical })!
        journal.acknowledgedIssues = [journal.issueKey(acknowledged)]
        journal.exportedPath = "/tmp/old-revision.ru.srt"
        return journal
    }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LectureSourceRevision-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Revision.de.srt")
        let oldData = srt()
        try oldData.write(to: source)
        let settings = TranslationSettings()
        let profile = TranslationProfile.builtIns[0]
        let oldLecture = try PreparedLecture.prepare(url: source, profile: profile, settings: settings)
        let oldJournal = try makeJournal(lecture: oldLecture)
        let changedData = srt(firstStart: "00:00:01,400", firstEnd: "00:00:05,500",
                              secondStart: "00:00:05,600", secondEnd: "00:00:09,500")

        let candidate = try SourceRevisionMigration.make(oldLecture: oldLecture, oldJournal: oldJournal,
                                                         sourceData: changedData, profile: profile, settings: settings)
        var legacyJobJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(JobSummary(sourcePath: source.path))) as! [String: Any]
        legacyJobJSON.removeValue(forKey: "archivedRevision")
        let decodedLegacyJob = try JSONDecoder().decode(JobSummary.self, from: JSONSerialization.data(withJSONObject: legacyJobJSON))
        check(!decodedLegacyJob.isArchivedRevision, "legacy job without revision marker remains readable")
        var legacyJournalJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(candidate.journal)) as! [String: Any]
        legacyJournalJSON.removeValue(forKey: "translationOriginSourceHash")
        let decodedLegacyJournal = try JSONDecoder().decode(TranslationJournal.self, from: JSONSerialization.data(withJSONObject: legacyJournalJSON))
        check(decodedLegacyJournal.translationOriginSourceHash == nil, "legacy journal without timing-origin field remains readable")
        check(candidate.changedCueIDs == [42, 105], "lists only cues whose times changed")
        check(candidate.lecture.document.cues.map(\.text) == oldLecture.document.cues.map(\.text), "source text is exact")
        check(candidate.lecture.parts.map(\.cueIDs) == oldLecture.parts.map(\.cueIDs), "part and cue assignments are retained")
        check(candidate.lecture.parts[0].startMS == 1_400 && candidate.lecture.parts[0].endMS == 9_500, "part timing boundaries are recomputed")
        check(candidate.journal.translated[42] == "Первая строка исправлена вручную.", "manual correction is retained")
        let newHistory = candidate.journal.manualHistory ?? [], oldHistory = oldJournal.manualHistory ?? []
        let historyPreserved = newHistory.count == oldHistory.count && newHistory.first?.cueID == oldHistory.first?.cueID &&
            newHistory.first?.previousText == oldHistory.first?.previousText && newHistory.first?.text == oldHistory.first?.text &&
            newHistory.first?.date == oldHistory.first?.date
        check(historyPreserved, "manual edit history is retained")
        let newDraft = candidate.journal.parts[1]?.draft, oldDraft = oldJournal.parts[1]?.draft
        let newRows = newDraft?.reply.translations.map { "\($0.id):\($0.text)" }
        let oldRows = oldDraft?.reply.translations.map { "\($0.id):\($0.text)" }
        check(newRows == oldRows && newDraft?.model == oldDraft?.model &&
              newDraft?.usage?.input_tokens == oldDraft?.usage?.input_tokens &&
              candidate.journal.parts[1]?.draftAttempts == 1, "paid primary result and attempt count are retained")
        check(candidate.journal.translationOriginSourceHash == oldLecture.document.sourceHash, "origin hash records original timing revision")
        check(candidate.journal.sourceHash == candidate.lecture.document.sourceHash, "new journal binds to new source hash")
        check(candidate.journal.exportedPath == nil, "old SRT is not treated as export for new revision")
        let oldStableIssue = oldJournal.unresolvedCandidates(for: oldLecture).first { $0.cueID == 105 }!
        let newStableIssue = candidate.journal.unresolvedCandidates(for: candidate.lecture).first { $0.cueID == 105 }!
        check(candidate.journal.acknowledgedIssues?.contains(candidate.journal.issueKey(newStableIssue)) == true,
              "unchanged issue confirmation is rebound to the new source hash")
        check(oldStableIssue.reason == newStableIssue.reason, "rebound confirmation requires identical issue basis")

        let twoPartLecture = PreparedLecture(version: oldLecture.version, document: oldLecture.document,
            parts: oldLecture.document.cues.enumerated().map { index, cue in
                TranslationPart(id: index + 1, cueIDs: [cue.id], startMS: cue.startMS, endMS: cue.endMS,
                                 characters: cue.text.count, boundaryWarning: index == 0)
            }, issues: oldLecture.issues, videoPaths: oldLecture.videoPaths, profile: profile, settings: settings)
        var partialJournal = TranslationJournal(sourceHash: twoPartLecture.document.sourceHash, settings: settings, profile: profile)
        let partialReply = TranslationReply(translations: [.init(id: 42, text: "Уже переведённая реплика.")], issues: [])
        partialJournal.parts[1] = PartProgress(draftAttempts: 1,
            draft: ModelResult(reply: partialReply, usage: nil, model: "gpt-6-luna", effort: "medium", elapsed: 1), done: true)
        let partialMigration = try SourceRevisionMigration.make(oldLecture: twoPartLecture, oldJournal: partialJournal,
            sourceData: changedData, profile: profile, settings: settings)
        check(partialMigration.journal.translated == [42: "Уже переведённая реплика."] &&
              partialMigration.journal.parts[2] == nil && partialMigration.lecture.completedTranslations.count == 1,
              "partial migration carries only accepted answers and leaves unfinished part pending")

        let denseOldData = srt(firstEnd: "00:00:03,000", secondStart: "00:00:03,100")
        try denseOldData.write(to: source)
        let denseOldLecture = try PreparedLecture.prepare(url: source, profile: profile, settings: settings)
        var denseJournal = try makeJournal(lecture: denseOldLecture)
        let longSpeechText = "Первая реплика содержит важные уточнения, ограничения и необходимые подробности."
        denseJournal.manualTranslations = [42: longSpeechText]
        let density = denseJournal.unresolvedCandidates(for: denseOldLecture).first { $0.cueID == 42 && $0.reason.contains("Плотная реплика") }!
        denseJournal.acknowledgedIssues = [denseJournal.issueKey(density)]
        let retimedDense = try SourceRevisionMigration.make(oldLecture: denseOldLecture, oldJournal: denseJournal,
            sourceData: srt(firstStart: "00:00:01,400", firstEnd: "00:00:02,900", secondStart: "00:00:03,000", secondEnd: "00:00:09,500"),
            profile: profile, settings: settings)
        let recalculatedDensity = retimedDense.journal.unresolvedCandidates(for: retimedDense.lecture).first {
            $0.cueID == 42 && $0.reason.contains("Плотная реплика")
        }!
        check(!retimedDense.journal.acknowledgedIssues!.contains(retimedDense.journal.issueKey(recalculatedDensity)),
              "time-dependent warning acknowledgement is rechecked after retiming")

        rejects("text changes rejected") {
            _ = try SourceRevisionMigration.make(oldLecture: oldLecture, oldJournal: oldJournal,
                sourceData: srt(firstStart: "00:00:01,400", firstText: "Die andere Zeile."), profile: profile, settings: settings)
        }
        rejects("cue ID changes rejected") {
            _ = try SourceRevisionMigration.make(oldLecture: oldLecture, oldJournal: oldJournal,
                sourceData: srt(firstStart: "00:00:01,400", firstID: 43), profile: profile, settings: settings)
        }
        rejects("cue order changes rejected") {
            let reordered = Data("105\n00:00:01,400 --> 00:00:05,000\nNicht verwenden.\n\n42\n00:00:05,100 --> 00:00:09,000\nDie erste Zeile.\n".utf8)
            _ = try SourceRevisionMigration.make(oldLecture: oldLecture, oldJournal: oldJournal, sourceData: reordered,
                                                  profile: profile, settings: settings)
        }
        rejects("cue count changes rejected") {
            _ = try SourceRevisionMigration.make(oldLecture: oldLecture, oldJournal: oldJournal,
                sourceData: Data("42\n00:00:01,400 --> 00:00:05,000\nDie erste Zeile.\n".utf8), profile: profile, settings: settings)
        }
        rejects("invalid new timing rejected") {
            _ = try SourceRevisionMigration.make(oldLecture: oldLecture, oldJournal: oldJournal,
                sourceData: srt(firstStart: "00:00:01,400", firstEnd: "00:00:06,000", secondStart: "00:00:05,600"),
                profile: profile, settings: settings)
        }
        rejects("profile change rejected") {
            _ = try SourceRevisionMigration.make(oldLecture: oldLecture, oldJournal: oldJournal, sourceData: changedData,
                profile: .builtIns[1], settings: settings)
        }
        var otherSettings = settings; otherSettings.model = "gpt-5.6-terra"
        rejects("translation setting change rejected") {
            _ = try SourceRevisionMigration.make(oldLecture: oldLecture, oldJournal: oldJournal, sourceData: changedData,
                profile: profile, settings: otherSettings)
        }

        // The previous and migrated revisions both survive a portable project round trip.
        let store = CheckpointStore(root: root.appendingPathComponent("store"))
        let oldID = UUID(), newID = UUID()
        try store.save(oldLecture, id: oldID); try store.saveJournal(oldJournal, id: oldID)
        try store.save(candidate.lecture, id: newID); try store.saveJournal(candidate.journal, id: newID)
        let reusedPrepared = try store.loadPreparedIfCurrent(newID, sourceData: changedData, profile: profile, settings: settings)
        check(reusedPrepared?.parts.map(\.cueIDs) == candidate.lecture.parts.map(\.cueIDs),
              "translation startup reuses migrated part mapping instead of splitting again")
        let otherProfileReuse = try store.loadPreparedIfCurrent(newID, sourceData: changedData, profile: .builtIns[1], settings: settings)
        check(otherProfileReuse == nil, "prepared checkpoint is not reused under another profile")
        var oldJob = JobSummary(sourcePath: source.path); oldJob.id = oldID; oldJob.archivedRevision = true
        oldJob.sourceHash = oldLecture.document.sourceHash; oldJob.status = .sourceChanged
        oldJob.cueCount = 2; oldJob.partCount = oldLecture.parts.count; oldJob.completedCues = oldJournal.translated.count
        var newJob = JobSummary(sourcePath: source.path); newJob.id = newID
        newJob.sourceHash = candidate.lecture.document.sourceHash; newJob.status = .needsReview
        newJob.cueCount = 2; newJob.partCount = candidate.lecture.parts.count; newJob.completedCues = candidate.journal.translated.count
        var state = ProjectState(); state.jobs = [oldJob, newJob]
        let archive = root.appendingPathComponent("BothRevisions.lectureproject")
        try ProjectArchive.save(state: state, store: store, to: archive)
        let importedStore = CheckpointStore(root: root.appendingPathComponent("imported"))
        let imported = try ProjectArchive.open(from: archive, into: importedStore)
        check(imported.state.jobs.count == 2 && imported.state.jobs[0].isArchivedRevision &&
              imported.state.jobs[0].status == .sourceChanged, "project retains archived revision as non-active history")
        let importedNewID = imported.state.jobs[1].id
        let importedLecture = try importedStore.loadLecture(importedNewID)
        let importedJournal = try importedStore.journal(importedNewID, lecture: importedLecture)
        check(importedJournal.translationOriginSourceHash == oldLecture.document.sourceHash,
              "origin hash survives project archive round trip")
        check(importedJournal.translated[42] == "Первая строка исправлена вручную." && importedJournal.exportedPath == nil,
              "migrated translation survives project round trip without stale export")

        print("PASS: \(passed) source revision checks")
    }
}
