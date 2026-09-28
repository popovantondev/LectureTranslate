import SwiftUI
import AppKit

extension TranslatorModel {
    var preferencesStore: RuntimePreferencesStore { RuntimePreferencesStore(root: store.root) }
    var chosenParallelism: Int {
        ConcurrencyPolicy.effectiveLimit(jobs: state.jobs.count, quota: quota, override: runtimePreferences.concurrencyOverride)
    }

    func loadRuntimePreferences() {
        guard writable else { return }
        do {
            runtimePreferences = try preferencesStore.load()
            if !FileManager.default.fileExists(atPath: preferencesStore.fileURL.path) {
                state.settings.maxReviewCallsPerLecture = 10
            }
            if !runtimePreferences.modelRoutingMigrationApplied {
                var upgraded = state
                if ModelRoutingMigration.apply(to: &upgraded) {
                    do {
                        if upgraded.settings != state.settings {
                            try store.save(upgraded)
                            state = upgraded
                            selection = state.jobs.first?.id
                            loadSelection()
                            banner = L10n.current("runtime.routing_updated")
                        }
                        var preferences = runtimePreferences
                        preferences.modelRoutingMigrationApplied = true
                        try preferencesStore.save(preferences, isMainOwner: writable && stateLock != nil)
                        runtimePreferences = preferences
                    } catch {
                        self.error = L10n.currentFormat("runtime.routing_save_error", error.localizedDescription)
                    }
                } else {
                    banner = L10n.current("runtime.routing_waiting")
                }
            }
            fastSession = FastSessionState(preferences: runtimePreferences)
        } catch {
            runtimePreferences = RuntimePreferences()
            fastSession = FastSessionState(preferences: RuntimePreferences())
            self.error = L10n.currentFormat("runtime.preferences_read_error", error.localizedDescription)
        }
    }

    @discardableResult func saveRuntimePreferences(includeQueue: Bool = true) -> Bool {
        guard writable else { return false }
        do {
            if includeQueue { try store.save(state) }
            try preferencesStore.save(runtimePreferences, isMainOwner: writable && stateLock != nil)
            return true
        } catch { self.error = L10n.currentFormat("runtime.preferences_save_error", error.localizedDescription); return false }
    }

    func setConcurrency(_ value: Int) {
        guard writable, !busy, !closing else { return }
        let previous = runtimePreferences
        runtimePreferences.concurrencyOverride = value == 0 ? nil : max(1, min(ConcurrencyPolicy.hardMaximum, value))
        if !saveRuntimePreferences(includeQueue: false) { runtimePreferences = previous }
    }

    /// The sheet holds a draft, never live bindings. Publish settings only after
    /// both files were saved; a failed queue write restores the previous prefs.
    @discardableResult func applyRuntimeSettings(_ proposed: RuntimePreferences, reserve: Double) -> Bool {
        guard writable, !busy, !closing, reserve.isFinite, (0...50).contains(reserve) else { return false }
        let previous = runtimePreferences
        var next = state
        next.settings.reserve = reserve
        do {
            try preferencesStore.save(proposed, isMainOwner: stateLock != nil)
            do { try store.save(next) }
            catch {
                let queueError = error.localizedDescription
                do { try preferencesStore.save(previous, isMainOwner: stateLock != nil) }
                catch {
                    self.error = L10n.currentFormat("runtime.rollback_error", queueError, error.localizedDescription)
                    return false
                }
                self.error = L10n.currentFormat("runtime.queue_save_error", queueError)
                return false
            }
            runtimePreferences = proposed
            state = next
            showRuntimeSettings = false
            return true
        } catch { self.error = L10n.currentFormat("runtime.settings_save_error", error.localizedDescription); return false }
    }

