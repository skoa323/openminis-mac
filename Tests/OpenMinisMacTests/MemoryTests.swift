import XCTest
@testable import OpenMinisMac

final class MemoryTests: XCTestCase {
    override func setUp() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("omt-\(UUID().uuidString)")
        MemoryStore.rootOverride = tmp.appendingPathComponent("memory")
        SkillLibrary.rootOverride = tmp.appendingPathComponent("skills")
    }

    func testWritePrependsAndRevoke() throws {
        _ = try MemoryStore.write("## A\nfirst")
        _ = try MemoryStore.write("## B\nsecond")
        let text = MemoryStore.read(MemoryStore.dailyFile())
        XCTAssertLessThan(text.range(of: "second")!.lowerBound, text.range(of: "first")!.lowerBound)
        XCTAssertTrue(MemoryStore.revoke("## A\nfirst"))
        XCTAssertFalse(MemoryStore.read(MemoryStore.dailyFile()).contains("first"))
    }

    func testGetRanksAndReportsNoMatch() throws {
        _ = try MemoryStore.write("swift package notes")
        _ = try MemoryStore.write("python tips")
        let out = MemoryStore.get(keywords: "swift", scope: "daily")
        XCTAssertTrue(out.contains("Found 1 matching"))
        XCTAssertTrue(MemoryStore.get(keywords: "zzz", scope: "daily").contains("No matches found"))
    }

    func testSoulRoundTripAndTokens() {
        var s = Soul(); s.name = "Mini"; s.style = "简洁"; s.body = "你好 world"
        let p = Soul.parse(s.serialize())
        XCTAssertEqual(p.name, "Mini"); XCTAssertEqual(p.style, "简洁"); XCTAssertEqual(p.body, "你好 world")
        XCTAssertEqual(Soul.tokenCount("你好 world"), 3)
        XCTAssertEqual(Soul.parse("no frontmatter").body, "no frontmatter")
    }

    func testSkillParseSlugVersion() {
        let fm = SkillLibrary.parse("---\nname: My Skill\ndescription: |\n  line1\n  line2\n---\nbody")
        XCTAssertEqual(fm?.name, "My Skill")
        XCTAssertTrue(fm?.description.contains("line1") ?? false)
        XCTAssertEqual(SkillLibrary.slugify("My Skill_v2"), "my-skill-v2")
        XCTAssertTrue(SkillLibrary.versionLess("2.1.0", "10.0.0"))
    }

    func testInstallAndPromptFragment() throws {
        let id = try SkillLibrary.install(skillMD: "---\nname: demo\ndescription: a <b> test\n---\n", source: "file")
        XCTAssertEqual(id, "demo")
        let meta = SkillLibrary.scan(SkillLibrary.loadMeta())
        let frag = SkillLibrary.promptFragment(meta)
        XCTAssertTrue(frag.contains("<available_skills>"))
        XCTAssertTrue(frag.contains("a &lt;b&gt; test"))
        XCTAssertEqual(SkillLibrary.promptFragment([]), "")
    }
}
