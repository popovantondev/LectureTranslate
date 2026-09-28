import Foundation

/// A portable snapshot, not a reference to the live queue and not an archive of media.
/// Sources keep their original paths and hashes; opening a project never guesses a replacement.
enum ProjectArchive {
    static let fileExtension = "lectureproject"
    static let maximumBytes = 256 * 1024 * 1024
    private static let maximumCheckpointBytes = 32 * 1024 * 1024

    struct Entry: Codable {
        let jobID: UUID
        let lecture: PreparedLecture?
        let journal: TranslationJournal?
    }
    struct Payload: Codable {
        let state: ProjectState
        let entries: [Entry]
    }
    struct Envelope: Codable {
        let format: String
        let version: Int
        let createdAt: Date
        let payloadHash: String
        let payload: Payload
    }

    struct ImportedProject {
        let state: ProjectState
        let warnings: [String]
        fileprivate let createdFiles: [(url: URL, hash: String)]

        /// Call only when saving the returned queue fails. Existing jobs, queue.json and
        /// files modified after import are never removed by this transaction rollback.
        func rollback() {
            for file in createdFiles.reversed() {
                guard let bytes = try? ProjectArchive.read(file.url, maximum: ProjectArchive.maximumCheckpointBytes),
                      SRTDocument.hash(bytes) == file.hash else { continue }
                try? FileManager.default.removeItem(at: file.url)
            }
        }
    }

    /// The caller first pauses the worker and waits for it to finish writing checkpoints.
    /// Replacement is opt-in and tied to the exact inspected file, never merely to
    /// an OK response from NSSavePanel. Automatic/background callers remain create-only.
    @discardableResult
    static func save(state: ProjectState, store: CheckpointStore, to destination: URL,
                     replacing: FilePublication.Existing? = nil) throws -> URL? {
        try validateDestination(destination)
        try validate(state)
        var entries: [Entry] = []
        var totalBytes = 0
        for job in state.jobs {
            let lectureURL = store.jobURL(job.id), journalURL = store.journalURL(job.id)
            var lecture: PreparedLecture?, journal: TranslationJournal?
            if exists(lectureURL) {
                let bytes = try read(lectureURL, maximum: maximumCheckpointBytes)
                totalBytes += bytes.count
                lecture = try JSONDecoder().decode(PreparedLecture.self, from: bytes)
            }
            if exists(journalURL) {
                let bytes = try read(journalURL, maximum: maximumCheckpointBytes)
                totalBytes += bytes.count
                journal = try JSONDecoder().decode(TranslationJournal.self, from: bytes)
            }
            guard totalBytes <= maximumBytes else { throw invalid("Проект больше 256 МиБ. Сохраните очередь несколькими проектами.") }
            // Do not turn a missing/corrupt journal into an empty translation with store.journal().
            entries.append(Entry(jobID: job.id, lecture: lecture, journal: journal))
        }
        var snapshot = state
        snapshot.projectFilePath = destination.standardizedFileURL.path
        snapshot.manuallyPaused = true; snapshot.translationPending = false; snapshot.resumeAt = nil
        let payload = Payload(state: snapshot, entries: entries)
        try validate(payload)
        let envelope = Envelope(format: "lecture-translate-project", version: 1, createdAt: Date(),
                                payloadHash: SRTDocument.hash(try encode(payload)), payload: payload)
        let bytes = try encode(envelope)
        guard bytes.count <= maximumBytes else { throw invalid("Проект больше 256 МиБ. Сохраните очередь несколькими проектами.") }
        return try FilePublication.publish(bytes, to: destination, replacing: replacing,
            backupDirectory: store.root.appendingPathComponent("file-backups", isDirectory: true),
            protectedSources: protectedSources(in: state))
    }

