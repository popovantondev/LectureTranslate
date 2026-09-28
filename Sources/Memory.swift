import Foundation

struct MemoryNote: Codable, Equatable {
    let ids: [Int]
    let text: String
}

struct TermProposal: Codable, Equatable {
    let ids: [Int]
    let german: String
    let russian: String
    let reason: String
}

struct ConfirmedTerm: Codable, Equatable {
    let german: String
    let russian: String
}

enum TermText {
    static func normalized(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.lowercased().replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func contains(_ source: String, term: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: normalized(term))
        guard !escaped.isEmpty else { return false }
        return normalized(source).range(of: "(?<![\\p{L}\\p{N}])" + escaped + "(?![\\p{L}\\p{N}])", options: .regularExpression) != nil
    }
    static func safe(_ text: String, maximum: Int) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= maximum &&
        !text.contains("\n") && !text.contains("\r") && !text.contains("-->") && !text.contains("=>")
    }
}

extension TranslationReply {
    /// Extra metadata is best-effort. Invalid metadata never discards an otherwise valid expensive translation.
    func safeNotes(cues: [Cue], allowed: Set<Int>) -> [MemoryNote] {
        (memory ?? []).prefix(4).filter {
            !$0.ids.isEmpty && $0.ids.count <= 6 && Set($0.ids).isSubset(of: allowed) && TermText.safe($0.text, maximum: 240)
        }
    }
    func safeTerms(cues: [Cue], allowed: Set<Int>) -> [TermProposal] {
        (terms ?? []).prefix(8).filter { term in
            !term.ids.isEmpty && term.ids.count <= 6 && Set(term.ids).isSubset(of: allowed) &&
            TermText.safe(term.german, maximum: 80) && TermText.safe(term.russian, maximum: 120) && TermText.safe(term.reason, maximum: 240) &&
            TermText.contains(cues.filter { term.ids.contains($0.id) }.map(\.text).joined(separator: " "), term: term.german)
        }
    }
    static var memorySchema: String {
        // Extend the old schema only for new journals. Legacy unfinished requests keep the original contract.
        var object = try! JSONSerialization.jsonObject(with: Data(schema.utf8)) as! [String: Any]
        var properties = object["properties"] as! [String: Any]
        let ids: [String: Any] = ["type": "array", "maxItems": 6, "items": ["type": "integer"]]
        properties["memory"] = ["type": "array", "maxItems": 4, "items": ["type": "object", "additionalProperties": false,
            "required": ["ids", "text"], "properties": ["ids": ids, "text": ["type": "string", "maxLength": 240]]]]
        properties["terms"] = ["type": "array", "maxItems": 8, "items": ["type": "object", "additionalProperties": false,
            "required": ["ids", "german", "russian", "reason"], "properties": ["ids": ids,
                "german": ["type": "string", "maxLength": 80], "russian": ["type": "string", "maxLength": 120], "reason": ["type": "string", "maxLength": 240]]]]
        object["properties"] = properties
        object["required"] = ["translations", "issues", "memory", "terms"]
        return String(data: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)!
    }
}

extension TranslationJournal {
    func partMetadata(_ part: TranslationPart, lecture: PreparedLecture) -> (notes: [MemoryNote], terms: [TermProposal]) {
        guard memoryEnabled == true, let record = parts[part.id], record.done || (reviewStrategy == ReviewPlanning.strategy && record.draft != nil) else { return ([], []) }
        let blocked = Set(issues(for: lecture).map(\.cueID))
        let reviewed = Set(record.review?.reply.translations.map(\.id) ?? [])
        var notes: [MemoryNote] = [], terms: [TermProposal] = []
        for (result, allowed, excluded) in [(record.draft, Set(part.cueIDs), reviewed), (record.review, reviewed, Set<Int>())] {
            guard let reply = result?.reply else { continue }
            notes += reply.safeNotes(cues: lecture.document.cues, allowed: allowed).filter { Set($0.ids).isDisjoint(with: blocked.union(excluded)) }
            terms += reply.safeTerms(cues: lecture.document.cues, allowed: allowed).filter { Set($0.ids).isDisjoint(with: excluded) }
        }
        // Manual corrections invalidate potentially stale machine memory, even after issue confirmation.
        let manuallyEdited = Set((manualTranslations ?? [:]).keys)
        return (notes.filter { Set($0.ids).isDisjoint(with: manuallyEdited) }, terms)
    }
    func memoryContext(lecture: PreparedLecture, before part: TranslationPart) -> String {
        guard memoryEnabled == true else { return "" }
        let candidates = lecture.parts.filter { $0.id < part.id }.flatMap { partMetadata($0, lecture: lecture).notes }
        // Keep a small opening anchor as well as recent context; the full local ledger is not resent.
        let priority = Array(candidates.indices.prefix(2)) + Array(candidates.indices.reversed())
        var entries: [(Int, String)] = [], size = 0, seen = Set<Int>()
        for index in priority where seen.insert(index).inserted {
            let note = candidates[index]
            let evidence = lecture.document.cues.filter { note.ids.contains($0.id) }.map { "\($0.id):\($0.text)" }.joined(separator: " ")
            let entry = "ID \(note.ids.map(String.init).joined(separator: ",")): \(note.text)\nDE: \(evidence.prefix(300))"
            if size + entry.count > 2200 || entries.count >= 8 { continue }
            entries.append((index, entry)); size += entry.count
        }
        return entries.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: "\n")
    }
    func confirmedContext(lecture: PreparedLecture, part: TranslationPart) -> String {
        let text = lecture.document.cues.filter { part.cueIDs.contains($0.id) }.map(\.text).joined(separator: " ")
        var result: [String] = [], count = 0
        for term in confirmedTerms ?? [] where TermText.contains(text, term: term.german) {
            let entry = "\(term.german) => \(term.russian)"
            guard result.count < 30, count + entry.count <= 2400 else { break }
            result.append(entry); count += entry.count
        }
        return result.joined(separator: "\n")
    }
}

