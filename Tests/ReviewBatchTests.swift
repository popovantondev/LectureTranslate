import Foundation

@main
enum ReviewBatchTests {
    static var passed = 0
    static func check(_ value: @autoclosure () -> Bool, _ name: String) {
        guard value() else { fputs("FAIL: \(name)\n", stderr); exit(1) }
        passed += 1
    }

    static let ordinary = "Это обычное русское предложение."
    static func fixture(parts count: Int = 3, rows: Int = 31, budget: Int = 10) -> PreparedLecture {
        let cues = (0..<(count * rows)).map { index in
            Cue(id: index * 7 + 11, startMS: index * 20_000, endMS: index * 20_000 + 19_000,
                timingLine: "test-\(index)", text: "Hier folgt eine gewöhnliche Aussage.")
        }
        let parts = (0..<count).map { offset in
            let group = Array(cues[(offset * rows)..<((offset + 1) * rows)])
            return TranslationPart(id: offset + 1, cueIDs: group.map(\.id), startMS: group.first!.startMS,
                                   endMS: group.last!.endMS, characters: group.reduce(0) { $0 + $1.text.count }, boundaryWarning: false)
        }
        var settings = TranslationSettings(); settings.outputStyle = "display"; settings.maxReviewCallsPerLecture = budget
        return PreparedLecture(version: 1, document: .init(sourceHash: "review-batch-fixture", cues: cues), parts: parts,
                               issues: [], videoPaths: [], profile: .builtIns[0], settings: settings)
    }
    static func drafted(_ lecture: PreparedLecture, substitutions: [Int: String] = [:], issues: [Int: String] = [:]) -> TranslationJournal {
        var journal = TranslationJournal(sourceHash: lecture.document.sourceHash, settings: lecture.settings, profile: lecture.profile)
        journal.version = 4; journal.reviewStrategy = ReviewPlanning.strategy
        for part in lecture.parts {
            let rows = part.cueIDs.map { TranslationReply.Row(id: $0, text: substitutions[$0] ?? ordinary) }
            let warnings = part.cueIDs.compactMap { id -> TranslationReply.Issue? in
                issues[id].map { .init(ids: [id], reason: $0, critical: true) }
            }
            let result = ModelResult(reply: .init(translations: rows, issues: warnings), usage: nil, model: "fixture", effort: "medium", elapsed: 0)
            journal.parts[part.id] = .init(draftAttempts: 1, draft: result)
        }
        return journal
    }
    static func replacingCues(_ lecture: PreparedLecture, _ cues: [Cue], issues: [LocalIssue]? = nil) -> PreparedLecture {
        .init(version: lecture.version, document: .init(sourceHash: lecture.document.sourceHash, cues: cues), parts: lecture.parts,
              issues: issues ?? lecture.issues, videoPaths: [], profile: lecture.profile, settings: lecture.settings)
    }

