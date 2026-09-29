import SwiftUI
import AppKit
import AVKit
import UniformTypeIdentifiers

@MainActor
final class VideoPreviewSession: ObservableObject {
    @Published private(set) var source: URL?
    @Published private(set) var candidates: [URL] = []
    @Published private(set) var tracks: [VideoPreviewAudioTrack] = []
    @Published private(set) var selectedTrack = -1
    @Published private(set) var player: AVPlayer?
    @Published private(set) var busy = false
    @Published private(set) var ready = false
    @Published private(set) var message = L10n.current("media.choose_source")
    @Published private(set) var interval = ""
    @Published var repeatFragment = false

    // Offline tests replace inspection only; neither a window nor AVPlayer is needed.
    var inspectionOverride: ((URL, Bool) async throws -> VideoPreviewInspection)?
    private var inspection: VideoPreviewInspection?
    private var sourceSRT: URL?
    private var cue: Cue?
    private var onSelectVideo: ((URL) -> Void)?
    private var nativeAsset: AVURLAsset?
    private var operation: ListeningOperation?
    private var preparation: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var generation = UUID()
    private var playbackIntent = UUID()
    private var timeline: VideoPreviewTimeline?
    private var statusObserver: NSKeyValueObservation?
    private var boundaryObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var seeking = false
    private var manualTools: ListeningTools?
    var canPlay: Bool { !busy && inspection != nil && selectedTrack >= 0 }

    func configure(sourceSRT: URL, preferredVideo: URL?, cue: Cue, onSelectVideo: @escaping (URL) -> Void) {
        let sameSource = self.sourceSRT.map(VideoPreviewFiles.canonical) == VideoPreviewFiles.canonical(sourceSRT)
        let sameVideo = preferredVideo == nil || preferredVideo.map(VideoPreviewFiles.canonical) == source.map(VideoPreviewFiles.canonical)
        if sameSource && sameVideo && inspection != nil {
            invalidate(keepMedia: true); self.cue = cue; self.onSelectVideo = onSelectVideo
            updateInterval(); message = L10n.current("media.next_cue"); return
        }
        close()
        self.sourceSRT = sourceSRT; self.cue = cue; self.onSelectVideo = onSelectVideo
        candidates = VideoPreviewFiles.matching(sourceSRT)
        if let preferredVideo {
            do { try ListeningOperation.validateSource(preferredVideo); select(preferredVideo) }
            catch { message = L10n.current("media.saved_unavailable") }
        } else if candidates.count == 1 { select(candidates[0]) }
        else { message = candidates.isEmpty ? L10n.current("media.not_found") : L10n.current("media.multiple_found") }
    }

    func select(_ url: URL, forceFallback: Bool = false) {
        invalidate(keepMedia: false); source = url
        do { try ListeningOperation.validateSource(url) }
        catch { message = L10n.errorPresentation(error); return }
        let ticket = generation; busy = true; message = L10n.current("media.reading_video")
        scheduleDeadline(30, ticket: ticket, message: L10n.current("media.read_timeout"))
        preparation = Task { [weak self] in
            guard let self else { return }
            do {
                let result: VideoPreviewInspection
                if let override = inspectionOverride { result = try await override(url, forceFallback) }
                else { result = try await inspect(url, forceFallback: forceFallback) }
                guard generation == ticket, !Task.isCancelled else { return }
                inspection = result; tracks = result.audio
                selectedTrack = tracks.count == 1 ? tracks[0].id : -1
                busy = false; deadline?.cancel(); deadline = nil
                updateInterval()
                message = tracks.count == 1
                    ? L10n.current("media.one_track")
                    : L10n.current("media.choose_german_audio")
                onSelectVideo?(url)
            } catch {
                guard generation == ticket else { return }
                busy = false; deadline?.cancel(); deadline = nil; message = L10n.errorPresentation(error)
            }
        }
    }

