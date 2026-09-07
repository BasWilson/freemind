import AppKit
import XCTest
@testable import Freemind

final class WindowOpacityTests: XCTestCase {
    @MainActor func testMainWindowBackdropBlursWithoutFadingOtherWindows() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: .borderless, backing: .buffered, defer: true)
        let other = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        let view = WindowBackdropView()
        view.enabled = true
        window.contentView = view
        XCTAssertEqual(window.alphaValue, 1, accuracy: 0.001)
        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(window.backgroundColor, .clear)
        XCTAssertEqual(view.blendingMode, .behindWindow)
        XCTAssertEqual(view.material, .underWindowBackground)
        XCTAssertEqual(view.state, .active)
        XCTAssertFalse(view.isHidden)
        XCTAssertTrue(other.isOpaque)
        XCTAssertEqual(other.alphaValue, 1)
        view.enabled = false; view.apply()
        XCTAssertTrue(window.isOpaque)
        XCTAssertTrue(view.isHidden)
        XCTAssertEqual(window.backgroundColor, .windowBackgroundColor)
        XCTAssertNil(view.hitTest(.zero))
        window.contentView = nil
    }
}
