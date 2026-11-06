import Foundation
import SwiftUI

// Memory / SOUL / skills state wiring (upstream MemoryTools, SoulStore, SkillStore session overrides).

extension AppStore {
    // MARK: - Memory switch

    /// Session value when set, otherwise the global default (upstream memory.global.enabled).
    func memoryEnabled(_ id: UUID?) -> Bool {
        if let id, let v = conversation(id)?.memoryEnabled { return v }
        return settings.memoryDefault
    }

    func setMemory(_ on: Bool, for id: UUID) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[i].memoryEnabled = on
        saveConversations()
    }

    /// `/memory` slash command: toggles memory for this conversation and leaves a local notice.
    /// Returns true when `text` was a slash command and must not be sent to the model.
    func handleSlash(_ text: String, in id: UUID) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard t == "/memory" || t == "/memory on" || t == "/memory off" else { return false }
        let on: Bool = t.hasSuffix(" on") ? true : t.hasSuffix(" off") ? false : !memoryEnabled(id)
        setMemory(on, for: id)
        if let i = conversations.firstIndex(where: { $0.id == id }) {
            let note = on ? "本会话已开启记忆：会注入 GLOBAL.md 和最近日志，并提供 memory_write / memory_get。"
                          : "本会话已关闭记忆：不注入记忆，也不提供记忆工具（SOUL 人格不受影响）。"
            conversations[i].messages.append(ChatMessage(role: .assistant, content: note, isError: true))
            saveConversations()
        }
        return true
    }

    // MARK: - Skills

    func reloadSkills() {
        var m = SkillLibrary.scan(SkillLibrary.loadMeta())
        SkillLibrary.installBundled(&m)
        m = SkillLibrary.scan(m)
        SkillLibrary.saveMeta(m)
        skills = m.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Session override when present, otherwise the global switch.
    func isSkillEnabled(_ sid: String, in id: UUID?) -> Bool {
        if let id, let v = conversation(id)?.skillOverrides[sid] { return v }
        return skills.first { $0.id == sid }?.isEnabled ?? false
    }

    func enabledSkills(_ id: UUID?) -> [SkillMeta] {
        skills.filter { isSkillEnabled($0.id, in: id) }
    }

    func setSkillGlobal(_ sid: String, enabled: Bool) {
        guard let i = skills.firstIndex(where: { $0.id == sid }) else { return }
        skills[i].isEnabled = enabled
        SkillLibrary.saveMeta(skills)
    }

    /// Writing the same value as the global switch removes the override (upstream setSessionOverride).
    func setSkillOverride(_ sid: String, enabled: Bool, in id: UUID) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        let global = skills.first { $0.id == sid }?.isEnabled ?? false
        conversations[i].skillOverrides[sid] = enabled == global ? nil : enabled
        saveConversations()
    }

    func setAllSkills(_ enabled: Bool, in id: UUID) {
        for s in skills { setSkillOverride(s.id, enabled: enabled, in: id) }
    }

    func deleteSkill(_ sid: String) {
        try? FileManager.default.removeItem(at: SkillLibrary.dir(sid))
        for i in conversations.indices { conversations[i].skillOverrides[sid] = nil }
        reloadSkills()
    }

    /// read → use_count +1 (normalized to 0–100 once any count passes 1000); write → rescan.
    func skillTouched(_ sid: String, wrote: Bool) {
        if wrote { reloadSkills(); return }
        guard let i = skills.firstIndex(where: { $0.id == sid }) else { return }
        skills[i].useCount += 1
        if let top = skills.map(\.useCount).max(), top > 1000 {
            for k in skills.indices { skills[k].useCount = skills[k].useCount * 100 / top }
        }
        SkillLibrary.saveMeta(skills)
    }

    /// Relative usage tier shown in the skills list.
    func usageTier(_ s: SkillMeta) -> String {
        let top = max(1, skills.map(\.useCount).max() ?? 1)
        let r = Double(s.useCount) / Double(top) * 100
        if s.useCount == 0 { return "未使用" }
        return r < 20 ? "低频" : r < 60 ? "常用" : "高频"
    }
}
