import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

@main struct LocalizationTests {
    static func main() {
        check(UILanguage(preferenceValue: nil) == .de, "German is the first-run default")
        check(UILanguage(preferenceValue: "ru") == .ru, "stored language is read")
        check(UILanguage(preferenceValue: "xx") == .de, "unknown language safely defaults")
        let suite = "localization-lifecycle-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        check(defaults.string(forKey: UILanguage.preferenceKey) == nil, "isolated first-run defaults start empty")
        check(UILanguage.launchLanguage(defaults: defaults) == .de, "first launch persists German before app lifecycle work")
        check(defaults.string(forKey: UILanguage.preferenceKey) == "de", "German first-run choice is stored")
        check(UILanguage.configureSystemLanguageAtLaunch(defaults: defaults) == .de &&
              defaults.stringArray(forKey: "AppleLanguages") == ["de"],
              "first launch selects German for AppKit-generated menus in this app domain")
        defaults.set("ru", forKey: UILanguage.preferenceKey)
        check(UILanguage.configureSystemLanguageAtLaunch(defaults: defaults) == .ru &&
              defaults.stringArray(forKey: "AppleLanguages") == ["ru"],
              "saved language synchronizes the app-specific system language at next launch")
        check(UILanguage.de.standardMenuTitle(for: "Файл") == "Ablage" &&
              UILanguage.de.standardMenuTitle(for: "Вид") == "Darstellung" &&
              UILanguage.ru.standardMenuTitle(for: "Ablage") == "Файл" &&
              UILanguage.en.standardMenuTitle(for: "Fenster") == "Window" &&
              UILanguage.de.standardMenuTitle(for: "Thema") == nil,
              "standard menu headings localize without altering app-owned menus")
        check(UILanguage.activeLanguage(atLaunch: .ru, selectedPreference: "en") == .ru, "language preference changes apply only after restart")
        check(UILanguage.activeLanguage(atLaunch: .de, selectedPreference: "ru") == .de, "current session language remains fixed")
        check(UIMessageID.invalidTerm.rawValue == "memory.invalid_term", "machine identifier is stable")
        let persistedStatus = (key: "queue.pause_reason", arguments: ["Quota"])
        for language in UILanguage.allCases {
            let displayed = L10n.jobMessage(key: persistedStatus.key, arguments: persistedStatus.arguments, legacy: "legacy", language: language)
            check(displayed.contains("Quota") && displayed != "legacy", "persisted status resolves with safe argument: \(language)")
        }
        let localizedPause = UILanguage.allCases.map { L10n.jobMessage(key: persistedStatus.key, arguments: persistedStatus.arguments, legacy: "legacy", language: $0) }
        check(Set(localizedPause).count == 3, "same persisted status key and arguments render in DE/RU/EN")
        check(L10n.jobMessage(key: "status.queued", legacy: "legacy", language: .en) != "legacy", "known status key resolves")
        check(L10n.jobMessage(key: "unknown.%@", arguments: ["%s"], legacy: "legacy", language: .en) == "legacy", "unknown key and format injection fall back unchanged")
        check(L10n.jobMessage(key: "queue.pause_reason", legacy: "legacy", language: .en) == "legacy", "wrong argument count falls back unchanged")
        for language in UILanguage.allCases {
            check(L10n.string("common.save", language: language) != "common.save", "localized key exists: \(language)")
            let usage = L10n.format("usage.summary", language: language, arguments: 17, 11, 13, 1200, 340, 500)
            for value in [17, 11, 13, 1200, 340, 500] {
                check(usage.contains(L10n.number(value, language: language)), "localized usage summary keeps counter \(value): \(language)")
            }
            check(usage != "usage.summary", "localized usage summary exists: \(language)")
            check(L10n.format("translation.completed_count", language: language, arguments: 2, 5).contains("2"), "format argument retained: \(language)")
            check(L10n.plural("queue.items_count", count: 3, language: language).contains("3"), "count retained: \(language)")
            for key in ["page.heading", "page.subtitle", "demo.banner", "table.german_original", "table.russian_translation",
                        "tab.transcript", "tab.model_package", "tab.review_count", "tab.memory", "result.translated",
                        "result.saved", "result.unsaved", "action.show_srt", "action.save_this_srt", "table.number",
                        "table.start", "table.seconds", "table.edit_help", "table.part", "table.save_package",
                        "review.plan_summary", "review.outcomes", "review.notes_intro", "edit.spoken_help",
                        "edit.review_help", "welcome.description", "profile.new_title", "action.show_video",
                        "export.cancelled_kept", "export.distinct_paths", "export.kept_in_project", "export.duplicate_target",
                        "export.skipped_existing", "export.same_folder", "export.already_current", "export.saved",
                        "export.stopped_in_project", "export.report_kept_in_app", "project.default_name",
                        "project.wait_for_pause_unchanged", "project.pause_before_save", "project.wait_for_pause_not_saved",
                        "project.wait_for_pause", "runtime.routing_updated", "runtime.routing_save_error", "runtime.routing_waiting",
                        "runtime.preferences_read_error", "runtime.preferences_save_error", "runtime.rollback_error",
                        "runtime.queue_save_error", "runtime.settings_save_error", "runtime.fast_disable_error",
                        "runtime.fast_enable_title", "runtime.fast_enable_body", "runtime.fast_enable",
                        "runtime.fast_remember_title", "runtime.fast_remember_body", "runtime.fast_until_close",
                        "runtime.fast_always", "runtime.fast_enable_error"] {
                check(L10n.string(key, language: language) != key, "screenshot-discovered UI key exists: \(language)/\(key)")
            }
            for key in ["timing.none", "timing.suggestion", "timing.no_suggestion", "timing.problem", "timing.errors_title",
                        "timing.source_unchanged", "timing.confirm_title", "timing.confirm_body", "timing.repair_backup",
                        "queue.choose_folder_title", "queue.choose_files_title", "timing.transfer_title", "timing.transfer_body",
                        "timing.transfer_action", "source.check_title", "edit.source_checked", "welcome.empty_title", "welcome.select_title",
                        "reserve.continue_title", "reserve.continue_body", "reserve.wait", "reserve.continue_run", "runtime.settings_title",
                        "runtime.first_run_title", "runtime.settings_description", "runtime.concurrent_lectures", "runtime.quantity",
                        "runtime.reserve_group", "runtime.keep_at_least", "runtime.reserve_accessibility", "runtime.reserve_stepper",
                        "runtime.reserve_zero_warning", "runtime.reserve_low_warning", "runtime.reserve_default_note"] {
                check(L10n.string(key, language: language) != key, "J18T4 UI key exists: \(language)/\(key)")
                check(!hasCyrillic(L10n.string(key, language: language)) || language == .ru, "J18T4 copy matches language: \(language)/\(key)")
            }
            check(L10n.format("runtime.rollback_error", language: language, arguments: "queue issue", "settings issue").contains("queue issue") &&
                  L10n.format("runtime.rollback_error", language: language, arguments: "queue issue", "settings issue").contains("settings issue"),
                  "runtime rollback message retains both technical details: \(language)")
        }
        let localizedSurfaceKeys = ["export.cancelled_kept", "export.distinct_paths", "export.kept_in_project", "export.duplicate_target",
                                    "export.skipped_existing", "export.same_folder", "export.already_current", "export.saved",
                                    "export.stopped_in_project", "export.report_kept_in_app", "project.default_name",
                                    "project.wait_for_pause_unchanged", "project.pause_before_save", "project.wait_for_pause_not_saved",
                                    "project.wait_for_pause", "runtime.routing_updated", "runtime.routing_save_error", "runtime.routing_waiting",
                                    "runtime.preferences_read_error", "runtime.preferences_save_error", "runtime.rollback_error",
                                    "runtime.queue_save_error", "runtime.settings_save_error", "runtime.fast_disable_error",
                                    "runtime.fast_enable_title", "runtime.fast_enable_body", "runtime.fast_enable",
                                    "runtime.fast_remember_title", "runtime.fast_remember_body", "runtime.fast_until_close",
                                    "runtime.fast_always", "runtime.fast_enable_error"]
        func hasCyrillic(_ value: String) -> Bool {
            value.unicodeScalars.contains { (0x0400...0x052F).contains(Int($0.value)) }
        }
        for key in localizedSurfaceKeys {
            check(L10n.string(key, language: .de) != L10n.string(key, language: .ru), "surface has distinct German and Russian copy: \(key)")
            check(!hasCyrillic(L10n.string(key, language: .de)) && !hasCyrillic(L10n.string(key, language: .en)),
                  "German and English surface copy is not Russian: \(key)")
        }
        for key in ["page.heading", "page.subtitle", "demo.banner", "table.german_original", "table.russian_translation",
                    "tab.transcript", "tab.model_package", "tab.review_count", "tab.memory", "result.translated",
                    "result.saved", "result.unsaved", "action.show_srt", "action.save_this_srt", "table.number",
                    "table.start", "table.seconds", "table.edit_help", "table.part", "table.save_package",
                    "review.plan_summary", "review.outcomes", "review.notes_intro", "edit.spoken_help",
                    "edit.review_help", "welcome.description", "profile.new_title", "action.show_video"] {
            let german = L10n.string(key, language: .de)
            let english = L10n.string(key, language: .en)
            check(!hasCyrillic(german) && !hasCyrillic(english),
                  "German and English product UI is not Russian: \(key)")
        }
        let mediaKeys = ["media.next_cue", "media.saved_unavailable", "media.not_found", "media.multiple_found", "media.reading_video", "media.read_timeout", "media.one_track", "media.choose_german_audio", "media.native_codec", "media.ffmpeg_required", "media.preparing_video", "media.prepare_timeout", "media.tools_missing", "media.preparing_short", "media.short_ready", "media.original_ready", "media.play_failed", "media.try_short_hint", "media.cancelled", "media.pick_video", "media.tools_not_found", "listen.prepare_audio_failed", "listen.play_audio_failed", "listen.clip_range", "startup.version_unknown"]
        for key in mediaKeys {
            for language in UILanguage.allCases {
                check(L10n.string(key, language: language) != key, "terms/startup/media key exists: \(language)/\(key)")
            }
            check(!hasCyrillic(L10n.string(key, language: .de)) && !hasCyrillic(L10n.string(key, language: .en)), "German and English media UI is not Russian: \(key)")
        }
        check(L10n.format("listen.clip_range", language: .en, arguments: "00:01", "00:04").contains("00:01–00:04"), "listening status retains exact clip bounds")
        check(L10n.format("timing.transfer_body", language: .en, arguments: 12, "rows", "more", "source.srt").contains("12 cues") && L10n.format("timing.transfer_body", language: .en, arguments: 12, "rows", "more", "source.srt").contains("source.srt"), "timing transfer retains count, rows, and source")
        check(L10n.format("timing.suggestion", language: .de, arguments: 2, "00:00", "00:01", 3, "00:01", "00:02").contains("00:02"), "timing suggestion retains both intervals")
        check(L10n.format("media.play_failed", language: .de, arguments: "codec error").contains("codec error"), "video error retains technical diagnostic")
        check(L10n.string("export.warnings_title", language: .de).contains("Übersetzungen") &&
              L10n.string("export.warnings_title", language: .en).contains("Translations"),
              "export warning title is German in DE and English in EN")
        check(L10n.string("export.save_with_notes", language: .de).contains("Hinweisen") &&
              L10n.string("export.save_with_notes", language: .en).contains("notes") &&
              L10n.string("export.cancel", language: .de) == "Abbrechen" &&
              L10n.string("export.cancel", language: .en) == "Cancel",
              "export warning actions match their selected language")
        let translatedWorkflowSamples: [(String, String, String)] = [
            ("export.preparing", "Fertige Übersetzungen", "Preparing completed translations"),
            ("export.collision_title", "Mehrere Vorlesungen", "Several lectures"),
            ("project.close_title", "Was soll beim Schließen", "What should happen to the queue"),
            ("project.close_body", "Behalten", "Keep saves the queue"),
            ("startup.instructions", "Um diese Version zu verwenden", "To use this version")
        ]
        for (key, german, english) in translatedWorkflowSamples {
            check(L10n.string(key, language: .de).contains(german) && L10n.string(key, language: .en).contains(english),
                  "high-impact workflow dialog matches selected language: \(key)")
        }
        let welcomeKeys = ["welcome.initial_status", "welcome.step_add_title", "welcome.step_add_detail",
                           "welcome.step_translate_title", "welcome.step_translate_detail", "welcome.step_voice_title", "welcome.step_voice_detail"]
        for key in welcomeKeys {
            let german = L10n.string(key, language: .de)
            let russian = L10n.string(key, language: .ru)
            let english = L10n.string(key, language: .en)
            check(!german.isEmpty && !russian.isEmpty && !english.isEmpty && german != english && russian != german,
                  "empty-queue onboarding has a separate translation: \(key)")
        }
        let date = Date(timeIntervalSince1970: 0)
        check(!L10n.date(date, language: .de).isEmpty && !L10n.date(date, language: .ru).isEmpty && !L10n.date(date, language: .en).isEmpty, "dates format in every locale")
        print("LocalizationTests: PASS")
    }
}
