import Foundation

// Quota.swift references the app runtime flag, while this focused offline target
// intentionally excludes AppKit startup code.
enum TranslatorRuntime { static var isDemoBuild: Bool { false } }

@main
enum SpeechIntegrationTests {
    static var passed = 0
    static func check(_ value: @autoclosure () -> Bool, _ name: String) {
        guard value() else { fputs("FAIL: \(name)\n", stderr); exit(1) }
        passed += 1
    }

    static func fixture(style: String, reviewBudget: Int = 1) -> PreparedLecture {
        let cues = (0..<13).map { index in
            let start = index * 20, end = start + 19
            return Cue(id: index * 10 + 7, startMS: start * 1000, endMS: end * 1000,
                       timingLine: String(format: "00:%02d:%02d,000 --> 00:%02d:%02d,000", start / 60, start % 60, end / 60, end % 60),
                       text: "Hier folgt eine gewöhnliche Aussage.")
        }
        let groups = [[cues[0]], Array(cues[1...11]), [cues[12]]]
        let parts = groups.enumerated().map { index, rows in
            TranslationPart(id: index + 1, cueIDs: rows.map(\.id), startMS: rows[0].startMS, endMS: rows.last!.endMS,
                            characters: rows.reduce(0) { $0 + $1.text.count }, boundaryWarning: false)
        }
        var settings = TranslationSettings(); settings.outputStyle = style; settings.maxReviewCallsPerLecture = reviewBudget
        return PreparedLecture(version: PreparedLecture.pipelineVersion,
                               document: .init(sourceHash: "speech-integration-fixture", cues: cues), parts: parts, issues: [], videoPaths: [],
                               profile: .builtIns[0], settings: settings)
    }

    static let hotID = 67
    static let ordinary = "Это обычное русское предложение."

    static func drafted(_ lecture: PreparedLecture, hotText: String) -> TranslationJournal {
        var journal = TranslationJournal(sourceHash: lecture.document.sourceHash, settings: lecture.settings, profile: lecture.profile)
        journal.version = 4; journal.reviewStrategy = ReviewPlanning.strategy
        for part in lecture.parts {
            let rows = part.cueIDs.map { TranslationReply.Row(id: $0, text: $0 == hotID ? hotText : ordinary) }
            let result = ModelResult(reply: .init(translations: rows, issues: []), usage: nil, model: "local-fixture", effort: "medium", elapsed: 0)
            journal.parts[part.id] = .init(draftAttempts: 1, draft: result)
        }
        return journal
    }

    static func reviewed(_ draft: TranslationJournal, lecture: PreparedLecture, hotText: String) -> TranslationJournal {
        var journal = draft
        let selection = TranslationPipeline.reviewSelection(lecture: lecture, journal: journal, part: lecture.parts[1])
        let rows = selection.cueIDs.map { TranslationReply.Row(id: $0, text: $0 == hotID ? hotText : ordinary) }
        journal.parts[2]!.review = .init(reply: .init(translations: rows, issues: []), usage: nil, model: "local-fixture-review", effort: "medium", elapsed: 0)
        journal.parts[2]!.reviewedIDs = selection.cueIDs; journal.parts[2]!.reviewAttempts = 1
        journal.reviewPlan = [2]
        for part in lecture.parts { journal.parts[part.id]!.done = true }
        return journal
    }

