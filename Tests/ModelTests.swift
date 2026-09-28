import Foundation

@main
enum ModelTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LectureModelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        setenv("LECTURE_TRANSLATOR_STATE_DIR", root.path, 1)
        let model = TranslatorModel()
        defer { model.shutdown() }
        var passed = 0
        func check(_ condition: Bool, _ name: String) {
            guard condition else { fputs("FAIL: \(name)\n", stderr); exit(1) }
            passed += 1
        }
        // The source deliberately does not exist: an accidentally fired timer cannot
        // get past local preparation, so these tests can never call a model/service.
        var job = JobSummary(sourcePath: root.appendingPathComponent("missing.srt").path)
        job.cueCount = 10; job.completedCues = 6
        model.state.jobs = [job]
        model.selection = job.id
        check(!model.canPause, "idle has no stop action")
        model.busy = true
        check(model.canPause, "active work can pause")
        model.busy = false

        for immediately in [false, true] {
            model.state.manuallyPaused = false; model.state.translationPending = true
            model.state.resumeAt = Date().addingTimeInterval(300)
            model.scheduleAutomaticResume(after: 0.03)
            check(model.canPause, "cooldown can pause while not busy")
            model.pause(immediately: immediately)
            let saved = try model.store.load()
            check(saved.manuallyPaused && saved.translationPending == false && saved.resumeAt == nil, "pause survives relaunch")
            check(saved.jobs[0].completedCues == 6, "pause preserves progress")
            check(!model.canPause, "paused controls disable")
            model.restoreAutomaticRun()
            check(!model.busy, "relaunch cannot bypass manual pause")
            // Re-arm state without a new timer; a stale cancelled timer must not fire.
            model.state.manuallyPaused = false; model.state.translationPending = true
            try await Task.sleep(nanoseconds: 100_000_000)
            check(model.state.jobs[0].status == .queued && model.state.translationPending == true, "cancelled callback never restarts work")
        }

        model.scheduleAutomaticResume(after: 0.02)
        model.scheduleAutomaticResume(after: 0.3)
        try await Task.sleep(nanoseconds: 100_000_000)
        check(model.state.jobs[0].status == .queued, "replaced timer cannot fire early")
        model.pause(immediately: false)

        model.state.manuallyPaused = false; model.state.translationPending = true
        model.scheduleAutomaticResume(after: 0.02)
        model.shutdown()
        try await Task.sleep(nanoseconds: 100_000_000)
        check(model.state.translationPending == true && model.state.jobs[0].status == .queued, "shutdown cancels timer without deleting pending state")

        model.scheduleAutomaticResume(after: 0.02)
        for _ in 0..<100 where model.state.translationPending == true { try await Task.sleep(nanoseconds: 20_000_000) }
        check(model.state.translationPending == false && model.state.jobs[0].status == .translationError, "live timer resumes local preparation")
        check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("requests").path), "no request files or model calls")
        print("PASS: \(passed) model lifecycle checks. Isolated state; no model requests.")
    }
}
