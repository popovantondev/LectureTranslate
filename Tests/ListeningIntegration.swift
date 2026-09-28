import Foundation
import AVFoundation

@main
enum ListeningIntegration {
    static func main() throws {
        guard let tools = ListeningTools.discover() else { throw TranslatorError.invalid("FFmpeg/ffprobe not found") }
        let operation = try ListeningOperation()
        let fixture = operation.directory.appendingPathComponent("Две дорожки ' $(literal).mkv")
        _ = try operation.run(tools.ffmpeg, ["-hide_banner", "-loglevel", "error", "-nostdin", "-n",
            "-f", "lavfi", "-i", "sine=frequency=880:duration=6:sample_rate=48000",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=6:sample_rate=48000",
            "-map", "0:a", "-map", "1:a", "-c:a", "pcm_s16le",
            "-metadata:s:a:0", "language=rus", "-metadata:s:a:1", "language=deu", fixture.path])
        let before = SRTDocument.hash(try Data(contentsOf: fixture))
        let media = try operation.inspect(fixture, tools: tools)
        guard media.streams.count == 2, media.onlyTrack == nil else { fatalError("Ambiguous tracks were guessed") }
        let cue = Cue(id: 7, startMS: 2123, endMS: 3456, timingLine: "", text: "Test")
        let range = try ListeningRange(cue: cue, padding: 0, mediaDuration: media.duration!)
        let clip = try operation.clip(fixture, tools: tools, track: media.streams[1].index, range: range)
        let audio = try AVAudioFile(forReading: clip)
        let frames = AVAudioFrameCount(audio.length)
        let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: frames)!
        try audio.read(into: buffer)
        let seconds = Double(audio.length) / audio.processingFormat.sampleRate
        guard abs(seconds - 1.333) < 0.002 else { fatalError("Clip window mismatch: \(seconds)") }
        let samples = buffer.floatChannelData![0]
        var crossings = 0
        for i in 1..<Int(buffer.frameLength) where samples[i - 1] < 0 && samples[i] >= 0 { crossings += 1 }
        let frequency = Double(crossings) / seconds
        guard abs(frequency - 440) < 2 else { fatalError("Wrong selected audio: \(frequency)") }
        guard SRTDocument.hash(try Data(contentsOf: fixture)) == before else { fatalError("Input modified") }
        let player = try AVAudioPlayer(contentsOf: clip)
        guard player.prepareToPlay() else { fatalError("AVAudioPlayer rejected WAV") }
        // Does not play any sound during this automated integration test.
        let timeout = try ListeningOperation()
        let started = Date()
        do { _ = try timeout.run(URL(fileURLWithPath: "/bin/sleep"), ["3"], timeout: 0.05); fatalError("No timeout") }
        catch { guard Date().timeIntervalSince(started) < 2 else { fatalError("Timeout did not stop process") } }
        let cancelled = try ListeningOperation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { cancelled.cancel() }
        do { _ = try cancelled.run(URL(fileURLWithPath: "/bin/sleep"), ["3"]); fatalError("No cancellation") }
        catch is CancellationError {} 
        if CommandLine.arguments.count > 1 {
            let source = URL(fileURLWithPath: CommandLine.arguments[1])
            let real = try operation.inspect(source, tools: tools)
            guard let selected = real.onlyTrack else { throw TranslatorError.invalid("Real input needs explicit track choice") }
            let actualRange = try ListeningRange(cue: cue, padding: 3, mediaDuration: real.duration!)
            let actualClip = try operation.clip(source, tools: tools, track: selected, range: actualRange)
            let actualPlayer = try AVAudioPlayer(contentsOf: actualClip)
            guard actualPlayer.prepareToPlay(), abs(actualPlayer.duration - actualRange.duration) < 0.1 else { fatalError("Real lecture clip failed") }
            print("PASS: real lecture clip decodes (not played), \(actualPlayer.duration) seconds")
        }
        print("PASS: selected second audio verified at 440 Hz, 1.333-second window, literal paths, unchanged MKV, playable WAV, timeout and cancellation. No model requests.")
    }
}
