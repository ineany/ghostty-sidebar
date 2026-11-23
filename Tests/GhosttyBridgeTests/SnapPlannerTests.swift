import CoreGraphics
import XCTest
@testable import GhosttyBridge

final class SnapPlannerTests: XCTestCase {
    let builtIn = CGRect(x: 0, y: 33, width: 1512, height: 949)
    let external = CGRect(x: -869, y: -1800, width: 3200, height: 1800)

    func testFillWidthTakesSpaceRightOfSidebarAndMatchesHeight() {
        let sidebar = CGRect(x: 0, y: 33, width: 260, height: 700)
        let t = SnapPlanner.target(current: CGRect(x: 500, y: 300, width: 600, height: 400),
                                   sidebar: sidebar, screen: builtIn, fillWidth: true)
        XCTAssertEqual(t, CGRect(x: 260, y: 33, width: 1252, height: 700))
    }

    func testKeepWidthWhenItFits() {
        let sidebar = CGRect(x: 0, y: 33, width: 260, height: 949)
        let t = SnapPlanner.target(current: CGRect(x: 500, y: 300, width: 900, height: 400),
                                   sidebar: sidebar, screen: builtIn, fillWidth: false)
        XCTAssertEqual(t, CGRect(x: 260, y: 33, width: 900, height: 949))
    }

    func testWindowFromBiggerScreenIsClampedWhenKeepingWidth() {
        let sidebar = CGRect(x: 0, y: 33, width: 300, height: 949)
        let fromExternal = CGRect(x: -709, y: -1682, width: 2880, height: 1593)
        let t = SnapPlanner.target(current: fromExternal, sidebar: sidebar, screen: builtIn, fillWidth: false)
        XCTAssertEqual(t, CGRect(x: 300, y: 33, width: 1212, height: 949))
    }

    func testSnapOnExternalScreen() {
        let sidebar = CGRect(x: -869, y: -1800, width: 280, height: 1200)
        let t = SnapPlanner.target(current: CGRect(x: 0, y: 33, width: 1512, height: 949),
                                   sidebar: sidebar, screen: external, fillWidth: true)
        XCTAssertEqual(t, CGRect(x: -589, y: -1800, width: 2920, height: 1200))
    }

    func testNarrowWindowGetsMinimumWidth() {
        let sidebar = CGRect(x: 0, y: 33, width: 260, height: 949)
        let t = SnapPlanner.target(current: CGRect(x: 0, y: 0, width: 120, height: 100),
                                   sidebar: sidebar, screen: builtIn, fillWidth: false)
        XCTAssertEqual(t.width, SnapPlanner.minimumWidth)
    }
}
