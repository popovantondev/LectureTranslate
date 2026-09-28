import SwiftUI

enum DetailPaneMetrics {
    static let fullPadding: CGFloat = 24
    static let compactPadding: CGFloat = 12
    static let sectionSpacing: CGFloat = 16
    static let minimumPanelHeight: CGFloat = 300

    static func padding(width: CGFloat) -> CGFloat {
        width.isFinite && width < 900 ? compactPadding : fullPadding
    }

    static func viewportHeight(totalHeight: CGFloat, padding: CGFloat = fullPadding) -> CGFloat {
        guard totalHeight.isFinite else { return 0 }
        let inset = padding.isFinite ? max(0, padding) : fullPadding
        return max(0, totalHeight - 2 * inset)
    }

    static func panelHeight(viewportHeight: CGFloat, measuredTopHeight: CGFloat) -> CGFloat {
        let viewport = viewportHeight.isFinite ? max(0, viewportHeight) : 0
        let top = measuredTopHeight.isFinite ? max(0, measuredTopHeight) : 0
        return max(minimumPanelHeight, viewport - top - sectionSpacing)
    }
}

private struct DetailTopHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Keeps the same breathing room in compact and full-screen windows. The top section
/// determines its own height (including wrapped messages); only the work panel flexes.
/// Native Table/List/TabView content must use the supplied finite panel height.
struct AdaptiveDetailPane<Top: View, Panel: View>: View {
    @State private var measuredTopHeight: CGFloat = 0
    private let top: Top
    private let panel: (CGFloat) -> Panel

    init(@ViewBuilder top: () -> Top, @ViewBuilder panel: @escaping (CGFloat) -> Panel) {
        self.top = top()
        self.panel = panel
    }

    var body: some View {
        GeometryReader { geometry in
            let inset = DetailPaneMetrics.padding(width: geometry.size.width)
            let viewport = DetailPaneMetrics.viewportHeight(totalHeight: geometry.size.height, padding: inset)
            let available = DetailPaneMetrics.panelHeight(viewportHeight: viewport, measuredTopHeight: measuredTopHeight)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: DetailPaneMetrics.sectionSpacing) {
                    top
                        .fixedSize(horizontal: false, vertical: true)
                        .background {
                            GeometryReader { topGeometry in
                                Color.clear.preference(key: DetailTopHeightKey.self, value: topGeometry.size.height)
                            }
                        }
                    panel(available)
                }
                .frame(maxWidth: .infinity, minHeight: viewport, alignment: .top)
            }
            // Padding belongs outside the scroll viewport, so content can never push
            // the header or bottom card flush against the window's outer edges.
            .padding(inset)
        }
        .onPreferenceChange(DetailTopHeightKey.self) { height in
            guard height.isFinite, height >= 0, abs(height - measuredTopHeight) > 0.5 else { return }
            measuredTopHeight = height
        }
    }
}