    func setFast(_ enabled: Bool) {
        guard writable, !busy, !closing, enabled != fastSession.isEnabled else { return }
        let previousPreferences = runtimePreferences, previousSession = fastSession
        if !enabled {
            fastSession.disable(preferences: &runtimePreferences)
            if !saveRuntimePreferences(includeQueue: false) {
                runtimePreferences = previousPreferences; fastSession = previousSession
                error = (error ?? "") + "\n" + L10n.current("runtime.fast_disable_error")
            }
            return
        }
        let warning = NSAlert()
        warning.alertStyle = .warning
        warning.messageText = L10n.current("runtime.fast_enable_title")
        warning.informativeText = L10n.current("runtime.fast_enable_body")
        warning.addButton(withTitle: L10n.current("common.cancel"))
        warning.addButton(withTitle: L10n.current("runtime.fast_enable"))
        guard warning.runModal() == .alertSecondButtonReturn else { return }
        let offerRemember = fastSession.confirmActivation(preferences: &runtimePreferences)
        if offerRemember {
            let remember = NSAlert()
            remember.messageText = L10n.current("runtime.fast_remember_title")
            remember.informativeText = L10n.current("runtime.fast_remember_body")
            remember.addButton(withTitle: L10n.current("runtime.fast_until_close"))
            remember.addButton(withTitle: L10n.current("runtime.fast_always"))
            fastSession.answerRemember(remember.runModal() == .alertSecondButtonReturn, preferences: &runtimePreferences)
        }
        if !saveRuntimePreferences(includeQueue: false) {
            runtimePreferences = previousPreferences; fastSession = previousSession
            error = (error ?? "") + "\n" + L10n.current("runtime.fast_enable_error")
        }
    }
}

struct ParallelRuntimePanel: View {
    @ObservedObject var model: TranslatorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 18) {
                Picker(L10n.current("queue.parallelism"), selection: Binding(get: { model.runtimePreferences.concurrencyOverride ?? 0 }, set: { model.setConcurrency($0) })) {
                    Text(model.chosenParallelism > 0 ? L10n.currentFormat("queue.auto_count", model.chosenParallelism) : L10n.current("queue.auto_quota")).tag(0)
                    ForEach(1...ConcurrencyPolicy.hardMaximum, id: \.self) { Text(L10n.currentFormat("queue.parallel_files", $0)).tag($0) }
                }.frame(maxWidth: 255)
        Toggle("Fast", isOn: Binding(get: { model.fastSession.isEnabled }, set: { model.setFast($0) }))
                    .toggleStyle(.switch).fixedSize()
                if model.fastSession.isEnabled {
                    Text(L10n.current(model.runtimePreferences.rememberFast ? "queue.fast_remembered" : "queue.fast_session"))
                        .font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                Button(L10n.current("settings.open"), systemImage: "gearshape") { model.showRuntimeSettings = true }
            }
            Text(runtimeExplanation)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var runtimeExplanation: String {
        if let override = model.runtimePreferences.concurrencyOverride {
            return L10n.currentFormat("queue.explanation.manual", min(ConcurrencyPolicy.hardMaximum, max(1, override)))
        }
        guard let quota = model.quota, quota.decision(reserve: 0) != .unknown else {
            return L10n.current("queue.explanation.unknown")
        }
        let limit = quota.isConfirmedPro ? ConcurrencyPolicy.hardMaximum : 15
        let tier = L10n.current(quota.isConfirmedPro ? "queue.tier.pro" : "queue.tier.plus_unknown")
        if model.state.jobs.isEmpty {
            return L10n.currentFormat("queue.explanation.auto_empty", tier, limit)
        }
        return L10n.currentFormat("queue.explanation.auto", tier, ConcurrencyPolicy.effectiveLimit(jobs: model.state.jobs.count, quota: quota, override: nil))
    }
}

struct ParallelProgressPanel: View {
    @ObservedObject var model: TranslatorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                ProgressView().controlSize(.small)
                Text(L10n.currentFormat("queue.parallel_progress", model.runRequestedParallelism, model.requestsInFlight.count, model.activePhases.count))
                    .font(.caption).monospacedDigit()
            }
            if let stop = model.parallelStop {
                Text(L10n.currentFormat("queue.pause_reason", stop.localizedDescription)).font(.caption).foregroundStyle(.orange)
            } else if model.reserveContinuationConfirmed {
                Text(L10n.current("queue.reserve_override_confirmed")).font(.caption).foregroundStyle(.orange)
            }
            ForEach(model.state.jobs.filter { model.activePhases[$0.id] != nil }) { job in
                HStack(alignment: .top) {
                    Text(job.title).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                    Text(model.activePhases[job.id] ?? "").foregroundStyle(.secondary)
                }.font(.caption)
            }
        }
    }
}
