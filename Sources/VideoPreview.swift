import Foundation
import AVFoundation

struct VideoPreviewAudioTrack: Identifiable, Equatable {
    let id: Int
    let language: String?
    let title: String?
    var label: String {
        "Дорожка \(id) · \(language ?? "язык не указан")" + (title.map { " · \($0)" } ?? "")
    }
}

enum VideoPreviewFiles {
    static let extensions: Set<String> = ["mp4", "mov", "m4v", "mkv"]
    static func nativeCandidate(_ url: URL) -> Bool { ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) }
    static func canonical(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }
    static func matching(_ srt: URL) -> [URL] {
        var stem = srt.deletingPathExtension().lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()
        if stem.hasSuffix(".ru") || stem.hasSuffix(".de") { stem = String(stem.dropLast(3)) }
        let siblings = (try? FileManager.default.contentsOfDirectory(at: srt.deletingLastPathComponent(), includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        return siblings.filter {
            extensions.contains($0.pathExtension.lowercased()) &&
            $0.deletingPathExtension().lastPathComponent.precomposedStringWithCanonicalMapping.lowercased() == stem &&
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
    static func time(_ seconds: Double) -> String {
        let value = max(0, seconds.isFinite ? Int(seconds) : 0)
        return String(format: "%02d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
    }
}

/// Same absolute timeline for native playback; the short fallback starts at zero.
struct VideoPreviewTimeline: Equatable {
    let original: ListeningRange
    let isShortClip: Bool
    var playerStart: Double { isShortClip ? 0 : original.start }
    var playerEnd: Double { isShortClip ? original.duration : original.end }
    func originalTime(playerSeconds: Double) -> Double { playerSeconds + (isShortClip ? original.start : 0) }
}

struct VideoPreviewProbe: Decodable {
    struct Stream: Decodable {
        let index: Int
        let codec_type: String
        let tags: [String: String]?
        let disposition: [String: Int]?
    }
    struct Format: Decodable { let duration: String? }
    let streams: [Stream]
    let format: Format?
    var duration: Double? { format?.duration.flatMap(Double.init).flatMap { $0.isFinite && $0 > 0 ? $0 : nil } }
    var videoIndex: Int? { streams.first { $0.codec_type == "video" && $0.disposition?["attached_pic"] != 1 }?.index }
    var audio: [VideoPreviewAudioTrack] {
        streams.filter { $0.codec_type == "audio" }.map { .init(id: $0.index, language: $0.tags?["language"], title: $0.tags?["title"]) }
    }
    func validate() throws {
        guard duration != nil, videoIndex != nil, !audio.isEmpty,
              streams.allSatisfy({ $0.index >= 0 }), Set(streams.map(\.index)).count == streams.count else {
            throw TranslatorError.invalid("В файле не найдены доступные видео, звук или длительность. Выберите исходное видео.")
        }
    }
}

enum VideoPreviewEncoder: Equatable {
    case videoToolbox, x264
    var arguments: [String] {
        switch self {
        case .videoToolbox: return ["-c:v", "h264_videotoolbox", "-b:v", "2M", "-allow_sw", "1"]
        case .x264: return ["-c:v", "libx264", "-preset", "veryfast", "-crf", "23"]
        }
    }
    static func available(in text: String) -> VideoPreviewEncoder? {
        if text.range(of: #"\bh264_videotoolbox\b"#, options: .regularExpression) != nil { return .videoToolbox }
        if text.range(of: #"\blibx264\b"#, options: .regularExpression) != nil { return .x264 }
        return nil
    }
}

enum VideoPreviewConversion {
    static func encoder(tools: ListeningTools, operation: ListeningOperation) throws -> VideoPreviewEncoder {
        let data = try operation.run(tools.ffmpeg, ["-hide_banner", "-encoders"], timeout: 10)
        guard let result = VideoPreviewEncoder.available(in: String(data: data, encoding: .utf8) ?? "") else {
            throw TranslatorError.invalid("В выбранном FFmpeg нет кодировщика H.264 (VideoToolbox или libx264). Укажите другую уже установленную сборку FFmpeg.")
        }
        return result
    }
    static func inspect(_ source: URL, tools: ListeningTools, operation: ListeningOperation) throws -> VideoPreviewProbe {
        try ListeningOperation.validateSource(source)
        let data = try operation.run(tools.ffprobe, ["-v", "error", "-protocol_whitelist", "file,pipe",
            "-show_entries", "format=duration:stream=index,codec_type:stream_tags=language,title:stream_disposition=attached_pic",
            "-of", "json", source.path], timeout: 25)
        let result = try JSONDecoder().decode(VideoPreviewProbe.self, from: data)
        try result.validate(); return result
    }

    static func arguments(source: URL, videoIndex: Int, audioIndex: Int, range: ListeningRange, destination: URL, encoder: VideoPreviewEncoder = .videoToolbox) -> [String] {
        func number(_ value: Double) -> String { String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value) }
        return ["-hide_banner", "-loglevel", "error", "-nostdin", "-n", "-protocol_whitelist", "file,pipe",
            "-ss", number(range.start), "-i", source.path, "-t", number(range.duration),
            "-map", "0:\(videoIndex)", "-map", "0:\(audioIndex)", "-sn", "-dn", "-map_metadata", "-1", "-map_chapters", "-1",
            "-vf", "scale=w='min(iw,1280)':h='min(ih,720)':force_original_aspect_ratio=decrease:force_divisible_by=2"] + encoder.arguments + [
            "-pix_fmt", "yuv420p", "-threads", "2",
            "-c:a", "aac", "-b:a", "128k", "-ar", "48000", "-ac", "2", "-movflags", "+faststart", destination.path]
    }

    static func clip(_ source: URL, media: VideoPreviewProbe, audioIndex: Int, cue: Cue,
                     tools: ListeningTools, operation: ListeningOperation) throws -> (URL, ListeningRange) {
        try ListeningOperation.validateSource(source); try media.validate()
        guard media.audio.contains(where: { $0.id == audioIndex }), let videoIndex = media.videoIndex, let duration = media.duration else {
            throw TranslatorError.invalid("Выберите звуковую дорожку из этого видео.")
        }
        let range = try ListeningRange(cue: cue, padding: 3, mediaDuration: duration)
        let encoder = try encoder(tools: tools, operation: operation)
        let destination = operation.directory.appendingPathComponent("video-\(UUID().uuidString).mp4")
        _ = try operation.run(tools.ffmpeg, arguments(source: source, videoIndex: videoIndex, audioIndex: audioIndex,
            range: range, destination: destination, encoder: encoder), timeout: 90)
        guard (try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 100 else {
            throw TranslatorError.invalid("Короткий видеофрагмент пуст. Проверьте исходное видео и временные метки.")
        }
        return (destination, range)
    }
}

/// Keeps local asset references, not a copied or re-encoded lecture.
final class NativeVideoPreview: @unchecked Sendable {
    let asset: AVURLAsset
    let duration: Double
    let videoTrack: AVAssetTrack
    let audioTracks: [AVAssetTrack]
    let audio: [VideoPreviewAudioTrack]

    init(asset: AVURLAsset, duration: Double, video: AVAssetTrack, tracks: [AVAssetTrack], audio: [VideoPreviewAudioTrack]) {
        self.asset = asset; self.duration = duration; videoTrack = video; audioTracks = tracks; self.audio = audio
    }

    static func asset(_ source: URL) -> AVURLAsset {
        AVURLAsset(url: source, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
    }

    static func inspect(_ asset: AVURLAsset) async throws -> NativeVideoPreview {
        let playable = try await asset.load(.isPlayable)
        let protected = try await asset.load(.hasProtectedContent)
        let duration = try await asset.load(.duration).seconds
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        guard playable, !protected, duration.isFinite, duration > 0, let video = videos.first, !audios.isEmpty else {
            throw TranslatorError.invalid("macOS не поддерживает эту видеозапись напрямую.")
        }
        var choices: [VideoPreviewAudioTrack] = []
        for track in audios {
            let extendedLanguage = try await track.load(.extendedLanguageTag)
            let languageCode = try await track.load(.languageCode)
            let language = extendedLanguage ?? languageCode
            let metadata = try await track.load(.commonMetadata)
            let titleItem = AVMetadataItem.metadataItems(from: metadata, withKey: AVMetadataKey.commonKeyTitle, keySpace: .common).first
            let title = try await titleItem?.load(.stringValue)
            choices.append(.init(id: Int(track.trackID), language: language, title: title))
        }
        return NativeVideoPreview(asset: asset, duration: duration, video: video, tracks: audios, audio: choices)
    }

    func composition(audioID: Int) async throws -> AVMutableComposition {
        guard let selected = audioTracks.first(where: { Int($0.trackID) == audioID }) else {
            throw TranslatorError.invalid("Выбранная звуковая дорожка недоступна.")
        }
        let composition = AVMutableComposition()
        let full = CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
        for track in [videoTrack, selected] {
            try Task.checkCancellation()
            let type: AVMediaType = track === videoTrack ? .video : .audio
            let sourceRange = try await track.load(.timeRange)
            let range = CMTimeRangeGetIntersection(full, otherRange: sourceRange)
            guard range.isValid, !range.isEmpty, let target = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw TranslatorError.invalid("Не удалось открыть выбранные дорожки видео.")
            }
            // Keep the source timing, including a nonzero track start or shorter audio.
            try target.insertTimeRange(range, of: track, at: range.start)
            if type == .video { target.preferredTransform = try await track.load(.preferredTransform) }
        }
        return composition
    }
}

enum VideoPreviewInspection {
    case native(NativeVideoPreview)
    case converted(VideoPreviewProbe)
    var audio: [VideoPreviewAudioTrack] {
        switch self { case .native(let value): return value.audio; case .converted(let value): return value.audio }
    }
    var duration: Double {
        switch self { case .native(let value): return value.duration; case .converted(let value): return value.duration ?? 0 }
    }
}
