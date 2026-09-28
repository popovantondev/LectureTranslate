import Foundation

/// Local review selection only. Does not request models, alter translated text, or
/// store a second review schema: one saved review still belongs to one source part.
enum ReviewBatch {
    static let placeholderPrefix = "Нераспознанное место:"
    private static let placeholder = try! NSRegularExpression(pattern:
        #"(?iu)(?<!\p{L})(?:не[\s-]?распознан\p{L}*|нерасслышан\p{L}*|неразборчив\p{L}*|не[\s-]+удалось\s+(?:распознать|расслышать|разобрать)|(?:неизвестн\p{L}*|неустановленн\p{L}*)\s+(?:субстанц|веществ|назван|термин|дозиров|препарат|растен)\p{L}*)(?!\p{L})|\[(?:inaudible|unintelligible|unverständlich|unverstaendlich|непонятно|неясно|\?{1,3})\]"#)

    /// Recompute from the current final text, including a review/manual edit. A
    /// confident model review does not make a surviving placeholder go away.
    /// The normal explicit, source-checked acknowledgement remains available for
    /// legitimate literal speech such as a lecturer saying "unknown substance".
    static func placeholderIssues(translations: [Int: String]) -> [LocalIssue] {
        translations.keys.sorted().compactMap { id in
            let text = translations[id]!.precomposedStringWithCanonicalMapping
            guard placeholder.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else { return nil }
            return LocalIssue(cueID: id, reason: "\(placeholderPrefix) в переводе осталось обозначение неясного слова или названия. Сверьте с оригиналом; не подставляйте правдоподобную догадку. Если это буквальные слова лектора, проверьте их контекст.", critical: true)
        }
    }

    /// This may call journal.issues; journal itself must call only the pure
    /// placeholderIssues helper above, never candidateIssues/issueScore/selection.
    static func candidateIssues(lecture: PreparedLecture, journal: TranslationJournal) -> [LocalIssue] {
        let positions = Dictionary(uniqueKeysWithValues: lecture.document.cues.enumerated().map { ($0.element.id, $0.offset) })
        var unique: [String: LocalIssue] = [:]
        for issue in lecture.issues + journal.issues(for: lecture) + placeholderIssues(translations: journal.translated) {
            guard positions[issue.cueID] != nil else { continue }
            // Duplicated local/model reasons must not inflate risk. Critical wins.
            if unique[issue.id]?.critical != true { unique[issue.id] = issue }
        }
        return unique.values.sorted {
            let a = positions[$0.cueID]!, b = positions[$1.cueID]!
            return a == b ? $0.reason < $1.reason : a < b
        }
    }

    /// Add to/compare with source-based safety scoring in ReviewPlanning. Unlike
    /// draft.reply.issues alone, this includes derived final-text risks and placeholders.
    static func issueScore(_ part: TranslationPart, lecture: PreparedLecture, journal: TranslationJournal) -> Int {
        let ids = Set(part.cueIDs)
        let issues = candidateIssues(lecture: lecture, journal: journal).filter { ids.contains($0.cueID) }
        let critical = Set(issues.filter(\.critical).map(\.cueID)).count
        let ordinary = Set(issues.filter { !$0.critical }.map(\.cueID)).count
        let placeholders = Set(issues.filter { $0.reason.hasPrefix(placeholderPrefix) }.map(\.cueID)).count
        return min(4, critical) * 150 + min(3, ordinary) * 30 + min(2, placeholders) * 600
    }

    struct Plan: Equatable {
        let selectedPartIDs: [Int]
        let deferredPartIDs: [Int]
        let candidateCueIDs: [Int]
        let deferredCueIDs: [Int]
    }

    struct Outcomes: Equatable {
        let candidates: Int
        let reviewedRiskFound: Int
        let reviewedUnchanged: Int
        let changedByReview: Int
        let unresolved: Int
        let unreviewedDueToBudget: Int
    }

    /// Counts cue locations, rather than model calls. A completed response is
    /// recognized from the saved journal so resuming never presents it as pending.
    static func outcomes(lecture: PreparedLecture, journal: TranslationJournal) -> Outcomes {
        let plan = self.plan(lecture: lecture, journal: journal)
        // Candidate IDs represent independently detected risks. Read-only
        // sentence context and the preventive sample are not error findings.
        let candidateIDs = riskIDs(lecture: lecture, journal: journal, issues: candidateIssues(lecture: lecture, journal: journal))
        let reviewedIDs = Set(lecture.parts.flatMap { part -> [Int] in
            guard let response = journal.parts[part.id]?.review else { return [] }
            return response.reply.translations.map(\.id)
        })
        var changed = Set<Int>()
        for part in lecture.parts {
            guard let progress = journal.parts[part.id], let review = progress.review else { continue }
            let draft = Dictionary(uniqueKeysWithValues: (progress.draft?.reply.translations ?? []).map { ($0.id, $0.text) })
            for row in review.reply.translations where draft[row.id] != nil && draft[row.id] != row.text {
                changed.insert(row.id)
            }
        }
        let unresolved = Set(journal.issues(for: lecture).map(\.cueID)).intersection(candidateIDs)
        let deferredPartIDs = Set(plan?.deferredPartIDs ?? [])
        let deferred = Set(lecture.parts.filter { deferredPartIDs.contains($0.id) }.flatMap(\.cueIDs)).intersection(candidateIDs)
        let reviewedCandidates = candidateIDs.intersection(reviewedIDs)
        return Outcomes(candidates: candidateIDs.count, reviewedRiskFound: unresolved.intersection(reviewedCandidates).count,
                        reviewedUnchanged: reviewedCandidates.subtracting(changed).count,
                        changedByReview: reviewedCandidates.intersection(changed).count,
                        unresolved: unresolved.count,
                        unreviewedDueToBudget: deferred.subtracting(reviewedIDs).count)
    }

    /// All drafts must exist before a new global plan is made. Existing saved
    /// plans remain frozen; updating the app cannot spend a different review budget.
    static func plan(lecture: PreparedLecture, journal: TranslationJournal) -> Plan? {
        guard lecture.parts.allSatisfy({ journal.parts[$0.id]?.draft != nil }) else { return nil }
        let issues = candidateIssues(lecture: lecture, journal: journal)
        let ids = riskIDs(lecture: lecture, journal: journal, issues: issues)
        let scored = lecture.parts.map { part in
            (part: part, score: max(ReviewPlanning.score(part, lecture: lecture, journal: journal),
                                   issueScore(part, lecture: lecture, journal: journal)))
        }.filter { $0.score > 0 }
        let ranked = scored.sorted { $0.score == $1.score ? $0.part.id < $1.part.id : $0.score > $1.score }
        let budget = max(0, min(10, lecture.settings.maxReviewCallsPerLecture))
        let selected = journal.reviewPlan ?? Array(ranked.prefix(budget).map { $0.part.id })
        let selectedSet = Set(selected)
        let deferred = lecture.parts.filter { part in
            !selectedSet.contains(part.id) && scored.contains { $0.part.id == part.id }
        }
        let deferredIDs = Set(deferred.flatMap(\.cueIDs))
        let ordered = lecture.document.cues.map(\.id).filter { ids.contains($0) }
        return .init(selectedPartIDs: selected, deferredPartIDs: deferred.map(\.id),
                     candidateCueIDs: ordered, deferredCueIDs: ordered.filter { deferredIDs.contains($0) })
    }

    /// Explain the pre-review evidence that selected this part. Callers persist
    /// the returned text before spending a Sol request so corrections do not
    /// erase the original reason from the lecture history.
    static func selectionReason(lecture: PreparedLecture, journal: TranslationJournal, part: TranslationPart) -> String {
        let ids = Set(part.cueIDs)
        let cues = lecture.document.cues.filter { ids.contains($0.id) }
        var reasons: [String] = []
        let sourceRisks = cues.filter { ReviewPlanning.safetyCue($0.text) }.map(\.id)
        if !sourceRisks.isEmpty {
            reasons.append("Риск в немецком оригинале (дозировка, противопоказание или предупреждение), реплики: \(sourceRisks.map(String.init).joined(separator: ", ")).")
        }
        let detected = candidateIssues(lecture: lecture, journal: journal).filter { ids.contains($0.cueID) }
        if !detected.isEmpty {
            let cueIDs = Array(Set(detected.map(\.cueID))).sorted().map(String.init).joined(separator: ", ")
            let categories = Array(Set(detected.map(\.category))).sorted().joined(separator: ", ")
            reasons.append("Сохранённые локальные/распознавательные замечания (\(categories)), реплики: \(cueIDs).")
        }
        let draftIssues = journal.parts[part.id]?.draft?.reply.issues ?? []
        if !draftIssues.isEmpty {
            let cueIDs = Array(Set(draftIssues.flatMap(\.ids).filter { ids.contains($0) })).sorted().map(String.init).joined(separator: ", ")
            reasons.append("Сомнения чернового перевода; реплики: \(cueIDs.isEmpty ? "часть \(part.id)" : cueIDs).")
        }
        if reasons.isEmpty && part.id == lecture.parts.first?.id {
            reasons.append("Профилактическая выборка первой части; самостоятельных признаков риска не найдено.")
        }
        return reasons.isEmpty ? "Причина отбора не определена автоматически." : reasons.joined(separator: " ")
    }

    /// Select every detected risky cue in the chosen part, plus bounded adjacent
    /// context. No additional character cap silently drops candidates: the source
    /// part was already bounded during preparation. Other parts supply read-only
    /// context through the existing prompt builder, never output IDs in this request.
    static func selection(lecture: PreparedLecture, journal: TranslationJournal, part: TranslationPart) -> TranslationPart {
        let partIDs = Set(part.cueIDs)
        let cues = lecture.document.cues.filter { partIDs.contains($0.id) }
        let requested: Set<Int>
        if let saved = journal.parts[part.id]?.reviewedIDs { requested = Set(saved) }
        else {
            let risks = riskIDs(lecture: lecture, journal: journal, issues: candidateIssues(lecture: lecture, journal: journal))
            var indices = Set<Int>()
            for (index, cue) in cues.enumerated() where risks.contains(cue.id) {
                var begin = max(0, index - 2), end = min(cues.count - 1, index + 2)
                while begin > 0 && index - begin < 8 && !cues[begin - 1].endsSentence { begin -= 1 }
                while end + 1 < cues.count && end - index < 8 && !cues[end].endsSentence { end += 1 }
                indices.formUnion(begin...end)
            }
            // A calm lecture gets one explicitly preventive sample in its first
            // part, but only after higher-risk parts have been ranked. Never
            // duplicate that part when a real risk already selected it.
            if part.id == lecture.parts.first?.id && risks.isDisjoint(with: Set(part.cueIDs)) {
                indices.insert(cues.count / 2)
            }
            requested = Set(indices.map { cues[$0].id })
        }
        let rows = cues.filter { requested.contains($0.id) }
        return TranslationPart(id: part.id, cueIDs: rows.map(\.id), startMS: rows.first?.startMS ?? part.startMS,
                               endMS: rows.last?.endMS ?? part.endMS,
                               characters: rows.reduce(0) { $0 + $1.text.count }, boundaryWarning: true)
    }

    private static func riskIDs(lecture: PreparedLecture, journal: TranslationJournal, issues: [LocalIssue]) -> Set<Int> {
        var ids = Set(issues.map(\.cueID))
        ids.formUnion(lecture.document.cues.filter { ReviewPlanning.safetyCue($0.text) }.map(\.id))
        // Keep the original risk in review history after Sol corrects it.
        for part in lecture.parts {
            guard let draft = journal.parts[part.id]?.draft else { continue }
            let draftText = Dictionary(uniqueKeysWithValues: draft.reply.translations.map { ($0.id, $0.text) })
            ids.formUnion(placeholderIssues(translations: draftText).map(\.cueID))
        }
        return ids
    }
}
