import Foundation
import Darwin
import Combine

/// Real queue orchestration with synthetic SRTs and both network boundaries
/// replaced. These tests never launch Codex, a GUI, or an audio model.
@main
enum ParallelIntegrationTests {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @MainActor static var passed = 0
    @MainActor static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message: message) }
        passed += 1
    }

    static let labels: [String] = {
        let base = ["альфа", "бета", "гамма", "дельта", "эпсилон", "дзета", "эта", "тета",
                    "йота", "каппа", "лямбда", "мю", "ню", "кси", "омикрон", "пи", "ро", "сигма"]
        return (0..<60).map { base[$0 % base.count] }
    }()

    static func quota() -> QuotaSnapshot {
        .init(checkedAt: Date(), bucket: .init(primary: .init(usedPercent: 0,
            windowDurationMins: 10080, resetsAt: Date().addingTimeInterval(86_400).timeIntervalSince1970),
            secondary: nil, rateLimitReachedType: nil, planType: "pro"))
    }

    static func stamp(_ seconds: Int) -> String {
        String(format: "%02d:%02d:%02d,000", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }

    static func translation(file: Int) -> String {
        "Это лекция «\(labels[file])». Мы обсуждаем историю."
    }

    static func memory(file: Int, part: Int) -> String {
        "Память лекции \(labels[file]), часть \(["первая", "вторая", "третья", "четвёртая", "пятая"][part - 1])."
    }

    struct Request: Hashable {
        let file: Int
        let part: Int
        let review: Bool
    }

    @MainActor final class Fixture {
        let root: URL
        let model: TranslatorModel
        let prepared: [PreparedLecture]
        let sourceBytes: [Data]
        var ownerByCue: [Int: (file: Int, part: Int)] = [:]

        init(parent: URL, name: String, files: Int, multiPart: Bool = true, parallelism: Int = 3, autoResume: Bool = false) throws {
            root = parent.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            let stateRoot = root.appendingPathComponent("state")
            setenv("LECTURE_TRANSLATOR_STATE_DIR", stateRoot.path, 1)
            model = TranslatorModel()
            try check(model.writable && model.store.root.standardizedFileURL.path == stateRoot.standardizedFileURL.path,
                      "\(name): isolated main-owner state")
            model.runtimePreferences.concurrencyOverride = parallelism
            model.runtimePreferences.reserveConfigured = true
            model.state.settings.reserve = 15
            model.state.settings.autoResumeAfterLimits = autoResume // Every possible retry still has both mock boundaries installed.
            model.state.settings.maxRepairPasses = 1
            model.state.settings.maxReviewCallsPerLecture = 1
            model.state.settings.outputStyle = "spoken"
            model.quota = ParallelIntegrationTests.quota()
            // Fail closed even if a scenario accidentally starts before installing its mock.
            model.quotaReadOverride = { throw Failure(message: "Quota mock not installed") }
            model.requestRunOverride = { _, _, _, _, _, _, _ in throw Failure(message: "Request mock not installed") }
            var lectures: [PreparedLecture] = [], bytes: [Data] = []
            for file in 0..<files {
                let source = root.appendingPathComponent("lecture-\(file).srt")
                let sentence = "Diese Vorlesung beschreibt eine allgemeine Geschichte und ihre Entwicklung. "
                let text = String(repeating: sentence, count: multiPart ? 8 : 1).trimmingCharacters(in: .whitespaces)
                let content = (0..<(multiPart ? 15 : 2)).map { row in
                    "\((file + 1) * 1000 + row + 1)\n\(stamp(row * 120)) --> \(stamp((row + 1) * 120))\n\(text)\n"
                }.joined(separator: "\n")
                let data = Data(content.utf8)
                try data.write(to: source, options: .withoutOverwriting)
                let lecture = try PreparedLecture.prepare(url: source, profile: model.profile, settings: model.state.settings)
                try check(lecture.issues.isEmpty, "\(name): synthetic source has no source risks")
                try check(multiPart ? lecture.parts.count >= 3 : lecture.parts.count == 1,
                          "\(name): fixture has the intended real split")
                lectures.append(lecture); bytes.append(data)
                model.state.jobs.append(JobSummary(sourcePath: source.path))
                for part in lecture.parts {
                    for id in part.cueIDs { ownerByCue[id] = (file, part.id) }
                }
            }
            prepared = lectures; sourceBytes = bytes
            try model.store.save(model.state)
        }

        func dispose() {
            model.pause(immediately: true)
            model.shutdown()
            model.stateLock = nil
        }

        func journal(_ file: Int) throws -> TranslationJournal {
            try model.store.journal(model.state.jobs[file].id, lecture: prepared[file])
        }

        func finished(_ ledger: Ledger, expectedMaximum: Int) throws {
            try check(!model.busy && !model.translating, "queue completes its worker group")
            try check(model.requestsInFlight.isEmpty && model.requestControls.isEmpty && model.activePhases.isEmpty,
                      "all admission/controller ledgers released")
            try check(ledger.active == 0 && ledger.maximum == expectedMaximum,
                      "expected max active \(expectedMaximum), observed \(ledger.maximum)")
            try check(ledger.inspectionFailures.isEmpty, "mock contracts: \(ledger.inspectionFailures.joined(separator: "; "))")
            try check(Set(ledger.starts).count == ledger.starts.count, "completed draft/review work is never requested twice")
            for file in prepared.indices {
                let job = model.state.jobs[file], lecture = prepared[file], progress = try journal(file)
                try check(job.status == .exported, "file \(file) exported, got \(job.status): \(job.message)")
                try check(progress.parts.values.allSatisfy(\.done), "file \(file): all parts finalized")
                try check(progress.issues(for: lecture).isEmpty, "file \(file): speech-safe fake reply has no warnings")
                try check(Set(progress.translated.keys) == Set(lecture.document.cues.map(\.id)), "file \(file): exact raw cue IDs")
                try check(progress.translated.values.allSatisfy { $0 == translation(file: file) }, "file \(file): no cross-file reply mix")
                let destination = TranslationPipeline.destination(source: URL(fileURLWithPath: job.sourcePath), settings: model.state.settings)
                let output = try SRTDocument.parse(Data(contentsOf: destination))
                try check(output.cues.map(\.id) == lecture.document.cues.map(\.id), "file \(file): export retains cue IDs")
                try check(output.cues.map(\.timingLine) == lecture.document.cues.map(\.timingLine), "file \(file): export retains exact timecodes")
                try check(output.cues.allSatisfy { $0.text == translation(file: file) }, "file \(file): export belongs to its source")
                try check(try Data(contentsOf: URL(fileURLWithPath: job.sourcePath)) == sourceBytes[file], "file \(file): original bytes unchanged")
            }
            try check(!FileManager.default.fileExists(atPath: model.store.root.appendingPathComponent("requests").path),
                      "no live Codex request directory was created")
        }
    }

    @MainActor final class Ledger {
        let fixture: Fixture
        var active = 0
        var maximum = 0
        var activeByFile: [Int: Int] = [:]
        var starts: [Request] = []
        var completed: [Request] = []
        var inspectionFailures: [String] = []
        var hold = false
        var failFile: Int?
        var quotaRefusalFile: Int?
        var beforeResult: ((Request) async throws -> Void)?
        var delayNanoseconds: UInt64 = 25_000_000
        var quotaCalls = 0
        var quotaThrows = false
        var quotaReadsActive = 0
        var maxQuotaReadsActive = 0
        var quotaSnapshot: QuotaSnapshot?

        init(_ fixture: Fixture) { self.fixture = fixture }

        func install() {
            fixture.model.quotaReadOverride = { [self] in
                quotaCalls += 1; quotaReadsActive += 1; maxQuotaReadsActive = max(maxQuotaReadsActive, quotaReadsActive)
                defer { quotaReadsActive -= 1 }
                // An actual suspension also tests serialized admission around awaited quota reads.
                try await Task.sleep(nanoseconds: 1_000_000)
                if quotaThrows { throw Failure(message: "Synthetic quota transport error") }
                return quotaSnapshot ?? ParallelIntegrationTests.quota()
            }
            fixture.model.requestRunOverride = { [self] prompt, model, effort, root, controller, memoryOutput, fast in
                try await request(prompt, model: model, effort: effort, root: root, controller: controller, memoryOutput: memoryOutput, fast: fast)
            }
        }

        func inspect(_ condition: Bool, _ message: String) {
            if !condition { inspectionFailures.append(message) }
        }

        func request(_ prompt: String, model: String, effort: String, root: URL,
                     controller: RequestControl, memoryOutput: Bool, fast: Bool) async throws -> ModelResult {
            let pattern = try NSRegularExpression(pattern: #"^(\d+)\|\d+\.\d+\|[^\n]+$"#, options: .anchorsMatchLines)
            let ids = pattern.matches(in: prompt, range: NSRange(prompt.startIndex..., in: prompt)).compactMap {
                Range($0.range(at: 1), in: prompt).flatMap { Int(prompt[$0]) }
            }
            guard let first = ids.first, let owner = fixture.ownerByCue[first] else { throw Failure(message: "Mock could not parse INPUT IDs") }
            let reviewing = prompt.contains("\nREVIEW:")
            let key = Request(file: owner.file, part: owner.part, review: reviewing)
            inspect(ids.allSatisfy { fixture.ownerByCue[$0]?.file == owner.file && fixture.ownerByCue[$0]?.part == owner.part }, "one request mixed source IDs")
            inspect(Set(ids).count == ids.count, "duplicate requested IDs")
            let expectedPart = fixture.prepared[owner.file].parts[owner.part - 1]
            inspect(reviewing || ids == expectedPart.cueIDs, "draft omitted part IDs")
            inspect(memoryOutput, "new journal must request memory metadata")
            inspect(!fast, "Fast must remain off by default")
            inspect(root == fixture.model.store.root.appendingPathComponent("requests"), "request escaped isolated root")
            inspect(model == (reviewing ? fixture.model.state.settings.reviewModel : fixture.model.state.settings.model), "wrong stage model")
            inspect(effort == (reviewing ? fixture.model.state.settings.reviewEffort : fixture.model.state.settings.effort), "wrong stage effort")
            inspect((activeByFile[owner.file] ?? 0) == 0, "same lecture ran concurrent requests")
            // The 50-worker fixture cycles harmless Russian labels; identical
            // fixture labels cannot distinguish cross-file context text.
            for other in fixture.prepared.indices where other != owner.file && labels[other] != labels[owner.file] {
                for part in fixture.prepared[other].parts {
                    inspect(!prompt.contains(memory(file: other, part: part.id)), "memory leaked between lectures")
                }
                inspect(!prompt.contains(translation(file: other)), "translated context leaked between lectures")
            }
            if !reviewing && owner.part > 1 {
                let previous = Request(file: owner.file, part: owner.part - 1, review: false)
                inspect(completed.contains(previous), "later draft started before previous reply completed")
                inspect(prompt.contains(memory(file: owner.file, part: owner.part - 1)), "previous part memory missing")
                inspect(prompt.contains(translation(file: owner.file)), "previous translated context missing")
            }
            if reviewing {
                inspect(fixture.prepared[owner.file].parts.allSatisfy { part in
                    completed.contains(Request(file: owner.file, part: part.id, review: false))
                }, "global review started before all drafts")
            }
            active += 1; maximum = max(maximum, active)
            activeByFile[owner.file, default: 0] += 1
            starts.append(key)
            defer { active -= 1; activeByFile[owner.file, default: 0] -= 1 }
            while hold {
                if controller.isCancelled || Task.isCancelled { throw TranslationFailure.stopped }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            try await Task.sleep(nanoseconds: delayNanoseconds)
            if controller.isCancelled || Task.isCancelled { throw TranslationFailure.stopped }
            if let beforeResult { try await beforeResult(key) }
            if quotaRefusalFile == owner.file { throw TranslationFailure.quota }
            if failFile == owner.file { throw Failure(message: "Synthetic per-lecture failure") }
            completed.append(key)
            let reply = TranslationReply(translations: ids.map { .init(id: $0, text: translation(file: owner.file)) }, issues: [],
                memory: [.init(ids: [first], text: memory(file: owner.file, part: owner.part))], terms: [])
            return .init(reply: reply, usage: nil, model: model, effort: effort, elapsed: 0.01)
        }
    }

    @MainActor static func wait(_ message: String, seconds: Double = 15, until predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !predicate() {
            guard Date() < deadline else { throw Failure(message: "Timeout: \(message)") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @MainActor static func completeQueue(_ parent: URL) async throws {
        let fixture = try Fixture(parent: parent, name: "complete", files: 6)
        defer { fixture.dispose() }
        let ledger = Ledger(fixture); ledger.hold = true; ledger.install()
        fixture.model.startTranslation()
        try await wait("three concurrently admitted lectures") { ledger.active == 3 }
        ledger.hold = false
        try await wait("complete six multipart lectures") { !fixture.model.busy }
        try fixture.finished(ledger, expectedMaximum: 3)
        try check(ledger.maxQuotaReadsActive == 1, "quota admission reads serialized")
        for file in fixture.prepared.indices {
            let drafts = ledger.starts.filter { $0.file == file && !$0.review }.map(\.part)
            try check(drafts == fixture.prepared[file].parts.map(\.id), "file \(file): ordered once-only drafts")
            try check(ledger.starts.filter { $0.file == file && $0.review }.count == 1, "file \(file): bounded independent review")
        }
        print("PASS: six multipart lectures, concurrency, memory order, isolated outputs")
    }

    @MainActor static func gracefulPause(_ parent: URL) async throws {
        let fixture = try Fixture(parent: parent, name: "graceful", files: 6)
        defer { fixture.dispose() }
        let ledger = Ledger(fixture); ledger.hold = true; ledger.install()
        fixture.model.startTranslation()
        try await wait("three requests held") { ledger.active == 3 }
        let active = ledger.starts
        fixture.model.pause(immediately: false)
        try check(fixture.model.busy, "graceful pause waits for active replies")
        try check(fixture.model.requestControls.values.allSatisfy { !$0.isCancelled }, "graceful pause does not cancel paid replies")
        ledger.hold = false
        try await wait("graceful pause saves all workers") { !fixture.model.busy }
        try check(ledger.completed.count == 3 && ledger.starts.count == 3, "all active replies saved, no new requests after pause")
        try check(fixture.model.state.manuallyPaused && fixture.model.state.translationPending == false, "pause is durable")
        for key in active {
            let progress = try fixture.journal(key.file)
            try check(progress.parts[key.part]?.draft != nil, "active file \(key.file): response saved before idle")
            try check(progress.translated.count == fixture.prepared[key.file].parts[key.part - 1].cueIDs.count, "active file \(key.file): saved complete part")
        }
        try check(try fixture.model.store.load().manuallyPaused, "restart sees pause state")
        fixture.model.startTranslation()
        try await wait("resume saved queue") { !fixture.model.busy }
        try fixture.finished(ledger, expectedMaximum: 3)
        for key in active { try check(ledger.starts.filter { $0 == key }.count == 1, "resume never repeats ready draft") }
        print("PASS: graceful pause preserves all three active answers; resume skips ready parts")
    }

    @MainActor static func immediateCancel(_ parent: URL) async throws {
        let fixture = try Fixture(parent: parent, name: "immediate", files: 6)
        defer { fixture.dispose() }
        let ledger = Ledger(fixture); ledger.hold = true; ledger.install()
        fixture.model.startTranslation()
        try await wait("three cancellable requests") { ledger.active == 3 }
        let controls = Array(fixture.model.requestControls.values), began = Date()
        fixture.model.pause(immediately: true)
        try await wait("immediate cancellation", seconds: 2) { !fixture.model.busy }
        try check(Date().timeIntervalSince(began) < 2, "mock cancellation bounded")
        try check(controls.allSatisfy(\.isCancelled), "every active controller cancelled")
        try check(ledger.starts.count == 3 && ledger.completed.isEmpty && ledger.active == 0, "cancelled results not accepted and no new starts")
        try check(fixture.model.requestsInFlight.isEmpty && fixture.model.requestControls.isEmpty, "cancel clears admission ledger")
        for file in 0..<3 {
            let progress = try fixture.journal(file)
            try check(progress.translated.isEmpty && progress.parts.values.reduce(0, { $0 + $1.draftAttempts }) == 1,
                      "cancelled file \(file): one durable attempt, no partial translation")
        }
        print("PASS: immediate cancellation is bounded across every active worker")
    }

    @MainActor static func individualFailure(_ parent: URL) async throws {
        let fixture = try Fixture(parent: parent, name: "one-failure", files: 6, multiPart: false)
        defer { fixture.dispose() }
        let ledger = Ledger(fixture); ledger.failFile = 0; ledger.install()
        fixture.model.startTranslation()
        try await wait("per-lecture failure does not abort siblings") { !fixture.model.busy }
        try check(fixture.model.state.jobs[0].status == .translationError, "bad lecture reports failure")
        try check(ledger.starts.filter { $0.file == 0 }.count == 2, "failed lecture respects repair budget")
        try check(fixture.model.state.jobs.dropFirst().allSatisfy { $0.status == .exported }, "all healthy lectures continue and export")
        try check(fixture.model.parallelStop == nil, "per-lecture failure not made global")
        try check(ledger.maximum <= 3 && ledger.active == 0, "failure does not leak request slots: max=\(ledger.maximum), active=\(ledger.active)")
        try check(ledger.inspectionFailures.isEmpty, "failure mock contracts: \(ledger.inspectionFailures.joined(separator: "; "))")
        print("PASS: a failed lecture is isolated and retries are bounded")
    }

    @MainActor static func quotaFailure(_ parent: URL) async throws {
        let fixture = try Fixture(parent: parent, name: "quota-failure", files: 6)
        defer { fixture.dispose() }
        let ledger = Ledger(fixture); ledger.hold = true; ledger.install()
        fixture.model.startTranslation()
        try await wait("active requests before quota transport failure") { ledger.active == 3 }
        ledger.quotaThrows = true
        ledger.hold = false
        try await wait("bounded failed quota reads", seconds: 10) { !fixture.model.busy }
        try check(ledger.starts.count == 3 && ledger.completed.count == 3, "quota error blocks every new request but keeps active replies")
        try check(ledger.quotaCalls <= 6, "quota transport failure has a shared bounded retry budget")
        try check(fixture.model.parallelStop != nil && fixture.model.state.translationPending == false, "quota error stops queue without an uncontrolled timer")
        try check(fixture.model.requestsInFlight.isEmpty, "quota error releases slots")
        for file in 0..<3 { try check(try fixture.journal(file).parts[1]?.draft != nil, "quota error keeps active draft \(file)") }
        try check(fixture.model.state.jobs.dropFirst(3).allSatisfy { $0.status == .queued }, "quota error never starts waiting lectures")
        print("PASS: quota transport failures block new starts and retain active results")
    }

    @MainActor static func unknownQuota(_ parent: URL) async throws {
        let fixture = try Fixture(parent: parent, name: "unknown-quota", files: 4, multiPart: false, parallelism: 4)
        defer { fixture.dispose() }
        let ledger = Ledger(fixture); ledger.install()
        let valid = quota()
        fixture.model.quotaReadOverride = {
            QuotaSnapshot(checkedAt: valid.checkedAt.addingTimeInterval(-121), bucket: valid.bucket)
        }
        fixture.model.startTranslation()
        try await wait("unknown quota stops without requests") { !fixture.model.busy }
        try check(ledger.starts.isEmpty, "stale quota admits no primary or Sol requests")
        try check(fixture.model.requestsInFlight.isEmpty, "unknown quota leaves the shared admission ledger empty")
        try check(fixture.model.parallelStop != nil, "unknown quota is visible as a stopped queue")
        print("PASS: stale quota fails closed before any request starts")
    }

    @MainActor static func reserveGate(_ parent: URL) async throws {
        func atReserve(_ shortRemaining: Double, stale: Bool = false) -> QuotaSnapshot {
            let checked = Date().addingTimeInterval(stale ? -121 : 0)
            return QuotaSnapshot(checkedAt: checked, bucket: LimitBucket(
                primary: LimitWindow(usedPercent: 100 - shortRemaining, windowDurationMins: 300, resetsAt: Date().addingTimeInterval(3600).timeIntervalSince1970),
                secondary: LimitWindow(usedPercent: 20, windowDurationMins: 10080, resetsAt: Date().addingTimeInterval(86_400).timeIntervalSince1970),
                rateLimitReachedType: nil, planType: "plus"))
        }
        let stopped = try Fixture(parent: parent, name: "reserve-stop", files: 1, multiPart: false, parallelism: 1)
        defer { stopped.dispose() }
        let stopLedger = Ledger(stopped); stopLedger.install(); stopLedger.quotaSnapshot = atReserve(15)
        stopped.model.reserveConfirmationOverride = { false }
        stopped.model.startTranslation()
        try await wait("reserve confirmation refusal waits for recovery") { !stopped.model.busy }
        let reserveWait = try stopped.model.store.load()
        try check(stopLedger.starts.isEmpty && !stopped.model.state.manuallyPaused && reserveWait.resumeAt != nil,
                  "reserve decline stops admissions and durably schedules recovery without overriding manual-pause state")
        try check(try stopped.model.store.load().settings.reserve == 15, "configured reserve remains saved for a later app run")

        let continued = try Fixture(parent: parent, name: "reserve-continue", files: 1, multiPart: false, parallelism: 1)
        defer { continued.dispose() }
        let continueLedger = Ledger(continued); continueLedger.install(); continueLedger.quotaSnapshot = atReserve(14)
        var confirmationCount = 0
        continued.model.reserveConfirmationOverride = { confirmationCount += 1; return true }
        continued.model.startTranslation()
        try await wait("confirmed positive quota completes") { !continued.model.busy }
        try check(!continueLedger.starts.isEmpty && confirmationCount == 1, "explicit current-run confirmation admits below reserve once (starts=\(continueLedger.starts.count), prompts=\(confirmationCount), stop=\(String(describing: continued.model.parallelStop)))")
        try check(continued.model.reserveContinuationConfirmed, "confirmation is visible for this run")

        let zero = try Fixture(parent: parent, name: "reserve-zero", files: 1, multiPart: false, parallelism: 1)
        defer { zero.dispose() }
        let zeroLedger = Ledger(zero); zeroLedger.install(); zeroLedger.quotaSnapshot = atReserve(0)
        var zeroPrompted = false
        zero.model.reserveConfirmationOverride = { zeroPrompted = true; return true }
        zero.model.startTranslation()
        try await wait("zero service quota stops") { !zero.model.busy }
        try check(zeroLedger.starts.isEmpty && !zeroPrompted, "zero service quota cannot be overridden by confirmation")
        print("PASS: reserve stop, current-run confirmation, and zero-quota refusal")
    }

    @MainActor static func serviceRefusal(_ parent: URL) async throws {
        let fixture = try Fixture(parent: parent, name: "service-refusal", files: 6)
        defer { fixture.dispose() }
        let ledger = Ledger(fixture); ledger.hold = true; ledger.quotaRefusalFile = 0; ledger.install()
        ledger.beforeResult = { key in
            if key.file != 0 {
                try await wait("quota refusal is visible before siblings finish") {
                    fixture.model.parallelStop != nil
                }
            }
        }
        fixture.model.startTranslation()
        try await wait("requests before service quota refusal") { ledger.active == 3 }
        ledger.hold = false
        try await wait("service quota refusal") { !fixture.model.busy }
        try check(ledger.starts.count == 3 && ledger.completed.count == 2, "service refusal leaves siblings durable without starting more")
        try check(fixture.model.parallelStop != nil && fixture.model.state.translationPending == false, "service refusal globally pauses")
        try check(try fixture.journal(0).translated.isEmpty, "quota-refused draft not accepted")
        for file in 1..<3 { try check(try fixture.journal(file).parts[1]?.draft != nil, "sibling \(file) saves despite refusal") }
        print("PASS: a model quota refusal stops new work and preserves sibling answers")
    }

    @MainActor static func hardCap(_ parent: URL) async throws {
        let fixture = try Fixture(parent: parent, name: "hard-cap", files: 51, multiPart: false, parallelism: 99)
        defer { fixture.dispose() }
        let ledger = Ledger(fixture); ledger.hold = true; ledger.install()
        fixture.model.startTranslation()
        try await wait("fifty admitted requests", seconds: 15) { ledger.active == 50 }
        try await Task.sleep(nanoseconds: 75_000_000)
        try check(ledger.starts.count == 50 && fixture.model.requestsInFlight.count == 50, "manipulated override cannot start fifty-first request")
        try check(Set(ledger.starts).count == ledger.starts.count, "fifty admitted requests are unique completed-work keys")
        try check(fixture.model.runRequestedParallelism == 50, "scheduler hard cap is fifty")
        ledger.hold = false
        try await wait("complete capped queue", seconds: 25) { !fixture.model.busy }
        try fixture.finished(ledger, expectedMaximum: 50)
        print("PASS: hard cap fifty survives a manipulated override of ninety-nine")
    }

    @MainActor static func repeatedPhaseProfile() throws {
        let model = TranslatorModel()
        model.state.jobs = (0..<1_000).map { _ in JobSummary(sourcePath: "/synthetic/queue.srt") }
        let active = Array(model.state.jobs.prefix(15))
        for job in active { model.setActivePhase("Ожидает свободного места / запаса лимита", for: job.id) }
        var notifications = 0
        let subscription = model.objectWillChange.sink { notifications += 1 }
        let baselineCPU = clock()
        let began = Date()
        for _ in 0..<1_000 {
            for job in active { model.activePhases[job.id] = "Ожидает свободного места / запаса лимита" }
        }
        let baselineElapsed = Date().timeIntervalSince(began)
        let baselineCPUSeconds = Double(clock() - baselineCPU) / Double(CLOCKS_PER_SEC)
        let baselineNotifications = notifications
        notifications = 0
        let fixedCPU = clock()
        let fixedBegan = Date()
        for _ in 0..<1_000 {
            for job in active { model.setActivePhase("Ожидает свободного места / запаса лимита", for: job.id) }
        }
        let fixedElapsed = Date().timeIntervalSince(fixedBegan)
        let fixedCPUSeconds = Double(clock() - fixedCPU) / Double(CLOCKS_PER_SEC)
        var finalUsage = rusage(); _ = getrusage(RUSAGE_SELF, &finalUsage)
        try check(baselineNotifications == 15_000, "baseline repeated phase writes emit 15,000 UI invalidations")
        try check(notifications == 0, "unchanged phase polling emits no SwiftUI invalidation")
        model.setActivePhase("Перевод · часть 1", for: active[0].id)
        try check(notifications == 1, "a real phase change still invalidates the UI")
        withExtendedLifetime(subscription) {}
        print(String(format: "PROFILE: queue=1000 active=15 writes=15000 baseline-invalidations=%d baseline-wall=%.3fs baseline-cpu=%.4fs fixed-invalidations=%d fixed-wall=%.3fs fixed-cpu=%.4fs peak-rss=%lldB; real phase change=1 invalidation", baselineNotifications, baselineElapsed, baselineCPUSeconds, notifications - 1, fixedElapsed, fixedCPUSeconds, finalUsage.ru_maxrss))
    }

    @MainActor static func strongerQuotaStop(_ parent: URL) async throws {
        let fixture = try Fixture(parent: parent, name: "quota-stop-priority", files: 6, multiPart: false, autoResume: true)
        defer { fixture.dispose() }
        // B has two previous service refusals, not two charged repair attempts.
        var previous = try fixture.journal(1)
        var part = PartProgress(); part.draftAttempts = 2; part.draftQuotaDeferrals = 2
        previous.parts[1] = part; previous.consecutiveQuotaRefusals = 2
        try fixture.model.store.saveJournal(previous, id: fixture.model.state.jobs[1].id)

        let ledger = Ledger(fixture); ledger.hold = true; ledger.install()
        var observedEarlierQuota = false
        ledger.beforeResult = { key in
            switch key.file {
            case 0:
                throw TranslationFailure.quota
            case 1:
                try await wait("A sets ordinary quota stop before B replies") {
                    if case .quota? = fixture.model.parallelStop { return true }; return false
                }
                observedEarlierQuota = true
                throw TranslationFailure.quota // The worker must upgrade this third refusal to safetyStop.
            case 2:
                try await wait("B upgrades global stop before C returns successfully") {
                    if case .quotaSafetyStop? = fixture.model.parallelStop { return true }; return false
                }
            default:
                throw Failure(message: "A queued lecture started after the global quota stop")
            }
        }
        fixture.model.startTranslation()
        try await wait("A, B and C are active together") { ledger.active == 3 }
        ledger.hold = false
        try await wait("strongest quota stop finishes all active workers") { !fixture.model.busy }
        try check(observedEarlierQuota, "ordinary quota failure was definitely observed first")
        if case .quotaSafetyStop? = fixture.model.parallelStop { try check(true, "later safety stop upgrades earlier ordinary quota") }
        else { throw Failure(message: "Third refusal did not win global stop priority") }
        try check(fixture.model.state.manuallyPaused && fixture.model.state.translationPending == false,
                  "safety stop requires manual continuation even with auto-resume enabled")
        let b = try fixture.journal(1)
        try check(b.quotaPaused && b.consecutiveQuotaRefusals == 3 && b.parts[1]?.draftQuotaDeferrals == 3,
                  "B durably records its third service refusal")
        try check(try fixture.journal(2).parts[1]?.draft != nil, "C's successful active answer is saved after the stronger stop")
        try check(ledger.starts.count == 3 && ledger.completed.count == 1 && ledger.active == 0,
                  "no new request is started while all three active workers settle")
        try check(fixture.model.state.jobs.dropFirst(3).allSatisfy { $0.status == .queued }, "waiting lectures remain untouched")
        let saved = try fixture.model.store.load()
        try check(saved.manuallyPaused && saved.translationPending == false, "strong stop survives a relaunch")
        fixture.model.restoreAutomaticRun()
        try await Task.sleep(nanoseconds: 100_000_000)
        try check(!fixture.model.busy && ledger.starts.count == 3, "automatic restore cannot restart the safety-paused queue")
        print("PASS: a later third quota refusal upgrades the global stop and disables automatic continuation")
    }

    @MainActor static func run() async throws {
        if CommandLine.arguments.contains("--profile-only") {
            try repeatedPhaseProfile()
            return
        }
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("LectureParallelTests-\(UUID().uuidString)")
        let previous = ProcessInfo.processInfo.environment["LECTURE_TRANSLATOR_STATE_DIR"]
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer {
            if let previous { setenv("LECTURE_TRANSLATOR_STATE_DIR", previous, 1) }
            else { unsetenv("LECTURE_TRANSLATOR_STATE_DIR") }
            try? FileManager.default.removeItem(at: parent)
        }
        try await completeQueue(parent)
        try await gracefulPause(parent)
        try await immediateCancel(parent)
        try await individualFailure(parent)
        try await quotaFailure(parent)
        try await unknownQuota(parent)
        try await reserveGate(parent)
        try await serviceRefusal(parent)
        try await strongerQuotaStop(parent)
        try await hardCap(parent)
        try repeatedPhaseProfile()
        print("PASS: \(passed) parallel integration checks. Isolated synthetic SRTs; no live quota/model/GUI.")
    }

    @MainActor static func main() async {
        do { try await run() }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
}
