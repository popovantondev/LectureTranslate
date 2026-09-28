import SwiftUI

@main
enum LayoutTests {
    static func main() {
        var passed = 0
        func check(_ condition: Bool, _ name: String) {
            guard condition else { fputs("FAIL: \(name)\n", stderr); exit(1) }
            passed += 1
        }
        check(DetailPaneMetrics.padding(width: 1200) == 24, "full layout uses 24-point insets")
        check(DetailPaneMetrics.padding(width: 700) == 12, "compact layout uses 12-point insets")
        check(DetailPaneMetrics.viewportHeight(totalHeight: 800) == 752, "both full-layout insets excluded from viewport")
        check(DetailPaneMetrics.viewportHeight(totalHeight: 660, padding: 12) == 636, "compact window retains balanced insets")
        check(DetailPaneMetrics.viewportHeight(totalHeight: 20) == 0, "small geometry cannot produce negative viewport")
        check(DetailPaneMetrics.viewportHeight(totalHeight: .infinity) == 0, "invalid geometry is bounded")
        check(DetailPaneMetrics.panelHeight(viewportHeight: 1000, measuredTopHeight: 384) == 600, "full-screen panel fills remaining height after measured controls")
        check(DetailPaneMetrics.panelHeight(viewportHeight: 612, measuredTopHeight: 384) == 300, "compact panel keeps usable height and lets outer view scroll")
        check(DetailPaneMetrics.panelHeight(viewportHeight: 1000, measuredTopHeight: 800) == 300, "long messages cause scrolling rather than zero-height table")
        check(DetailPaneMetrics.panelHeight(viewportHeight: 900, measuredTopHeight: 384) -
              DetailPaneMetrics.panelHeight(viewportHeight: 900, measuredTopHeight: 434) == 50, "extra settings row consumes its measured height")
        check(DetailPaneMetrics.panelHeight(viewportHeight: 0, measuredTopHeight: 100) == 300, "native tab panel always has a finite minimum")
        check(DetailPaneMetrics.panelHeight(viewportHeight: .nan, measuredTopHeight: .infinity) == 300, "invalid measurements cannot escape into native view sizes")
        check(DetailPaneMetrics.panelHeight(viewportHeight: 800, measuredTopHeight: -50) == 784, "negative measurement is clamped")
        print("PASS: \(passed) adaptive layout metric checks. No GUI, service or model requests.")
    }
}