    static func main() throws {
        let positives = ["Это нераспознанная субстанция.", "Название не распознано.", "НЕРАСПОЗНАННЫЙ ПРЕПАРАТ", "Нерасслышанное слово.",
                         "[неразборчиво]", "Не удалось расслышать название.", "Неизвестное вещество.", "[inaudible]", "[unverständlich]", "[???]"]
        for text in positives {
            let found = ReviewBatch.placeholderIssues(translations: [13: text])
            check(found.count == 1 && found[0].cueID == 13 && found[0].critical, "placeholder independently detected: \(text)")
            check(found[0].category == "Смысл и распознавание", "placeholder is semantic risk")
        }
        for text in [ordinary, "Гиперицин содержится в зверобое.", "Исследователям неизвестны все свойства этого растения.", "Возьмите пять миллилитров."] {
            check(ReviewBatch.placeholderIssues(translations: [13: text]).isEmpty, "ordinary text not rewritten or flagged")
        }

        let lecture = fixture(), hot = lecture.parts[2].cueIDs[15]
        let draft = drafted(lecture, substitutions: [hot: positives[0]])
        let before = try JSONEncoder().encode(draft)
        check(draft.parts.values.allSatisfy { $0.draft!.reply.issues.isEmpty }, "fixture translator claims no doubts")
        check(ReviewBatch.candidateIssues(lecture: lecture, journal: draft).contains { $0.cueID == hot && $0.critical }, "full scan finds silent late placeholder")
        check(ReviewBatch.issueScore(lecture.parts[2], lecture: lecture, journal: draft) > 600, "placeholder receives high review priority")
        check(ReviewBatch.plan(lecture: lecture, journal: draft)?.selectedPartIDs.first == 3, "late placeholder outranks first sample")
        check(ReviewBatch.selectionReason(lecture: lecture, journal: draft, part: lecture.parts[2]).contains("распознав"), "saved recognition flags explain review selection")
        let calm = drafted(lecture)
        let calmPlan = ReviewBatch.plan(lecture: lecture, journal: calm)!
        check(calmPlan.selectedPartIDs == [1], "calm lecture gets one preventive first-part sample")
        check(ReviewBatch.selectionReason(lecture: lecture, journal: calm, part: lecture.parts[0]).contains("Профилактическая выборка"), "preventive sample has an explicit non-error reason")
        check(calmPlan.candidateCueIDs.isEmpty, "preventive sample is not reported as an error candidate")
        check(ReviewBatch.selection(lecture: lecture, journal: calm, part: lecture.parts[0]).cueIDs == [lecture.parts[0].cueIDs[15]], "preventive sample is a single cue")

        var incomplete = draft; incomplete.parts[2]?.draft = nil
        check(ReviewBatch.plan(lecture: lecture, journal: incomplete) == nil, "no planning before every draft exists")
        let chosen = ReviewBatch.selection(lecture: lecture, journal: draft, part: lecture.parts[2])
        check(chosen.cueIDs.contains(hot) && chosen.cueIDs.count == 5, "all risky IDs plus bounded sentence context")
        check(Set(chosen.cueIDs).isSubset(of: Set(lecture.parts[2].cueIDs)), "review outputs never cross part")
        check(ReviewBatch.selection(lecture: lecture, journal: draft, part: lecture.parts[1]).cueIDs.isEmpty, "review selection has no unrelated fallback cue")
        check(chosen.startMS == lecture.document.cues.first { $0.id == chosen.cueIDs.first }!.startMS, "selection uses exact first cue timing")
        check(chosen.characters == lecture.document.cues.filter { chosen.cueIDs.contains($0.id) }.reduce(0) { $0 + $1.text.count }, "selection recalculates text size")

        let edge = lecture.parts[2].cueIDs[0], end = lecture.parts[2].cueIDs.last!
        let many = drafted(lecture, substitutions: [edge: positives[0], end: positives[0]])
        let split = ReviewBatch.selection(lecture: lecture, journal: many, part: lecture.parts[2])
        check(split.cueIDs.contains(edge) && split.cueIDs.contains(end), "distant risky groups both selected")
        check(!split.cueIDs.contains(hot), "unrelated middle is not sent just to bridge groups")
        check(split.cueIDs == lecture.parts[2].cueIDs.filter { split.cueIDs.contains($0) }, "nonconsecutive IDs stay in original order")
        let every = drafted(lecture, substitutions: Dictionary(uniqueKeysWithValues: lecture.parts[2].cueIDs.map { ($0, positives[0]) }))
        check(ReviewBatch.selection(lecture: lecture, journal: every, part: lecture.parts[2]).cueIDs == lecture.parts[2].cueIDs, "no hidden ceiling drops all-risk part")

        var saved = draft; saved.parts[3]!.reviewedIDs = [edge, end]
        check(ReviewBatch.selection(lecture: lecture, journal: saved, part: lecture.parts[2]).cueIDs == [edge, end], "saved requested IDs remain frozen for retry")
        saved.reviewPlan = [1]
        check(ReviewBatch.plan(lecture: lecture, journal: saved)?.selectedPartIDs == [1], "saved plan not silently reprioritized")
        check(ReviewBatch.plan(lecture: lecture, journal: saved)?.deferredCueIDs.contains(hot) == true, "unselected risks explicit even with old frozen plan")

        var reviewed = draft
        reviewed.parts[3]!.reviewedIDs = chosen.cueIDs
        reviewed.parts[3]!.reviewAttempts = 1
        reviewed.parts[3]!.review = .init(reply: .init(translations: chosen.cueIDs.map { .init(id: $0, text: $0 == hot ? positives[0] : ordinary) }, issues: []), usage: nil, model: "confident-review", effort: "medium", elapsed: 0)
        check(ReviewBatch.placeholderIssues(translations: reviewed.translated).contains { $0.cueID == hot }, "unchanged placeholder survives confident Sol response")
        reviewed.parts[3]!.review = .init(reply: .init(translations: chosen.cueIDs.map { .init(id: $0, text: ordinary) }, issues: []), usage: nil, model: "fixed-review", effort: "medium", elapsed: 0)
        check(ReviewBatch.placeholderIssues(translations: reviewed.translated).isEmpty, "corrected text clears derived placeholder")
        reviewed.manualTranslations = [hot: positives[0]]
        check(!ReviewBatch.placeholderIssues(translations: reviewed.translated).isEmpty, "manual reintroduction detected")

        // Real journal integration: neither a silent draft nor a confident Sol
        // response can hide a placeholder, but explicit source-checked literal
        // speech can be acknowledged without rewriting what the lecturer said.
        var real = draft
        real.parts[3]!.reviewedIDs = chosen.cueIDs; real.parts[3]!.reviewAttempts = 1
        real.parts[3]!.review = .init(reply: .init(translations: chosen.cueIDs.map { .init(id: $0, text: $0 == hot ? positives[0] : ordinary) }, issues: []), usage: nil, model: "confident-review", effort: "medium", elapsed: 0)
        real.reviewPlan = [3]
        for part in lecture.parts { real.parts[part.id]!.done = true }
        try real.validate(lecture: lecture)
        let unresolved = real.issues(for: lecture).first { $0.cueID == hot && $0.reason.hasPrefix(ReviewBatch.placeholderPrefix) }
        check(unresolved != nil && unresolved!.critical, "actual journal preserves placeholder after empty Sol issues")
        check(TranslationPipeline.restoredStatus(lecture: lecture, journal: real).0 == .needsReview, "placeholder prevents clean automatic export")
        check(TranslationPipeline.prompt(lecture: lecture, journal: draft, part: lecture.parts[2], review: true).contains(ReviewBatch.placeholderPrefix), "Sol prompt receives exact local placeholder warning")
        let attempts = real.totalReviews
        do {
            try real.edit(cueID: hot, text: positives[0], confirming: unresolved, sourceChecked: false, lecture: lecture)
            check(false, "unchecked confirmation must fail")
        } catch { check(true, "unchecked confirmation rejected") }
        check(real.issues(for: lecture).contains { $0.id == unresolved!.id }, "failed confirmation leaves original risk")
        try real.edit(cueID: hot, text: positives[0], confirming: unresolved, sourceChecked: true, lecture: lecture)
        check(!real.issues(for: lecture).contains { $0.id == unresolved!.id }, "verified literal lecturer speech may be acknowledged")
        check(real.translated[hot] == positives[0] && real.totalReviews == attempts, "manual acknowledgement changes neither words nor paid counter")
        check(real.manualHistory?.last?.confirmedReason == unresolved!.reason, "literal acknowledgement keeps audit history")
        let restored = try JSONDecoder().decode(TranslationJournal.self, from: JSONEncoder().encode(real))
        check(restored.issues(for: lecture).isEmpty, "verified literal acknowledgement survives restart")
        try real.edit(cueID: hot, text: positives[1], confirming: nil, sourceChecked: false, lecture: lecture)
        check(real.issues(for: lecture).contains { $0.cueID == hot && $0.reason.hasPrefix(ReviewBatch.placeholderPrefix) }, "changed placeholder invalidates previous acknowledgement")
        try real.edit(cueID: hot, text: ordinary, confirming: nil, sourceChecked: false, lecture: lecture)
        check(real.issues(for: lecture).isEmpty, "actual text repair clears current derived risk")

        let big = fixture(parts: 13, rows: 1), all = drafted(big, substitutions: Dictionary(uniqueKeysWithValues: big.document.cues.map { ($0.id, positives[0]) }))
        let plan = ReviewBatch.plan(lecture: big, journal: all)!
        check(plan.selectedPartIDs.count == 10, "at most ten part checks")
        check(plan.deferredPartIDs.count == 3 && plan.deferredCueIDs.count == 3, "risks over budget explicitly deferred")
        check(plan.candidateCueIDs.count == 13, "all candidates kept even when only ten selected")
        check(Set(plan.selectedPartIDs).isDisjoint(with: Set(plan.deferredPartIDs)), "selected and deferred groups disjoint")
        var outcomesJournal = all
        outcomesJournal.reviewPlan = plan.selectedPartIDs
        for part in big.parts.prefix(2) {
            let cueID = part.cueIDs[0]
            outcomesJournal.parts[part.id]!.reviewedIDs = [cueID]
            outcomesJournal.parts[part.id]!.reviewAttempts = 1
            outcomesJournal.parts[part.id]!.review = .init(reply: .init(translations: [.init(id: cueID, text: part.id == 1 ? ordinary : positives[0])], issues: []), usage: nil, model: "saved-review", effort: "medium", elapsed: 0)
        }
        let savedOutcomes = ReviewBatch.outcomes(lecture: big, journal: outcomesJournal)
        check(savedOutcomes.candidates == 13 && savedOutcomes.reviewedUnchanged == 1 && savedOutcomes.changedByReview == 1, "outcomes separate candidate, unchanged, and changed cues")
        check(savedOutcomes.reviewedRiskFound == 1, "reviewed unchanged risk stays distinguishable as found")
        check(savedOutcomes.unresolved == 12 && savedOutcomes.unreviewedDueToBudget == 3, "unchanged critical candidates remain unresolved and three are budget-deferred")
        let resumedJournal = try JSONDecoder().decode(TranslationJournal.self, from: JSONEncoder().encode(outcomesJournal))
        check(ReviewBatch.outcomes(lecture: big, journal: resumedJournal) == savedOutcomes, "outcomes survive journal resume without recounting completed responses")
        if case .review(let next) = TranslationPipeline.next(lecture: big, journal: resumedJournal) {
            check(next.id == 3, "resume advances past both stored Sol responses")
        } else { check(false, "resume must continue with next pending selected part") }
        var corrected = all
        let correctedCue = big.document.cues[1].id
        corrected.parts[2]!.reviewedIDs = [correctedCue]
        corrected.parts[2]!.reviewAttempts = 1
        corrected.parts[2]!.review = .init(reply: .init(translations: [.init(id: correctedCue, text: ordinary)], issues: []), usage: nil, model: "saved-review", effort: "medium", elapsed: 0)
        let correctedOutcome = ReviewBatch.outcomes(lecture: big, journal: corrected)
        check(correctedOutcome.candidates == 13 && correctedOutcome.changedByReview == 1 && correctedOutcome.unresolved == 12, "corrected risk remains in history and is no longer unresolved")
        let previous = fixture(parts: 13, rows: 1, budget: 3), legacy = drafted(previous, substitutions: Dictionary(uniqueKeysWithValues: previous.document.cues.map { ($0.id, positives[0]) }))
        check(ReviewBatch.plan(lecture: previous, journal: legacy)!.selectedPartIDs.count == 3, "earlier lecture budget preserved")
        let zero = fixture(parts: 2, rows: 1, budget: 0), none = drafted(zero, substitutions: Dictionary(uniqueKeysWithValues: zero.document.cues.map { ($0.id, positives[0]) }))
        check(ReviewBatch.plan(lecture: zero, journal: none)!.deferredCueIDs.count == 2, "zero budget retains every risk")

        let warning = "Есть неоднозначное слово."
        let withDraftIssues = drafted(lecture, issues: [hot: warning])
        let sourceIssues = replacingCues(lecture, lecture.document.cues, issues: [.init(cueID: hot, reason: warning, critical: true)])
        check(ReviewBatch.candidateIssues(lecture: sourceIssues, journal: withDraftIssues).filter { $0.cueID == hot && $0.reason == warning }.count == 1, "duplicate reasons do not inflate score")
        check(ReviewBatch.selection(lecture: sourceIssues, journal: withDraftIssues, part: lecture.parts[2]).cueIDs.contains(hot), "source and draft issues enter selection")

        var cues = lecture.document.cues
        let position = cues.firstIndex { $0.id == hot }!
        cues[position] = .init(id: hot, startMS: cues[position].startMS, endMS: cues[position].endMS, timingLine: cues[position].timingLine, text: "Nicht einnehmen während der Schwangerschaft.")
        let safety = replacingCues(lecture, cues), safeDraft = drafted(safety)
        check(ReviewBatch.selection(lecture: safety, journal: safeDraft, part: safety.parts[2]).cueIDs.contains(hot), "source safety risks independent of model issues")
        check(ReviewBatch.selectionReason(lecture: safety, journal: safeDraft, part: safety.parts[2]).contains("немецком оригинале"), "source safety reason is recorded independently of model doubt")
        for index in (position - 12)...(position + 12) {
            let old = cues[index]; cues[index] = .init(id: old.id, startMS: old.startMS, endMS: old.endMS, timingLine: old.timingLine, text: "weiter ohne Satzende")
        }
        let noBoundary = replacingCues(lecture, cues)
        check(ReviewBatch.selection(lecture: noBoundary, journal: draft, part: noBoundary.parts[2]).cueIDs.count == 17, "missing punctuation does not grow context indefinitely")

        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let after = try encoder.encode(draft)
        let normalizedBefore = try encoder.encode(JSONDecoder().decode(TranslationJournal.self, from: before))
        check(after == normalizedBefore, "local planning never mutates journals or attempts")
        var legacyObject = try JSONSerialization.jsonObject(with: before) as! [String: Any]
        var legacyParts = legacyObject["parts"] as! [String: [String: Any]]
        for key in legacyParts.keys { legacyParts[key]?.removeValue(forKey: "reviewSelectionReason") }
        legacyObject["parts"] = legacyParts
        let legacyDecoded = try JSONDecoder().decode(TranslationJournal.self, from: JSONSerialization.data(withJSONObject: legacyObject))
        check(legacyDecoded.parts.values.allSatisfy { $0.reviewSelectionReason == nil }, "older journals decode with selection reason explicitly unknown")
        check(draft.totalReviews == 0, "offline helper spends no review attempts")
        print("PASS: \(passed) review-batch checks (offline, no models/account).")
    }
}