    /// Validates the entire archive before creating any live job. The caller owns queue.json:
    /// save imported.state atomically, or call imported.rollback() if that save fails.
    static func open(from source: URL, into store: CheckpointStore) throws -> ImportedProject {
        try validateDestination(source)
        let envelope = try JSONDecoder().decode(Envelope.self, from: read(source, maximum: maximumBytes))
        guard envelope.format == "lecture-translate-project", envelope.version == 1,
              envelope.createdAt.timeIntervalSinceReferenceDate.isFinite,
              envelope.payloadHash == SRTDocument.hash(try encode(envelope.payload)) else {
            throw invalid("Файл проекта повреждён или создан неподдерживаемой версией. Текущая очередь не изменена.")
        }
        try validate(envelope.payload)
        var state = envelope.payload.state
        // The embedded path is documentary only. A copied/moved project must save
        // back to the file actually opened, not to its previous machine/location.
        state.projectFilePath = source.standardizedFileURL.path
        state.manuallyPaused = true; state.translationPending = false; state.resumeAt = nil
        var staged: [(url: URL, bytes: Data)] = []
        var warnings: [String] = []
        let byID = Dictionary(uniqueKeysWithValues: envelope.payload.entries.map { ($0.jobID, $0) })
        for index in state.jobs.indices {
            let entry = byID[state.jobs[index].id]!
            // New identities prevent an imported project from overwriting active or archived jobs.
            let id = UUID()
            state.jobs[index].id = id
            if let lecture = entry.lecture {
                staged.append((store.jobURL(id), try encode(lecture)))
                state.jobs[index].sourceHash = lecture.document.sourceHash
                state.jobs[index].cueCount = lecture.document.cues.count
                state.jobs[index].partCount = lecture.parts.count
                state.jobs[index].completedCues = entry.journal?.translated.count ?? lecture.completedTranslations.count
                if let journal = entry.journal {
                    staged.append((store.journalURL(id), try encode(journal)))
                    if state.jobs[index].isArchivedRevision {
                        state.jobs[index].status = .sourceChanged
                        state.jobs[index].message = "Архивная ревизия сохранена отдельно; её переводы и таймкоды не применяются к текущему исходнику."
                    } else {
                        let restored = TranslationPipeline.restoredStatus(lecture: lecture, journal: journal)
                        state.jobs[index].status = restored.0; state.jobs[index].message = restored.1
                    }
                } else {
                    state.jobs[index].status = .prepared
                    state.jobs[index].message = "Проект открыт на паузе. Подготовка сохранена; перевод не запускался."
                }
            } else {
                state.jobs[index].status = .queued
                state.jobs[index].message = "Проект открыт на паузе. Требуется локальная подготовка."
            }
            if !FileManager.default.fileExists(atPath: state.jobs[index].sourcePath) {
                warnings.append("Не найден исходник: \(state.jobs[index].sourcePath)")
                state.jobs[index].status = .invalid
                state.jobs[index].message = "Исходник не найден. Готовые части сохранены; перед продолжением верните SRT по исходному пути."
            }
        }
        let jobsDirectory = store.root.appendingPathComponent("jobs", isDirectory: true)
        if !staged.isEmpty {
            if exists(jobsDirectory) {
                let attributes = try FileManager.default.attributesOfItem(atPath: jobsDirectory.path)
                guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                    throw invalid("Папка рабочих журналов не является обычной папкой. Текущая очередь не изменена.")
                }
            } else { try FileManager.default.createDirectory(at: jobsDirectory, withIntermediateDirectories: true) }
        }
        var created: [(url: URL, hash: String)] = []
        do {
            for file in staged {
                guard file.bytes.count <= maximumCheckpointBytes else { throw invalid("Слишком большой журнал в проекте.") }
                try FilePublication.publish(file.bytes, to: file.url)
                created.append((file.url, SRTDocument.hash(file.bytes)))
            }
        } catch {
            ImportedProject(state: state, warnings: [], createdFiles: created).rollback()
            throw error
        }
        return ImportedProject(state: state, warnings: warnings, createdFiles: created)
    }

    private static func validate(_ payload: Payload) throws {
        try validate(payload.state)
        guard payload.entries.count == payload.state.jobs.count,
              Set(payload.entries.map(\.jobID)).count == payload.entries.count,
              Set(payload.entries.map(\.jobID)) == Set(payload.state.jobs.map(\.id)) else {
            throw invalid("Номера заданий в проекте не совпадают с очередью.")
        }
        let jobs = Dictionary(uniqueKeysWithValues: payload.state.jobs.map { ($0.id, $0) })
        for entry in payload.entries {
            let job = jobs[entry.jobID]!
            if let lecture = entry.lecture {
                try validate(lecture)
                guard job.sourceHash == nil || job.sourceHash == lecture.document.sourceHash else {
                    throw invalid("Контрольная сумма исходника не совпадает с сохранённой лекцией: \(job.title)")
                }
                if let journal = entry.journal { try validate(journal, lecture: lecture) }
                else if job.completedCues > 0 || [.translated, .needsReview, .exported].contains(job.status) {
                    throw invalid("Нет журнала перевода для завершённого задания: \(job.title)")
                }
            } else {
                guard entry.journal == nil, job.sourceHash == nil, job.cueCount == 0,
                      job.completedCues == 0, job.partCount == 0,
                      [.queued, .invalid, .paused, .translationError, .sourceChanged].contains(job.status) else {
                    throw invalid("Отсутствует подготовленная лекция, на которую ссылается очередь: \(job.title)")
                }
            }
        }
    }

    private static func validate(_ state: ProjectState) throws {
        guard state.version == 1, state.jobs.count <= 10_000,
              Set(state.jobs.map(\.id)).count == state.jobs.count,
              !state.profiles.isEmpty, state.profiles.count <= 1000,
              Set(state.profiles.map(\.id)).count == state.profiles.count,
              state.profiles.contains(where: { $0.id == state.settings.profileID }) else {
            throw invalid("Некорректная очередь или список профилей в проекте.")
        }
        try validate(state.settings)
        guard state.projectFilePath == nil || (path(state.projectFilePath!) &&
                URL(fileURLWithPath: state.projectFilePath!).pathExtension.lowercased() == fileExtension) else {
            throw invalid("Некорректный путь файла проекта.")
        }
        for profile in state.profiles { try validate(profile) }
        for job in state.jobs {
            guard path(job.sourcePath), URL(fileURLWithPath: job.sourcePath).pathExtension.lowercased() == "srt",
                  job.originalVideoPath == nil || path(job.originalVideoPath!),
                  job.sourceHash == nil || hash(job.sourceHash!), (0...200_000).contains(job.cueCount),
                  (0...job.cueCount).contains(job.completedCues), (0...10_000).contains(job.partCount),
                  job.message.count <= 100_000 else { throw invalid("Некорректное задание в проекте.") }
        }
    }

    private static func validate(_ settings: TranslationSettings) throws {
        guard SupportedCodexModels.ids.contains(settings.model),
              SupportedCodexModels.ids.contains(settings.reviewModel),
              ["medium", "high"].contains(settings.effort), ["medium", "high"].contains(settings.reviewEffort),
              settings.reserve.isFinite, settings.reserve >= 0, settings.reserve < 100,
              ["spoken", "display"].contains(settings.outputStyle), (0...1).contains(settings.maxRepairPasses),
              settings.maxReviewPassesPerPart == 1, (1...10).contains(settings.maxReviewCallsPerLecture) else {
            throw invalid("Неподдерживаемые или небезопасные настройки в проекте.")
        }
        guard settings.outputLocation == nil || ["source", "downloads", "custom"].contains(settings.outputLocation!),
              settings.customOutputDirectory == nil || path(settings.customOutputDirectory!),
              settings.outputLocation != "custom" || settings.customOutputDirectory != nil else {
            throw invalid("Некорректная папка сохранения в проекте.")
        }
    }

    private static func validate(_ profile: TranslationProfile) throws {
        guard !profile.id.isEmpty, profile.id.count <= 200, !profile.name.isEmpty, profile.name.count <= 1000,
              profile.subject.count <= 100_000, profile.glossary.count <= 1_000_000 else {
            throw invalid("Некорректный профиль перевода в проекте.")
        }
    }

    private static func validate(_ lecture: PreparedLecture) throws {
        try validate(lecture.settings); try validate(lecture.profile)
        guard lecture.version == PreparedLecture.pipelineVersion, hash(lecture.document.sourceHash),
              lecture.settings.profileID == lecture.profile.id,
              !lecture.document.cues.isEmpty, lecture.document.cues.count <= 200_000,
              !lecture.parts.isEmpty, lecture.parts.count <= 10_000,
              lecture.videoPaths.count <= 100, lecture.videoPaths.allSatisfy(path) else {
            throw invalid("Повреждена подготовленная лекция в проекте.")
        }
        let cues = lecture.document.cues
        // Parse reconstructed blocks to reject duplicate IDs, invalid/forged numeric timing,
        // unsupported display text and overflow before any dictionary/interval uses these fields.
        let reconstructed = cues.map { "\($0.id)\n\($0.timingLine)\n\($0.text)\n" }.joined(separator: "\n")
        let reparsed = try SRTDocument.parse(Data(reconstructed.utf8))
        guard reparsed.cues == cues, lecture.parts.map(\.id) == Array(1...lecture.parts.count),
              lecture.parts.flatMap(\.cueIDs) == cues.map(\.id) else {
            throw invalid("Повреждены реплики, таймкоды или границы частей в проекте.")
        }
        let byID = Dictionary(uniqueKeysWithValues: cues.map { ($0.id, $0) })
        for part in lecture.parts {
            let group = part.cueIDs.compactMap { byID[$0] }
            guard !group.isEmpty, part.startMS == group.first!.startMS, part.endMS == group.last!.endMS,
                  part.characters == group.reduce(0, { $0 + $1.text.count }) else {
                throw invalid("Некорректные границы части в проекте.")
            }
        }
        guard lecture.issues.count <= 1_000_000,
              lecture.issues.allSatisfy({ byID[$0.cueID] != nil && !$0.reason.isEmpty && $0.reason.count <= 100_000 }),
              Set(lecture.completedTranslations.keys).isSubset(of: Set(byID.keys)) else {
            throw invalid("Некорректные замечания или переводы в подготовленной лекции.")
        }
        if !lecture.completedTranslations.isEmpty {
            _ = try TranslationReply(translations: lecture.completedTranslations.map { .init(id: $0.key, text: $0.value) },
                                     issues: []).validated(ids: Array(lecture.completedTranslations.keys))
        }
    }

    private static func validate(_ journal: TranslationJournal, lecture: PreparedLecture) throws {
        try journal.validate(lecture: lecture)
        let cueIDs = Set(lecture.document.cues.map(\.id))
        guard (journal.acknowledgedIssues ?? []).allSatisfy(hash),
              (journal.confirmedTerms ?? []).count <= 10_000,
              journal.exportedPath == nil || path(journal.exportedPath!),
              (journal.manualHistory ?? []).allSatisfy({
                  cueIDs.contains($0.cueID) && $0.date.timeIntervalSinceReferenceDate.isFinite &&
                  !$0.text.isEmpty && $0.text.count <= 14_000 && !$0.previousText.isEmpty && $0.previousText.count <= 14_000 &&
                  ($0.confirmedReason?.count ?? 0) <= 100_000
              }) else { throw invalid("Повреждена история ручных правок или словарь в проекте.") }
        for progress in journal.parts.values {
            guard progress.review == nil || progress.draft != nil,
                  progress.draft == nil || progress.draftAttempts > 0,
                  progress.review == nil || progress.reviewAttempts > 0 else {
                throw invalid("Результаты в журнале не совпадают с историей запросов.")
            }
            for result in [progress.draft, progress.review].compactMap({ $0 }) {
                guard result.elapsed.isFinite, result.elapsed >= 0,
                      SupportedCodexModels.ids.contains(result.model),
                      ["medium", "high"].contains(result.effort) else { throw invalid("Повреждён результат перевода.") }
                if let usage = result.usage {
                    guard [usage.input_tokens, usage.cached_input_tokens, usage.output_tokens, usage.reasoning_output_tokens ?? 0]
                        .allSatisfy({ (0...10_000_000_000).contains($0) }) else { throw invalid("Повреждён учёт запросов в проекте.") }
                }
            }
        }
    }

    private static func validateDestination(_ url: URL) throws {
        guard url.isFileURL, url.pathExtension.lowercased() == fileExtension else {
            throw invalid("Выберите файл с расширением .lectureproject.")
        }
    }

    /// Used only by Save As. Core save/open methods require a valid explicit name.
    static func normalizedDestination(_ url: URL) throws -> URL {
        guard url.isFileURL, path(url.path) else { throw invalid("Выберите локальный файл проекта.") }
        // A selected directory/symlink must not become an implied replacement after
        // extension normalization. Inspect the original selection as well.
        _ = try FilePublication.inspect(url)
        var name = url.lastPathComponent
        let suffix = "." + fileExtension
        while name.lowercased().hasSuffix(suffix) { name.removeLast(suffix.count) }
        if name.isEmpty { name = "Лекции" }
        return url.deletingLastPathComponent().appendingPathComponent(name + suffix)
    }

    static func protectedSources(in state: ProjectState) -> [URL] {
        state.jobs.flatMap { job in
            [URL(fileURLWithPath: job.sourcePath)] + (job.originalVideoPath.map { [URL(fileURLWithPath: $0)] } ?? [])
        }
    }
    private static func hash(_ value: String) -> Bool {
        value.count == 64 && value.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
    }
    private static func path(_ value: String) -> Bool {
        value.hasPrefix("/") && value.utf8.count <= 16_384 && !value.contains("\0")
    }
    private static func invalid(_ message: String) -> TranslatorError { .invalid(message) }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    private static func exists(_ url: URL) -> Bool {
        // attributesOfItem also sees broken symlinks; they must not be treated as an absent checkpoint.
        FileManager.default.fileExists(atPath: url.path) || (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }
    private static func read(_ url: URL, maximum: Int) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value <= Int64(maximum) else {
            throw invalid("Неподдерживаемый тип или слишком большой файл: \(url.lastPathComponent)")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: maximum + 1) ?? Data()
        guard bytes.count <= maximum else { throw invalid("Файл изменился или превысил безопасный размер.") }
        return bytes
    }
}
