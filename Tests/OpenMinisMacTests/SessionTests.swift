import XCTest
@testable import OpenMinisMac

final class SessionTests: XCTestCase {
    private func conv(_ title: String, _ texts: [String], updated: Date = Date()) -> Conversation {
        var c = Conversation()
        c.title = title
        c.messages = texts.map { ChatMessage(role: .user, content: $0) }
        c.updatedAt = updated
        return c
    }

    func testTermsDedupAndFullWidthSpace() {
        XCTAssertEqual(SessionSearch.terms("Foo  foo\u{3000}bar"), ["Foo", "bar"])
        XCTAssertEqual(SessionSearch.terms((1...20).map(String.init).joined(separator: " ")).count, 10)
    }

    func testSearchIsOrAndTitleOrSnippet() {
        let a = conv("Swift 笔记", ["hello"])
        let b = conv("其他", ["关于 python 的问题"])
        let c = conv("无关", ["nothing"])
        let hits = SessionSearch.search([a, b, c], query: "swift python")
        XCTAssertEqual(Set(hits.map(\.conversationID)), [a.id, b.id])
        XCTAssertTrue(hits.first { $0.conversationID == a.id }!.titleHit)
        XCTAssertEqual(hits.first { $0.conversationID == b.id }?.snippet, "关于 python 的问题")
    }

    func testHitLineWindow() {
        let line = String(repeating: "a", count: 100) + "TARGET" + String(repeating: "b", count: 100)
        let s = SessionSearch.hitLine(in: line, terms: ["target"])!
        XCTAssertTrue(s.hasPrefix("…"))
        XCTAssertTrue(s.hasSuffix("…"))
        XCTAssertTrue(s.contains("TARGET"))
        XCTAssertEqual(s.count, 90 + 2)
    }

    func testChatFindDiacriticInsensitive() {
        let ms = [ChatMessage(role: .user, content: "Café cafe CAFE")]
        XCTAssertEqual(ChatFind.matches(ms, query: "cafe").count, 3)
        XCTAssertEqual(ChatFind.label(current: 0, total: 3), "1/3")
        XCTAssertEqual(ChatFind.label(current: nil, total: 0), "0/0")
    }

    func testGroupingOrder() {
        let now = Date()
        var pinned = conv("p", ["x"], updated: now); pinned.pinnedAt = now
        let today = conv("t", ["x"], updated: now)
        let old = conv("o", ["x"], updated: now.addingTimeInterval(-90 * 86400))
        var f = ChatFolder(name: "F")
        f.updatedAt = now
        var filed = conv("f", ["x"], updated: now); filed.folderID = f.id
        let g = SidebarGrouping.group([old, today, pinned, filed], folders: [f], now: now)
        XCTAssertEqual(g.map(\.0), [.pinned, .folder(f.id), .bucket(.today), .bucket(.earlier)])
    }

    func testRelative() {
        let now = Date()
        XCTAssertEqual(SidebarGrouping.relative(now.addingTimeInterval(-10), now: now), "刚刚")
        XCTAssertEqual(SidebarGrouping.relative(now.addingTimeInterval(-300), now: now), "5 分钟前")
    }

    func testCopyTitle() {
        XCTAssertEqual(SessionCopy.copyTitle("Foo", existing: []), "Foo (副本)")
        XCTAssertEqual(SessionCopy.copyTitle("Foo (副本)", existing: ["Foo (副本)"]), "Foo (副本 2)")
        XCTAssertEqual(SessionCopy.copyTitle("", existing: []), "未命名 (副本)")
    }

    func testForkPrefixKeepsToolResults() {
        let u = ChatMessage(role: .user, content: "q")
        let a = ChatMessage(role: .assistant, content: "", toolCalls: [ToolCall(id: "c1", name: "shell", arguments: "{}")])
        let t = ChatMessage(role: .tool, content: "ok", toolCallId: "c1", toolName: "shell")
        let a2 = ChatMessage(role: .assistant, content: "done")
        let p = SessionCopy.forkPrefix([u, a, t, a2], through: a.id)
        XCTAssertEqual(p.map(\.id), [u.id, a.id, t.id])
    }

    func testExportFormats() throws {
        let c = conv("T/x", ["hello"])
        XCTAssertEqual(SessionExport.fileName([c], format: .markdown), "T-x.md")
        XCTAssertTrue(SessionExport.render([c], format: .markdown).contains("hello"))
        XCTAssertTrue(SessionExport.render([c], format: .text).contains("[用户]"))
        let data = SessionExport.render([c], format: .json).data(using: .utf8)!
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: data))
    }

    func testOldConversationDecodes() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"t","messages":[]}"#
        let c = try JSONDecoder().decode(Conversation.self, from: Data(json.utf8))
        XCTAssertNil(c.folderID)
        XCTAssertFalse(c.isPinned)
    }

    func testTitleClean() {
        XCTAssertEqual(TitleGen.clean("标题：「整理 Mac 项目」\n解释"), "整理 Mac 项目")
    }
}
