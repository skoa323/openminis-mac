import XCTest
@testable import OpenMinisMac

final class BrowserTests: XCTestCase {
    func testActionParsingAndLooseScalars() throws {
        let res = BrowserActionInput.parse([
            "action": "scroll_and_collect",
            "selector": "div.feed",
            "direction": "DOWN",
            "amount": "650",
            "scroll_count": 12.0,
            "full_page": "true",
            "tab_id": "2",
            "keywords": "session auth",
            "fuzzy": "0",
        ])
        let input = try res.get()
        XCTAssertEqual(input.action, .scrollAndCollect)
        XCTAssertEqual(input.selector, "div.feed")
        XCTAssertEqual(input.direction, .down)
        XCTAssertEqual(input.amount, 650)
        XCTAssertEqual(input.scrollCount, 12)
        XCTAssertEqual(input.fullPage, true)
        XCTAssertEqual(input.tabId, 2)
        XCTAssertEqual(input.keywords, ["session", "auth"])
        XCTAssertEqual(input.fuzzy, false)

        if case .failure(.missingAction) = BrowserActionInput.parse([:]) {} else {
            XCTFail("Expected missingAction")
        }
        if case .failure(.unknownAction(let a)) = BrowserActionInput.parse(["action": "fly"]) {
            XCTAssertEqual(a, "fly")
        } else {
            XCTFail("Expected unknownAction")
        }
    }

    func testUserAgentAliases() {
        XCTAssertEqual(UserAgentProfile.parse("desktop"), .desktopSafari)
        XCTAssertEqual(UserAgentProfile.parse("Desktop-Safari"), .desktopSafari)
        XCTAssertEqual(UserAgentProfile.parse("MOBILE"), .mobileSafari)
        XCTAssertEqual(UserAgentProfile.parse("mobile_safari"), .mobileSafari)
        XCTAssertNil(UserAgentProfile.parse("chrome"))
    }

    func testNormalizeNavigationURLAndAddressBar() {
        if case .ok(let u) = BrowserLogic.normalizeNavigationURL("example.com/path") {
            XCTAssertEqual(u.absoluteString, "https://example.com/path")
        } else { XCTFail("Expected ok URL") }

        if case .ok(let f) = BrowserLogic.normalizeNavigationURL("/tmp/index.html") {
            XCTAssertTrue(f.isFileURL)
        } else { XCTFail("Expected file URL") }

        if case .invalid(let msg) = BrowserLogic.normalizeNavigationURL("javascript:alert(1)") {
            XCTAssertTrue(msg.contains("Cannot navigate"))
        } else { XCTFail("Expected invalid scheme") }

        XCTAssertEqual(BrowserLogic.addressBarURL("localhost:3000")?.absoluteString, "http://localhost:3000")
        XCTAssertEqual(BrowserLogic.addressBarURL("swift.org")?.absoluteString, "https://swift.org")
        let search = BrowserLogic.addressBarURL("swift wkwebview tutorial")
        XCTAssertEqual(search?.host, "www.bing.com")
    }

    func testViewportRequestValidation() {
        XCTAssertEqual(BrowserLogic.viewportRequest(width: nil, height: nil, reset: true), .reset)
        XCTAssertEqual(BrowserLogic.viewportRequest(width: 1920, height: 1080, reset: nil), .set(width: 1920, height: 1080))
        if case .invalid = BrowserLogic.viewportRequest(width: 100, height: 1080, reset: nil) {} else {
            XCTFail("Expected invalid viewport width")
        }
    }

    func testCookieMatchingAndEnvFile() {
        XCTAssertTrue(BrowserLogic.cookieMatchesHost(cookieDomain: ".github.com", host: "gist.github.com"))
        XCTAssertFalse(BrowserLogic.cookieMatchesHost(cookieDomain: "gitlab.com", host: "github.com"))
        XCTAssertTrue(BrowserLogic.cookieNameMatches("user_session_id", keywords: ["user", "session"], fuzzy: true))
        XCTAssertFalse(BrowserLogic.cookieNameMatches("user_session_id", keywords: ["user", "token"], fuzzy: true))
        XCTAssertTrue(BrowserLogic.cookieNameMatches("sid", keywords: ["SID", "tok"], fuzzy: false))

        let env = BrowserLogic.cookieEnvFile([("session-id", "a'b"), ("session.id", "c")])
        XCTAssertTrue(env.contains("export COOKIE_SESSION_ID='a'\\''b'"))
        XCTAssertTrue(env.contains("export COOKIE_SESSION_ID_2='c'"))
        XCTAssertTrue(env.contains("BROWSER_COOKIE_HEADER="))

        let props = BrowserLogic.cookieProperties(
            ["name": "sid", "value": "123", "httpOnly": true, "secure": 1, "expirationDate": 1_800_000_000],
            defaultDomain: "example.com"
        )
        XCTAssertEqual(props?[.name] as? String, "sid")
        XCTAssertEqual(props?[.domain] as? String, "example.com")
        XCTAssertNotNil(props?[.expires])
    }

    func testFetchFilenameAndJSWrap() {
        let fn = BrowserLogic.fetchFilename(
            contentDisposition: "attachment; filename=\"../secret/report.pdf\"",
            finalURL: "https://example.com/dl",
            contentType: "application/pdf",
            timestamp: 100
        )
        XCTAssertFalse(fn.contains("/"))
        XCTAssertTrue(fn.hasSuffix("report.pdf"))

        let wrapped = BrowserLogic.wrapExecuteJSReturn("const x = 1;\nawait fetch('/a')")
        XCTAssertTrue(wrapped.contains("return await fetch('/a')"))

        let out = BrowserLogic.toolOutput(BrowserActionResult(text: "Done", tabId: 3), dialogs: ["[alert] hi"])
        XCTAssertTrue(out.hasPrefix("[tab_id: 3] Done"))
        XCTAssertTrue(out.contains("[JavaScript dialogs auto-answered]"))
    }
}
