import CoreGraphics
import XCTest
@testable import GhosttyBridge

final class ArrangePlannerTests: XCTestCase {
    // Built-in display below a 4K display, as on the author's machine (AX coordinates).
    let builtIn = CGRect(x: 0, y: 33, width: 1512, height: 949)
    let external = CGRect(x: -869, y: -1800, width: 3200, height: 1800)

    func testFullWidthWindowIsPushedRightOfLeftSidebar() {
        let sidebar = CGRect(x: 0, y: 33, width: 260, height: 949)
        let plan = ArrangePlanner.plan(windows: [CGRect(x: 0, y: 33, width: 1512, height: 915)],
                                       sidebar: sidebar, screen: builtIn)
        XCTAssertEqual(plan[0], CGRect(x: 260, y: 33, width: 1252, height: 915))
    }

    func testWindowAlreadyBesideSidebarIsUntouched() {
        let sidebar = CGRect(x: 0, y: 33, width: 260, height: 949)
        let plan = ArrangePlanner.plan(windows: [CGRect(x: 260, y: 50, width: 1000, height: 800)],
                                       sidebar: sidebar, screen: builtIn)
        XCTAssertTrue(plan.isEmpty)
    }

    func testWindowOnOtherScreenIsUntouched() {
        let sidebar = CGRect(x: 0, y: 33, width: 260, height: 949)
        let onExternal = CGRect(x: -709, y: -1682, width: 2880, height: 1593)
        XCTAssertTrue(ArrangePlanner.plan(windows: [onExternal], sidebar: sidebar, screen: builtIn).isEmpty)
    }

    func testSidebarOnExternalScreenMovesOnlyThoseWindows() {
        let sidebar = CGRect(x: -869, y: -1800, width: 260, height: 1800)
        let onExternal = CGRect(x: -869, y: -1682, width: 2880, height: 1593)
        let onBuiltIn = CGRect(x: 0, y: 33, width: 1512, height: 915)
        let plan = ArrangePlanner.plan(windows: [onBuiltIn, onExternal], sidebar: sidebar, screen: external)
        XCTAssertNil(plan[0])
        XCTAssertEqual(plan[1], CGRect(x: -609, y: -1682, width: 2620, height: 1593))
    }

    func testNarrowResultKeepsMinimumWidth() {
        let sidebar = CGRect(x: 0, y: 33, width: 260, height: 949)
        let plan = ArrangePlanner.plan(windows: [CGRect(x: 100, y: 100, width: 300, height: 400)],
                                       sidebar: sidebar, screen: builtIn)
        XCTAssertEqual(plan[0]?.minX, 260)
        XCTAssertEqual(plan[0]?.width, ArrangePlanner.minimumWidth)
    }

    func testRightSidebarPushesWindowLeft() {
        let sidebar = CGRect(x: 1252, y: 33, width: 260, height: 949)
        let plan = ArrangePlanner.plan(windows: [CGRect(x: 0, y: 33, width: 1512, height: 915)],
                                       sidebar: sidebar, screen: builtIn)
        XCTAssertEqual(plan[0], CGRect(x: 0, y: 33, width: 1252, height: 915))
    }

    func testAccessibilityConversion() {
        // AppKit rect of the external display's left 260 pt strip.
        let appKit = CGRect(x: -869, y: 982, width: 260, height: 1800)
        XCTAssertEqual(ArrangePlanner.toAccessibility(appKit, primaryHeight: 982),
                       CGRect(x: -869, y: -1800, width: 260, height: 1800))
    }

    func testParseFrames() throws {
        let frames = try GhosttyWindowArranger.parseFrames("-709,-1682,2880,1593;0,33,1512,915")
        XCTAssertEqual(frames, [CGRect(x: -709, y: -1682, width: 2880, height: 1593),
                                CGRect(x: 0, y: 33, width: 1512, height: 915)])
        XCTAssertEqual(try GhosttyWindowArranger.parseFrames(""), [])
    }
}
