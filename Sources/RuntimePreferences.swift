import Foundation
import SwiftUI
import Darwin

/// Device/runtime choices, deliberately outside ProjectState and .lectureproject.
/// The reserve itself remains in the existing TranslationSettings.reserve field.
struct RuntimePreferences: Codable, Equatable {
    var version = 1
    var concurrencyOverride: Int? = nil
    var reserveConfigured = false
    var fastActivationCount = 0
    var rememberFast = false
    var rememberFastPromptShown = false
    var modelRoutingMigrationApplied = false

    init(concurrencyOverride: Int? = nil, reserveConfigured: Bool = false, fastActivationCount: Int = 0,
         rememberFast: Bool = false, rememberFastPromptShown: Bool = false, modelRoutingMigrationApplied: Bool = false) {
        self.concurrencyOverride = concurrencyOverride; self.reserveConfigured = reserveConfigured
        self.fastActivationCount = fastActivationCount; self.rememberFast = rememberFast
        self.rememberFastPromptShown = rememberFastPromptShown
        self.modelRoutingMigrationApplied = modelRoutingMigrationApplied
    }

    private enum CodingKeys: String, CodingKey {
        case version, concurrencyOverride, reserveConfigured, fastActivationCount, rememberFast, rememberFastPromptShown, modelRoutingMigrationApplied
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        concurrencyOverride = try values.decodeIfPresent(Int.self, forKey: .concurrencyOverride)
        reserveConfigured = try values.decodeIfPresent(Bool.self, forKey: .reserveConfigured) ?? false
        fastActivationCount = try values.decodeIfPresent(Int.self, forKey: .fastActivationCount) ?? 0
        rememberFast = try values.decodeIfPresent(Bool.self, forKey: .rememberFast) ?? false
        rememberFastPromptShown = try values.decodeIfPresent(Bool.self, forKey: .rememberFastPromptShown) ?? false
        modelRoutingMigrationApplied = try values.decodeIfPresent(Bool.self, forKey: .modelRoutingMigrationApplied) ?? false
        try validate()
    }

    func validate() throws {
        guard version == 1 else { throw RuntimePreferencesError.invalid("Неизвестная версия настроек запуска.") }
        guard concurrencyOverride == nil || (1...ConcurrencyPolicy.hardMaximum).contains(concurrencyOverride!) else {
            throw RuntimePreferencesError.invalid("Параллельность должна быть от одного до пятидесяти либо «Авто».")
        }
        guard fastActivationCount >= 0,
              !rememberFastPromptShown || fastActivationCount >= 3,
              !rememberFast || (fastActivationCount >= 3 && rememberFastPromptShown) else {
            throw RuntimePreferencesError.invalid("Повреждено подтверждение быстрого режима. Fast не включён автоматически.")
        }
    }
}

enum RuntimePreferencesError: LocalizedError {
    case notOwner, invalid(String), unreadable(String), write(String)
    var errorDescription: String? {
        switch self {
        case .notOwner: return "Настройки может сохранять только экземпляр, владеющий рабочей очередью."
        case .invalid(let detail): return detail
        case .unreadable(let detail): return "Не удалось прочитать настройки запуска. Fast оставлен выключенным; файл не заменён. \(detail)"
        case .write(let detail): return "Не удалось сохранить настройки запуска. \(detail)"
        }
    }
}

enum ConcurrencyPolicy {
    static let hardMaximum = 50

    static func schedulingCeiling(quota: QuotaSnapshot?, override: Int? = nil) -> Int {
        min(hardMaximum, max(1, override ?? (quota?.isConfirmedPro == true ? hardMaximum : 15)))
    }

    /// This is a scheduling ceiling, never authorization to bypass the quota gate.
    /// Only the explicitly confirmed Pro weekly-only shape receives the larger default.
    static func automaticLimit(jobs: Int, quota: QuotaSnapshot?) -> Int {
        guard let quota, quota.decision(reserve: 0) != .unknown else { return 0 }
        let requested = quota.isConfirmedPro ? hardMaximum : 15
        return min(max(0, jobs), requested)
    }

