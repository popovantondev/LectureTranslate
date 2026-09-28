import Foundation

/// The UI language is presentation state only. Persist its raw value in user defaults,
/// never in a translation journal, project, prompt, or review identifier.
enum UILanguage: String, CaseIterable, Codable {
    case de, ru, en

    static let preferenceKey = "translatorLanguage"
    static let firstRunDefault = UILanguage.de

    /// Establishes a durable first-run choice before any app lifecycle task can resume work.
    static func launchLanguage(defaults: UserDefaults = .standard) -> UILanguage {
        if let stored = defaults.string(forKey: preferenceKey), let language = UILanguage(rawValue: stored) {
            return language
        }
        defaults.set(firstRunDefault.rawValue, forKey: preferenceKey)
        return firstRunDefault
    }

    /// Keep AppKit-generated system menu titles in the app's selected language.
    /// The language takes effect on the next launch, so synchronize before SwiftUI
    /// constructs the standard command menus for that process.
    @discardableResult
    static func configureSystemLanguageAtLaunch(defaults: UserDefaults = .standard) -> UILanguage {
        let language = launchLanguage(defaults: defaults)
        defaults.set([language.rawValue], forKey: "AppleLanguages")
        return language
    }

    /// A language preference is written immediately, but takes effect in the next process.
    static func activeLanguage(atLaunch: UILanguage, selectedPreference: String?) -> UILanguage {
        atLaunch
    }

    init(preferenceValue: String?) {
        self = preferenceValue.flatMap(UILanguage.init(rawValue:)) ?? Self.firstRunDefault
    }

    var locale: Locale { Locale(identifier: rawValue) }

    /// Translate only recognized AppKit top-level headings. Their actions,
    /// shortcuts, and app-owned command menus remain unchanged.
    func standardMenuTitle(for title: String) -> String? {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let index: Int?
        switch normalized {
        case "File", "Ablage", "Datei", "Файл": index = 0
        case "Edit", "Bearbeiten", "Правка": index = 1
        case "View", "Darstellung", "Ansicht", "Вид": index = 2
        case "Window", "Fenster", "Окно": index = 3
        case "Help", "Hilfe", "Справка": index = 4
        default: index = nil
        }
        guard let index else { return nil }
        let titles: [[String]] = [
            ["Ablage", "Файл", "File"],
            ["Bearbeiten", "Правка", "Edit"],
            ["Darstellung", "Вид", "View"],
            ["Fenster", "Окно", "Window"],
            ["Hilfe", "Справка", "Help"]
        ]
        return titles[index][self == .de ? 0 : self == .ru ? 1 : 2]
    }
}

/// Stable machine identifiers remain independent from localized presentation text.
enum UIMessageID: String {
    case invalidTerm = "memory.invalid_term"
    case duplicateConfirmedTerm = "memory.duplicate_confirmed_term"
    case unknownTerm = "memory.unknown_term"
}

enum L10n {
    static let currentLanguage = UILanguage.configureSystemLanguageAtLaunch()
    static func current(_ key: String) -> String { string(key, language: currentLanguage) }
    static func currentFormat(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: current(key), locale: currentLanguage.locale, arguments: arguments)
    }
    static func string(_ key: String, language: UILanguage, bundle: Bundle = .main) -> String {
        let table = "Localizable"
        let path = bundle.path(forResource: language.rawValue, ofType: "lproj")
        let localizedBundle = path.flatMap(Bundle.init(path:)) ?? bundle
        return localizedBundle.localizedString(forKey: key, value: key, table: table)
    }

    /// Resolve only explicitly supported status keys. Persisted values never act as format strings.
    static func jobMessage(key: String?, arguments: [String] = [], legacy: String,
                           language: UILanguage = currentLanguage, bundle: Bundle = .main) -> String {
        guard let key, key.count <= 128, arguments.count <= 8, arguments.allSatisfy({ $0.count <= 512 }) else { return legacy }
        let argumentCount: Int
        if key.hasPrefix("status.") && ["status.queued", "status.prepared", "status.invalid", "status.sourceChanged",
            "status.translating", "status.translated", "status.needsReview", "status.translationError", "status.exported", "status.paused"].contains(key) {
            argumentCount = 0
        } else if key == "queue.pause_reason" {
            argumentCount = 1
        } else { return legacy }
        guard arguments.count == argumentCount else { return legacy }
        let template = string(key, language: language, bundle: bundle)
        guard template != key else { return legacy }
        guard argumentCount == 1 else { return template }
        return String(format: template, locale: language.locale, arguments[0] as NSString)
    }

    static func format(_ key: String, language: UILanguage, arguments: CVarArg..., bundle: Bundle = .main) -> String {
        String(format: string(key, language: language, bundle: bundle), locale: language.locale, arguments: arguments)
    }

    static func number(_ value: Int, language: UILanguage) -> String {
        value.formatted(.number.locale(language.locale))
    }

    static func date(_ value: Date, language: UILanguage, style: Date.FormatStyle.DateStyle = .abbreviated) -> String {
        value.formatted(Date.FormatStyle(date: style, time: .omitted, locale: language.locale))
    }

    /// Present a plain-language cause first and retain the original diagnostic separately.
    /// This affects only UI presentation; it never changes persisted errors or decisions.
    static func errorPresentation(_ error: Error, language: UILanguage = currentLanguage) -> String {
        let nsError = error as NSError
        let key: String
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError: key = "error.permission"
            case NSFileWriteOutOfSpaceError: key = "error.space"
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError: key = "error.missing"
            case NSFileWriteFileExistsError: key = "error.exists"
            default: key = "error.generic"
            }
        } else if nsError.domain == NSPOSIXErrorDomain {
            switch nsError.code {
            case Int(EACCES), Int(EPERM), Int(EROFS): key = "error.permission"
            case Int(ENOSPC): key = "error.space"
            case Int(ENOENT): key = "error.missing"
            case Int(EEXIST): key = "error.exists"
            default: key = "error.generic"
            }
        } else { key = "error.generic" }
        return string(key, language: language) + "\n\n" + format("error.technical", language: language, arguments: nsError.localizedDescription)
    }

    static func plural(_ key: String, count: Int, language: UILanguage, bundle: Bundle = .main) -> String {
        let format = string(key, language: language, bundle: bundle)
        return String(format: format, locale: language.locale, count)
    }
}