struct TermEvidence: Codable, Equatable {
    let sourcePath: String
    let sourceHash: String
    let ids: [Int]
    let germanContext: String
    let russianContext: String
    let reason: String
}
struct LibraryTerm: Codable, Identifiable {
    enum Status: String, Codable { case proposed, confirmed, deferred }
    let id: String
    let profileID: String
    var german: String
    var russian: String
    var status: Status = .proposed
    var evidence: [TermEvidence]
    var confirmedAt: Date?
}
struct TermLibrary: Codable {
    var version = 1
    var entries: [LibraryTerm] = []
    func confirmed(profile: TranslationProfile) -> [ConfirmedTerm] {
        // A manual profile entry wins over the shared library; conflicts never silently change it.
        let manual = Set(profile.glossary.components(separatedBy: .newlines).map { TermText.normalized($0.components(separatedBy: "=>")[0]) })
        return entries.filter { $0.profileID == profile.id && $0.status == .confirmed && !manual.contains(TermText.normalized($0.german)) }
            .sorted { $0.german.localizedStandardCompare($1.german) == .orderedAscending }.map { .init(german: $0.german, russian: $0.russian) }
    }
    mutating func collect(lecture: PreparedLecture, journal: TranslationJournal, sourcePath: String) {
        for part in lecture.parts {
            for term in journal.partMetadata(part, lecture: lecture).terms {
                let id = SRTDocument.hash(Data("\(lecture.profile.id)|\(TermText.normalized(term.german))|\(TermText.normalized(term.russian))".utf8))
                let evidence = TermEvidence(sourcePath: sourcePath, sourceHash: lecture.document.sourceHash, ids: term.ids,
                    germanContext: String(lecture.document.cues.filter { term.ids.contains($0.id) }.map(\.text).joined(separator: " ").prefix(1500)),
                    russianContext: String(term.ids.compactMap { journal.translated[$0] }.joined(separator: " ").prefix(1500)), reason: term.reason)
                if let index = entries.firstIndex(where: { $0.id == id }) {
                    if entries[index].evidence.count < 5 && !entries[index].evidence.contains(evidence) { entries[index].evidence.append(evidence) }
                } else { entries.append(.init(id: id, profileID: lecture.profile.id, german: term.german, russian: term.russian, evidence: [evidence])) }
            }
        }
    }
    mutating func confirm(id: String, german: String? = nil, russian: String, checked: Bool) throws {
        guard checked, TermText.safe(russian, maximum: 120), let index = entries.firstIndex(where: { $0.id == id }) else {
            throw TranslatorError.invalid("Укажите перевод термина и подтвердите его проверку.")
        }
        let entry = entries[index]
        let selectedGerman = (german ?? entry.german).trimmingCharacters(in: .whitespacesAndNewlines)
        guard TermText.safe(selectedGerman, maximum: 80) else { throw TranslatorError.invalid("Проверьте немецкое написание термина.") }
        guard !entries.contains(where: { $0.id != id && $0.profileID == entry.profileID && $0.status == .confirmed && TermText.normalized($0.german) == TermText.normalized(selectedGerman) }) else {
            throw TranslatorError.invalid("Этот немецкий термин уже подтверждён. Сначала снимите подтверждение старой записи; существующий перевод не заменён.")
        }
        entries[index].german = selectedGerman
        entries[index].russian = russian.trimmingCharacters(in: .whitespacesAndNewlines)
        entries[index].status = .confirmed; entries[index].confirmedAt = Date()
    }
    mutating func setStatus(id: String, status: LibraryTerm.Status) throws {
        guard status != .confirmed, let index = entries.firstIndex(where: { $0.id == id }) else { throw TranslatorError.invalid("Неизвестный термин.") }
        entries[index].status = status; entries[index].confirmedAt = nil
    }
    func validate() throws {
        guard version == 1, Set(entries.map(\.id)).count == entries.count,
              entries.allSatisfy({ TermText.safe($0.german, maximum: 80) && TermText.safe($0.russian, maximum: 120) && !$0.profileID.isEmpty && ($0.status != .confirmed || $0.confirmedAt != nil) }) else {
            throw TranslatorError.invalid("Не удалось проверить словарь терминов. Старый файл не перезаписан.")
        }
        let keys = entries.filter { $0.status == .confirmed }.map { $0.profileID + "|" + TermText.normalized($0.german) }
        guard Set(keys).count == keys.count else { throw TranslatorError.invalid("Конфликт подтверждённых терминов в словаре.") }
    }
}
extension CheckpointStore {
    var termsURL: URL { root.appendingPathComponent("terms.json") }
    func termLibrary() throws -> TermLibrary {
        guard FileManager.default.fileExists(atPath: termsURL.path) else { return TermLibrary() }
        let result = try JSONDecoder().decode(TermLibrary.self, from: Data(contentsOf: termsURL)); try result.validate(); return result
    }
    func saveTerms(_ library: TermLibrary) throws {
        try library.validate()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(library).write(to: termsURL, options: .atomic)
    }
    func collectTerms(lecture: PreparedLecture, journal: TranslationJournal, sourcePath: String) throws {
        guard journal.memoryEnabled == true else { return }
        var library = try termLibrary(); library.collect(lecture: lecture, journal: journal, sourcePath: sourcePath); try saveTerms(library)
    }
}
