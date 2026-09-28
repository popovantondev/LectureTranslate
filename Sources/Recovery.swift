import Foundation

enum ServiceLimit {
    // Only inspect service error events, never subtitle text or the model's answer.
    static func recognized(_ event: [String: Any]) -> Bool {
        guard ["error", "turn.failed"].contains(event["type"] as? String ?? "") else { return false }
        let error = event["error"] as? [String: Any] ?? event
        for value in [error["code"], error["codexErrorInfo"], event["code"]] {
            if let code = value as? String, ["usagelimitexceeded", "usage_limit_exceeded", "rate_limit_exceeded", "insufficient_quota"].contains(code.lowercased()) { return true }
        }
        let message = ((error["message"] as? String) ?? "").lowercased()
        return ["you've hit your usage limit", "usage limit exceeded", "usage limit reached", "rate limit exceeded", "rate limit reached", "insufficient quota"].contains { message.contains($0) }
    }
}

extension PartProgress {
    var chargedDraftAttempts: Int { draftAttempts - (draftQuotaDeferrals ?? 0) }
    var chargedReviewAttempts: Int { reviewAttempts - (reviewQuotaDeferrals ?? 0) }
    mutating func deferQuota(reviewing: Bool) {
        if reviewing { reviewQuotaDeferrals = (reviewQuotaDeferrals ?? 0) + 1 }
        else { draftQuotaDeferrals = (draftQuotaDeferrals ?? 0) + 1 }
    }
}

extension TranslationJournal {
    var quotaPaused: Bool { (consecutiveQuotaRefusals ?? 0) >= 3 }
    mutating func recordQuotaRefusal(partID: Int, reviewing: Bool, hasPartialResult: Bool) {
        version = max(version, 4)
        if !hasPartialResult { parts[partID]?.deferQuota(reviewing: reviewing) }
        consecutiveQuotaRefusals = (consecutiveQuotaRefusals ?? 0) + 1
    }
    mutating func acceptServiceResult() { if consecutiveQuotaRefusals != nil { consecutiveQuotaRefusals = 0 } }
    mutating func resumeAfterQuotaPause() { if quotaPaused { consecutiveQuotaRefusals = 0 } }
}

enum ReviewPlanning {
    static let strategy = "global-risk-v1"
    static func safetyCue(_ text: String) -> Bool {
        text.range(of: #"(?i)\b(mg|ml|milligramm|milliliter|dosierung|dosis|tropfen|gramm)\b|schwanger|stillzeit|stillen|kontraind|gegenanzeig|wechselwirkung|nebenwirkung|vergift|toxisch|nicht\s+(einnehmen|anwenden|verwenden|nehmen)"#, options: .regularExpression) != nil
    }
    static func score(_ part: TranslationPart, lecture: PreparedLecture, journal: TranslationJournal) -> Int {
        let cues = lecture.document.cues.filter { part.cueIDs.contains($0.id) }
        let text = cues.map(\.text).joined(separator: " ").lowercased()
        func matches(_ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }
        var score = 0
        if matches(#"\b(mg|ml|milligramm|milliliter|dosierung|dosis|tropfen|gramm)\b"#) { score += 400 }
        if matches(#"schwanger|stillzeit|stillen|kontraind|gegenanzeig|wechselwirkung|nebenwirkung|vergift|toxisch|nicht\s+(einnehmen|anwenden|verwenden|nehmen)"#) { score += 500 }
        let issues = journal.parts[part.id]?.draft?.reply.issues ?? []
        score += min(4, issues.filter(\.critical).count) * 150
        score += min(3, issues.filter { !$0.critical }.count) * 30
        score += min(3, lecture.issues.filter { part.cueIDs.contains($0.cueID) }.count) * 25
        if lecture.settings.outputStyle == "spoken" {
            let translations = journal.translated
            let unsafe = cues.filter { cue in
                translations[cue.id].map { !SpeechText.issues(text: $0, cueID: cue.id).isEmpty } ?? false
            }
            score += min(4, unsafe.count) * 150
        }
        score = max(score, ReviewBatch.issueScore(part, lecture: lecture, journal: journal))
        if score == 0 && part.id == lecture.parts.first?.id { score = 1 } // Small independent sample, only after more serious risks.
        return score
    }
    static func plan(lecture: PreparedLecture, journal: TranslationJournal) -> [Int] {
        ReviewBatch.plan(lecture: lecture, journal: journal)?.selectedPartIDs ?? []
    }
}