    static func effectiveLimit(jobs: Int, quota: QuotaSnapshot?, override: Int? = nil) -> Int {
        guard jobs > 0 else { return 0 }
        let requested = override.map { min(hardMaximum, max(1, $0)) } ?? automaticLimit(jobs: jobs, quota: quota)
        return min(max(0, jobs), min(hardMaximum, max(0, requested)))
    }

    static func explanation(jobs: Int, quota: QuotaSnapshot?, override: Int? = nil,
                            language: UILanguage = L10n.currentLanguage) -> String {
        if let override {
            return L10n.format("queue.explanation.manual", language: language,
                               arguments: min(hardMaximum, max(1, override)))
        }
        if let quota, quota.decision(reserve: 0) != .unknown {
            let planLimit = quota.isConfirmedPro ? hardMaximum : 15
            let plan = L10n.string(quota.isConfirmedPro ? "queue.tier.pro" : "queue.tier.plus_unknown", language: language)
            if jobs == 0 {
                return L10n.format("queue.explanation.auto_empty", language: language, arguments: plan, planLimit)
            }
            let limit = automaticLimit(jobs: jobs, quota: quota)
            return L10n.format("queue.explanation.auto", language: language, arguments: plan, limit)
        }
        return L10n.string("queue.explanation.unknown", language: language)
    }
}

/// Session-only Fast state. Merely opening the application cannot count as consent.
struct FastSessionState: Equatable {
    private(set) var isEnabled: Bool
    private var rememberQuestionPending = false

    init(preferences: RuntimePreferences) {
        isEnabled = (try? preferences.validate()) != nil && preferences.rememberFast
    }

    /// Call only after the user confirms enabling Fast. Returns whether to show a
    /// separate, one-time question about remembering it for subsequent launches.
    @discardableResult mutating func confirmActivation(preferences: inout RuntimePreferences) -> Bool {
        guard !isEnabled, (try? preferences.validate()) != nil else { return false }
        isEnabled = true
        if preferences.fastActivationCount < Int.max { preferences.fastActivationCount += 1 }
        guard preferences.fastActivationCount >= 3, !preferences.rememberFastPromptShown else { return false }
        preferences.rememberFastPromptShown = true
        rememberQuestionPending = true
        return true
    }

    @discardableResult mutating func answerRemember(_ remember: Bool, preferences: inout RuntimePreferences) -> Bool {
        guard rememberQuestionPending, isEnabled, preferences.fastActivationCount >= 3, preferences.rememberFastPromptShown,
              (try? preferences.validate()) != nil else { return false }
        rememberQuestionPending = false
        preferences.rememberFast = remember
        return preferences.rememberFast
    }

    mutating func disable(preferences: inout RuntimePreferences) {
        isEnabled = false; preferences.rememberFast = false; rememberQuestionPending = false
        // A refusal or turning Fast off must not trigger the same question every click.
    }
}

struct RuntimePreferencesStore {
    let root: URL
    var fileURL: URL { root.appendingPathComponent("runtime-preferences.json") }

    /// A missing file means a first launch. A malformed existing file is an error,
    /// not permission to restore Fast or silently replace the file with defaults.
    func load() throws -> RuntimePreferences {
        do {
            guard root.isFileURL else { throw RuntimePreferencesError.invalid("Требуется локальная папка состояния.") }
            guard try checkExistingFile() else { return RuntimePreferences() }
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 65_537) ?? Data()
            guard !data.isEmpty, data.count <= 65_536 else { throw RuntimePreferencesError.invalid("Некорректный размер файла настроек.") }
            return try JSONDecoder().decode(RuntimePreferences.self, from: data)
        } catch { throw RuntimePreferencesError.unreadable(error.localizedDescription) }
    }

    /// The caller passes its current `writable && stateLock != nil` ownership gate.
    /// Main-actor serialization plus the app's process-lifetime queue lock ensures
    /// one writer; atomic rename prevents a torn JSON file on interruption.
    @MainActor func save(_ preferences: RuntimePreferences, isMainOwner: Bool) throws {
        guard isMainOwner else { throw RuntimePreferencesError.notOwner }
        try preferences.validate()
        guard root.isFileURL else { throw RuntimePreferencesError.invalid("Требуется локальная папка состояния.") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(preferences)
        guard data.count <= 65_536 else { throw RuntimePreferencesError.invalid("Настройки превышают допустимый размер.") }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            _ = try checkExistingFile()
            let temporary = root.appendingPathComponent(".runtime-preferences-\(UUID().uuidString).tmp")
            try data.write(to: temporary, options: .withoutOverwriting)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            guard rename(temporary.path, fileURL.path) == 0 else {
                throw RuntimePreferencesError.write(String(cString: strerror(errno)))
            }
        } catch { throw RuntimePreferencesError.write(error.localizedDescription) }
    }

    private func checkExistingFile() throws -> Bool {
        var info = stat()
        if lstat(fileURL.path, &info) != 0 {
            if errno == ENOENT { return false }
            throw RuntimePreferencesError.invalid(String(cString: strerror(errno)))
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw RuntimePreferencesError.invalid("runtime-preferences.json должен быть обычным файлом, не ссылкой или папкой.")
        }
        guard info.st_size <= 65_536 else { throw RuntimePreferencesError.invalid("Файл настроек слишком большой.") }
        return true
    }
}

