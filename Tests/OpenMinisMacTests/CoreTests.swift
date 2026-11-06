import XCTest
@testable import OpenMinisMac

final class MarkdownParserTests: XCTestCase {
    func testHeadingAndParagraph() {
        let b = MarkdownParser.parse("# 标题\n\n正文一行")
        XCTAssertEqual(b.first, .heading(1, "标题"))
        XCTAssertEqual(b.last, .paragraph("正文一行"))
    }

    func testFencedCodeKeepsContent() {
        let b = MarkdownParser.parse("```swift\nlet a = 1\n# not heading\n```")
        XCTAssertEqual(b, [.code("swift", "let a = 1\n# not heading")])
    }

    func testUnterminatedFenceStillCode() {
        let b = MarkdownParser.parse("```py\nprint(1)")
        XCTAssertEqual(b, [.code("py", "print(1)")])
    }

    func testListMarkers() {
        XCTAssertEqual(MarkdownParser.listItem("- a"), MDListItem(indent: 0, marker: "•", text: "a"))
        XCTAssertEqual(MarkdownParser.listItem("  - [x] done"), MDListItem(indent: 1, marker: "☑", text: "done"))
        XCTAssertEqual(MarkdownParser.listItem("12. item"), MDListItem(indent: 0, marker: "12.", text: "item"))
        XCTAssertNil(MarkdownParser.listItem("plain"))
    }

    func testTable() {
        let b = MarkdownParser.parse("| a | b |\n|:--|--:|\n| 1 | 2 |")
        guard case let .table(h, al, rows)? = b.first else { return XCTFail("no table: \(b)") }
        XCTAssertEqual(h, ["a", "b"])
        XCTAssertEqual(al, [.leading, .trailing])
        XCTAssertEqual(rows, [["1", "2"]])
    }

    func testQuoteAndRule() {
        let b = MarkdownParser.parse("> 引用\n\n---")
        XCTAssertEqual(b, [.quote([.paragraph("引用")]), .rule])
    }
}

final class ModelDecodingTests: XCTestCase {
    func testOldMessageWithoutNewFieldsDecodes() throws {
        let json = #"{"id":"9F0C1E7A-1D8B-4E7B-9C35-3F6A2D1B0C11","role":"assistant","content":"hi","toolCalls":[],"isError":false,"date":"2026-11-06T08:00:00Z"}"#
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let m = try dec.decode(ChatMessage.self, from: Data(json.utf8))
        XCTAssertEqual(m.content, "hi")
        XCTAssertEqual(m.reasoning, "")
        XCTAssertEqual(m.images, [])
    }

    func testRoundTrip() throws {
        let m = ChatMessage(role: .user, content: "x", reasoning: "r", images: ["a.jpg"])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(ChatMessage.self, from: enc.encode(m))
        XCTAssertEqual(back.images, ["a.jpg"])
        XCTAssertEqual(back.reasoning, "r")
    }
}
