import Foundation

/// Local export of already-paid translations. Never calls a model or alters review status.
struct SRTExportCandidate {
    let job: JobSummary
    let lecture: PreparedLecture
    let journal: TranslationJournal
    let destination: URL
    let bytes: Data
    let issueCount: Int
    let speechIssueCount: Int
}

enum SRTExport {
    static func shouldAutomaticallySave(issueCount: Int) -> Bool { issueCount == 0 }

    struct Reservation { let jobID: UUID; let title: String }
    struct CollisionGroup { let destination: URL; let candidates: [SRTExportCandidate] }
    enum CollisionDecision { case separate([UUID: URL]), keep(UUID), cancel }
    struct CollisionResolution { let destinations: [UUID: URL]; let keptInProject: Set<UUID>; let cancelled: Bool }
    typealias Reservations = [String: [Reservation]]
    /// Detect collisions among this batch before any destination is written.
    static func collisions(_ candidates: [SRTExportCandidate]) -> [CollisionGroup] {
        let groups = Dictionary(grouping: candidates, by: { key($0.destination) })
        return groups.values.filter { $0.count > 1 }.compactMap { group in
            guard let first = group.first else { return nil }
            return CollisionGroup(destination: first.destination, candidates: group)
        }.sorted { $0.destination.path < $1.destination.path }
    }
    static func resolve(_ group: CollisionGroup, decision: CollisionDecision) throws -> CollisionResolution {
        switch decision {
        case .cancel: return .init(destinations: [:], keptInProject: [], cancelled: true)
        case .keep(let id):
            guard group.candidates.contains(where: { $0.job.id == id }) else {
                throw TranslatorError.invalid("Выбранный перевод не входит в эту коллизию.")
            }
            return .init(destinations: [:], keptInProject: Set(group.candidates.map { $0.job.id }.filter { $0 != id }), cancelled: false)
        case .separate(let destinations):
            let ids = Set(group.candidates.map { $0.job.id })
            guard Set(destinations.keys) == ids, destinations.values.allSatisfy({ $0.pathExtension.lowercased() == "srt" }),
                  Set(destinations.values.map(key)).count == destinations.count else {
                throw TranslatorError.invalid("Для каждой лекции укажите отдельный SRT-путь. Переводы не потеряны.")
            }
            return .init(destinations: destinations, keptInProject: [], cancelled: false)
        }
    }
    static func key(_ destination: URL) -> String {
        destination.resolvingSymlinksInPath().standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
    }
    /// Both prospective and previously exported paths belong to their lecture, not
    /// merely to the subset of jobs in a failed-auto-export retry dialog.
    static func reservations(state: ProjectState, store: CheckpointStore) -> Reservations {
        var result: Reservations = [:]
        for job in state.jobs {
            var paths = [TranslationPipeline.destination(source: URL(fileURLWithPath: job.sourcePath), settings: state.settings)]
            if let bytes = try? Data(contentsOf: store.journalURL(job.id)),
               let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
               let path = object["exportedPath"] as? String, path.hasPrefix("/") {
                paths.append(URL(fileURLWithPath: path))
            }
            for path in paths { result[key(path), default: []].append(.init(jobID: job.id, title: job.title)) }
        }
        return result
    }
    static func validateDestination(_ destination: URL, for jobID: UUID, reservations: Reservations) throws {
        if let other = reservations[key(destination)]?.first(where: { $0.jobID != jobID }) {
            throw TranslatorError.invalid("Этот путь также принадлежит другой лекции «\(other.title)». Файл не заменён. Сохраните лекции в разные папки через «Сохранить этот SRT…» или выберите сохранение рядом с исходниками.")
        }
    }
    static func prepare(job: JobSummary, settings: TranslationSettings, store: CheckpointStore) throws -> SRTExportCandidate {
        let lecture = try store.loadLecture(job.id)
        // Do not manufacture an empty journal if a checkpoint is missing.
        let journal = try JSONDecoder().decode(TranslationJournal.self, from: Data(contentsOf: store.journalURL(job.id)))
        try TranslationPipeline.verifySource(job, lecture: lecture)
        let bytes = try TranslationPipeline.renderedData(lecture: lecture, journal: journal)
        let speechIssueCount = lecture.settings.outputStyle == "spoken"
            ? journal.translated.reduce(0) { $0 + SpeechText.issues(text: $1.value, cueID: $1.key).count } : 0
        return .init(job: job, lecture: lecture, journal: journal,
                     destination: TranslationPipeline.destination(source: URL(fileURLWithPath: job.sourcePath), settings: settings),
                     bytes: bytes, issueCount: journal.issues(for: lecture).count, speechIssueCount: speechIssueCount)
    }

    static func matchingOutput(bytes: Data, at destination: URL, protectedSources: [URL]) throws -> Bool {
        guard try FilePublication.inspect(destination, protectedSources: protectedSources) != nil else { return false }
        // Check the normal file before reading; FilePublication rejects symlinks and protected inputs.
        return try Data(contentsOf: destination) == bytes
    }

    static func status(issueCount: Int, path: String) -> (JobStatus, String) {
        (issueCount == 0 ? .exported : .needsReview,
         "Файл SRT сохранён: \(path)" + (issueCount == 0 ? " · локальные проверки пройдены; это не проверка звучания." : " · перевод сохранён, замечаний: \(issueCount); готовность к озвучке не подтверждена."))
    }

    /// Snapshot inputs and reject an edit made while the overwrite dialog was open.
    @discardableResult static func publish(_ candidate: SRTExportCandidate, to destination: URL, store: CheckpointStore,
                                         replacing: FilePublication.Existing?, protectedSources: [URL]) throws -> URL? {
        guard destination.pathExtension.lowercased() == "srt" else { throw TranslatorError.invalid("Для субтитров нужно расширение .srt.") }
        try TranslationPipeline.verifySource(candidate.job, lecture: candidate.lecture)
        let current = try JSONDecoder().decode(TranslationJournal.self, from: Data(contentsOf: store.journalURL(candidate.job.id)))
        guard try TranslationPipeline.renderedData(lecture: candidate.lecture, journal: current) == candidate.bytes else {
            throw TranslatorError.invalid("Перевод изменился во время сохранения. Повторите сохранение, готовые ответы не потеряны.")
        }
        return try FilePublication.publish(candidate.bytes, to: destination, replacing: replacing,
                                           backupDirectory: store.root.appendingPathComponent("file-backups", isDirectory: true),
                                           protectedSources: protectedSources)
    }
}
