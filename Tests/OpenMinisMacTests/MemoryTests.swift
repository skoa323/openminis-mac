import XCTest
@testable import OpenMinisMac

final class MemoryTests: XCTestCase {
    private var tmp: URL!

    override func setUp() {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("om-mem-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        MemoryStore.rootOverride = tmp.appendingPathComponent("memory")
        SkillLibrary.rootOverride = tmp.appendingPathComponent("skills")
    }

    override func tearDown() {
        MemoryStore.rootOverride = nil
        SkillLibrary.rootOverride = nil
        try? FileManager.default.removeItem(at: tmp)
    }

    func testWritePrependsAndGetFinds() throws {
        _ = try MemoryStore.write("## A\nlikes swift")
        _ = try MemoryStore.write("## B\nprefers dark mode")
        let text = MemoryStore.read(MemoryStore.dailyFile())
        XCTAssertTrue(text.hasPrefix("<!-- "))
        XCTAssertTrue(text.range(of: "dark mode")!.lowerBound < text.range(of: "swift")!.lowerBound)
        let r = MemoryStore.get(keywords: "swift", scope: "all")
        XCTAssertTrue(r.contains("likes swift"))
        XCTAssertFalse(r.contains("dark mode"))
        XCTAssertTrue(MemoryStore.get(keywords: "nothinghere", scope: "daily").hasPrefix("No matches"))
    }

    func testRevoke() throws {
        _ = try MemoryStore.write("remember me")
        XCTAssertTrue(MemoryStore.revoke("remember me"))
        XCTAssertFalse(MemoryStore.read(MemoryStore.dailyFile()).contains("remember me"))
    }

    func testSoulRoundTrip() {
        var s = Soul()
        s.name = "Kiro"; s.style = "简洁"; s.body = "Be kind."
        let p = Soul.parse(s.serialize())
        XCTAssertEqual(p.name, "Kiro")
        XCTAssertEqual(p.style, "简洁")
        XCTAssertEqual(p.body.trimmingCharacters(in: .whitespacesAndNewlines), "Be kind.")
        XCTAssertEqual(Soul.parse("no frontmatter").body, "no frontmatter")
        XCTAssertEqual(Soul.tokenCount("你好 world"), 3)
    }

    func testSkillFrontmatterAndSlug() {
        let fm = SkillLibrary.parse("---\nname: My Skill\ndescription: does things\n---\nbody")
        XCTAssertEqual(fm?.name, "My Skill")
        XCTAssertEqual(fm?.description, "does things")
        XCTAssertEqual(fm?.version, "1.0.0")
        XCTAssertEqual(SkillLibrary.slugify("My Skill_v2!"), "my-skill-v2")
        XCTAssertTrue(SkillLibrary.versionLess("2.1.0", "10.0"))
        XCTAssertFalse(SkillLibrary.versionLess("2.1.0", "2.1.0"))
    }

    func testSkillPromptFragment() {
        XCTAssertEqual(SkillLibrary.promptFragment([]), "")
        let s = SkillMeta(id: "a", name: "A<b>", description: String(repeating: "x", count: 250), version: "1.0.0")
        let p = SkillLibrary.promptFragment([s])
        XCTAssertTrue(p.contains("<available_skills>"))
        XCTAssertTrue(p.contains("A&lt;b&gt;"))
        XCTAssertTrue(p.contains("…"))
    }
}
