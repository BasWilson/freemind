import AppKit
import XCTest
@testable import Freemind

final class WindowOpacityTests: XCTestCase {
    @MainActor func testWindowOpacityAppliesOnAttachmentAndUpdates() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: .borderless, backing: .buffered, defer: true)
        let view = WindowOpacityView()
        view.opacity = 0.8
        window.contentView = view
        XCTAssertEqual(window.alphaValue, 0.8, accuracy: 0.001)
        view.opacity = 0.9; view.apply()
        XCTAssertEqual(window.alphaValue, 0.9, accuracy: 0.001)
        view.opacity = 1; view.apply()
        XCTAssertEqual(window.alphaValue, 1, accuracy: 0.001)
        XCTAssertNil(view.hitTest(.zero))
        window.contentView = nil
    }
}
