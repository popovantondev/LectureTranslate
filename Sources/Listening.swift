import Foundation

struct ListeningRange: Equatable {
    let start: Double
    let end: Double
    var duration: Double { end - start }
    init(cue: Cue, padding: Int, mediaDuration: Double) throws {
        guard mediaDuration.isFinite, mediaDuration > 0, cue.startMS >= 0,
              cue.endMS > cue.startMS, [0, 3, 8].contains(padding) else {
            throw TranslatorError.invalid("Не удалось определить временное окно записи.")
        }
        guard Double(cue.startMS) / 1000 < mediaDuration else {
            throw TranslatorError.invalid("Реплика начинается за концом выбранной записи. Проверьте соответствие видео и SRT.")
        }
        start = max(0, Double(cue.startMS) / 1000 - Double(padding))
        end = min(mediaDuration, Double(cue.endMS) / 1000 + Double(padding))
        guard duration <= 120 else { throw TranslatorError.invalid("Фрагмент длиннее двух минут. Откройте оригинал отдельно.") }
    }
}

struct ListeningTrack: Decodable, Identifiable {
    let index: Int
    let tags: [String: String]?
    var id: Int { index }
    var label: String {
        "Дорожка \(index) · \(tags?["language"] ?? "язык не указан")" + (tags?["title"].map { " · \($0)" } ?? "")
    }
}

struct ListeningMedia: Decodable {
    struct Format: Decodable { let duration: String? }
    let streams: [ListeningTrack]
    let format: Format?
    var duration: Double? { format?.duration.flatMap(Double.init).flatMap { $0.isFinite && $0 > 0 ? $0 : nil } }
    // Never infer German from a default flag or choose among multiple tracks.
    var onlyTrack: Int? { streams.count == 1 ? streams[0].index : nil }
}

struct ListeningTools {
    let ffmpeg: URL
    let ffprobe: URL
    static func inDirectory(_ directory: URL) -> ListeningTools? {
        let a = directory.appendingPathComponent("ffmpeg"), b = directory.appendingPathComponent("ffprobe")
        guard FileManager.default.isExecutableFile(atPath: a.path), FileManager.default.isExecutableFile(atPath: b.path) else { return nil }
        return ListeningTools(ffmpeg: a, ffprobe: b)
    }
    static func discover() -> ListeningTools? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var directories = [URL(fileURLWithPath: "/opt/homebrew/bin"), URL(fileURLWithPath: "/usr/local/bin")]
        if let saved = UserDefaults.standard.string(forKey: "listeningToolsDirectory") { directories.insert(URL(fileURLWithPath: saved), at: 0) }
        directories += ["Projects/Programmierung/Оля лекции транскрипция FFMPEG/Версия 2.0/vendor",
                        "Projects/Programmierung/Оля лекции транскрипция FFMPEG/vendor"].map { home.appendingPathComponent($0) }
        directories += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: String($0)) }
        return directories.compactMap(inDirectory).first
    }
}

/// One local operation; cancellation and a deadline also cover a stuck decoder.
/// All output is restricted to this operation's newly-created UUID directory.
final class ListeningOperation: @unchecked Sendable {
    let directory: URL
    private let lock = NSLock()
    private var cancelled = false
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("LectureListening-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func run(_ executable: URL, _ arguments: [String], timeout: Double = 45) throws -> Data {
        if isCancelled { throw CancellationError() }
        let output = directory.appendingPathComponent(UUID().uuidString + ".log")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = executable; process.arguments = arguments
        process.standardInput = FileHandle.nullDevice; process.standardOutput = handle; process.standardError = handle
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if isCancelled || Date() >= deadline {
                process.terminate()
                let grace = Date().addingTimeInterval(1)
                while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.025) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                if isCancelled { throw CancellationError() }
                throw TranslatorError.invalid("Локальная подготовка звука превысила время ожидания. Оригинал не изменён.")
            }
            Thread.sleep(forTimeInterval: 0.025)
        }
        process.waitUntilExit()
        if isCancelled { throw CancellationError() }
        let reader = try FileHandle(forReadingFrom: output)
        defer { try? reader.close() }
        let data = try reader.read(upToCount: 131_072) ?? Data()
        guard process.terminationStatus == 0 else {
            throw TranslatorError.invalid("Не удалось прочитать запись: " + String((String(data: data, encoding: .utf8) ?? "ошибка FFmpeg").suffix(1600)))
        }
        return data
    }
    static func validateSource(_ source: URL) throws {
        guard source.isFileURL, ["mp4", "mkv", "mov", "m4v"].contains(source.pathExtension.lowercased()),
              (try? source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              FileManager.default.isReadableFile(atPath: source.path) else {
            throw TranslatorError.invalid("Выберите доступный локальный видеофайл MP4, MKV, MOV или M4V.")
        }
    }
    func inspect(_ source: URL, tools: ListeningTools) throws -> ListeningMedia {
        try Self.validateSource(source)
        let data = try run(tools.ffprobe, ["-v", "error", "-protocol_whitelist", "file,pipe", "-select_streams", "a",
            "-show_entries", "stream=index:stream_tags=language,title:format=duration", "-of", "json", source.path])
        let media = try JSONDecoder().decode(ListeningMedia.self, from: data)
        guard !media.streams.isEmpty else { throw TranslatorError.invalid("В выбранном видео нет звуковой дорожки.") }
        guard media.duration != nil else { throw TranslatorError.invalid("Не удалось прочитать длительность видео.") }
        return media
    }
    static func clipArguments(source: URL, track: Int, range: ListeningRange, destination: URL) -> [String] {
        func number(_ value: Double) -> String { String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value) }
        return ["-hide_banner", "-loglevel", "error", "-nostdin", "-n", "-protocol_whitelist", "file,pipe",
                "-ss", number(range.start), "-i", source.path, "-t", number(range.duration),
                "-map", "0:\(track)", "-vn", "-sn", "-dn", "-c:a", "pcm_s16le", "-ar", "48000", destination.path]
    }
    func clip(_ source: URL, tools: ListeningTools, track: Int, range: ListeningRange) throws -> URL {
        try Self.validateSource(source)
        let output = directory.appendingPathComponent("preview-\(UUID().uuidString).wav")
        _ = try run(tools.ffmpeg, Self.clipArguments(source: source, track: track, range: range, destination: output))
        guard (try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 44 else { throw TranslatorError.invalid("В указанном окне нет звука. Проверьте видео и таймкоды.") }
        return output
    }
}