    private func inspect(_ source: URL, forceFallback: Bool) async throws -> VideoPreviewInspection {
        if !forceFallback && VideoPreviewFiles.nativeCandidate(source) {
            let asset = NativeVideoPreview.asset(source); nativeAsset = asset
            do { return .native(try await NativeVideoPreview.inspect(asset)) }
            catch {
                try Task.checkCancellation()
                guard tools != nil else {
                    throw TranslatorError.invalid(L10n.current("media.native_codec"))
                }
            }
        }
        guard let tools else {
            throw TranslatorError.invalid(L10n.current("media.ffmpeg_required"))
        }
        let op = try ListeningOperation(); operation = op
        return .converted(try await Task.detached { try VideoPreviewConversion.inspect(source, tools: tools, operation: op) }.value)
    }

    private var tools: ListeningTools? { manualTools ?? ListeningTools.discover() }
    private func updateInterval() {
        guard let cue, let inspection, let range = try? ListeningRange(cue: cue, padding: 3, mediaDuration: inspection.duration) else { interval = ""; return }
        interval = L10n.currentFormat("media.interval", VideoPreviewFiles.time(range.start), VideoPreviewFiles.time(range.end), cue.id)
    }

    func selectAudio(_ id: Int) {
        invalidate(keepMedia: true)
        selectedTrack = tracks.contains(where: { $0.id == id }) ? id : -1
        message = selectedTrack >= 0 ? L10n.current("media.confirm_track") : L10n.current("media.choose_original_track")
    }

    func play() {
        guard canPlay else { return }
        if ready, player != nil { seekToStart(); return }
        guard let source, let cue, let inspection else { return }
        do {
            let range = try ListeningRange(cue: cue, padding: 3, mediaDuration: inspection.duration)
            let track = selectedTrack
            invalidate(keepMedia: true)
            let ticket = generation; busy = true; message = L10n.current("media.preparing_video")
            scheduleDeadline(100, ticket: ticket, message: L10n.current("media.prepare_timeout"))
            preparation = Task { [weak self] in
                guard let self else { return }
                do {
                    let item: AVPlayerItem, shortClip: Bool
                    switch inspection {
                    case .native(let media):
                        nativeAsset = media.asset
                        item = AVPlayerItem(asset: try await media.composition(audioID: track)); shortClip = false
                    case .converted(let media):
                        guard let tools else { throw TranslatorError.invalid(L10n.current("media.tools_missing")) }
                        let op = try ListeningOperation(); operation = op
                        message = L10n.current("media.preparing_short")
                        let output = try await Task.detached {
                            try VideoPreviewConversion.clip(source, media: media, audioIndex: track, cue: cue, tools: tools, operation: op)
                        }.value
                        item = AVPlayerItem(asset: NativeVideoPreview.asset(output.0)); shortClip = true
                    }
                    guard generation == ticket, !Task.isCancelled else { return }
                    install(item, timeline: .init(original: range, isShortClip: shortClip), ticket: ticket)
                } catch {
                    guard generation == ticket else { return }
                    busy = false; ready = false; deadline?.cancel(); deadline = nil
                    message = L10n.errorPresentation(error)
                }
            }
        } catch { message = L10n.errorPresentation(error) }
    }

