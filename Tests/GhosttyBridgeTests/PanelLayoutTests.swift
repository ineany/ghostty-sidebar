import CoreGraphics
import XCTest
@testable import GhosttyBridge

final class PanelLayoutTests: XCTestCase {
    // Built-in display visible frame in AppKit coordinates.
    let visible = CGRect(x: 0, y: 0, width: 1512, height: 949)

    private func frame(width: CGFloat = 260, height: CGFloat? = nil,
                       x: CGFloat = 0, top: CGFloat = 0) -> CGRect {
        PanelLayout.frame(in: visible, width: width, height: height, offsetX: x, offsetTop: top,
                          widthRange: 200...480, minimumHeight: 280)
    }

    func testDefaultIsTopLeftFullHeight() {
        XCTAssertEqual(frame(), CGRect(x: 0, y: 0, width: 260, height: 949))
    }

    func testOffsetWithoutHeightReachesBottom() {
        XCTAssertEqual(frame(x: 100, top: 200), CGRect(x: 100, y: 0, width: 260, height: 749))
    }

    func testOffsetKeepsExplicitHeight() {
        XCTAssertEqual(frame(height: 400, x: 50, top: 100), CGRect(x: 50, y: 449, width: 260, height: 400))
    }

    func testClampedInsideScreen() {
        let f = frame(height: 400, x: 5000, top: 5000)
        XCTAssertEqual(f.maxX, visible.maxX)
        XCTAssertEqual(f.height, 280)
        XCTAssertEqual(f.minY, visible.minY)
    }

    func testNegativeOffsetsStickToEdges() {
        XCTAssertEqual(frame(x: -30, top: -10).origin, CGPoint(x: 0, y: 0))
        XCTAssertEqual(frame(height: 300, x: -30, top: -10).maxY, visible.maxY)
    }

    func testOtherScreenOrigin() {
        let lg = CGRect(x: -869, y: 982, width: 3200, height: 1775)
        let f = PanelLayout.frame(in: lg, width: 300, height: 600, offsetX: 400, offsetTop: 100,
                                  widthRange: 200...480, minimumHeight: 280)
        XCTAssertEqual(f, CGRect(x: -469, y: 982 + 1775 - 100 - 600, width: 300, height: 600))
    }
}
