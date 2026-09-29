import AppKit
import SwiftUI

enum QueueAccessProblem: Equatable {
    case inUse
    case unreadable(String)
}

/// A duplicate macOS launch may not construct its SwiftUI Window at all. The
/// AppKit delegate still needs the very same model to find the existing owner.
@MainActor enum TranslatorApplicationSession {
    static let model = TranslatorModel()
}

enum TranslatorRuntime {
    static var isDemoBuild: Bool {
        #if TRANSLATOR_DEMO
        true
        #else
        false
        #endif
    }

    static func traceStartup(_ message: String) {
        guard ProcessInfo.processInfo.environment["LECTURE_TRANSLATOR_STARTUP_TRACE"] == "1" else { return }
        FileHandle.standardError.write(Data("[startup] \(message)\n".utf8))
    }

    static func stateDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        previewDirectoryName: String? = Bundle.main.object(forInfoDictionaryKey: "LectureTranslatorPreviewStateDirectoryName") as? String,
        demoStateDirectory: String? = Bundle.main.object(forInfoDictionaryKey: "LectureTranslatorDemoStateDirectory") as? String,
        applicationSupport: URL? = nil
    ) -> URL {
        let root: URL
        if isDemoBuild {
            // GUI acceptance can opt into a disposable demo fixture, but the
            // override is accepted only inside this checkout's .build package.
            // A demo binary can never be redirected to production/user state.
            let requestedDemoState = environment["LECTURE_TRANSLATOR_STATE_DIR"] ?? demoStateDirectory
            if let candidate = requestedDemoState, Self.isDisposableDemoState(URL(fileURLWithPath: candidate)) {
                root = URL(fileURLWithPath: candidate).standardizedFileURL.resolvingSymlinksInPath()
            } else {
                root = (applicationSupport ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
                    .appendingPathComponent("LectureTranslator2-Demo", isDirectory: true)
            }
        } else if let path = environment["LECTURE_TRANSLATOR_STATE_DIR"], !path.isEmpty {
            root = URL(fileURLWithPath: path)
        } else if let name = previewDirectoryName, !name.isEmpty,
                  !name.contains("/"), name != ".", name != ".." {
            // The bundle carries only a stable child name, never its temporary build path.
            // This survives Finder relaunches and moving the .app bundle.
            root = (applicationSupport ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
                .appendingPathComponent(name, isDirectory: true)
        } else {
            root = (applicationSupport ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
                .appendingPathComponent("LectureTranslator2")
        }
        return root.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func isDisposableDemoState(_ candidate: URL) -> Bool {
        guard candidate.path.hasPrefix("/") else { return false }
        let url = candidate.standardizedFileURL.resolvingSymlinksInPath()
        let package = url.deletingLastPathComponent().resolvingSymlinksInPath()
        let build = package.deletingLastPathComponent().resolvingSymlinksInPath()
        return url.lastPathComponent == "demo-state" && package.lastPathComponent.hasPrefix("package.") && build.lastPathComponent == ".build"
    }
}

struct ExistingTranslator: Identifiable, Equatable {
    let id: Int32
    let bundleURL: URL
    let version: String
    let launchDate: Date?

    static func recognizesBundleIdentifier(_ identifier: String) -> Bool {
        identifier == "local.lecturetranslator.v2" ||
            identifier == "local.lecturetranslator.v2.preview" ||
            identifier.hasPrefix("local.lecturetranslator.v2.preview.")
    }

    @MainActor static func verified(processID: Int32) -> ExistingTranslator? {
        guard processID != ProcessInfo.processInfo.processIdentifier,
              let app = NSRunningApplication(processIdentifier: processID), !app.isTerminated,
              let identifier = app.bundleIdentifier,
              recognizesBundleIdentifier(identifier),
              app.executableURL?.lastPathComponent == "LectureTranslator",
              let url = app.bundleURL else { return nil }
        let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
        return ExistingTranslator(id: processID, bundleURL: canonicalURL,
            version: Bundle(url: canonicalURL)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? L10n.current("startup.version_unknown"),
            launchDate: app.launchDate)
    }
}

extension TranslatorModel {
    /// Acquire before reading, and publish the loaded state only after a successful
    /// read. Neither failure path writes a replacement queue or removes queue.lock.
    @discardableResult func retryOpeningQueue() -> Bool {
        guard !writable, !busy, !closing else { return writable }
        do {
            let acquired = try TranslationStateLock(root: store.root)
            let restored = try store.load()
            stateLock = acquired
            state = restored; selection = restored.jobs.first?.id
            loadSelection()
            error = nil; queueAccessProblem = nil; otherInstance = nil; startupDetail = ""
            banner = restored.manuallyPaused
                ? L10n.current("project.banner_paused")
                : L10n.current("project.banner_restored")
            writable = true
            loadRuntimePreferences()
            return true
        } catch TranslationStateLockError.busy {
            queueAccessProblem = .inUse
        } catch {
            stateLock = nil
            queueAccessProblem = .unreadable(L10n.errorPresentation(error))
            otherInstance = nil
        }
        return false
    }

    func refreshQueueAccess(automaticallyFocus: Bool = false) async {
        TranslatorRuntime.traceStartup("lookup entered; writable=\(writable), running=\(locatingOwner), auto=\(automaticallyFocus)")
        guard !writable, !locatingOwner else { return }
        locatingOwner = true
        defer { locatingOwner = false }
        if retryOpeningQueue() { return }
        guard queueAccessProblem == .inUse else { return }
        let root = store.root
        do {
            let pids = try await Task.detached { try TranslationStateLock.ownerProcessIDs(root: root) }.value
            TranslatorRuntime.traceStartup("lookup finished; candidates=\(pids.count), cancelled=\(Task.isCancelled)")
            guard !Task.isCancelled, !writable else { return }
            // The owner may have exited while lsof ran. The lock, not a PID, decides.
            if retryOpeningQueue() { return }
            guard queueAccessProblem == .inUse else { return }
            let candidates = pids.compactMap { ExistingTranslator.verified(processID: $0) }
            guard candidates.count == 1 else {
                otherInstance = nil
                startupDetail = L10n.current("startup.ambiguous")
                return
            }
            otherInstance = candidates[0]; startupDetail = ""
            let sameBundle = candidates[0].bundleURL == Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
            let sameVersion = candidates[0].version == Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            TranslatorRuntime.traceStartup("owner verified; sameBundle=\(sameBundle), sameVersion=\(sameVersion)")
            // A new release must not silently hand the user back to an older version.
            if automaticallyFocus && sameBundle && sameVersion { showExistingInstance() }
        } catch {
            otherInstance = nil
            startupDetail = L10n.current("startup.lookup_failed")
        }
    }

    func showExistingInstance() {
        guard !writable, let owner = otherInstance,
              ExistingTranslator.verified(processID: owner.id) == owner,
              let app = NSRunningApplication(processIdentifier: owner.id) else {
            otherInstance = nil; startupDetail = L10n.current("startup.owner_closed"); return
        }
        app.unhide()
        NSApp.yieldActivation(to: app)
        let allowed = app.activate(from: .current, options: [.activateAllWindows])
        TranslatorRuntime.traceStartup("activation allowed=\(allowed)")
        if allowed {
            // Only this read-only duplicate closes; no signal is sent to the owner.
            NSApp.terminate(nil)
        } else {
            startupDetail = L10n.current("startup.activation_denied")
        }
    }
}

struct QueueAccessView: View {
    @ObservedObject var model: TranslatorModel
    private var inUse: Bool { model.queueAccessProblem == .inUse }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 18) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().scaledToFit().frame(width: 80, height: 80)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(inUse ? L10n.current("startup.busy_title") : L10n.current("startup.error_title")).font(.title2.bold())
                        Text(L10n.current("startup.safe")).foregroundStyle(.secondary)
                    }
                }
                if inUse {
                    Text(L10n.current("startup.in_use"))
                    if let owner = model.otherInstance {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L10n.currentFormat("startup.owner_version", owner.version)).font(.headline)
                            Text(owner.bundleURL.path).font(.caption).textSelection(.enabled).foregroundStyle(.secondary)
                        }
                    }
                    Text(L10n.current("startup.instructions"))
                } else if case .unreadable(let reason) = model.queueAccessProblem {
                    Text(L10n.current("startup.safe_unreadable"))
                    Text(reason).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if !model.startupDetail.isEmpty { Text(model.startupDetail).foregroundStyle(.secondary) }
                HStack {
                    if model.otherInstance != nil {
                        Button(L10n.current("startup.show")) { model.showExistingInstance() }.buttonStyle(.borderedProminent)
                    }
                    Button(L10n.current("startup.retry")) { Task { await model.refreshQueueAccess() } }.disabled(model.locatingOwner)
                    if model.locatingOwner { ProgressView().controlSize(.small) }
                    Spacer()
                    Button(L10n.current("startup.close")) { NSApp.terminate(nil) }
                }
            }
            .padding(28).frame(maxWidth: 760, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 18))
            .padding(32).frame(maxWidth: .infinity, minHeight: 420)
        }
        .tint(TranslatorTheme.accent).frame(minWidth: 780, minHeight: 460)
        .task { await model.refreshQueueAccess(automaticallyFocus: true) }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            guard inUse, !model.writable else { return }
            Task { await model.refreshQueueAccess() }
        }
    }
}
