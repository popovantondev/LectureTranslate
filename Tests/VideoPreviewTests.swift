import Foundation
import AVFoundation
import Darwin

@main
enum VideoPreviewTests {
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
    @MainActor static var passed = 0
    @MainActor static func check(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure(message: message) }; passed += 1
    }
    @MainActor static func rejects(_ message: String, _ operation: () throws -> Void) throws {
        do { try operation() } catch { passed += 1; return }
        throw Failure(message: message)
    }
    static func cue(start: Int = 5_000, end: Int = 8_000) -> Cue {
        Cue(id: 17, startMS: start, endMS: end, timingLine: "00:00:05,000 --> 00:00:08,000", text: "Обычный текст.")
    }
    static func probe(_ text: String = #"{"streams":[{"index":0,"codec_type":"video"},{"index":1,"codec_type":"audio","tags":{"language":"rus"}},{"index":2,"codec_type":"audio","tags":{"language":"deu","title":"Original"}}],"format":{"duration":"60"}}"#) throws -> VideoPreviewProbe {
        try JSONDecoder().decode(VideoPreviewProbe.self, from: Data(text.utf8))
    }

    @MainActor static func pure(_ root: URL) throws {
        for ext in ["mp4", "MP4", "mov", "m4v"] { try check(VideoPreviewFiles.nativeCandidate(root.appendingPathComponent("a." + ext)), "native extension \(ext)") }
        for ext in ["mkv", "srt", "txt"] { try check(!VideoPreviewFiles.nativeCandidate(root.appendingPathComponent("a." + ext)), "not native extension \(ext)") }
        let raw = "Видео ' $(literal)"
        let mp4 = root.appendingPathComponent(raw + ".mp4"), mov = root.appendingPathComponent(raw + ".mov")
        try Data("synthetic placeholder".utf8).write(to: mp4, options: .withoutOverwriting)
        try Data("synthetic placeholder".utf8).write(to: mov, options: .withoutOverwriting)
        let unrelated = root.appendingPathComponent("unrelated.mkv")
        try Data().write(to: unrelated, options: .withoutOverwriting)
        for suffix in [".srt", ".ru.srt", ".de.srt"] {
            let matches = VideoPreviewFiles.matching(root.appendingPathComponent(raw + suffix))
            try check(Set(matches.map(VideoPreviewFiles.canonical)) == Set([mp4, mov].map(VideoPreviewFiles.canonical)),
                      "matching keeps literal filenames and strips \(suffix): \(matches.map(\.path))")
        }
        try check(VideoPreviewFiles.matching(root.appendingPathComponent("absent.srt")).isEmpty, "unrelated video not guessed")
        for (start, end, duration, expectedStart, expectedEnd) in [
            (5_000, 8_000, 60.0, 2.0, 11.0), (500, 2_000, 60.0, 0.0, 5.0),
            (58_000, 65_000, 60.0, 55.0, 60.0), (0, 1_000, 1.0, 0.0, 1.0)
        ] {
            let range = try ListeningRange(cue: cue(start: start, end: end), padding: 3, mediaDuration: duration)
            try check(range.start == expectedStart && range.end == expectedEnd, "bounded three-second source padding")
            let native = VideoPreviewTimeline(original: range, isShortClip: false)
            let short = VideoPreviewTimeline(original: range, isShortClip: true)
            try check(native.playerStart == expectedStart && native.playerEnd == expectedEnd, "native retains source timeline")
            try check(short.playerStart == 0 && short.playerEnd == range.duration, "short clip uses zero-based playback")
            try check(short.originalTime(playerSeconds: 0.5) == expectedStart + 0.5 && native.originalTime(playerSeconds: 0.5) == 0.5, "source position mapping")
        }
        try rejects("out-of-source cue must fail") { _ = try ListeningRange(cue: cue(start: 60_000, end: 62_000), padding: 3, mediaDuration: 60) }
        try rejects("long cue must not convert a whole lecture") { _ = try ListeningRange(cue: cue(start: 0, end: 600_000), padding: 3, mediaDuration: 3600) }
        try check(VideoPreviewFiles.time(3661) == "01:01:01" && VideoPreviewFiles.time(-4) == "00:00:00", "source time label")
        let media = try probe(); try media.validate()
        try check(media.audio.map(\.id) == [1, 2] && media.audio[1].language == "deu", "probe retains explicit audio indices")
        try check(media.audio[1].label.contains("Original"), "audio label includes title")
        let cover = try probe(#"{"streams":[{"index":0,"codec_type":"video","disposition":{"attached_pic":1}},{"index":3,"codec_type":"video"},{"index":5,"codec_type":"audio"}],"format":{"duration":"8"}}"#)
        try check(cover.videoIndex == 3, "cover artwork not mistaken for lecture video")
        for json in [
            #"{"streams":[{"index":1,"codec_type":"audio"}],"format":{"duration":"8"}}"#,
            #"{"streams":[{"index":1,"codec_type":"video"}],"format":{"duration":"8"}}"#,
            #"{"streams":[{"index":1,"codec_type":"video"},{"index":1,"codec_type":"audio"}],"format":{"duration":"8"}}"#,
            #"{"streams":[{"index":0,"codec_type":"video"},{"index":1,"codec_type":"audio"}],"format":{"duration":"nan"}}"#
        ] { try rejects("invalid media must be rejected") { try probe(json).validate() } }
        let range = try ListeningRange(cue: cue(), padding: 3, mediaDuration: 60)
        let destination = root.appendingPathComponent("short preview.mp4")
        let args = VideoPreviewConversion.arguments(source: mp4, videoIndex: 0, audioIndex: 2, range: range, destination: destination)
        try check(args[args.firstIndex(of: "-ss")! + 1] == "2.000" && args[args.firstIndex(of: "-t")! + 1] == "9.000", "FFmpeg gets only bounded range")
        try check(args[args.firstIndex(of: "-i")! + 1] == mp4.path && args.last == destination.path, "paths passed literally, not through shell")
        let maps = args.indices.filter { args[$0] == "-map" }.map { args[$0 + 1] }
        try check(maps == ["0:0", "0:2"], "exact selected video and audio, never original default")
        try check(args.contains("-n") && !args.contains("-y") && args.contains("file,pipe"), "no overwrite or network protocols")
        try check(args.contains("h264_videotoolbox") && args.contains("aac") && args.contains("yuv420p"), "compatible short MP4 codecs")
        try check(VideoPreviewEncoder.available(in: " V....D h264_videotoolbox VideoToolbox H.264 Encoder") == .videoToolbox, "native hardware encoder supported")
        try check(VideoPreviewEncoder.available(in: " V....D libx264 H.264") == .x264, "software H.264 alternative supported")
        try check(VideoPreviewEncoder.available(in: " V....D libx264rgb H.264") == nil, "unsupported RGB encoder not mistaken for ordinary H.264")
        try check(VideoPreviewEncoder.available(in: "libx264 h264_videotoolbox") == .videoToolbox, "hardware encoder preferred on Mac")
        try check(args.contains("-sn") && args.contains("-dn") && args.contains("-map_metadata"), "unneeded streams and source metadata not copied")
        try check(args[args.firstIndex(of: "-threads")! + 1] == "2", "bounded conversion CPU threads")
        let operation = try ListeningOperation()
        let fakeTools = ListeningTools(ffmpeg: root.appendingPathComponent("missing-ffmpeg"), ffprobe: root.appendingPathComponent("missing-ffprobe"))
        try rejects("audio selection validated before spawning encoder") { _ = try VideoPreviewConversion.clip(mp4, media: media, audioIndex: 0, cue: cue(), tools: fakeTools, operation: operation) }
        try check(try FileManager.default.contentsOfDirectory(atPath: operation.directory.path).isEmpty, "invalid selection creates no processes or output")
        try rejects("remote source forbidden") { try ListeningOperation.validateSource(URL(string: "https://example.invalid/video.mp4")!) }
    }

    @MainActor static func wait(_ name: String, until condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(3)
        while !condition() {
            guard Date() < end else { throw Failure(message: "Timeout: " + name) }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @MainActor static func lifecycle(_ root: URL) async throws {
        let source = root.appendingPathComponent("lifecycle.mp4")
        let other = root.appendingPathComponent("lifecycle-other.mkv")
        try Data("synthetic".utf8).write(to: source, options: .withoutOverwriting)
        try Data("synthetic other".utf8).write(to: other, options: .withoutOverwriting)
        let srt = root.appendingPathComponent("lifecycle.srt")
        let media = try probe()
        let session = VideoPreviewSession()
        defer { session.close() }
        var pending: CheckedContinuation<VideoPreviewInspection, Error>?
        var selected: [URL] = []
        session.inspectionOverride = { _, _ in try await withCheckedThrowingContinuation { pending = $0 } }
        session.configure(sourceSRT: srt, preferredVideo: source, cue: cue()) { selected.append($0) }
        try await wait("inspection begins") { pending != nil }
        session.close()
        pending?.resume(returning: .converted(media)); pending = nil
        try await Task.sleep(nanoseconds: 30_000_000)
        try check(session.source == nil && session.tracks.isEmpty && session.player == nil && !session.busy && selected.isEmpty,
                  "closing rejects stale inspection and cannot start playback or save a wrong binding")

        session.inspectionOverride = { url, _ in
            if url == source { return try await withCheckedThrowingContinuation { pending = $0 } }
            return .converted(media)
        }
        session.configure(sourceSRT: srt, preferredVideo: source, cue: cue()) { selected.append($0) }
        try await wait("first source pending") { pending != nil }
        session.select(other)
        try await wait("new source ready") { !session.busy && !session.tracks.isEmpty }
        pending?.resume(returning: .converted(try probe(#"{"streams":[{"index":0,"codec_type":"video"},{"index":9,"codec_type":"audio"}],"format":{"duration":"6"}}"#))); pending = nil
        try await Task.sleep(nanoseconds: 30_000_000)
        try check(session.source == other && session.tracks.map(\.id) == [1, 2] && selected == [other], "old source response cannot replace a newly selected video")
        try check(session.selectedTrack == -1 && !session.canPlay, "multiple audio tracks never chosen silently")
        session.selectAudio(2)
        try check(session.canPlay, "explicit German selection unlocks playback without a redundant confirmation")
        session.selectAudio(1)
        try check(session.canPlay && session.player == nil, "changing track does not autoplay")
        session.selectAudio(999)
        try check(session.selectedTrack == -1 && !session.canPlay, "unlisted audio index rejected")
        session.close()
        session.configure(sourceSRT: srt, preferredVideo: root.appendingPathComponent("missing.mp4"), cue: cue()) { selected.append($0) }
        try check(session.source == nil && session.message == L10n.current("media.saved_unavailable"),
                  "missing saved video reports the localized unavailable state without selecting a nearby candidate")
        try check(selected == [other], "missing preferred video does not persist a replacement")
        session.close()

        session.inspectionOverride = { _, _ in .converted(try probe(#"{"streams":[{"index":0,"codec_type":"video"},{"index":7,"codec_type":"audio"}],"format":{"duration":"20"}}"#)) }
        session.configure(sourceSRT: srt, preferredVideo: source, cue: cue()) { _ in }
        try await wait("single audio source ready") { !session.busy && !session.tracks.isEmpty }
        try check(session.selectedTrack == 7 && session.canPlay, "single audio can be played immediately for audible verification")
        try check(session.player == nil, "inspection never creates a player or plays sound")
    }

    @MainActor static func cancellation() async throws {
        let operation = try ListeningOperation()
        let task = Task.detached {
            try operation.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "printf '%s\\n' \"$$\"; exec /bin/sleep 30"], timeout: 5)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let began = Date(); operation.cancel()
        do { _ = try await task.value; throw Failure(message: "Cancelled operation unexpectedly succeeded") }
        catch is CancellationError { passed += 1 }
        try check(Date().timeIntervalSince(began) < 2, "cancelled preparation stops promptly")
        let logs = try FileManager.default.contentsOfDirectory(at: operation.directory, includingPropertiesForKeys: nil)
        let pidText = try logs.map { try String(contentsOf: $0, encoding: .utf8) }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = Int32(pidText) else { throw Failure(message: "Cancellation test did not capture child PID") }
        try check(kill(pid, 0) == -1 && errno == ESRCH, "no orphan preparation process remains after cancellation")
    }

    @MainActor static func ffmpeg(_ root: URL) async throws {
        guard let tools = ListeningTools.discover() else { throw Failure(message: "--ffmpeg requires already installed ffmpeg and ffprobe; nothing is downloaded") }
        let operation = try ListeningOperation()
        let encoder = try VideoPreviewConversion.encoder(tools: tools, operation: operation)
        let mkv = root.appendingPathComponent("Фрагмент ' $(literal).mkv")
        _ = try operation.run(tools.ffmpeg, ["-hide_banner", "-loglevel", "error", "-nostdin", "-n",
            "-f", "lavfi", "-i", "color=c=blue:s=320x180:r=10:d=6",
            "-f", "lavfi", "-i", "sine=frequency=880:duration=6:sample_rate=48000",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=6:sample_rate=48000",
            "-map", "0:v", "-map", "1:a", "-map", "2:a"] + encoder.arguments + [
            "-pix_fmt", "yuv420p", "-c:a", "aac", "-metadata:s:a:0", "language=rus", "-metadata:s:a:1", "language=deu", "-t", "6", mkv.path])
        let original = try Data(contentsOf: mkv)
        let media = try VideoPreviewConversion.inspect(mkv, tools: tools, operation: operation)
        try check(media.audio.count == 2 && media.audio[1].language == "deu", "real probe finds the second German audio")
        let selectedCue = cue(start: 4_200, end: 4_800)
        let (clip, range) = try VideoPreviewConversion.clip(mkv, media: media, audioIndex: media.audio[1].id, cue: selectedCue, tools: tools, operation: operation)
        let clipMedia = try VideoPreviewConversion.inspect(clip, tools: tools, operation: operation)
        try check(clipMedia.audio.count == 1 && abs(clipMedia.duration! - range.duration) < 0.15, "fallback contains one selected audio and only the short interval")
        let wav = operation.directory.appendingPathComponent("selected.wav")
        _ = try operation.run(tools.ffmpeg, ["-v", "error", "-nostdin", "-n", "-i", clip.path, "-map", "0:a:0", "-c:a", "pcm_s16le", "-ac", "1", wav.path])
        let audio = try AVAudioFile(forReading: wav)
        let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length))!
        try audio.read(into: buffer)
        let samples = buffer.floatChannelData![0]
        // AAC can leave very quiet ringing in encoder padding. Inspect the
        // steady middle, not zero crossings in that almost-silent padding.
        let trim = Int(audio.processingFormat.sampleRate / 4)
        let first = trim, last = Int(buffer.frameLength) - trim
        guard last > first else { throw Failure(message: "Decoded audio is too short for the tone check") }
        func energy(_ frequency: Double) -> Double {
            var real = 0.0, imaginary = 0.0
            for index in first..<last {
                let angle = 2 * Double.pi * frequency * Double(index) / audio.processingFormat.sampleRate
                real += Double(samples[index]) * cos(angle); imaginary += Double(samples[index]) * sin(angle)
            }
            return real * real + imaginary * imaginary
        }
        let germanEnergy = energy(440), russianEnergy = energy(880)
        try check(germanEnergy > 100 * russianEnergy && germanEnergy > 1,
                  "fallback selected German 440 Hz, not Russian 880 Hz: energy=\(germanEnergy)/\(russianEnergy)")
        try check(try Data(contentsOf: mkv) == original, "fallback leaves MKV unchanged")
        let mp4 = root.appendingPathComponent("native.mp4")
        _ = try operation.run(tools.ffmpeg, ["-v", "error", "-nostdin", "-n", "-i", mkv.path, "-map", "0", "-c", "copy", mp4.path])
        let mp4Before = try Data(contentsOf: mp4)
        let native = try await NativeVideoPreview.inspect(NativeVideoPreview.asset(mp4))
        try check(native.audio.count == 2, "AVFoundation inspects both native audio tracks")
        let composition = try await native.composition(audioID: native.audio[1].id)
        let videoTracks = try await composition.loadTracks(withMediaType: .video)
        let audioTracks = try await composition.loadTracks(withMediaType: .audio)
        try check(videoTracks.count == 1 && audioTracks.count == 1, "native composition exposes only selected audio")
        guard let audioTrack = audioTracks.first else { throw Failure(message: "Composition audio unavailable") }
        let segments = try await audioTrack.load(.segments).compactMap { $0 as? AVCompositionTrackSegment }.filter { !$0.isEmpty }
        try check(!segments.isEmpty && segments.allSatisfy { $0.sourceTrackID == native.audioTracks[1].trackID }, "native composition references the selected source track, never the default")
        try check(try Data(contentsOf: mp4) == mp4Before, "native preparation does not rewrite MP4")
        print("PASS: synthetic MKV short conversion, selected 440 Hz audio, native two-track MP4 composition. No audio played.")
    }

    @MainActor static func run() async throws {
        guard CommandLine.arguments.count == 1 || CommandLine.arguments.dropFirst() == ["--ffmpeg"] else { throw Failure(message: "Usage: VideoPreviewTests [--ffmpeg]") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LectureVideoPreviewTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try pure(root); try await lifecycle(root); try await cancellation()
        if CommandLine.arguments.contains("--ffmpeg") { try await ffmpeg(root) }
        print("PASS: \(passed) video-preview checks. Synthetic local files only; no GUI, network, models, or playback.")
    }
    @MainActor static func main() async {
        do { try await run() } catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
}
