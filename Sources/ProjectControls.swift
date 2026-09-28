import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum ProjectSavePanelName {
    /// NSSavePanel applies its allowed type's extension itself. Seed only the stem,
    /// after setting allowedContentTypes, including when reopening Save As.
    static func seed(currentPath: String?, language: UILanguage = L10n.currentLanguage,
                     localizedDefaultName: (UILanguage) -> String = { L10n.string("project.default_name", language: $0) }) -> String {
        let defaultName = localizedDefaultName(language)
        var name = currentPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? defaultName
        let suffix = "." + ProjectArchive.fileExtension
        while name.lowercased().hasSuffix(suffix) { name.removeLast(suffix.count) }
        return name.isEmpty ? defaultName : name
    }
}

extension TranslatorModel {
    // The backup references the retained journals; no input, output or paid result is deleted.
    func backupQueue() throws {
        guard !state.jobs.isEmpty else { return }
        let directory = store.root.appendingPathComponent("queue-backups", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var snapshot = state
        snapshot.manuallyPaused = true; snapshot.translationPending = false; snapshot.resumeAt = nil
        try JSONEncoder().encode(snapshot).write(to: directory.appendingPathComponent("\(UUID().uuidString).json"), options: .withoutOverwriting)
    }

    func clearQueue() throws {
        guard writable, !busy else { throw TranslatorError.invalid(L10n.current("project.wait_for_pause_unchanged")) }
        try backupQueue()
        var empty = state
        empty.jobs = []; empty.manuallyPaused = true; empty.translationPending = false; empty.resumeAt = nil
        empty.projectFilePath = nil // A new empty queue must not overwrite the previous saved project.
        try store.save(empty) // Publish before changing the visible state.
        cancelAutomaticResume()
        state = empty; selection = nil; lecture = nil; journal = nil
        banner = L10n.current("project.banner_cleared")
    }

    func confirmClearQueue() {
        guard !busy, !closing, !state.jobs.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = L10n.current("project.clear_title")
        alert.informativeText = L10n.currentFormat("project.clear_body", state.jobs.count)
        alert.addButton(withTitle: L10n.current("project.cancel"))
        alert.addButton(withTitle: L10n.current("project.clear"))
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do { try clearQueue() } catch { self.error = L10n.errorPresentation(error) }
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.title = L10n.current("project.output_title")
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.settings.customOutputDirectory = url.path; state.settings.outputLocation = "custom"; save()
    }

    @discardableResult func saveProject(asNew: Bool = false) -> Bool {
        guard writable, !busy else { error = L10n.current("project.pause_before_save"); return false }
        do {
            let destination: URL
            if !asNew, let currentPath = state.projectFilePath {
                destination = URL(fileURLWithPath: currentPath)
            } else {
                let panel = NSSavePanel()
                panel.title = asNew ? L10n.current("project.save_as_title") : L10n.current("project.save_title")
                let current = state.projectFilePath.map { URL(fileURLWithPath: $0) }
                panel.directoryURL = current?.deletingLastPathComponent()
                panel.allowedContentTypes = [UTType(filenameExtension: "lectureproject") ?? .data]
                panel.nameFieldStringValue = ProjectSavePanelName.seed(currentPath: state.projectFilePath)
                panel.message = L10n.current("project.panel_message")
                guard panel.runModal() == .OK, let selected = panel.url else { return false }
                destination = try ProjectArchive.normalizedDestination(selected)
            }
            let existing = try FilePublication.inspect(destination, protectedSources: ProjectArchive.protectedSources(in: state))
            if let existing {
                let alert = NSAlert()
                alert.messageText = L10n.current("project.update_title")
                alert.informativeText = L10n.currentFormat("project.update_body", existing.url.path)
                alert.addButton(withTitle: L10n.current("project.cancel"))
                alert.addButton(withTitle: L10n.current("project.save_backup"))
                guard alert.runModal() == .alertSecondButtonReturn else { return false }
            }
            let backup = try saveProject(to: destination, replacing: existing)
            banner = L10n.currentFormat("project.saved_path", destination.lastPathComponent)
            if let backup { banner += "\n" + L10n.currentFormat("project.previous_version", backup.path) }
            return true
        } catch { self.error = L10n.errorPresentation(error); return false }
    }

    /// Non-UI transaction used after an explicit save decision. Publishing the project
    /// never writes paid journals. Remember its actual location only after publication.
    @discardableResult
    func saveProject(to destination: URL, replacing: FilePublication.Existing? = nil) throws -> URL? {
        guard writable, !busy else { throw TranslatorError.invalid(L10n.current("project.wait_for_pause_not_saved")) }
        let backup = try ProjectArchive.save(state: state, store: store, to: destination, replacing: replacing)
        state.projectFilePath = destination.standardizedFileURL.path
        do { try store.save(state) }
        catch {
            // Do not misleadingly report that the successfully published project failed.
            // Its path remains known in this window; the next run may need Open Project.
            self.error = L10n.currentFormat("project.saved_path_warning", destination.path, error.localizedDescription)
        }
        return backup
    }

    func importProject(from url: URL) throws {
        guard writable, !busy else { throw TranslatorError.invalid(L10n.current("project.wait_for_pause")) }
        // Validate and stage under new IDs; the current queue survives any failed import.
        let imported = try ProjectArchive.open(from: url, into: store)
        do { try backupQueue(); try store.save(imported.state) }
        catch { imported.rollback(); throw error }
        cancelAutomaticResume()
        state = imported.state; selection = state.jobs.first?.id; loadSelection()
        banner = L10n.current("project.banner_opened")
        if !imported.warnings.isEmpty { banner += "\n" + imported.warnings.joined(separator: "\n") }
    }

    func openProject() {
        guard !busy, !closing else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.current("project.open_title")
        panel.allowedContentTypes = [UTType(filenameExtension: "lectureproject") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !state.jobs.isEmpty {
            let alert = NSAlert()
            alert.messageText = L10n.current("project.replace_queue_title")
            alert.informativeText = L10n.current("project.replace_queue_body")
            alert.addButton(withTitle: L10n.current("project.cancel"))
            alert.addButton(withTitle: L10n.current("project.open"))
            alert.addButton(withTitle: L10n.current("project.save_current_open"))
            let choice = alert.runModal()
            if choice == .alertFirstButtonReturn { return }
            if choice == .alertThirdButtonReturn && !saveProject() { return }
        }
        do { try importProject(from: url) } catch { self.error = L10n.errorPresentation(error) }
    }

    func requestClose() async -> Bool {
        guard !closing else { return false }
        guard writable else { return true } // Do not overwrite an unreadable queue on exit.
        guard !state.jobs.isEmpty || busy else { return true }
        let alert = NSAlert()
        alert.messageText = L10n.current("project.close_title")
        alert.informativeText = L10n.current("project.close_body")
        alert.addButton(withTitle: L10n.current("project.keep_close"))
        alert.addButton(withTitle: L10n.current("project.save_close"))
        alert.addButton(withTitle: L10n.current("project.clear_close"))
        alert.addButton(withTitle: L10n.current("project.cancel")).keyEquivalent = "\u{1b}"
        let choice = alert.runModal()
        guard choice != NSApplication.ModalResponse(rawValue: 1003) else { return false }
        closing = true
        defer { closing = false }
        pause(immediately: false)
        while busy { try? await Task.sleep(nanoseconds: 100_000_000) }
        if choice == .alertSecondButtonReturn && !saveProject() { return false }
        do {
            if choice == .alertThirdButtonReturn { try clearQueue() }
            else { try store.save(state) }
            return true
        } catch { self.error = L10n.errorPresentation(error); return false }
    }
}

@MainActor
final class TranslatorAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    weak var model: TranslatorModel?
    private var awaitingClose = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let session = TranslatorApplicationSession.model
        model = session
        // SwiftUI may build standard command menus after didFinishLaunching.
        // Update known headings once the menu tree exists; do not alter actions.
        let language = L10n.currentLanguage
        DispatchQueue.main.async { [weak self] in
            guard self != nil, let menu = NSApp.mainMenu else { return }
            for item in menu.items {
                guard let title = language.standardMenuTitle(for: item.title) else { continue }
                item.title = title
            }
        }
        // Do not rely on QueueAccessView.task: a second launch can have no
        // visible window, so that task may never start.
        if !session.writable {
            Task { await session.refreshQueueAccess(automaticallyFocus: true) }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // macOS can deny focus transfer from a background CLI launch. Retry only
        // when the user actually brings this copy forward, never steal focus on a timer.
        guard let model, !model.writable, model.queueAccessProblem == .inUse else { return }
        Task { await model.refreshQueueAccess(automaticallyFocus: true) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard !awaitingClose else { return .terminateCancel }
        awaitingClose = true
        Task {
            let approved = await model.requestClose()
            if approved { model.shutdown() }
            awaitingClose = false
            sender.reply(toApplicationShouldTerminate: approved)
        }
        return .terminateLater
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil) // Both the red close button and Cmd-Q use the same safe decision.
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        for window in sender.windows where window.identifier?.rawValue == "main" {
            window.deminiaturize(nil); window.makeKeyAndOrderFront(nil)
        }
        return true
    }
}

struct WindowCloseBridge: NSViewRepresentable {
    let delegate: TranslatorAppDelegate
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { view.window?.delegate = delegate }
    }
}
