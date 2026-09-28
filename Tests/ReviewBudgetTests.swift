import Foundation

@main
enum ReviewBudgetTests {
    static var passed = 0
    static func check(_ value: @autoclosure () -> Bool, _ name: String) {
        guard value() else { fputs("FAIL: \(name)\n", stderr); exit(1) }
        passed += 1
    }
    static func bytes<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func lecture(parts: Int = 14, budget: Int = 3) -> PreparedLecture {
        let cues = (0..<parts).map { index in
            Cue(id: index * 7 + 11, startMS: index * 20_000, endMS: index * 20_000 + 19_000,
                timingLine: "fixture-\(index)", text: "Hier folgt eine gewöhnliche Aussage.")
        }
        let groups = cues.enumerated().map { offset, cue in
            TranslationPart(id: offset + 1, cueIDs: [cue.id], startMS: cue.startMS, endMS: cue.endMS,
                            characters: cue.text.count, boundaryWarning: false)
        }
        var settings = TranslationSettings(); settings.maxReviewCallsPerLecture = budget; settings.outputStyle = "display"
        return PreparedLecture(version: 1, document: .init(sourceHash: "review-budget-fixture", cues: cues), parts: groups,
                               issues: [], videoPaths: [], profile: .builtIns[0], settings: settings)
    }
    static func journal(_ lecture: PreparedLecture, paid: Int = 3) -> TranslationJournal {
        var journal = TranslationJournal(sourceHash: lecture.document.sourceHash, settings: lecture.settings, profile: lecture.profile)
        journal.version = 4; journal.reviewStrategy = ReviewPlanning.strategy
        journal.memoryEnabled = true; journal.confirmedTerms = []
        journal.reviewPlan = Array(lecture.parts.prefix(paid).map(\.id))
        for part in lecture.parts {
            let draft = ModelResult(reply: .init(translations: [.init(id: part.cueIDs[0], text: "Это нераспознанная субстанция.")], issues: []), usage: .init(input_tokens: 100, cached_input_tokens: 40, output_tokens: 80), model: "draft-fixture", effort: "medium", elapsed: 1)
            let review = ModelResult(reply: .init(translations: [.init(id: part.cueIDs[0], text: "Здесь речь идёт о лекарственном растении.")], issues: []), usage: .init(input_tokens: 90, cached_input_tokens: 10, output_tokens: 60), model: "review-fixture", effort: "medium", elapsed: 2)
            journal.parts[part.id] = .init(draftAttempts: 1, reviewAttempts: part.id <= paid ? 1 : 0,
                                          draft: draft, review: part.id <= paid ? review : nil,
                                          done: true, reviewSkipped: part.id > paid,
                                          reviewedIDs: part.id <= paid ? part.cueIDs : nil)
        }
        journal.exportedPath = "/not-accessed/original.ru.srt"
        return journal
    }