    private func install(_ item: AVPlayerItem, timeline: VideoPreviewTimeline, ticket: UUID) {
        self.timeline = timeline
        let playback = AVPlayer(playerItem: item)
        playback.allowsExternalPlayback = false
        playback.appliesMediaSelectionCriteriaAutomatically = false
        playback.actionAtItemEnd = .pause
        player = playback
        statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self, weak item] _, _ in
            Task { @MainActor in
                guard let self, let item, self.generation == ticket, self.player?.currentItem === item else { return }
                switch item.status {
                case .readyToPlay:
                    guard !self.ready else { return }
                    self.ready = true; self.busy = false; self.deadline?.cancel(); self.deadline = nil
                    self.message = timeline.isShortClip ? L10n.current("media.short_ready") : L10n.current("media.original_ready")
                    self.seekToStart()
                case .failed:
                    self.busy = false; self.ready = false; self.deadline?.cancel(); self.deadline = nil
                    self.player?.pause()
                    self.message = L10n.currentFormat("media.play_failed", item.error?.localizedDescription ?? "") +
                        (timeline.isShortClip ? "" : " " + L10n.current("media.try_short_hint"))
                default: break
                }
            }
        }
        boundaryObserver = playback.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(seconds: timeline.playerEnd, preferredTimescale: 600))], queue: .main) { [weak self] in
            Task { @MainActor in if let self, self.generation == ticket { self.reachedEnd() } }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in if let self, self.generation == ticket { self.reachedEnd() } }
        }
    }

    private func reachedEnd() {
        player?.pause()
        if repeatFragment && selectedTrack >= 0 { seekToStart() }
    }

    private func seekToStart() {
        guard !seeking, selectedTrack >= 0, let player, let timeline else { return }
        let ticket = generation, intent = UUID(); playbackIntent = intent; seeking = true
        player.seek(to: CMTime(seconds: timeline.playerStart, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] finished in
            Task { @MainActor in
                guard let self, let player, self.generation == ticket, self.playbackIntent == intent, self.player === player else { return }
                self.seeking = false
                if finished && self.selectedTrack >= 0 { player.play() }
            }
        }
    }

    func stop() {
        if busy { invalidate(keepMedia: true); message = L10n.current("media.cancelled") }
        else { playbackIntent = UUID(); seeking = false; player?.currentItem?.cancelPendingSeeks(); player?.pause() }
    }

    private func scheduleDeadline(_ seconds: Double, ticket: UUID, message: String) {
        deadline?.cancel()
        deadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } catch { return }
            guard let self, self.generation == ticket else { return }
            self.invalidate(keepMedia: true); self.message = message
        }
    }

    private func invalidate(keepMedia: Bool) {
        generation = UUID(); playbackIntent = UUID(); preparation?.cancel(); preparation = nil; deadline?.cancel(); deadline = nil
        operation?.cancel(); nativeAsset?.cancelLoading(); nativeAsset = nil
        player?.pause(); statusObserver?.invalidate(); statusObserver = nil
        if let boundaryObserver { player?.removeTimeObserver(boundaryObserver) }; boundaryObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }; endObserver = nil
        player?.replaceCurrentItem(with: nil); player = nil
        operation = nil // Its private files are removed only after a cancelled worker releases it.
        ready = false; busy = false; seeking = false; timeline = nil
        if !keepMedia { inspection = nil; tracks = []; selectedTrack = -1 }
    }

    func close() {
        invalidate(keepMedia: false); source = nil; sourceSRT = nil; cue = nil; onSelectVideo = nil
        candidates = []; interval = ""
    }

    func chooseVideo() {
        let panel = NSOpenPanel(); panel.title = L10n.current("media.pick_video"); panel.allowsMultipleSelection = false
        panel.allowedContentTypes = VideoPreviewFiles.extensions.sorted().compactMap { UTType(filenameExtension: $0) }
        panel.directoryURL = source?.deletingLastPathComponent() ?? sourceSRT?.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url { select(url) }
    }

    func chooseTools() {
        let panel = NSOpenPanel(); panel.title = L10n.current("media.tools_folder")
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            guard let found = ListeningTools.inDirectory(url) else { message = L10n.current("media.tools_not_found"); return }
            manualTools = found
            if let source { select(source, forceFallback: true) }
        }
    }

    func forceShortPreview() { if let source { select(source, forceFallback: true) } }
}

private struct OriginalVideoPlayerView: NSViewRepresentable {
    let player: AVPlayer?
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView(); view.controlsStyle = .inline
        view.showsSharingServiceButton = false; view.showsFullScreenToggleButton = false
        view.allowsPictureInPicturePlayback = false; view.allowsVideoFrameAnalysis = false
        view.videoGravity = .resizeAspect; return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { if view.player !== player { view.player = player } }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player?.pause(); view.player = nil }
}

