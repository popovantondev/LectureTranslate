import Foundation
import Darwin

@main
enum RuntimePreferencesTests {
    @MainActor static func main() throws {
        var passed = 0
        func check(_ condition: Bool, _ name: String) {
            guard condition else { fputs("FAIL: \(name)\n", stderr); exit(1) }
            passed += 1
        }
        func rejects(_ name: String, _ operation: () throws -> Void) {
            do { try operation(); fputs("FAIL: \(name) was accepted\n", stderr); exit(1) }
            catch { passed += 1 }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RuntimePreferencesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RuntimePreferencesStore(root: root.appendingPathComponent("state"))
        let defaults = try store.load()
        check(defaults == RuntimePreferences(), "missing file returns exact safe defaults")
        check(!FileManager.default.fileExists(atPath: store.root.path), "reading missing preferences does not create state")
        check(defaults.concurrencyOverride == nil && !defaults.reserveConfigured && defaults.fastActivationCount == 0 && !defaults.rememberFast,
              "first launch is auto concurrency, unconfigured reserve and Fast off")
        check(TranslationSettings().reserve == 15, "existing reserve default remains fifteen")
        let emptyObject = try JSONDecoder().decode(RuntimePreferences.self, from: Data("{}".utf8))
        check(emptyObject == defaults, "missing old optional settings decode safely")
        let persistedFifty = try JSONDecoder().decode(RuntimePreferences.self, from: Data(#"{"concurrencyOverride":50}"#.utf8))
        check(persistedFifty.concurrencyOverride == 50, "maximum manual concurrency decodes from persisted preferences")
        do {
            _ = try JSONDecoder().decode(RuntimePreferences.self, from: Data(#"{"concurrencyOverride":51}"#.utf8))
            check(false, "manual setting above fifty must be rejected")
        } catch { check(true, "manual setting above fifty is rejected") }
        check(!emptyObject.modelRoutingMigrationApplied, "old runtime preferences remain eligible for a one-time model migration")
        var oldRouting = ProjectState()
        oldRouting.settings.model = "gpt-5.6-terra"; oldRouting.settings.reviewModel = "gpt-5.6-sol"
        check(ModelRoutingMigration.apply(to: &oldRouting), "empty old queue migrates safely")
        check(oldRouting.settings.model == "gpt-6-luna" && oldRouting.settings.effort == "medium" &&
              oldRouting.settings.reviewModel == "gpt-6-sol" && oldRouting.settings.reviewEffort == "medium",
              "legacy default route upgrades to Luna Medium and Sol Medium")
        var partialRouting = ProjectState()
        partialRouting.settings.model = "gpt-5.6-terra"; partialRouting.settings.reviewModel = "gpt-5.6-sol"
        var partialJob = JobSummary(sourcePath: "/tmp/example.srt"); partialJob.cueCount = 20; partialJob.completedCues = 7
        partialRouting.jobs = [partialJob]
        check(!ModelRoutingMigration.apply(to: &partialRouting) && partialRouting.settings.model == "gpt-5.6-terra",
              "partially translated queue is not switched or mixed")
        var completeRouting = ProjectState()
        completeRouting.settings.model = "gpt-5.6-terra"; completeRouting.settings.reviewModel = "gpt-5.6-sol"
        var completeJob = JobSummary(sourcePath: "/tmp/done.srt"); completeJob.cueCount = 20; completeJob.completedCues = 20
        completeRouting.jobs = [completeJob]
        check(ModelRoutingMigration.apply(to: &completeRouting) && completeRouting.settings.model == "gpt-6-luna",
              "fully completed queue can switch defaults for future work")
        let jsonObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(defaults)) as! [String: Any]
        check(jsonObject["reserve"] == nil && jsonObject["jobs"] == nil && jsonObject["model"] == nil, "runtime preferences do not duplicate translation settings or jobs")

        let weekly = LimitWindow(usedPercent: 12, windowDurationMins: 10080, resetsAt: 2_100_000_000)
        let fiveHours = LimitWindow(usedPercent: 7, windowDurationMins: 300, resetsAt: 2_000_000_000)
        func quota(_ plan: String?, primary: LimitWindow?, secondary: LimitWindow?) -> QuotaSnapshot {
            .init(checkedAt: Date(), bucket: .init(primary: primary, secondary: secondary, rateLimitReachedType: nil, planType: plan))
        }
        let pro = quota("pro", primary: weekly, secondary: nil)
        let proLite = quota("prolite", primary: weekly, secondary: nil)
        let proWithBothWindows = quota("pro", primary: fiveHours, secondary: weekly)
        let proLiteWithBothWindows = quota("prolite", primary: weekly, secondary: fiveHours)
        let plus = quota("plus", primary: fiveHours, secondary: weekly)
        let unknownValid = quota("mystery", primary: fiveHours, secondary: weekly)
        let ordinary: [QuotaSnapshot?] = [plus, unknownValid, quota(nil, primary: weekly, secondary: nil),
            quota("other", primary: weekly, secondary: nil), quota("pro", primary: nil, secondary: nil)]
        for item in ordinary {
            for jobs in [0, 1, 3, 4, 10, 11, 19, 20, 3000] {
                let validQuota = item.map { $0.decision(reserve: 0) != .unknown } ?? false
                let expected = validQuota ? min(15, jobs) : 0
                check(ConcurrencyPolicy.automaticLimit(jobs: jobs, quota: item) == expected, "Plus/valid unknown defaults to fifteen; invalid quota fails closed")
                check(ConcurrencyPolicy.effectiveLimit(jobs: jobs, quota: item) == expected, "automatic choice respects valid quota and queue size")
            }
        }
        for item in [pro, proLite, proWithBothWindows, proLiteWithBothWindows] {
            for jobs in [0, 1, 3, 4, 10, 11, 19, 20, 3000] {
                check(ConcurrencyPolicy.automaticLimit(jobs: jobs, quota: item) == min(50, jobs), "confirmed Pro defaults to fifty")
                check(ConcurrencyPolicy.effectiveLimit(jobs: jobs, quota: item) == min(jobs, 50), "confirmed Pro capacity respects queue size")
            }
        }
        let stale = QuotaSnapshot(checkedAt: Date().addingTimeInterval(-121), bucket: plus.bucket)
        check(ConcurrencyPolicy.automaticLimit(jobs: 80, quota: stale) == 0, "stale quota does not present an automatic concurrency default")
        for jobs in [1, 15, 50, 200, 250] {
            check(ConcurrencyPolicy.automaticLimit(jobs: jobs, quota: plus) == min(15, jobs), "Plus synthetic queue boundary (jobs) stays within fifteen")
            check(ConcurrencyPolicy.automaticLimit(jobs: jobs, quota: pro) == min(50, jobs), "confirmed Pro synthetic queue boundary (jobs) stays within fifty")
            check(ConcurrencyPolicy.automaticLimit(jobs: jobs, quota: proLite) == min(50, jobs), "confirmed prolite Pro synthetic queue boundary (jobs) stays within fifty")
            check(ConcurrencyPolicy.effectiveLimit(jobs: jobs, quota: nil, override: 50) == min(50, jobs), "manual cap handles synthetic queue boundary (jobs) without quota authorization")
        }
        for setting in [1, 15, 50, 200, Int.max] {
            check(ConcurrencyPolicy.schedulingCeiling(quota: plus, override: setting) == min(50, setting), "manual setting (setting) has priority within hard cap")
        }
        for item in ordinary + [pro, proLite, proWithBothWindows, proLiteWithBothWindows] {
            check(ConcurrencyPolicy.effectiveLimit(jobs: 3000, quota: item, override: 50) == 50, "manual fifty is available on all plans")
            check(ConcurrencyPolicy.effectiveLimit(jobs: 3000, quota: item, override: Int.max) == 50, "absolute maximum fifty cannot be bypassed")
            check(ConcurrencyPolicy.effectiveLimit(jobs: 3, quota: item, override: 50) == 3, "manual count cannot exceed queue")
            check(ConcurrencyPolicy.effectiveLimit(jobs: -1, quota: item, override: 50) == 0, "negative queue length is fail-closed zero")
        }
        let germanProExplanation = ConcurrencyPolicy.explanation(jobs: 14, quota: pro, language: .de)
        let russianProExplanation = ConcurrencyPolicy.explanation(jobs: 14, quota: pro, language: .ru)
        let englishProExplanation = ConcurrencyPolicy.explanation(jobs: 14, quota: pro, language: .en)
        check(germanProExplanation.contains("50") && germanProExplanation.contains("bestätigt") &&
              russianProExplanation.contains("50") && russianProExplanation.contains("подтверждённый") &&
              englishProExplanation.contains("50") && englishProExplanation.contains("confirmed"),
              "Pro concurrency explanation follows each selected UI language")
        let emptyQueueExplanation = ConcurrencyPolicy.explanation(jobs: 0, quota: pro, language: .ru)
        check(emptyQueueExplanation.contains("до 50") && emptyQueueExplanation.contains("очередь пуста") && !emptyQueueExplanation.contains("до 0"),
              "empty queue explains plan ceiling without presenting zero as the plan limit")

        var preferences = RuntimePreferences()
        var session = FastSessionState(preferences: preferences)
        check(!session.isEnabled, "Fast starts off without explicit memory consent")
        for count in 1...3 {
            let offer = session.confirmActivation(preferences: &preferences)
            check(session.isEnabled && preferences.fastActivationCount == count, "confirmed activation increments once")
            check(offer == (count == 3), "remember question appears only at the third confirmation")
            check(!preferences.rememberFast, "offering to remember never enables permanent Fast")
            check(!session.confirmActivation(preferences: &preferences) && preferences.fastActivationCount == count, "duplicate on action does not increment or reprompt")
            if count < 3 { session.disable(preferences: &preferences) }
        }
        check(!session.answerRemember(false, preferences: &preferences) && preferences.rememberFastPromptShown, "declining memory is remembered")
        check(!session.answerRemember(true, preferences: &preferences) && !preferences.rememberFast, "an answered question cannot later be silently accepted")
        session.disable(preferences: &preferences)
        check(!session.confirmActivation(preferences: &preferences) && preferences.fastActivationCount == 4, "declined memory question does not return next click")
        check(!FastSessionState(preferences: preferences).isEnabled, "new process does not inherit session-only Fast")
        let encoded = try JSONEncoder().encode(preferences)
        let decoded = try JSONDecoder().decode(RuntimePreferences.self, from: encoded)
        check(decoded == preferences && !FastSessionState(preferences: decoded).isEnabled, "decline and off-on count survive JSON without restoring Fast")

        var remembered = RuntimePreferences(fastActivationCount: 2)
        var rememberingSession = FastSessionState(preferences: remembered)
        check(rememberingSession.confirmActivation(preferences: &remembered), "third confirmation offers independent memory consent")
        check(rememberingSession.answerRemember(true, preferences: &remembered) && remembered.rememberFast, "explicit memory acceptance enables future Fast")
        let rememberedOnDisk = try JSONDecoder().decode(RuntimePreferences.self, from: JSONEncoder().encode(remembered))
        var nextSession = FastSessionState(preferences: rememberedOnDisk)
        check(nextSession.isEnabled && rememberedOnDisk.fastActivationCount == 3, "explicit remember enables next startup without counting it as consent")
        nextSession.disable(preferences: &remembered)
        check(!nextSession.isEnabled && !remembered.rememberFast && !FastSessionState(preferences: remembered).isEnabled, "off revokes permanent Fast immediately")
        check(!nextSession.confirmActivation(preferences: &remembered), "turning off remembered Fast does not cause endless memory questions")
        var premature = RuntimePreferences()
        var prematureSession = FastSessionState(preferences: premature)
        check(!prematureSession.answerRemember(true, preferences: &premature) && !premature.rememberFast, "cannot remember Fast before confirmed activation")
        var saturated = RuntimePreferences(fastActivationCount: Int.max, rememberFastPromptShown: true)
        var saturatedSession = FastSessionState(preferences: saturated)
        _ = saturatedSession.confirmActivation(preferences: &saturated)
        check(saturated.fastActivationCount == Int.max && saturatedSession.isEnabled, "activation counter cannot overflow")

        for broken in ["{", "null", "[]", #"{"version":2}"#, #"{"concurrencyOverride":0}"#,
                       #"{"concurrencyOverride":51}"#, #"{"concurrencyOverride":"3"}"#,
                       #"{"fastActivationCount":-1}"#, #"{"rememberFast":true}"#,
                       #"{"rememberFastPromptShown":true}"#, #"{"rememberFast":"true"}"#] {
            rejects("invalid preferences JSON") { _ = try JSONDecoder().decode(RuntimePreferences.self, from: Data(broken.utf8)) }
        }
        let impossible = RuntimePreferences(fastActivationCount: 0, rememberFast: true)
        check(!FastSessionState(preferences: impossible).isEnabled, "invalid in-memory consent cannot enable Fast")
        rejects("read-only app cannot create preferences") { try store.save(defaults, isMainOwner: false) }
        check(!FileManager.default.fileExists(atPath: store.root.path), "read-only save creates no files")
        preferences.concurrencyOverride = 50
        try store.save(preferences, isMainOwner: true)
        check(try store.load() == preferences, "main owner can save and reload preferences")
        let before = try Data(contentsOf: store.fileURL)
        rejects("read-only app cannot replace preferences") { try store.save(rememberedOnDisk, isMainOwner: false) }
        check(try Data(contentsOf: store.fileURL) == before, "read-only write preserves existing bytes")
        rejects("invalid memory cannot be persisted") { try store.save(impossible, isMainOwner: true) }
        check(try Data(contentsOf: store.fileURL) == before, "invalid write leaves valid settings unchanged")
        try store.save(rememberedOnDisk, isMainOwner: true)
        check(try store.load() == rememberedOnDisk, "atomic replacement preserves explicit remembered consent")
        let children = try FileManager.default.contentsOfDirectory(atPath: store.root.path)
        check(children == ["runtime-preferences.json"], "successful atomic saves leave no temporary debris or project files")
        let mode = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber
        check(mode?.intValue == 0o600, "runtime settings are private to the current user")

        let corruptBytes = Data(#"{"rememberFast":true,"fastActivationCount":"damaged"}"#.utf8)
        try corruptBytes.write(to: store.fileURL)
        rejects("corrupt stored preference file must not silently default or restore Fast") { _ = try store.load() }
        check(try Data(contentsOf: store.fileURL) == corruptBytes, "failed load preserves corrupt settings for recovery")
        let linkedRoot = root.appendingPathComponent("linked-state")
        try FileManager.default.createDirectory(at: linkedRoot, withIntermediateDirectories: false)
        let linked = RuntimePreferencesStore(root: linkedRoot)
        try FileManager.default.createSymbolicLink(at: linked.fileURL, withDestinationURL: store.fileURL)
        rejects("symlink preferences cannot be read as trusted consent") { _ = try linked.load() }
        rejects("symlink preferences cannot be overwritten") { try linked.save(defaults, isMainOwner: true) }
        check(try Data(contentsOf: store.fileURL) == corruptBytes, "symlink target remains unchanged")
        let oversizedRoot = root.appendingPathComponent("large-state")
        try FileManager.default.createDirectory(at: oversizedRoot, withIntermediateDirectories: false)
        let oversized = RuntimePreferencesStore(root: oversizedRoot)
        try Data(repeating: 32, count: 65_537).write(to: oversized.fileURL)
        rejects("oversized settings are not accepted") { _ = try oversized.load() }
        print("PASS: \(passed) runtime preference checks. No UI launch, model, network or user state.")
    }
}
