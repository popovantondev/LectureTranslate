import Foundation

/// Conservative, local preflight for a single SRT used both on screen and by Russian TTS.
/// This is deliberately a detector, not a medical-number converter or a pronunciation oracle.
/// Call only in the spoken-text mode. Never run it on SRT IDs or timestamp lines.
enum SpeechText {
    static let issuePrefix = "Для озвучки:"

    static let promptInstruction = """
    РЕЖИМ ТЕКСТА ДЛЯ РУССКОЙ ОЗВУЧКИ (Silero v5.5 / kseniya и Siri): единственный SRT должен читаться обычным русским текстом. Числа, единицы и однозначные сокращения полностью раскрой словами В КАЖДОЙ реплике, не только при первом упоминании. Не оставляй арабские/римские цифры, проценты, знаки единиц, формулы и буквенные сокращения без проговариваемого эквивалента.
    Сохрани точную величину, единицу, диапазон, отрицание и значение; согласуй падеж и род: «от 5 мл» → «от пяти миллилитров»; «с 2 таблетками» → «с двумя таблетками»; «0,5 мг» → «ноль целых пять десятых миллиграмма»; «5–10%» → «от пяти до десяти процентов»; «витамин B12» → «витамин бэ двенадцать»; «II стадия» → «вторая стадия». Даты, дроби, степени, температуры и соотношения тоже раскрывай по контексту, без округления или самовольного пересчёта единиц. Сокращённые медицинские термины раскрывай только при однозначном значении.
    Латинские ботанические названия сохраняй правильно: не выдумывай транслитерацию и не заменяй вид похожим. Если точное русское чтение или расшифровка не установлены по контексту/подтверждённому словарю, сохрани исходный термин и обязательно добавь critical issue о проверке произношения/смысла. Никогда не удаляй такой термин или дозу ради прохождения проверки. Не добавляй SSML, HTML, служебные пометки и знаки ударения в translations; обычная буква «ё» допустима. Перед возвратом JSON проверь каждую реплику на оставшиеся цифры и сокращения.
    """

