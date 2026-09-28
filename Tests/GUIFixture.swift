import Foundation

/// Explicit opt-in fixture builder for the isolated preview app. No user lectures,
/// account, quotas, model calls, or production state are used.
@main enum GUIFixture {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw TranslatorError.invalid("Specify the isolated preview-state directory") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        guard root.path.contains("/.build/package."), ["preview-state", "demo-state"].contains(root.lastPathComponent),
              !FileManager.default.fileExists(atPath: root.appendingPathComponent("queue.json").path) else {
            throw TranslatorError.invalid("Refusing to overwrite state or use a non-preview directory")
        }
        let store = CheckpointStore(root: root)
        let fixtures = root.appendingPathComponent("SyntheticLectures", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        var state = ProjectState(); state.manuallyPaused = true; state.translationPending = false
        for number in 1...3 {
            let source = fixtures.appendingPathComponent("Проверка \(number).srt")
            let bytes = Data("1\n00:00:04,000 --> 00:00:08,000\nGuten Morgen.\n\n2\n00:00:09,000 --> 00:00:13,000\nDas ist ein Beispiel.\n".utf8)
            try bytes.write(to: source, options: .withoutOverwriting)
            let lecture = try PreparedLecture.prepare(url: source, profile: .builtIns[0], settings: state.settings)
            var job = JobSummary(sourcePath: source.path)
            job.status = [JobStatus.needsReview, .translating, .queued][number - 1]; job.sourceHash = lecture.document.sourceHash
            job.cueCount = 2; job.completedCues = 2; job.partCount = 1
            var journal = TranslationJournal(sourceHash: lecture.document.sourceHash, settings: lecture.settings, profile: lecture.profile)
            let reply = TranslationReply(translations: [.init(id: 1, text: "Доброе утро."), .init(id: 2, text: "Это пример.")],
                                         issues: [.init(ids: [1], reason: "Искусственный пример замечания для проверки интерфейса.", critical: false)])
            let result = ModelResult(reply: reply, usage: nil, model: "gpt-5.6-terra", effort: "medium", elapsed: 0)
            journal.parts[1] = .init(draftAttempts: 1, draft: result, done: true)
            try store.save(lecture, id: job.id); try store.saveJournal(journal, id: job.id)
            state.jobs.append(job)
            try Data("1\n00:00:04,000 --> 00:00:08,000\nПредыдущий тестовый перевод.\n".utf8)
                .write(to: fixtures.appendingPathComponent("Проверка \(number).ru.srt"), options: .withoutOverwriting)
        }
        try store.save(state)
        try JSONEncoder().encode(RuntimePreferences(reserveConfigured: true))
            .write(to: root.appendingPathComponent("runtime-preferences.json"), options: .withoutOverwriting)
        try Data("{\"kind\":\"synthetic-demo-quota\",\"fiveHourRemaining\":65,\"weeklyRemaining\":78}\n".utf8)
            .write(to: root.appendingPathComponent("demo-quota.json"), options: .withoutOverwriting)
        try Data("{\"kind\":\"synthetic-demo-responses\",\"draft\":\"Это демонстрационный ответ.\",\"review\":\"Проверьте искусственный пример.\"}\n".utf8)
            .write(to: root.appendingPathComponent("demo-responses.json"), options: .withoutOverwriting)
        try Data("{\"kind\":\"synthetic-demo-media\",\"states\":[\"не прикреплено\",\"готово\",\"недоступно\"]}\n".utf8)
            .write(to: root.appendingPathComponent("demo-media-states.json"), options: .withoutOverwriting)
        print(fixtures.path)
    }
}
