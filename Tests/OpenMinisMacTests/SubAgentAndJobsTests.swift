import XCTest
@testable import OpenMinisMac

final class SubAgentAndJobsTests: XCTestCase {
    func testRosterNormalizationAndResolve() {
        let custom1 = SubAgentDefinition(
            id: "c1",
            name: String(repeating: "A", count: 80),
            description: String(repeating: "B", count: 300),
            sortOrder: 5
        )
        let dupOfCustom1 = SubAgentDefinition(id: "c2", name: custom1.clamped().name.lowercased(), description: "dup", sortOrder: 6)
        let mutatedBuiltIn = SubAgentDefinition(
            id: SubAgentDefinition.builtInId,
            name: "Wrong Name",
            description: "Wrong Desc",
            instructions: "Keep my custom instructions",
            isBuiltIn: true,
            sortOrder: 99
        )

        let norm = SubAgentRoster.normalize([custom1, dupOfCustom1, mutatedBuiltIn])
        XCTAssertEqual(norm.count, 2)
        XCTAssertEqual(norm[0].id, SubAgentDefinition.builtInId)
        XCTAssertEqual(norm[0].name, SubAgentDefinition.builtInName)
        XCTAssertEqual(norm[0].instructions, "Keep my custom instructions")
        XCTAssertEqual(norm[1].name.count, SubAgentLimits.nameMaxLength)
        XCTAssertEqual(norm[1].description.count, SubAgentLimits.descriptionMaxLength)
        XCTAssertEqual(norm[1].sortOrder, 1)

        XCTAssertEqual(SubAgentRoster.resolve(name: nil, in: norm).id, SubAgentDefinition.builtInId)
        XCTAssertEqual(SubAgentRoster.resolve(name: "unknown", in: norm).id, SubAgentDefinition.builtInId)
        XCTAssertEqual(SubAgentRoster.resolve(name: norm[1].name.lowercased(), in: norm).id, "c1")

        let gid = UUID()
        var pinned = SubAgentDefinition(id: "p1", name: "Researcher", description: "Finds docs", modelGroupID: gid)
        pinned.sortOrder = 2
        let section = SubAgentRoster.rosterSection([pinned], groupName: { $0 == gid ? "Pro Group" : nil })
        XCTAssertTrue(section.contains("General Sub Agent"))
        XCTAssertTrue(section.contains("Researcher — Finds docs Model: fixed — Pro Group."))
    }

    func testAgentCallbackXMLRoundTrip() {
        let finished = AgentCallback(
            kind: .finished,
            jobId: "JOB123",
            childSessionId: "SESSION456",
            title: "Audit \" quotes & <tags>",
            status: "done",
            modelOrigin: "inherited",
            modelResolved: "OpenAI · GPT-5",
            agent: "Code Reviewer",
            elapsed: "1m05s",
            tool: nil,
            activity: nil,
            turn: 4,
            summary: "tools shell×2, read_file×1 · turns 4",
            body: "Line 1\nLine 2 with <tag> & \"quotes\"",
            siblings: "Other sub agents in this conversation: 1 running."
        )
        let xml = finished.xml
        XCTAssertTrue(AgentCallback.isCallbackText(xml))
        let parsed = AgentCallback.parse(xml)
        XCTAssertEqual(parsed, finished)

        let sched = AgentCallback(
            kind: .scheduled,
            jobId: "SCHED99",
            childSessionId: nil,
            title: "Check build",
            status: "running",
            modelOrigin: nil,
            modelResolved: nil,
            agent: nil,
            elapsed: nil,
            tool: nil,
            activity: nil,
            turn: nil,
            summary: nil,
            body: "[Scheduled task \"Check build\" · fire 2 · remaining 4]\nCheck CI status",
            siblings: nil,
            fireIndex: 2,
            remaining: 4,
            triggerLabel: "loop(600s×6)",
            nextFireAt: "2026-11-07T12:00:00Z"
        )
        XCTAssertEqual(AgentCallback.parse(sched.xml), sched)
    }

    func testScheduleDurationAndCronParsing() {
        XCTAssertEqual(ScheduleParser.parseDuration("30s"), 30)
        XCTAssertEqual(ScheduleParser.parseDuration("10m"), 600)
        XCTAssertEqual(ScheduleParser.parseDuration("1h30m"), 5400)
        XCTAssertEqual(ScheduleParser.parseDuration("2d"), 172_800)
        XCTAssertNil(ScheduleParser.parseDuration("invalid"))

        XCTAssertEqual(ScheduleParser.parseTimeOfDay("09:05")?.hour, 9)
        XCTAssertEqual(ScheduleParser.parseTimeOfDay("09:05")?.minute, 5)
        XCTAssertNil(ScheduleParser.parseTimeOfDay("25:00"))

        XCTAssertEqual(ScheduleParser.parseWeekdays(repeatMode: "weekdays", daysRaw: nil), [2, 3, 4, 5, 6])
        XCTAssertEqual(ScheduleParser.parseWeekdays(repeatMode: "custom", daysRaw: "mon, fri"), [2, 6])

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let base = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 22:13:20 UTC
        let next = ScheduleParser.nextCronDate(hour: 9, minute: 30, days: Set(1...7), from: base, calendar: cal)
        XCTAssertNotNil(next)
        XCTAssertGreaterThan(next!, base)
    }

    func testTargetDeliveryAndPresetToolCall() throws {
        let (target1, def1) = ScheduledTargetDelivery.resolveTarget(explicit: nil, session: nil, callerSession: "ABC")
        XCTAssertEqual(target1, "follow-up")
        XCTAssertTrue(def1)
        let s1 = ScheduledTargetDelivery.sentence(.followUp(sessionId: "ABCDEF1234", title: "Dev", isCallerSession: true), defaulted: true)
        XCTAssertTrue(s1.contains("IN THIS CHAT"))

        let preset = try ScheduledPresetToolCall.parse(command: "git status", timeoutSeconds: 30).get()
        XCTAssertEqual(preset?.command, "git status")
        XCTAssertEqual(preset?.timeoutSeconds, 30)

        if case .failure = ScheduledPresetToolCall.parse(command: "ls", timeoutSeconds: 99999) {} else {
            XCTFail("Expected timeout out-of-range error")
        }
    }

    func testChildConversationsExcludedFromSidebarAndSearch() {
        var parent = Conversation()
        parent.title = "Main Project"
        parent.messages = [ChatMessage(role: .user, content: "deploy alpha")]

        var child = Conversation()
        child.title = "🤖 Sub-agent"
        child.parentConversationID = parent.id
        child.messages = [ChatMessage(role: .user, content: "deploy alpha secret")]

        let grouped = SidebarGrouping.group([parent, child], folders: [])
        let allGroupedIDs = grouped.flatMap { $0.1.map(\.id) }
        XCTAssertEqual(allGroupedIDs, [parent.id])

        let hits = SessionSearch.search([parent, child], query: "alpha")
        XCTAssertEqual(hits.map(\.conversationID), [parent.id])
    }
}