    static func main() throws {
        let old = lecture(), target = lecture(budget: 10), saved = journal(old)
        let original = try bytes(saved)
        let change = try ReviewBudget.raised(journal: saved, lecture: target)
        let raised = change.journal
        check(change.changed && raised.settings.maxReviewCallsPerLecture == 10, "budget increases three to ten")
        check(raised.reviewPlan == Array(1...10), "old ordered plan retained then seven most risky parts appended")
        check(change.reopenedPartIDs == Array(4...10), "only unused reviews reopened")
        check(raised.totalReviews == 3, "paid review count never reset")
        check(raised.exportedPath == nil && saved.exportedPath != nil, "new checks invalidate export marker, not file")
        check(raised.sourceHash == saved.sourceHash && raised.profile == saved.profile, "source identity and profile retained")
        check(raised.memoryEnabled == saved.memoryEnabled && raised.confirmedTerms == saved.confirmedTerms, "memory mode and frozen terms retained")
        for part in target.parts {
            let afterDraft = try bytes(raised.parts[part.id]!.draft), beforeDraft = try bytes(saved.parts[part.id]!.draft)
            check(afterDraft == beforeDraft, "paid draft preserved for part \(part.id)")
            check(raised.parts[part.id]!.draftAttempts == saved.parts[part.id]!.draftAttempts, "draft attempts retained for part \(part.id)")
            if part.id <= 3 {
                let a = try bytes(raised.parts[part.id]!), b = try bytes(saved.parts[part.id]!)
                check(a == b, "finished paid review not touched")
            } else if part.id <= 10 {
                check(!raised.parts[part.id]!.done && !raised.parts[part.id]!.reviewSkipped, "new review is pending")
            } else {
                check(raised.parts[part.id]!.done && raised.parts[part.id]!.reviewSkipped, "outside budget remains explicit and unchanged")
            }
        }
        if case .review(let next) = TranslationPipeline.next(lecture: target, journal: raised) {
            check(next.id == 4, "continuation requests Sol, never repeats draft")
        } else { check(false, "next operation must be review") }
        let untouched = try bytes(saved)
        check(untouched == original, "input value unchanged")
        let second = try ReviewBudget.raised(journal: raised, lecture: target)
        let secondBytes = try bytes(second.journal), raisedBytes = try bytes(raised)
        check(!second.changed && second.reopenedPartIDs.isEmpty && secondBytes == raisedBytes, "repeat migration is idempotent")
        let lower = try ReviewBudget.raised(journal: raised, lecture: old)
        let lowerBytes = try bytes(lower.journal)
        check(!lower.changed && lowerBytes == raisedBytes, "lower runtime budget never erases saved maximum/history")

        var temporarilyLimited = raised
        for id in 4...10 {
            temporarilyLimited.parts[id]!.reviewSkipped = true
            temporarilyLimited.parts[id]!.done = true
        }
        temporarilyLimited.exportedPath = "/not-accessed/lower-budget-export.ru.srt"
        let restoredAllowance = try ReviewBudget.raised(journal: temporarilyLimited, lecture: target)
        check(restoredAllowance.changed && restoredAllowance.reopenedPartIDs == Array(4...10), "returning to saved ten reactivates unpaid budget-skipped checks")
        check(restoredAllowance.journal.reviewPlan == raised.reviewPlan && restoredAllowance.journal.totalReviews == 3, "return to stored maximum keeps original plan and paid counters")
        check(restoredAllowance.journal.exportedPath == nil, "newly reactivated checks invalidate prior export marker")
        let repeatedAllowance = try ReviewBudget.raised(journal: restoredAllowance.journal, lecture: target)
        check(!repeatedAllowance.changed, "reactivation is idempotent once pending")
        var fixedUnplanned = temporarilyLimited
        fixedUnplanned.reviewPlan = [1, 2, 3]
        for id in 4...14 { fixedUnplanned.parts[id]!.reviewSkipped = false }
        let frozen = try ReviewBudget.raised(journal: fixedUnplanned, lecture: target)
        check(!frozen.changed && frozen.journal.reviewPlan == [1, 2, 3], "equal budget does not add unmarked new risks to frozen plan")

        var pending = saved
        pending.parts[3]!.review = nil; pending.parts[3]!.reviewAttempts = 0
        pending.parts[3]!.done = false; pending.parts[3]!.reviewSkipped = false
        let withPending = try ReviewBudget.raised(journal: pending, lecture: target)
        check(withPending.journal.totalReviews == 2 && withPending.reopenedPartIDs.count == 7, "already pending review reserves one of ten slots")
        check(withPending.journal.reviewPlan == Array(1...10), "pending existing entry not duplicated")

        var failed = saved
        failed.parts[4]!.reviewAttempts = 1; failed.parts[4]!.failure = "Previous paid review failed."
        failed.parts[4]!.reviewedIDs = target.parts[3].cueIDs
        let notRepeated = try ReviewBudget.raised(journal: failed, lecture: target)
        check(!notRepeated.reopenedPartIDs.contains(4) && notRepeated.reopenedPartIDs.count == 6, "failed charged review is not purchased twice")
        let failedAfter = try bytes(notRepeated.journal.parts[4]!), failedBefore = try bytes(failed.parts[4]!)
        check(failedAfter == failedBefore, "failed review IDs/counter/diagnostic retained")

        var deferred = saved
        deferred.parts[4]!.reviewAttempts = 1; deferred.parts[4]!.reviewQuotaDeferrals = 1
        deferred.parts[4]!.failure = "Quota refusal before response."
        deferred.parts[4]!.reviewedIDs = target.parts[3].cueIDs
        let quotaRetry = try ReviewBudget.raised(journal: deferred, lecture: target)
        check(quotaRetry.reopenedPartIDs.contains(4), "uncharged quota deferral eligible within larger budget")
        check(quotaRetry.journal.parts[4]!.reviewAttempts == 1 && quotaRetry.journal.parts[4]!.reviewQuotaDeferrals == 1, "quota refusal counters not reset")
        check(quotaRetry.journal.parts[4]!.reviewedIDs == deferred.parts[4]!.reviewedIDs, "quota retry request IDs retained")

        var alreadyPlanned = saved
        alreadyPlanned.reviewPlan = [1, 2, 4]
        let reenabled = try ReviewBudget.raised(journal: alreadyPlanned, lecture: target)
        check(Array(reenabled.journal.reviewPlan!.prefix(3)) == [1, 2, 4], "existing plan order remains intact")
        check(reenabled.reopenedPartIDs.contains(4) && !reenabled.journal.parts[4]!.reviewSkipped, "previous budget-skipped planned item can reopen")

        var allSpent = saved
        for id in 4...10 { allSpent.parts[id]!.reviewAttempts = 1 }
        let noSlots = try ReviewBudget.raised(journal: allSpent, lecture: target)
        check(noSlots.changed && noSlots.reopenedPartIDs.isEmpty && noSlots.journal.totalReviews == 10, "no extra call after ten total charged reviews")
        check(noSlots.journal.exportedPath == allSpent.exportedPath, "metadata-only change preserves export marker")

        var noPlan = saved; noPlan.reviewPlan = nil
        let deferredPlanning = try ReviewBudget.raised(journal: noPlan, lecture: target)
        check(deferredPlanning.journal.reviewPlan == nil && deferredPlanning.reopenedPartIDs.isEmpty, "missing plan left for normal global planning step")
        var incomplete = noPlan
        incomplete.parts[14]!.draft = nil; incomplete.parts[14]!.done = false
        let unfinished = try ReviewBudget.raised(journal: incomplete, lecture: target)
        check(unfinished.journal.settings.maxReviewCallsPerLecture == 10 && unfinished.reopenedPartIDs.isEmpty, "incomplete draft set gets metadata only")
        var legacy = noPlan; legacy.reviewStrategy = nil
        let earlier = try ReviewBudget.raised(journal: legacy, lecture: target)
        check(earlier.reopenedPartIDs.isEmpty && earlier.journal.reviewStrategy == nil, "legacy strategy not migrated implicitly")

        var manual = saved
        let cue = old.parts[3].cueIDs[0]
        manual.manualTranslations = [cue: "Проверенный вручную перевод."]
        manual.manualHistory = [.init(cueID: cue, previousText: saved.translated[cue]!, text: manual.manualTranslations![cue]!, date: Date(timeIntervalSince1970: 100), confirmedReason: "Сверено с оригиналом")]
        manual.acknowledgedIssues = ["confirmed-fixture"]
        let edited = try ReviewBudget.raised(journal: manual, lecture: target)
        check(edited.changed && edited.reopenedPartIDs.isEmpty, "manual work prevents automatic reopening")
        let manualParts = try bytes(manual.parts), editedParts = try bytes(edited.journal.parts)
        let oldHistory = try bytes(manual.manualHistory), newHistory = try bytes(edited.journal.manualHistory)
        check(manualParts == editedParts && oldHistory == newHistory, "manual history and all completed part flags preserved")
        check(edited.journal.manualTranslations == manual.manualTranslations && edited.journal.acknowledgedIssues == manual.acknowledgedIssues, "manual translations/acknowledgements preserved")
        check(edited.journal.exportedPath == manual.exportedPath, "manual export remains untouched")
        try edited.journal.validate(lecture: target)
        check(true, "manual journal remains valid")
        let manualAgain = try ReviewBudget.raised(journal: edited.journal, lecture: target)
        check(!manualAgain.changed && manualAgain.reopenedPartIDs.isEmpty, "equal-budget reactivation also preserves manual work")
        var historyOnly = saved; historyOnly.manualHistory = manual.manualHistory
        check(tryNoReopen(historyOnly, lecture: target), "history alone prevents reopening")
        var ackOnly = saved; ackOnly.acknowledgedIssues = manual.acknowledgedIssues
        check(tryNoReopen(ackOnly, lecture: target), "acknowledgement alone prevents reopening")

        var damaged = saved; damaged.parts[4]!.reviewAttempts = 2
        do { _ = try ReviewBudget.raised(journal: damaged, lecture: target); check(false, "corrupt counters must fail") }
        catch { check(true, "corrupt journal rejected before changes") }
        let invalid = lecture(budget: 11)
        do { _ = try ReviewBudget.raised(journal: saved, lecture: invalid); check(false, "unsupported budget must fail") }
        catch { check(true, "unsupported target budget rejected") }

        // Actual checkpoint-store integration, only inside a fresh synthetic root.
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("review-budget-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let store = CheckpointStore(root: root), jobID = UUID()
        let export = root.appendingPathComponent("synthetic-existing.ru.srt")
        let exportBytes = Data("1\n00:00:00,000 --> 00:00:01,000\nПрежний проверенный текст.\n".utf8)
        try exportBytes.write(to: export, options: .withoutOverwriting)
        var onDisk = saved; onDisk.exportedPath = export.path
        try store.saveJournal(onDisk, id: jobID)
        let oldBytes = try Data(contentsOf: store.journalURL(jobID))
        let backups = root.appendingPathComponent("journal-backups", isDirectory: true)
        let readOnly = try store.journal(jobID, lecture: target)
        let afterReadBytes = try Data(contentsOf: store.journalURL(jobID))
        check(readOnly.settings.maxReviewCallsPerLecture == 3 && oldBytes == afterReadBytes && !fm.fileExists(atPath: backups.path), "default journal read never migrates or creates backup")

        let migrated = try store.journal(jobID, lecture: target, migrateReviewBudget: true)
        let backupFiles = try fm.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
        let backupBytes = try backupFiles.map { try Data(contentsOf: $0) }
        check(backupFiles.count == 1 && backupBytes == [oldBytes], "explicit migration saves byte-exact original journal backup")
        let migratedBytes = try Data(contentsOf: store.journalURL(jobID))
        let persisted = try JSONDecoder().decode(TranslationJournal.self, from: migratedBytes)
        check(migrated.settings.maxReviewCallsPerLecture == 10 && persisted.reviewPlan == Array(1...10) && persisted.parts[4]?.done == false && persisted.exportedPath == nil, "explicit migration persists raised allowance and pending reviews after backup")
        _ = try store.journal(jobID, lecture: target, migrateReviewBudget: true)
        let afterRepeat = try Data(contentsOf: store.journalURL(jobID))
        let repeatedBackups = try fm.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
        check(repeatedBackups.count == 1 && afterRepeat == migratedBytes, "idempotent repeated migration creates no extra backup or journal rewrite")
        let retainedExport = try Data(contentsOf: export)
        check(retainedExport == exportBytes, "budget migration never modifies existing exported SRT")

        print("PASS: \(passed) review-budget checks (offline, isolated fixtures, no models/account).")
    }

    static func tryNoReopen(_ journal: TranslationJournal, lecture: PreparedLecture) -> Bool {
        guard let changed = try? ReviewBudget.raised(journal: journal, lecture: lecture) else { return false }
        return changed.changed && changed.reopenedPartIDs.isEmpty
    }
}