    private static let numeric = regex(#"[\p{Nd}\p{No}]+(?:[.,:/–-][\p{Nd}\p{No}]+)*"#)
    private static let roman = regex(#"(?<![\p{L}\p{N}])[IVXLCDM]+(?![\p{L}\p{N}])|\p{Nl}"#)
    private static let latinWord = regex(#"[\p{Latin}][\p{Latin}\p{M}\p{Nd}]*"#)
    private static let units = regex(#"(?iu)(?<![\p{L}\p{N}])(?:мкг|мг|нг|кг|г|мкл|мл|дл|л|ммоль|мкмоль|моль|мкм|мм|см|км|мгц|кгц|гц|ккал|кдж|дж|кпа|гпа|па|атм|ме|ед|капл?|табл|амп|уп|сут|сек|мин|ч)(?![\p{L}\p{N}])|(?<![\p{L}\p{N}])(?:ст|ч)\s*\.\s*л\s*\.|мм\s+рт\s*\.\s*ст\s*\."#)
    private static let shortForms = regex(#"(?iu)(?<!\p{L})(?:(?:[а-яё]\s*\.\s*){2,}|и\s+др\s*\.|[вп]\s*/\s*[вмк]|им\s*\.|напр\s*\.|г{1,2}\s*\.)(?!\p{L})"#)
    private static let uppercaseWord = regex(#"(?<![\p{L}\p{N}])[А-ЯЁ]{2,}(?:[а-яё]{1,5})?(?![\p{L}\p{N}])"#)
    private static let singleLetterTerm = regex(#"(?iu)\b(?:витамин\w*|групп\w*|тип\w*)\s+[А-ЯЁ](?!\p{L})"#)
    private static let mathAndUnits = regex(#"[%‰‱°℃℉№@#$€₽£¥₴±×÷≤≥≠≈=+*/\\^_|~<>∑√∞→←↔µμ]"#)
    private static let markup = regex(#"<[^>\r\n]+>|&(?:#\w+|[A-Za-z]+);|\[\[|\]\]"#)
    private static let stress = regex(#"[\u0300\u0301]"#)

    // Common uppercase function words can be emphasis rather than abbreviations.
    // Other all-caps words are deliberately review candidates, not silently rewritten.
    private static let ordinaryUppercase: Set<String> = [
        "МЫ", "ВЫ", "ОН", "ОНА", "ОНО", "ОНИ", "ДА", "НЕТ", "НЕ", "НИ", "НО", "ИЛИ", "ЭТО", "КАК",
        "ОТ", "ДО", "ПРИ", "БЕЗ", "НА", "ПО", "ЗА", "ВО", "КО", "ПОД", "НАД", "ЖЕ", "ЛИ", "ЧТО", "ВСЕ", "ВСЁ"
    ]

    static func issues(text: String, cueID: Int) -> [LocalIssue] {
        let normalized = text.precomposedStringWithCanonicalMapping
        var reasons: [String] = []
        let numbers = allMatches(numeric, normalized)
        if !numbers.isEmpty {
            reasons += numbers.map { "цифры/число [\($0)]: запишите словами с точной величиной и правильным падежом." }
        }
        let romans = allMatches(roman, normalized)
        if !romans.isEmpty {
            reasons += romans.map { "возможное римское число или буквенное обозначение [\($0)]. Уточните значение, не заменяя догадкой." }
        }
        let abbreviated = allMatches(units, normalized) + allMatches(shortForms, normalized)
        if !abbreviated.isEmpty {
            reasons += abbreviated.map { "сокращённая единица/запись [\($0)]: нужна однозначная полная форма с правильным склонением." }
        }
        let capitals = allMatches(uppercaseWord, normalized)
        let abbreviations = capitals.filter { !ordinaryUppercase.contains($0) } + allMatches(singleLetterTerm, normalized)
        if !abbreviations.isEmpty {
            reasons += abbreviations.map { "возможная аббревиатура/обозначение [\($0)]. Уточните полную форму; медицинский термин не угадывайте." }
        }
        let foreignLatin = allMatches(latinWord, normalized).filter { token in
            // An isolated uppercase Roman token already has a dedicated warning.
            !token.allSatisfy { "IVXLCDM".contains($0) }
        }
        let foreignOther = letterTokens(normalized).filter { token in
            !token.allSatisfy { "IVXLCDM".contains($0) } && token.unicodeScalars.contains { CharacterSet.letters.contains($0) && !isRussianLetter($0) }
        }
        let foreign = foreignLatin + foreignOther.filter { !foreignLatin.contains($0) }
        if !foreign.isEmpty {
            reasons += foreign.map { "нерусские или смешанные буквы [\($0)]. Проверьте по оригиналу/словарю; не искажайте и не удаляйте название." }
        }
        let markupTokens = allMatches(markup, normalized) + allMatches(stress, text)
        if !markupTokens.isEmpty {
            reasons += markupTokens.map { "служебная разметка/знак ударения [\($0)]. В SRT нужен обычный текст без подсказок голоса." }
        } else if matches(mathAndUnits, normalized) {
            reasons += allMatches(mathAndUnits, normalized).map { "знак, формула или символ [\($0)]. Раскройте словами по смыслу, сохранив дозы и соотношения." }
        }
        return Array(Set(reasons)).sorted().map { LocalIssue(cueID: cueID, reason: "\(issuePrefix) \($0)", critical: true) }
    }

    private static func isRussianLetter(_ scalar: Unicode.Scalar) -> Bool {
        (0x0410...0x044F).contains(scalar.value) || scalar.value == 0x0401 || scalar.value == 0x0451
    }

    private static func letterTokens(_ text: String) -> [String] {
        let pattern = #"[\p{L}\p{M}]+(?:[-’'][\p{L}\p{M}]+)*"#
        return allMatches(regex(pattern), text)
    }
    private static func regex(_ pattern: String) -> NSRegularExpression {
        // All patterns are compile-time constants and are exercised by offline tests.
        try! NSRegularExpression(pattern: pattern)
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func allMatches(_ regex: NSRegularExpression, _ text: String) -> [String] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }
}
