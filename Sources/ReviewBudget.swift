import Foundation

/// Raises the local allowance for future reviews without replacing paid drafts,
/// review answers, counters, manual edits, or the original file on disk.
enum ReviewBudget {
    struct Change {
        let journal: TranslationJournal
        let changed: Bool
        let reopenedPartIDs: [Int]
    }

    static func raised(journal: TranslationJournal, lecture: PreparedLecture) throws -> Change {
        try journal.validate(lecture: lecture)
        let oldBudget = journal.settings.maxReviewCallsPerLecture
        let target = lecture.settings.maxReviewCallsPerLecture
        guard (1...10).contains(oldBudget), (1...10).contains(target) else {
            throw TranslationFailure.failed("Предел проверок Sol должен быть от одного до десяти. Сохранённые ответы не изменены.")
        }
        guard target >= oldBudget else {
            return Change(journal: journal, changed: false, reopenedPartIDs: [])
        }

        var updated = journal
        let metadataChanged = target > oldBudget
        if metadataChanged { updated.settings.maxReviewCallsPerLecture = target }
        let hasManualWork = !(journal.manualTranslations ?? [:]).isEmpty ||
            !(journal.manualHistory ?? []).isEmpty || !(journal.acknowledgedIssues ?? []).isEmpty
        guard !hasManualWork, journal.reviewStrategy == ReviewPlanning.strategy,
              lecture.parts.allSatisfy({ journal.parts[$0.id]?.draft != nil }),
              var plan = journal.reviewPlan else {
            // A missing global plan is built by the ordinary .planReviews step,
            // including its deferred-risk markers. Legacy and edited work is not reopened.
            try updated.validate(lecture: lecture)
            return Change(journal: updated, changed: metadataChanged, reopenedPartIDs: [])
        }

        let alreadyPending = Set(plan.filter { id in
            guard let record = journal.parts[id] else { return false }
            return record.review == nil && record.chargedReviewAttempts == 0 && !record.reviewSkipped
        })
        var available = max(0, target - journal.totalReviews - alreadyPending.count)
        var planned = Set(plan)
        let ranked = lecture.parts.compactMap { part -> (part: TranslationPart, score: Int)? in
            guard let record = journal.parts[part.id], record.review == nil,
                  record.chargedReviewAttempts == 0, !alreadyPending.contains(part.id) else { return nil }
            // Returning to an earlier stored maximum may reactivate budget-skipped
            // checks, not silently replace an otherwise frozen plan with new risks.
            guard metadataChanged || record.reviewSkipped else { return nil }
            let score = ReviewPlanning.score(part, lecture: lecture, journal: journal)
            return score > 0 ? (part, score) : nil
        }.sorted { $0.score == $1.score ? $0.part.id < $1.part.id : $0.score > $1.score }

        var reopened: [Int] = []
        for candidate in ranked where available > 0 {
            let id = candidate.part.id
            guard planned.contains(id) || plan.count < target else { continue }
            if planned.insert(id).inserted { plan.append(id) }
            var record = updated.parts[id]!
            if record.reviewSelectionReason == nil {
                record.reviewSelectionReason = ReviewBatch.selectionReason(lecture: lecture, journal: updated, part: candidate.part)
            }
            record.reviewSkipped = false
            record.done = false
            // Keep reviewAttempts/deferrals/failure/reviewedIDs intact. A quota
            // refusal with no charged attempt does not authorize changing request IDs.
            updated.parts[id] = record
            reopened.append(id)
            available -= 1
        }
        updated.reviewPlan = plan
        if !reopened.isEmpty { updated.exportedPath = nil }
        try updated.validate(lecture: lecture)
        return Change(journal: updated, changed: metadataChanged || !reopened.isEmpty, reopenedPartIDs: reopened)
    }
}
