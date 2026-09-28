import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

@MainActor
final class ListeningController: ObservableObject {
    @Published var source: URL?
    @Published var candidates: [String] = []
    @Published var media: ListeningMedia?
    @Published var track = -1
    @Published var padding = 3
    @Published var busy = false
    @Published var message = ""
    @Published var ready = false
    private var player: AVAudioPlayer?
    private var operation: ListeningOperation?
    private var generation = UUID()
    private var srt: URL?

    func configure(srt: URL) {
        self.srt = srt
        candidates = PreparedLecture.matchingVideos(srt)
        let saved = UserDefaults.standard.dictionary(forKey: "listeningVideoBindings") as? [String: String] ?? [:]
        if let path = saved[srt.path], FileManager.default.isReadableFile(atPath: path) { select(URL(fileURLWithPath: path)) }
        else if candidates.count == 1 { select(URL(fileURLWithPath: candidates[0])) }
        else { message = candidates.isEmpty ? L10n.current("listen.none_nearby") : L10n.current("listen.multiple") }
    }
    func stop() { player?.stop() }
    func close() { generation = UUID(); operation?.cancel(); operation = nil; player?.stop(); player = nil; ready = false; busy = false }
    func invalidateClip() { player?.stop(); player = nil; ready = false }
    func select(_ url: URL) {
        close(); source = url; media = nil; track = -1
        guard let tools = ListeningTools.discover() else { message = L10n.current("listen.need_tools"); return }
        do {
            let op = try ListeningOperation(); operation = op
            let ticket = generation; busy = true; message = L10n.current("listen.reading")
            Task {
                do {
                    let result = try await Task.detached { try op.inspect(url, tools: tools) }.value
                    guard generation == ticket else { return }
                    media = result; track = result.onlyTrack ?? -1; busy = false
                    message = result.streams.count > 1 ? L10n.current("listen.choose_german") : L10n.current("listen.one_track")
                    if let srt {
                        var bindings = UserDefaults.standard.dictionary(forKey: "listeningVideoBindings") as? [String: String] ?? [:]
                        bindings[srt.path] = url.path; UserDefaults.standard.set(bindings, forKey: "listeningVideoBindings")
                    }
                } catch { if generation == ticket { busy = false; message = L10n.errorPresentation(error) } }
            }
        } catch { message = L10n.errorPresentation(error) }
    }
    func play(cue: Cue) {
        if let player, ready { player.currentTime = 0; player.play(); return }
        guard let source, let media, let duration = media.duration, media.streams.contains(where: { $0.index == track }), let tools = ListeningTools.discover() else { return }
        do {
            let range = try ListeningRange(cue: cue, padding: padding, mediaDuration: duration)
            let op = try ListeningOperation(); operation?.cancel(); operation = op
            let ticket = UUID(); generation = ticket; busy = true; message = L10n.current("listen.preparing_clip")
            let chosenTrack = track
            Task {
                do {
                    let output = try await Task.detached { try op.clip(source, tools: tools, track: chosenTrack, range: range) }.value
                    guard generation == ticket else { return }
                    let audio = try AVAudioPlayer(contentsOf: output)
                    guard audio.duration > 0, audio.prepareToPlay() else { throw TranslatorError.invalid(L10n.current("listen.prepare_audio_failed")) }
                    player = audio; ready = true; busy = false
                    guard audio.play() else { throw TranslatorError.invalid(L10n.current("listen.play_audio_failed")) }
                    message = L10n.currentFormat("listen.clip_range", readableTime(Int(range.start * 1000)), readableTime(Int(range.end * 1000)))
                } catch { if generation == ticket { busy = false; ready = false; message = L10n.errorPresentation(error) } }
            }
        } catch { message = L10n.errorPresentation(error) }
    }
    func chooseVideo() {
        let panel = NSOpenPanel(); panel.title = L10n.current("media.choose_original"); panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["mp4", "mkv", "mov", "m4v"].compactMap { UTType(filenameExtension: $0) }
        panel.directoryURL = source?.deletingLastPathComponent() ?? srt?.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url { select(url) }
    }
    func chooseTools() {
        let panel = NSOpenPanel(); panel.title = L10n.current("media.tools_folder"); panel.canChooseFiles = false; panel.canChooseDirectories = true
        if panel.runModal() == .OK, let directory = panel.url {
            guard ListeningTools.inDirectory(directory) != nil else { message = L10n.current("media.tools_missing"); return }
            UserDefaults.standard.set(directory.path, forKey: "listeningToolsDirectory")
            if let source { select(source) }
        }
    }
}

struct ListeningView: View {
    let sourceSRT: URL
    let cue: Cue
    @StateObject private var listening = ListeningController()
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(L10n.current("listen.title"), systemImage: "waveform").font(.headline)
                Spacer()
                Button(L10n.current("media.video")) { listening.chooseVideo() }.disabled(listening.busy)
                Button(L10n.current("media.ffmpeg")) { listening.chooseTools() }.disabled(listening.busy).help(L10n.current("media.tools_help"))
            }
            if let source = listening.source { Text(source.lastPathComponent).font(.caption).lineLimit(1).help(source.path) }
            else if listening.candidates.count > 1 {
                Menu(L10n.current("media.found_videos")) {
                    ForEach(listening.candidates, id: \.self) { path in Button(URL(fileURLWithPath: path).lastPathComponent) { listening.select(URL(fileURLWithPath: path)) } }
                }
            }
            if let media = listening.media {
                HStack {
                    Picker(L10n.current("media.audio"), selection: $listening.track) {
                        Text(L10n.current("media.choose_track")).tag(-1)
                        ForEach(media.streams) { item in Text(item.label).tag(item.index) }
                    }.disabled(listening.busy)
                    Picker(L10n.current("listen.padding"), selection: $listening.padding) {
                        Text(L10n.current("listen.no_padding")).tag(0); Text(L10n.current("listen.padding_3")).tag(3); Text(L10n.current("listen.padding_8")).tag(8)
                    }.frame(width: 150).disabled(listening.busy)
                }
                HStack {
                    Button(listening.ready ? L10n.current("media.repeat_clip") : L10n.current("listen.play_clip"), systemImage: "play.fill") { listening.play(cue: cue) }.disabled(listening.busy || listening.track < 0)
                    Button(listening.busy ? L10n.current("media.cancel_prepare") : L10n.current("common.stop")) {
                        if listening.busy { listening.close() } else { listening.stop() }
                    }.disabled(!listening.busy && !listening.ready)
                }
            }
            Text(listening.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if listening.busy && listening.media == nil {
                Button(L10n.current("media.cancel_read")) { listening.close(); listening.message = L10n.current("listen.read_cancelled") }
            }
        }.padding(10).background(TranslatorTheme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .onAppear { listening.configure(srt: sourceSRT) }
            .onDisappear { listening.close() }
            .onChange(of: listening.track) { _, _ in listening.invalidateClip() }
            .onChange(of: listening.padding) { _, _ in listening.invalidateClip() }
    }
}