/// Editing uses a local draft. Cancel never mutates the provided bindings.
struct RuntimeSettingsView: View {
    @State private var draftPreferences: RuntimePreferences
    @State private var draftReserve: Double
    private let quota: QuotaSnapshot?
    private let jobs: Int
    private let onSave: (RuntimePreferences, Double) -> Void
    private let onCancel: () -> Void

    init(preferences: RuntimePreferences, reserve: Double, quota: QuotaSnapshot? = nil, jobs: Int = 0,
         onSave: @escaping (RuntimePreferences, Double) -> Void, onCancel: @escaping () -> Void) {
        _draftPreferences = State(initialValue: preferences)
        let value = reserve
        _draftReserve = State(initialValue: value.isFinite ? min(50, max(0, value.rounded())) : 15)
        self.quota = quota; self.jobs = jobs; self.onSave = onSave; self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L10n.current(draftPreferences.reserveConfigured ? "runtime.settings_title" : "runtime.first_run_title")).font(.title2.bold())
            Text(L10n.current("runtime.settings_description"))
                .foregroundStyle(.secondary)
            GroupBox(L10n.current("runtime.concurrent_lectures")) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker(L10n.current("runtime.quantity"), selection: $draftPreferences.concurrencyOverride) {
                        Text(L10n.current("queue.auto_quota")).tag(Int?.none)
                        ForEach(1...ConcurrencyPolicy.hardMaximum, id: \.self) { Text("\($0)").tag(Int?.some($0)) }
                    }
                    ConcurrencyExplanation(jobs: jobs, quota: quota, override: draftPreferences.concurrencyOverride)
                }.padding(8)
            }
            GroupBox(L10n.current("runtime.reserve_group")) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(L10n.current("runtime.keep_at_least"))
                        Spacer()
                        Text("\(Int(draftReserve)) %").monospacedDigit().font(.headline)
                    }
                    Slider(value: $draftReserve, in: 0...50, step: 1).accessibilityLabel(L10n.current("runtime.reserve_accessibility"))
                    Stepper(L10n.current("runtime.reserve_stepper"), value: $draftReserve, in: 0...50, step: 1).font(.caption)
                    if draftReserve == 0 {
                        Label(L10n.current("runtime.reserve_zero_warning"), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    } else if draftReserve < 15 {
                        Label(L10n.current("runtime.reserve_low_warning"), systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    } else {
                        Text(L10n.current("runtime.reserve_default_note")).foregroundStyle(.secondary)
                    }
                }.font(.callout).padding(8)
            }
            HStack {
                Button(L10n.current("common.cancel"), action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.current("common.save")) {
                    draftPreferences.reserveConfigured = true
                    onSave(draftPreferences, draftReserve)
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 550).tint(TranslatorTheme.accent)
    }

    private struct ConcurrencyExplanation: View {
        let jobs: Int
        let quota: QuotaSnapshot?
        let override: Int?
        var body: some View {
            Text(ConcurrencyPolicy.explanation(jobs: jobs, quota: quota, override: override, language: L10n.currentLanguage))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
