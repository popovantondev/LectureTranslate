import Foundation

@main
enum RuntimeSettingsIntegrationTests {
    private static var passed = 0
    private static func check(_ value: Bool, _ message: String) {
        guard value else { fputs("FAIL: \(message)\n", stderr); exit(1) }
        passed += 1
    }
    private static func bytes<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    @MainActor private static func fixture(_ root: URL) throws -> TranslatorModel {
        setenv("LECTURE_TRANSLATOR_STATE_DIR", root.path, 1)
        let model = TranslatorModel()
        guard model.writable, model.stateLock != nil else { throw TranslatorError.invalid("Test fixture cannot own isolated queue.") }
        model.runtimePreferences = RuntimePreferences(concurrencyOverride: 2, reserveConfigured: true)
        model.state.settings.reserve = 15
        model.state.jobs = [JobSummary(sourcePath: root.appendingPathComponent("synthetic-never-opened.srt").path)]
        model.state.manuallyPaused = true; model.state.translationPending = false
        model.showRuntimeSettings = true
        try model.preferencesStore.save(model.runtimePreferences, isMainOwner: true)
        try model.store.save(model.state)
        return model
    }

    @MainActor static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("RuntimeSettingsIntegrationTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        let previousRoot = ProcessInfo.processInfo.environment["LECTURE_TRANSLATOR_STATE_DIR"]
        defer {
            if let previousRoot { setenv("LECTURE_TRANSLATOR_STATE_DIR", previousRoot, 1) }
            else { unsetenv("LECTURE_TRANSLATOR_STATE_DIR") }
            try? fm.removeItem(at: root) // Only this fresh test-owned directory.
        }

        let blockedPrefs = try fixture(root.appendingPathComponent("prefs-failure", isDirectory: true))
        defer { blockedPrefs.shutdown(); blockedPrefs.stateLock = nil }
        let firstState = try bytes(blockedPrefs.state), firstPreferences = blockedPrefs.runtimePreferences
        let firstQueue = blockedPrefs.store.root.appendingPathComponent("queue.json")
        let firstQueueBytes = try Data(contentsOf: firstQueue)
        try fm.moveItem(at: blockedPrefs.preferencesStore.fileURL, to: blockedPrefs.store.root.appendingPathComponent("original-preferences.json"))
        try fm.createDirectory(at: blockedPrefs.preferencesStore.fileURL, withIntermediateDirectories: false)
        let proposed = RuntimePreferences(concurrencyOverride: 15, reserveConfigured: true)
        let firstResult = blockedPrefs.applyRuntimeSettings(proposed, reserve: 0)
        let firstAfterState = try bytes(blockedPrefs.state), firstAfterQueue = try Data(contentsOf: firstQueue)
        check(!firstResult && blockedPrefs.runtimePreferences == firstPreferences &&
              firstAfterState == firstState && firstAfterQueue == firstQueueBytes &&
              blockedPrefs.showRuntimeSettings && blockedPrefs.error != nil,
              "failed preferences write preserves live settings and durable reserve/queue")
        blockedPrefs.setConcurrency(9)
        let afterConcurrency = try Data(contentsOf: firstQueue)
        check(blockedPrefs.runtimePreferences == firstPreferences && afterConcurrency == firstQueueBytes,
              "failed concurrency-only write rolls back visible choice without changing queue")

        let blockedQueue = try fixture(root.appendingPathComponent("queue-failure", isDirectory: true))
        defer { blockedQueue.shutdown(); blockedQueue.stateLock = nil }
        let secondState = try bytes(blockedQueue.state), secondPreferences = blockedQueue.runtimePreferences
        let secondPreferencesBytes = try Data(contentsOf: blockedQueue.preferencesStore.fileURL)
        let queue = blockedQueue.store.root.appendingPathComponent("queue.json")
        try fm.moveItem(at: queue, to: blockedQueue.store.root.appendingPathComponent("original-queue.json"))
        try fm.createDirectory(at: queue, withIntermediateDirectories: false)
        let marker = queue.appendingPathComponent("do-not-overwrite")
        let markerBytes = Data("test-owned directory obstruction".utf8)
        try markerBytes.write(to: marker, options: .withoutOverwriting)
        let secondResult = blockedQueue.applyRuntimeSettings(proposed, reserve: 0)
        let secondAfterState = try bytes(blockedQueue.state)
        let secondAfterPreferences = try Data(contentsOf: blockedQueue.preferencesStore.fileURL)
        let secondAfterMarker = try Data(contentsOf: marker)
        check(!secondResult && blockedQueue.runtimePreferences == secondPreferences &&
              secondAfterState == secondState && secondAfterPreferences == secondPreferencesBytes &&
              secondAfterMarker == markerBytes && blockedQueue.error != nil,
              "failed queue write restores previous durable preferences and keeps session/directory unchanged")

        let success = try fixture(root.appendingPathComponent("success", isDirectory: true))
        defer { success.shutdown(); success.stateLock = nil }
        let originalIDs = success.state.jobs.map(\.id)
        let accepted = RuntimePreferences(concurrencyOverride: 7, reserveConfigured: true)
        let successResult = success.applyRuntimeSettings(accepted, reserve: 25)
        check(successResult && success.runtimePreferences == accepted && success.state.settings.reserve == 25 &&
              success.state.jobs.map(\.id) == originalIDs && !success.showRuntimeSettings && !success.fastSession.isEnabled,
              "successful apply publishes proposed settings and closes sheet without changing jobs/Fast")
        let durablePreferences = try success.preferencesStore.load(), durableState = try success.store.load()
        check(durablePreferences == accepted && durableState.settings.reserve == 25 && durableState.jobs.map(\.id) == originalIDs,
              "successful apply persists both files consistently")
        print("PASS: \(passed) runtime-settings integration checks (isolated files, no GUI/models/account).")
    }
}
