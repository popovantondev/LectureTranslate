#!/bin/bash
set -euo pipefail
root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$root"
scratch="$(mktemp -d /tmp/lecture-translate-ui-perf.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT
cat > "$scratch/Bench.swift" <<'SWIFT'
import AppKit
import Foundation

struct Row: Codable { let id: Int; let title: String; let status: String }
final class Rows: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let rows = (0..<1000).map { Row(id: $0, title: String(format: "Synthetic lecture %04d · German source and Russian result", $0), status: $0.isMultiple(of: 3) ? "Ready" : "Queued") }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: rows[row].title + " · " + rows[row].status)
        label.lineBreakMode = .byTruncatingTail
        cell.addSubview(label); label.frame = NSRect(x: 6, y: 2, width: 340, height: 18)
        return cell
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let data = Rows()
let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 1100, height: 760), styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
window.title = "Synthetic UI performance · 1000 rows · 50 fake workers"
let split = NSSplitView(frame: window.contentView!.bounds); split.isVertical = true; split.autoresizingMask = [.width, .height]
let sidebar = NSView(frame: NSRect(x: 0, y: 0, width: 330, height: 760))
let scroll = NSScrollView(frame: sidebar.bounds); scroll.hasVerticalScroller = true; scroll.autoresizingMask = [.width, .height]
let table = NSTableView(frame: scroll.bounds); let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("rows")); column.width = 320; table.addTableColumn(column); table.rowHeight = 24; table.dataSource = data; table.delegate = data
scroll.documentView = table; sidebar.addSubview(scroll)
let detail = NSTextField(wrappingLabelWithString: "Synthetic detail panel · scrolling / resizing / sidebar / theme / minimize")
detail.frame = NSRect(x: 24, y: 350, width: 600, height: 60)
let panel = NSView(frame: NSRect(x: 330, y: 0, width: 770, height: 760)); panel.addSubview(detail)
split.addSubview(sidebar); split.addSubview(panel); window.contentView = split
window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
let start = DispatchTime.now().uptimeNanoseconds
var previousTick = start
var latency: [Double] = []; var saves: [Double] = []; var workerCompletions = 0
let timer = Timer(timeInterval: 0.02, repeats: true) { _ in
    let now = DispatchTime.now().uptimeNanoseconds
    latency.append(max(0, Double(now - previousTick) / 1e6 - 20))
    previousTick = now
}
RunLoop.main.add(timer, forMode: .common)
let group = DispatchGroup()
for worker in 0..<50 {
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        for item in 0..<20 {
            let payload = "fake-result-\(worker)-\(item)"
            DispatchQueue.main.async { _ = payload; workerCompletions += 1; table.reloadData() }
            Thread.sleep(forTimeInterval: 0.004)
        }
        group.leave()
    }
}
for cycle in 0..<60 {
    let fraction = CGFloat(cycle % 20) / 19
    scroll.contentView.scroll(to: NSPoint(x: 0, y: fraction * max(0, table.frame.height - scroll.contentView.bounds.height)))
    scroll.reflectScrolledClipView(scroll.contentView)
    window.setContentSize(NSSize(width: 900 + CGFloat(cycle % 8) * 40, height: 620 + CGFloat(cycle % 6) * 20))
    sidebar.isHidden = cycle % 10 == 0
    window.appearance = cycle % 2 == 0 ? NSAppearance(named: .aqua) : NSAppearance(named: .darkAqua)
    if cycle % 15 == 0 { window.miniaturize(nil); window.deminiaturize(nil) }
    let rows = data.rows
    let t = DispatchTime.now().uptimeNanoseconds
    let encoded = try JSONEncoder().encode(rows)
    try encoded.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
    saves.append(Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6)
    if cycle % 3 == 0 { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.025)) }
}
_ = group.wait(timeout: .now() + 10)
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15)); timer.invalidate(); window.close()
func p95(_ values: [Double]) -> Double { let sorted = values.sorted(); return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)] }
var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
let memoryMB = Double(usage.ru_maxrss) / 1_048_576
let cpuSeconds = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
let wallSeconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
print(String(format: "main_runloop_lag_p95_ms=%.2f save_p95_ms=%.2f cpu_percent=%.1f memory_peak_mb=%.2f rows=1000 fake_workers=50 worker_updates=%d", p95(latency), p95(saves), 100 * cpuSeconds / max(0.001, wallSeconds), memoryMB, workerCompletions))
SWIFT
mkdir -p .build/ModuleCache-v06
xcrun swiftc -swift-version 5 -module-cache-path .build/ModuleCache-v06 "$scratch/Bench.swift" -o "$scratch/Bench"
for run in 1 2 3; do echo "run=$run"; "$scratch/Bench" "$scratch/save.json"; done
