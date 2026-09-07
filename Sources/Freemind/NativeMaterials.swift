import SwiftUI
import AppKit

private struct WorkspaceWindowKey: EnvironmentKey { static let defaultValue = -1 }
extension EnvironmentValues {
    var workspaceWindowID: Int {
        get { self[WorkspaceWindowKey.self] }
        set { self[WorkspaceWindowKey.self] = newValue }
    }
}

extension View {
    @ViewBuilder func navigationGlass(cornerRadius: CGFloat = 10) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
    @ViewBuilder func workspaceToolbarTitle() -> some View {
        if #available(macOS 26.0, *) { self.toolbar(removing: .title) } else { self }
    }
}

struct NativePaneButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.55 : 1)
            .frame(minWidth: 22, minHeight: 22).contentShape(Rectangle())
    }
}

struct WindowBackdrop: NSViewRepresentable {
    var enabled: Bool
    func makeNSView(context: Context) -> WindowBackdropView {
        let view = WindowBackdropView(); view.enabled = enabled; return view
    }
    func updateNSView(_ view: WindowBackdropView, context: Context) {
        view.enabled = enabled; view.apply()
    }
}

final class WindowBackdropView: NSVisualEffectView {
    var enabled = false
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func apply() {
        material = .underWindowBackground
        blendingMode = .behindWindow
        state = .active
        isHidden = !enabled
        // Fade the main window's content over this macOS blur, instead of fading
        // the native window itself (which exposes an unblurred desktop).
        window?.alphaValue = 1
        window?.isOpaque = !enabled
        window?.backgroundColor = enabled ? .clear : .windowBackgroundColor
    }
}