    static func main() throws {
        let spoken = fixture(style: "spoken"), display = fixture(style: "display")
        check(TranslationSettings().outputStyle == "spoken", "spoken is the default")
        let spokenPrompt = spoken.prompt(for: spoken.parts[1]), displayPrompt = display.prompt(for: display.parts[1])
        check(spokenPrompt.contains(SpeechText.promptInstruction), "full spoken instruction included in draft prompt")
        check(spokenPrompt.contains("67|19.000|"), "model sees compact ID and duration")
        check(!spokenPrompt.contains(spoken.document.cues[0].timingLine), "full timestamp syntax stays local")
        check(displayPrompt.contains("числа можно писать цифрами"), "display explicitly permits digits")
        check(!displayPrompt.contains(SpeechText.promptInstruction), "display has no conflicting spoken instruction")
        check(!spoken.settings.translationCompatible(with: display.settings), "changing text style never reuses incompatible paid results")

        let cases: [(unsafe: String, fixed: String)] = [
            ("От 5 мл.", "От пяти миллилитров."),
            ("0,5 мг.", "Ноль целых пять десятых миллиграмма."),
            ("II стадия.", "Вторая стадия."),
            ("От пяти мл.", "От пяти миллилитров."),
            ("Не меньше пяти %.", "Не меньше пяти процентов."),
            ("Витамин B12.", "Витамин бэ двенадцать."),
            ("ГАМК.", "Гамма-аминомасляная кислота."),
            ("β-каротин.", "Бета-каротин.")
        ]
        for item in cases {
            let draft = drafted(spoken, hotText: item.unsafe)
            try draft.validate(lecture: spoken)
            check(draft.parts.values.allSatisfy { $0.draft?.reply.issues.isEmpty == true }, "fixture model claims confidence: \(item.unsafe)")
            let local = draft.issues(for: spoken).filter { $0.reason.hasPrefix(SpeechText.issuePrefix) }
            check(!local.isEmpty && local.allSatisfy { $0.cueID == hotID && $0.critical }, "local safety is independent of model confidence: \(item.unsafe)")
            check(local.allSatisfy { $0.category == "Написание для озвучки" }, "speech category in real issue list")
            check(ReviewPlanning.plan(lecture: spoken, journal: draft) == [2], "late local issue outranks opening sample: \(item.unsafe)")
            let selection = TranslationPipeline.reviewSelection(lecture: spoken, journal: draft, part: spoken.parts[1])
            check(selection.cueIDs.contains(hotID) && selection.cueIDs.count > 1 && !selection.cueIDs.contains(17), "review selects unsafe middle cue and nearby context, not fallback start")
            let reviewPrompt = TranslationPipeline.prompt(lecture: spoken, journal: draft, part: spoken.parts[1], review: true)
            check(reviewPrompt.contains(SpeechText.promptInstruction) && reviewPrompt.contains("LOCAL_DRAFT_WARNINGS") && reviewPrompt.contains("ID 67: Для озвучки:"), "review receives same spoken rules and explicit local reason")
            check(reviewPrompt.contains("67|\(item.unsafe)"), "review receives exact unsafe draft, not guessed replacement")

            let unchanged = reviewed(draft, lecture: spoken, hotText: item.unsafe)
            try unchanged.validate(lecture: spoken)
            check(TranslationPipeline.restoredStatus(lecture: spoken, journal: unchanged).0 == .needsReview, "confident but unchanged review remains needsReview")
            check(unchanged.issues(for: spoken).contains { $0.reason.hasPrefix(SpeechText.issuePrefix) && $0.cueID == hotID }, "unsafe symbols still detected after review")
            if case .complete = TranslationPipeline.next(lecture: spoken, journal: unchanged) { check(true, "no endless retry for residual speech flag") }
            else { check(false, "residual flag unexpectedly requests more model work") }

            let fixed = reviewed(draft, lecture: spoken, hotText: item.fixed)
            try fixed.validate(lecture: spoken)
            check(fixed.issues(for: spoken).isEmpty, "correct full words clear derived issue: \(item.fixed)")
            check(TranslationPipeline.restoredStatus(lecture: spoken, journal: fixed).0 == .translated, "correct words do not keep false needsReview")
            check(fixed.totalReviews == 1 && fixed.parts.values.reduce(0) { $0 + $1.draftAttempts } == 3, "local checks do not spend or invent requests")

            let screenDraft = drafted(display, hotText: item.unsafe)
            check(screenDraft.issues(for: display).isEmpty, "display disables spoken-only issues: \(item.unsafe)")
            check(ReviewPlanning.plan(lecture: display, journal: screenDraft) == [1], "display leaves independent sample, no speech risk scoring")
            let screenReview = TranslationPipeline.prompt(lecture: display, journal: screenDraft, part: display.parts[1], review: true)
            check(!screenReview.contains(SpeechText.issuePrefix) && !screenReview.contains(SpeechText.promptInstruction), "display review does not reintroduce spoken-only instructions")
        }

        let unsafe = drafted(spoken, hotText: "От 5 мл.")
        let roundTrip = try JSONDecoder().decode(TranslationJournal.self, from: JSONEncoder().encode(unsafe))
        try roundTrip.validate(lecture: spoken)
        check(roundTrip.settings.outputStyle == "spoken" && ReviewPlanning.plan(lecture: spoken, journal: roundTrip) == [2], "spoken validation survives saved journal")
        let noBudget = fixture(style: "spoken", reviewBudget: 0)
        let exhausted = drafted(noBudget, hotText: "От 5 мл.")
        check(ReviewPlanning.plan(lecture: noBudget, journal: exhausted).isEmpty && !exhausted.issues(for: noBudget).isEmpty, "zero review budget never hides unsafe text")
        let nonSpeech = drafted(display, hotText: "Beschwerden.")
        check(nonSpeech.issues(for: display).contains(where: \.critical), "display does not disable untranslated German safety")
        let latin = drafted(spoken, hotText: "Hypericum perforatum.")
        check(latin.translated[hotID] == "Hypericum perforatum." && !latin.issues(for: spoken).isEmpty, "Latin term preserved, pronunciation uncertainty explicit")

        // A user may confirm an uncertain meaning after listening, but a checkbox
        // cannot make a still-present written digit pronounceable by Russian TTS.
        for item in cases {
            let draft = drafted(spoken, hotText: item.unsafe)
            var confirmed = reviewed(draft, lecture: spoken, hotText: item.unsafe)
            let writtenIssues = confirmed.issues(for: spoken).filter { $0.reason.hasPrefix(SpeechText.issuePrefix) }
            for issue in writtenIssues {
                try confirmed.edit(cueID: hotID, text: item.unsafe, confirming: issue, sourceChecked: true, lecture: spoken)
                check(confirmed.issues(for: spoken).contains(issue), "acknowledgement cannot conceal unchanged written speech risk: \(item.unsafe)")
            }
            confirmed = try JSONDecoder().decode(TranslationJournal.self, from: JSONEncoder().encode(confirmed))
            check(confirmed.issues(for: spoken).filter { $0.reason.hasPrefix(SpeechText.issuePrefix) }.count == writtenIssues.count,
                  "saved acknowledgement cannot bypass fresh local text checks")
            check(TranslationPipeline.restoredStatus(lecture: spoken, journal: confirmed).0 == .needsReview,
                  "acknowledged but unchanged spoken text is still needsReview after restart")
            try confirmed.edit(cueID: hotID, text: item.fixed, confirming: nil, sourceChecked: false, lecture: spoken)
            check(confirmed.issues(for: spoken).isEmpty, "actual full-word correction removes persistent written risk")
            try confirmed.edit(cueID: hotID, text: item.unsafe, confirming: nil, sourceChecked: false, lecture: spoken)
            check(!confirmed.issues(for: spoken).isEmpty, "reintroducing previously acknowledged unsafe text is detected again")
        }
        var semantic = reviewed(unsafe, lecture: spoken, hotText: "От пяти миллилитров.")
        let oldReview = semantic.parts[2]!.review!
        semantic.parts[2]!.review = .init(reply: .init(translations: oldReview.reply.translations,
            issues: [.init(ids: [hotID], reason: "Название требует сверки с оригиналом.", critical: true)]),
            usage: nil, model: "local-fixture-review", effort: "medium", elapsed: 0)
        let semanticIssue = semantic.issues(for: spoken).first!
        try semantic.edit(cueID: hotID, text: "От пяти миллилитров.", confirming: semanticIssue, sourceChecked: true, lecture: spoken)
        check(semantic.issues(for: spoken).isEmpty, "ordinary semantic uncertainty can still be confirmed after checking original")

        var manuallyFixed = reviewed(unsafe, lecture: spoken, hotText: "От 5 мл.")
        try manuallyFixed.edit(cueID: hotID, text: "От пяти миллилитров.", confirming: nil, sourceChecked: false, lecture: spoken)
        check(manuallyFixed.issues(for: spoken).isEmpty && manuallyFixed.manualHistory?.count == 1, "manual correction resolves local flag without modifying paid draft history")
        check(manuallyFixed.parts[2]!.draft!.reply.translations.first(where: { $0.id == hotID })!.text == "От 5 мл.", "original draft retained for audit")

        let exportRoot = FileManager.default.temporaryDirectory.appendingPathComponent("SpeechIntegration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: exportRoot, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: exportRoot) }
        let target = exportRoot.appendingPathComponent("Лекция.ru.srt")
        try TranslationPipeline.export(lecture: spoken, journal: manuallyFixed, to: target)
        let exported = try SRTDocument.parse(Data(contentsOf: target))
        check(exported.cues.map(\.id) == spoken.document.cues.map(\.id), "single spoken SRT retains exact source IDs")
        check(exported.cues.map(\.timingLine) == spoken.document.cues.map(\.timingLine), "single spoken SRT retains exact timing windows")
        check(exported.cues.first(where: { $0.id == hotID })!.text == "От пяти миллилитров.", "export contains grammatical full words")
        let exportedFiles = try FileManager.default.contentsOfDirectory(atPath: exportRoot.path)
        check(exportedFiles == ["Лекция.ru.srt"], "one SRT only, no hidden second speech subtitle or service file")
        var revised = manuallyFixed
        revised.exportedPath = target.path
        try revised.edit(cueID: hotID, text: "От пяти миллилитров и пяти капель.", confirming: nil, sourceChecked: false, lecture: spoken)
        check(revised.exportedPath == nil && revised.issues(for: spoken).isEmpty, "manual edit recalculates speech validity and marks prior export stale")
        let revisedBytes = try TranslationPipeline.renderedData(lecture: spoken, journal: revised)
        let priorBytes = try Data(contentsOf: target)
        check(revisedBytes != priorBytes, "revised SRT bytes differ from the previously saved result")
        print("PASS: \(passed) speech pipeline integration checks. No model, TTS, network or user state.")
    }
}
