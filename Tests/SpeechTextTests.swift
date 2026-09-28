import Foundation

@main
enum SpeechTextTests {
    static func main() throws {
        var passed = 0
        func check(_ condition: Bool, _ name: String) {
            guard condition else { fputs("FAIL: \(name)\n", stderr); exit(1) }
            passed += 1
        }
        let plain = [
            "От пяти миллилитров до десяти миллилитров.",
            "Принимать с двумя таблетками, но не во время беременности.",
            "Ноль целых пять десятых миллиграмма.",
            "От пяти до десяти процентов; соотношение — один к пяти.",
            "Витамин бэ двенадцать, гамма-аминомасляная кислота и зверобой.",
            "Трижды в день. Буква «ё», листья мать-и-мачехи.",
            "НЕ увеличивайте дозу. НЕТ подтверждённых данных.",
            "Вторая стадия, двадцать первый век, третьего сентября.",
            "Температура — тридцать семь градусов Цельсия.",
            "Сто сорок на девяносто миллиметров ртутного столба.",
            "Это зелёный чай.".decomposedStringWithCanonicalMapping,
            "Пауза… затем врач говорит: «Не применять!»",
            ""
        ]
        for value in plain {
            check(SpeechText.issues(text: value, cueID: 42).isEmpty, "ordinary Russian: \(value)")
        }
        let unsafe: [(String, String)] = [
            ("От 5 мл", "цифры"), ("0,5 миллиграмма", "цифры"),
            ("Пять–10 капель", "цифры"), ("Второго 09.2026", "цифры"),
            ("½ таблетки", "цифры"), ("CO₂", "цифры"), ("１０ процентов", "цифры"),
            ("II стадия", "римское"), ("III–IV стадия", "римское"), ("Ⅳ стадия", "римское"),
            ("Пять мл", "единица"), ("Два мкг", "единица"), ("Пять мг/кг", "единица"),
            ("Две ст. л.", "единица"), ("Одна ч. л.", "единица"), ("Давление мм рт. ст.", "единица"),
            ("Две табл.", "единица"), ("Ввести в/в", "единица"), ("Т. е. не принимать", "единица"),
            ("Т. к. принимать нельзя", "единица"), ("Пояснил к. м. н.", "единица"),
            ("При этом АД падает", "аббревиатура"), ("ГАМК и АТФ", "аббревиатура"),
            ("Эти БАДы не лекарства", "аббревиатура"), ("Из группы НПВП", "аббревиатура"),
            ("Витамин А", "аббревиатура"), ("ЭКГ", "аббревиатура"),
            ("Hypericum perforatum", "нерусские"), ("Matricāria chamomilla", "нерусские"),
            ("Тбилиси საქართველოში", "нерусские"), ("латинский смешанный токен AД", "нерусские"),
            ("витамин B12", "нерусские"), ("Beschwerden", "нерусские"),
            ("β-каротин", "нерусские"), ("pH", "нерусские"),
            ("Пять процентов %", "знак, формула"), ("Сорок °C", "знак, формула"),
            ("№ один", "знак, формула"), ("А + б", "знак, формула"),
            ("Пять µг", "знак, формула"), ("Пять €", "знак, формула"),
            ("<speak>Пять миллиграммов</speak>", "разметка"),
            ("Молок+о", "знак, формула"), ("молоко\u{0301}", "знак ударения"),
            ("Пять &amp; десять", "разметка"), ("[[rate 150]] Привет", "разметка")
        ]
        for (value, reason) in unsafe {
            let issues = SpeechText.issues(text: value, cueID: 42)
            check(issues.contains { $0.reason.contains(reason) }, "detect \(reason): \(value)")
            check(issues.allSatisfy { $0.cueID == 42 && $0.critical && $0.reason.hasPrefix(SpeechText.issuePrefix) }, "explicit reviewable issue: \(value)")
        }
        check(SpeechText.issues(text: "III", cueID: 1).count == 1, "Roman numeral has no duplicate Latin flag")
        let exact = SpeechText.issues(text: "Принять 5 мл Hypericum", cueID: 77)
        check(exact.allSatisfy { $0.cueID == 77 } && exact.contains { $0.reason.contains("[5]") } && exact.contains { $0.reason.contains("[мл]") } && exact.contains { $0.reason.contains("[Hypericum]") }, "exact token diagnostics retain cue and literal tokens")
        check(exact.count >= 3 && exact.allSatisfy { $0.reason.filter { $0 == "[" }.count == 1 }, "each suspicious span is shown separately with its exact spelling")
        check(exact.contains { $0.reason.contains("Hypericum") } && !exact.contains { $0.reason.contains("удалите название") }, "valid Latin names remain intact and are only flagged for review")
        let georgian = SpeechText.issues(text: "თბილისი", cueID: 78)
        check(georgian.contains { $0.reason.contains("[თბილისი]") }, "Georgian token is identified exactly")
        let original = "От 5 мл Hypericum perforatum, не превышать 1/2 дозы."
        let before = Data(original.utf8)
        _ = SpeechText.issues(text: original, cueID: 5)
        check(before == Data(original.utf8), "detector never rewrites number, unit, Latin term or negation")
        check(SpeechText.issues(text: String(repeating: original, count: 300), cueID: 5).count <= 7, "bounded issues per cue")
        check(SpeechText.issues(text: original, cueID: 5) == SpeechText.issues(text: original, cueID: 5), "deterministic issue identity")
        check(SpeechText.promptInstruction.contains("В КАЖДОЙ") && SpeechText.promptInstruction.contains("от пяти миллилитров") && SpeechText.promptInstruction.contains("с двумя таблетками"), "full expansion and grammatical examples in model instruction")
        check(SpeechText.promptInstruction.contains("без округления") && SpeechText.promptInstruction.contains("Никогда не удаляй") && SpeechText.promptInstruction.contains("critical issue"), "medical meaning and uncertainty safety in instruction")
        check(SpeechText.promptInstruction.contains("Не добавляй SSML") && SpeechText.promptInstruction.contains("не выдумывай транслитерацию"), "no markup or fabricated pronunciation")
        print("PASS: \(passed) speech-text checks. No model, TTS, network or user state.")
    }
}
