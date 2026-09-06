import SwiftUI
import AppKit

/// Content splits use explicit SwiftUI bounds so AppKit children cannot expand
/// into the floating navigation sidebar's safe area on macOS 26.
struct WorkspaceColumns<Leading: View, Trailing: View>: View {
    let initial: CGFloat
    var minimum: CGFloat = 160
    var maximum: CGFloat = 340
    var leadingVisible = true
    @Binding var savedWidth: Double?
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing
    @State private var dragOrigin: CGFloat?
    var body: some View {
        GeometryReader { geometry in
            let limit = max(minimum, min(maximum, geometry.size.width - 320))
            let actual = leadingVisible ? min(limit, max(minimum, savedWidth ?? initial)) : 0
            let divider: CGFloat = leadingVisible ? 5 : 0
            HStack(spacing: 0) {
                leading().frame(width: actual, height: geometry.size.height).clipped()
                SplitHandle(vertical: true).frame(width: divider).clipped().allowsHitTesting(leadingVisible)
                    .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                        if dragOrigin == nil { dragOrigin = actual }
                        savedWidth = min(limit, max(minimum, (dragOrigin ?? actual) + value.translation.width))
                    }.onEnded { _ in dragOrigin = nil })
                trailing().frame(width: max(1, geometry.size.width - actual - divider), height: geometry.size.height).clipped()
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
    }
}

struct WorkspaceRows<Top: View, Bottom: View>: View {
    var topVisible = true
    @Binding var savedFraction: Double?
    @ViewBuilder let top: () -> Top
    @ViewBuilder let bottom: () -> Bottom
    @State private var dragOrigin: CGFloat?
    var body: some View {
        GeometryReader { geometry in
            let divider: CGFloat = topVisible ? 5 : 0
            let available = max(1, geometry.size.height - divider)
            let upper = topVisible ? min(max(100, available - 240), max(180, available * (savedFraction ?? 0.5))) : 0
            VStack(spacing: 0) {
                top().frame(width: geometry.size.width, height: upper).clipped()
                SplitHandle(vertical: false).frame(height: divider).clipped().allowsHitTesting(topVisible)
                    .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                        if dragOrigin == nil { dragOrigin = upper }
                        savedFraction = min(0.85, max(0.15, ((dragOrigin ?? upper) + value.translation.height) / available))
                    }.onEnded { _ in dragOrigin = nil })
                bottom().frame(width: geometry.size.width, height: max(1, available - upper)).clipped()
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
    }
}
private struct SplitHandle: View {
    @Environment(\.appTheme) private var theme
    let vertical: Bool
    var body: some View {
        Rectangle().fill(theme.border).contentShape(Rectangle())
            .onHover { over in if over { (vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() } }
            .accessibilityLabel(vertical ? "Resize columns" : "Resize rows")
    }
}
