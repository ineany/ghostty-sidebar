import XCTest
@testable import GhosttyBridge

final class ProjectGroupingTests: XCTestCase {
    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    func testGroupsKeepOrderOfFirstItemAndPutOthersLast() {
        let items = ["a1", "x", "b1", "a2", "b2", "y"]
        let roots: [String: String] = ["a1": "/p/a", "a2": "/p/a", "b1": "/p/b", "b2": "/p/b"]
        let groups = ProjectGrouping.group(items) { roots[$0] }
        XCTAssertEqual(groups.map(\.root), ["/p/a", "/p/b", nil])
        XCTAssertEqual(groups.map(\.items), [["a1", "a2"], ["b1", "b2"], ["x", "y"]])
        XCTAssertEqual(groups.map(\.name), ["a", "b", nil])
    }

    func testEmptyInputHasNoGroups() {
        XCTAssertTrue(ProjectGrouping.group([String]()) { _ in "/p" }.isEmpty)
    }

    func testUnicodeNormalizationFormsShareAGroup() {
        // macOS paths can come back decomposed (NFD) from one source and composed from another.
        let nfc = "/p/\u{D55C}"            // 한
        let nfd = "/p/\u{1112}\u{1161}\u{11AB}"
        let groups = ProjectGrouping.group([nfc, nfd]) { $0 }
        XCTAssertEqual(groups.count, 1)
    }

    func testResolverFindsNearestGitFolder() {
        let repo = home + "/work/repo"
        let resolver = ProjectResolver { $0 == repo + "/.git" }
        XCTAssertEqual(resolver.root(for: repo + "/apps/api/src"), repo)
        XCTAssertEqual(resolver.root(for: repo), repo)
        XCTAssertEqual(resolver.root(for: repo + "/"), repo)
    }

    func testResolverFallsBackToTheDirectory() {
        let resolver = ProjectResolver { _ in false }
        XCTAssertEqual(resolver.root(for: home + "/scratch"), home + "/scratch")
    }

    func testPathsOutsideHomeAreNotSearched() {
        var lookups = 0
        let resolver = ProjectResolver { _ in lookups += 1; return true }
        XCTAssertEqual(resolver.root(for: "/Volumes/NAS/repo/src"), "/Volumes/NAS/repo/src")
        XCTAssertEqual(lookups, 0)
    }

    func testStableOrderKeepsFirstSeenOrder() {
        var order = StableOrder.update(known: [], current: ["w1", "w2", "w3"])
        XCTAssertEqual(order, ["w1", "w2", "w3"])
        // w3 comes to the front: the order stays.
        order = StableOrder.update(known: order, current: ["w3", "w1", "w2"])
        XCTAssertEqual(order, ["w1", "w2", "w3"])
        // w1 closes, w4 opens in front.
        order = StableOrder.update(known: order, current: ["w4", "w3", "w2"])
        XCTAssertEqual(order, ["w2", "w3", "w4"])
    }

    func testHomeGitRepoDoesNotSwallowSubfolders() {
        let resolver = ProjectResolver { $0 == self.home + "/.git" }
        XCTAssertEqual(resolver.root(for: home + "/notes"), home + "/notes")
        XCTAssertEqual(resolver.root(for: home), home)
    }

    func testResolverRejectsMissingOrRelativePaths() {
        let resolver = ProjectResolver { _ in true }
        XCTAssertNil(resolver.root(for: nil))
        XCTAssertNil(resolver.root(for: ""))
        XCTAssertNil(resolver.root(for: "relative/dir"))
    }

    func testCacheExpiresSoGitInitIsPickedUp() {
        var clock = Date(timeIntervalSince1970: 0)
        var hasGit = false
        var lookups = 0
        let dir = home + "/new"
        let resolver = ProjectResolver(lifetime: 60, now: { clock }) { path in
            lookups += 1
            return hasGit && path == dir + "/.git"
        }
        XCTAssertEqual(resolver.root(for: dir + "/sub"), dir + "/sub")
        let afterFirst = lookups
        hasGit = true
        XCTAssertEqual(resolver.root(for: dir + "/sub"), dir + "/sub", "cached")
        XCTAssertEqual(lookups, afterFirst)
        clock = clock.addingTimeInterval(61)
        XCTAssertEqual(resolver.root(for: dir + "/sub"), dir)
    }
}
