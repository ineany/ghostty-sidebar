import XCTest
@testable import GhosttyBridge

final class TitleParserTests: XCTestCase {
    func testIdleGlyph() {
        let r = TitleParser.parse("✳ 팀 Slack 스레드 요약")
        XCTAssertEqual(r.status, .idle)
        XCTAssertEqual(r.title, "팀 Slack 스레드 요약")
    }

    func testIdleKoreanTitle() {
        let r = TitleParser.parse("✳ Known 수기 처리 누락 시 영향")
        XCTAssertEqual(r.status, .idle)
        XCTAssertEqual(r.title, "Known 수기 처리 누락 시 영향")
    }

    func testIdleGlyphWithVariationSelector() {
        let r = TitleParser.parse("✳\u{FE0F} Waiting")
        XCTAssertEqual(r.status, .idle)
        XCTAssertEqual(r.title, "Waiting")
    }

    func testBusyQuarterCircles() {
        for glyph in ["◐", "◓", "◑", "◒"] {
            let r = TitleParser.parse("\(glyph) Ghostty 작업 세션 재개")
            XCTAssertEqual(r.status, .busy, glyph)
            XCTAssertEqual(r.title, "Ghostty 작업 세션 재개", glyph)
        }
    }

    func testBusyBrailleRange() {
        for glyph in ["\u{2800}", "⠋", "⠙", "⣾", "\u{28FF}"] {
            let r = TitleParser.parse("\(glyph) Working")
            XCTAssertEqual(r.status, .busy, glyph)
            XCTAssertEqual(r.title, "Working", glyph)
        }
    }

    func testBusyOtherSpinnerGlyphs() {
        for glyph in ["·", "✢", "✶", "✻", "✽"] {
            let r = TitleParser.parse("\(glyph) Thinking")
            XCTAssertEqual(r.status, .busy, glyph)
            XCTAssertEqual(r.title, "Thinking", glyph)
        }
    }

    func testPlainTitleIsUnknownAndUnchanged() {
        let r = TitleParser.parse("문서 초안 검토 | 2026-메모")
        XCTAssertEqual(r.status, .unknown)
        XCTAssertEqual(r.title, "문서 초안 검토 | 2026-메모")
    }

    func testUnknownTitleIsTrimmed() {
        let r = TitleParser.parse("  zsh \n")
        XCTAssertEqual(r.status, .unknown)
        XCTAssertEqual(r.title, "zsh")
    }

    func testGlyphWithoutSpaceIsStripped() {
        let r = TitleParser.parse("◐Build")
        XCTAssertEqual(r.status, .busy)
        XCTAssertEqual(r.title, "Build")
    }

    func testGlyphOnlyFallsBackToRawTitle() {
        let r = TitleParser.parse("✳  ")
        XCTAssertEqual(r.status, .idle)
        XCTAssertEqual(r.title, "✳")
    }

    func testEmptyTitleUsesPlaceholder() {
        XCTAssertEqual(TitleParser.parse("").title, "(untitled)")
        XCTAssertEqual(TitleParser.parse("   ").title, "(untitled)")
        XCTAssertEqual(TitleParser.parse("").status, .unknown)
    }

    func testOtherSymbolsAreUnknown() {
        XCTAssertEqual(TitleParser.parse("* notes").status, .unknown)
        XCTAssertEqual(TitleParser.parse("★ star").status, .unknown)
        XCTAssertEqual(TitleParser.parse("★ star").title, "★ star")
    }
}
