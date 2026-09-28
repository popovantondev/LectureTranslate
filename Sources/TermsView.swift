import SwiftUI
import AppKit

struct TermsView: View {
    let store: CheckpointStore
    let profiles: [TranslationProfile]
    @Environment(\.dismiss) private var dismiss
    @State private var library = TermLibrary()
    @State private var selection: String?
    @State private var filter = "proposed"
    @State private var search = ""
    @State private var translatedTerm = ""
    @State private var germanTerm = ""
    @State private var checked = false
    @State private var error: String?
    @State private var writable = false
    private var selected: LibraryTerm? { library.entries.first { $0.id == selection } }
    private var entries: [LibraryTerm] {
        library.entries.filter { (filter == "all" || $0.status.rawValue == filter) &&
            (search.isEmpty || ($0.german + " " + $0.russian).localizedCaseInsensitiveContains(search)) }
            .sorted { $0.german.localizedStandardCompare($1.german) == .orderedAscending }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.current("terms.title")).font(.title2.bold())
                Spacer(); Button(L10n.current("common.close")) { dismiss() }
            }
            Text(L10n.current("terms.explanation")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Picker(L10n.current("terms.filter"), selection: $filter) {
                    Text(L10n.current("terms.proposed")).tag("proposed"); Text(L10n.current("terms.confirmed")).tag("confirmed"); Text(L10n.current("terms.deferred")).tag("deferred"); Text(L10n.current("common.all")).tag("all")
                }
                TextField(L10n.current("terms.search"), text: $search)
            }
            HSplitView {
                List(selection: $selection) {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading) {
                            Text(entry.german).fontWeight(.medium)
                            Text(entry.russian).foregroundStyle(.secondary)
                            Text(profiles.first { $0.id == entry.profileID }?.name ?? entry.profileID).font(.caption)
                        }.tag(entry.id)
                    }
                }.frame(minWidth: 230, idealWidth: 260)
                ScrollView {
                    if let term = selected {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(term.german).font(.title3.bold()).textSelection(.enabled)
                            Text(L10n.current("terms.german_label")).font(.caption)
                            TextField(L10n.current("terms.german"), text: $germanTerm).disabled(term.status == .confirmed)
                            Text(L10n.current("terms.russian_label")).font(.caption)
                            TextField(L10n.current("terms.russian"), text: $translatedTerm)
                                .disabled(term.status == .confirmed)
                            Text(L10n.current("terms.asr_help")).font(.caption).foregroundStyle(.secondary)
                            Text(L10n.current("terms.evidence_intro")).font(.caption).foregroundStyle(.secondary)
                            ForEach(Array(term.evidence.enumerated()), id: \.offset) { _, evidence in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(URL(fileURLWithPath: evidence.sourcePath).lastPathComponent + " · ID " + evidence.ids.map(String.init).joined(separator: ",")).font(.caption.bold())
                                    Text("DE: " + evidence.germanContext)
                                    Text("RU: " + evidence.russianContext)
                                    Text(evidence.reason).font(.caption).foregroundStyle(.secondary)
                                    Button(L10n.current("terms.show_source")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: evidence.sourcePath)]) }
                                }.textSelection(.enabled)
                                Divider()
                            }
                            if term.status == .confirmed {
                                Text(term.confirmedAt.map { L10n.currentFormat("terms.confirmed_at", $0.formatted(date: .abbreviated, time: .shortened)) } ?? L10n.current("terms.confirmed_by_user")).foregroundStyle(.green)
                                Button(L10n.current("terms.unconfirm")) { change { try $0.setStatus(id: term.id, status: .proposed) } }
                            } else {
                                Toggle(L10n.current("terms.checked"), isOn: $checked)
                                Button(L10n.current("terms.confirm")) { change { try $0.confirm(id: term.id, german: germanTerm, russian: translatedTerm, checked: checked) } }.disabled(!checked || translatedTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || germanTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                Button(term.status == .deferred ? L10n.current("terms.restore") : L10n.current("terms.defer")) { change { try $0.setStatus(id: term.id, status: term.status == .deferred ? .proposed : .deferred) } }
                            }
                        }.padding().disabled(!writable)
                    } else {
                        Text(L10n.current(entries.isEmpty ? "terms.empty" : "terms.select")).foregroundStyle(.secondary).padding()
                    }
                }.frame(minWidth: 380)
            }
            Text(L10n.currentFormat("terms.counts", library.entries.count, library.entries.filter { $0.status == .confirmed }.count)).font(.caption).foregroundStyle(.secondary)
        }.padding(22).frame(width: 860, height: min(730, (NSScreen.main?.visibleFrame.height ?? 900) - 90)).tint(TranslatorTheme.accent)
        .onAppear { do { library = try store.termLibrary(); writable = true } catch { self.error = L10n.errorPresentation(error) } }
        .onChange(of: selection) { _, _ in translatedTerm = selected?.russian ?? ""; germanTerm = selected?.german ?? ""; checked = false }
        .onChange(of: filter) { _, _ in selection = nil }
        .alert(L10n.current("terms.title"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button(L10n.current("common.ok")) { error = nil } } message: { Text(error ?? "") }
    }
    private func change(_ action: (inout TermLibrary) throws -> Void) {
        guard writable else { return }
        do {
            var fresh = try store.termLibrary(); try action(&fresh); try store.saveTerms(fresh)
            library = fresh; selection = nil; checked = false
        } catch { self.error = L10n.errorPresentation(error) }
    }
}

struct LectureMemoryView: View {
    let lecture: PreparedLecture
    let journal: TranslationJournal?
    var body: some View {
        List {
            Text(L10n.current("memory.disclaimer")).foregroundStyle(.secondary)
            if let journal, journal.memoryEnabled == true {
                if journal.reviewStrategy == ReviewPlanning.strategy {
                    Text(L10n.current("memory.workflow")).font(.caption).foregroundStyle(.secondary)
                }
                Text(L10n.currentFormat("memory.confirmed_count", journal.confirmedTerms?.count ?? 0))
                ForEach(lecture.parts) { part in
                    let notes = journal.partMetadata(part, lecture: lecture).notes
                    Section(L10n.currentFormat("memory.part_notes", part.id, notes.count)) {
                        ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(note.text)
                                Text("ID: " + note.ids.map(String.init).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                                Text("DE: " + lecture.document.cues.filter { note.ids.contains($0.id) }.map(\.text).joined(separator: " ")).font(.caption)
                            }
                        }
                    }
                }
            } else { Text(L10n.current("memory.legacy_notice")) }
        }.textSelection(.enabled)
    }
}