private struct VideoPreviewView: View {
    @ObservedObject var session: VideoPreviewSession
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(session.source?.lastPathComponent ?? L10n.current("media.source_video")).font(.headline).lineLimit(1).help(session.source?.path ?? "")
                Spacer(); Button(L10n.current("media.select_video")) { session.chooseVideo() }
            }
            if session.candidates.count > 1 {
                Menu(L10n.current("media.found_videos")) { ForEach(session.candidates, id: \.path) { url in Button(url.lastPathComponent) { session.select(url) } } }
            }
            ZStack {
                Color.black
                OriginalVideoPlayerView(player: session.player)
                if session.player == nil { Text(session.busy ? L10n.current("media.preparing_video") : L10n.current("media.choose_track_play")).foregroundStyle(.white.opacity(0.8)).padding() }
            }.frame(minHeight: 210, maxHeight: .infinity).clipShape(RoundedRectangle(cornerRadius: 8))
            if !session.tracks.isEmpty {
                Picker(L10n.current("media.audio"), selection: Binding(get: { session.selectedTrack }, set: { session.selectAudio($0) })) {
                    Text(L10n.current("media.choose_german_track")).tag(-1)
                    ForEach(session.tracks) { Text($0.label).tag($0.id) }
                }.disabled(session.busy)
            }
            HStack {
                Button(session.ready ? L10n.current("media.repeat_clip") : L10n.current("media.play_clip"), systemImage: "play.fill") { session.play() }.disabled(!session.canPlay)
                Button(session.busy ? L10n.current("media.cancel_prepare") : L10n.current("common.stop")) { session.stop() }.disabled(!session.busy && session.player == nil)
                Spacer(); Toggle(L10n.current("media.repeat"), isOn: $session.repeatFragment).toggleStyle(.checkbox)
            }
            if !session.interval.isEmpty { Text(session.interval).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            Text(session.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L10n.current("media.short_clip")) { session.forceShortPreview() }.disabled(session.source == nil || session.busy)
                    .help(L10n.current("media.short_clip_help"))
                Spacer(); Button(L10n.current("media.ffmpeg")) { session.chooseTools() }.disabled(session.busy)
            }.font(.caption)
        }.padding(14).frame(minWidth: 500, minHeight: 470).tint(TranslatorTheme.accent)
    }
}

@MainActor
final class VideoPreviewWindowController: NSObject, NSWindowDelegate {
    private static let shared = VideoPreviewWindowController()
    private let session = VideoPreviewSession()
    private var previewWindow: NSWindow?
    private var parentObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?

    static func show(sourceSRT: URL, preferredVideo: URL?, cue: Cue, onSelectVideo: @escaping (URL) -> Void) {
        shared.present(sourceSRT: sourceSRT, preferredVideo: preferredVideo, cue: cue, onSelectVideo: onSelectVideo)
    }
    static func closeIfOpen() { shared.previewWindow?.close(); shared.session.close() }

    private func present(sourceSRT: URL, preferredVideo: URL?, cue: Cue, onSelectVideo: @escaping (URL) -> Void) {
        let parent = NSApp.keyWindow === previewWindow ? previewWindow?.parent : NSApp.keyWindow ?? NSApp.mainWindow
        if previewWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 580), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = L10n.current("media.window_title"); window.isReleasedWhenClosed = false; window.delegate = self
            window.contentMinSize = NSSize(width: 528, height: 500); window.collectionBehavior = [.fullScreenAuxiliary]
            window.contentView = NSHostingView(rootView: VideoPreviewView(session: session)); previewWindow = window
            terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.session.close() }
            }
        }
        guard let window = previewWindow else { return }
        if let parent, parent !== window, window.parent !== parent {
            window.parent?.removeChildWindow(window); parent.addChildWindow(window, ordered: .above)
            if let parentObserver { NotificationCenter.default.removeObserver(parentObserver) }
            parentObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: parent, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.previewWindow?.close() }
            }
        }
        if !window.isVisible {
            if let parent { window.setFrameOrigin(NSPoint(x: parent.frame.midX - window.frame.width / 2, y: parent.frame.midY - window.frame.height / 2)) }
            else { window.center() }
        }
        session.configure(sourceSRT: sourceSRT, preferredVideo: preferredVideo, cue: cue, onSelectVideo: onSelectVideo)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        session.close(); if let window = previewWindow { window.parent?.removeChildWindow(window) }
        if let parentObserver { NotificationCenter.default.removeObserver(parentObserver) }; parentObserver = nil
    }
}
