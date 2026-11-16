import Foundation
import Darwin

public struct PromptItem: Identifiable, Equatable {
    public var id: UUID
    public var title: String
    public var category: String
    public var badge: String?
    public var content: String
    public var createdAt: String
    public var updatedAt: String
    public var sortOrder: Int
    public var url: URL?

    public init(id: UUID = UUID(), title: String, category: String, badge: String? = nil, content: String,
                createdAt: String = "", updatedAt: String = "", sortOrder: Int = 0, url: URL? = nil) {
        self.id = id
        self.title = title
        self.category = category
        self.badge = badge.flatMap { let clean = $0.trimmingCharacters(in: .whitespacesAndNewlines); return clean.isEmpty ? nil : clean }
        self.content = content
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sortOrder = sortOrder
        self.url = url
    }
}

public enum PromptFormat {
    public enum Invalid: Error { case malformed, unsupported }
    private static let requiredKeys = ["id", "title", "category", "created_at", "updated_at"]

    public static func encode(_ item: PromptItem) throws -> Data {
        let title = item.title.trimmingCharacters(in: .newlines)
        let category = item.category.trimmingCharacters(in: .newlines)
        guard !title.isEmpty, !category.isEmpty else { throw Invalid.unsupported }
        let encoder = JSONEncoder()
        var pairs: [(String, String)] = [
            ("id", item.id.uuidString),
            ("title", title),
            ("category", category),
            ("created_at", item.createdAt),
            ("updated_at", item.updatedAt),
        ]
        if let badge = item.badge?.trimmingCharacters(in: .whitespacesAndNewlines), !badge.isEmpty {
            pairs.append(("badge", badge))
        }
        var header = "---\ncwsy_prompt_version: 1\n"
        for (key, value) in pairs {
            let escaped = String(decoding: try encoder.encode(value), as: UTF8.self)
            header += "\(key): \(escaped)\n"
        }
        header += "sort_order: \(item.sortOrder)\n---\n\n"
        return Data((header + item.content).utf8)
    }

    public static func decode(_ data: Data, url: URL? = nil) throws -> PromptItem {
        guard let text = String(data: data, encoding: .utf8), text.hasPrefix("---\n"),
              let end = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex)
        else { throw Invalid.malformed }

        let header = text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound]
        var fields: [String: String] = [:]
        var sortOrder = 0
        for line in header.components(separatedBy: "\n") where !line.isEmpty {
            guard let sep = line.range(of: ": ") else { throw Invalid.malformed }
            let key = String(line[..<sep.lowerBound])
            let raw = String(line[sep.upperBound...])
            if key == "cwsy_prompt_version" {
                guard raw == "1" else { throw Invalid.unsupported }
                fields[key] = raw
            } else if key == "sort_order" {
                guard let parsed = Int(raw) else { throw Invalid.malformed }
                sortOrder = parsed
            } else if requiredKeys.contains(key) || key == "badge" {
                guard let decoded = try? JSONDecoder().decode(String.self, from: Data(raw.utf8)) else {
                    throw Invalid.malformed
                }
                fields[key] = decoded
            }
        }
        guard fields["cwsy_prompt_version"] == "1",
              let id = fields["id"].flatMap(UUID.init(uuidString:)),
              let title = fields["title"], !title.isEmpty,
              let category = fields["category"], !category.isEmpty,
              let createdAt = fields["created_at"],
              let updatedAt = fields["updated_at"]
        else { throw Invalid.malformed }

        var body = String(text[end.upperBound...])
        if body.hasPrefix("\n") { body.removeFirst() }
        return PromptItem(
            id: id,
            title: title,
            category: category,
            badge: fields["badge"],
            content: body,
            createdAt: createdAt,
            updatedAt: updatedAt,
            sortOrder: sortOrder,
            url: url
        )
    }
}

public final class PromptStore {
    public enum Failure: Error { case unsafePath, invalidInput, notFound, conflict }

    public static let defaultCategoryFallback = "未分类"
    public static let defaultCategories = ["深度思考", "工程架构", "产品体验", "创意生成"]
    public static let kazikeBadge = "卡兹克精选"

    public let root: URL
    public let folder: URL
    private let categoriesFile: URL
    private let seedMarker: URL
    private let kazikeBadgeMarker: URL
    private let lockFile: URL
    private let fm = FileManager.default

    public init(root: URL) throws {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.folder = self.root.appendingPathComponent("Prompts", isDirectory: true)
        self.categoriesFile = folder.appendingPathComponent(".categories.json")
        self.seedMarker = folder.appendingPathComponent(".seeded_v1")
        self.kazikeBadgeMarker = folder.appendingPathComponent(".seeded_v2_kazike")
        self.lockFile = folder.appendingPathComponent(".cwsy-prompts.lock")
        try checkPath(folder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try checkPath(categoriesFile)
        try checkPath(seedMarker)
        try checkPath(kazikeBadgeMarker)
        try checkPath(lockFile)
    }

    private func checkPath(_ url: URL) throws {
        let resolved = url.resolvingSymlinksInPath()
        guard resolved.path == url.standardizedFileURL.path,
              (resolved.path == root.path || resolved.path.hasPrefix(root.path + "/")) else {
            throw Failure.unsafePath
        }
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        try checkPath(lockFile)
        let fd = open(lockFile.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw Failure.unsafePath }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw Failure.unsafePath }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    private func commit(_ data: Data, to destination: URL) throws {
        try checkPath(destination)
        let staging = folder.appendingPathComponent(".staging-" + UUID().uuidString)
        try data.write(to: staging, options: .withoutOverwriting)
        defer { try? fm.removeItem(at: staging) }
        let handle = try FileHandle(forWritingTo: staging)
        defer { try? handle.close() }
        try handle.synchronize()
        guard rename(staging.path, destination.path) == 0 else { throw Failure.unsafePath }
    }

    private func nowISO() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    public func seedIfNeeded() throws {
        try locked {
            if !fm.fileExists(atPath: seedMarker.path) {
                let existing = try listItemsLocked()
                if existing.isEmpty {
                    let timestamp = nowISO()
                    for (index, preset) in Self.presetPrompts.enumerated() {
                        let item = PromptItem(
                            id: UUID(),
                            title: preset.title,
                            category: preset.category,
                            badge: preset.badge,
                            content: preset.content,
                            createdAt: timestamp,
                            updatedAt: timestamp,
                            sortOrder: index + 1
                        )
                        try writeItemLocked(item)
                    }
                    if !fm.fileExists(atPath: categoriesFile.path) {
                        try writeCategoriesLocked(Self.defaultCategories)
                    }
                }
                try commit(Data("1\n".utf8), to: seedMarker)
            }
            if !fm.fileExists(atPath: kazikeBadgeMarker.path) {
                try applyKazikeBadgesToExistingLocked()
                try commit(Data("1\n".utf8), to: kazikeBadgeMarker)
            }
        }
    }

    private func applyKazikeBadgesToExistingLocked() throws {
        let kazikePresets = Self.presetPrompts.filter { $0.badge == Self.kazikeBadge }
        let normalizedMap: [String: Preset] = Dictionary(uniqueKeysWithValues: kazikePresets.map {
            (Self.normalizeForBadgeMatch($0.content), $0)
        })
        for var item in try listItemsLocked() {
            let key = Self.normalizeForBadgeMatch(item.content)
            guard let matched = normalizedMap[key] else { continue }
            var changed = false
            if item.badge == nil {
                item.badge = matched.badge
                changed = true
            }
            if item.content != matched.content {
                item.content = matched.content
                changed = true
            }
            if changed {
                _ = try writeItemLocked(item)
            }
        }
    }

    private static func normalizeForBadgeMatch(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "。.")))
    }

    public func loadAll() throws -> (categories: [String], items: [PromptItem]) {
        try locked {
            let items = try listItemsLocked()
            var categories = readCategoriesLocked()
            for item in items where !categories.contains(item.category) {
                categories.append(item.category)
            }
            return (categories, items)
        }
    }

    @discardableResult
    public func save(id: UUID? = nil, title: String, category: String, badge: String? = nil, content: String) throws -> PromptItem {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBadge = badge?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalBadge = (cleanBadge?.isEmpty == false) ? cleanBadge : nil
        let cleanContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, !cleanCategory.isEmpty, !cleanContent.isEmpty else {
            throw Failure.invalidInput
        }
        return try locked {
            let items = try listItemsLocked()
            let now = nowISO()
            let item: PromptItem
            if let id, let existing = items.first(where: { $0.id == id }) {
                item = PromptItem(
                    id: existing.id,
                    title: cleanTitle,
                    category: cleanCategory,
                    badge: finalBadge,
                    content: content,
                    createdAt: existing.createdAt,
                    updatedAt: now,
                    sortOrder: existing.sortOrder,
                    url: existing.url
                )
            } else {
                let minOrder = (items.map(\.sortOrder).min() ?? 1) - 1
                item = PromptItem(
                    id: id ?? UUID(),
                    title: cleanTitle,
                    category: cleanCategory,
                    badge: finalBadge,
                    content: content,
                    createdAt: now,
                    updatedAt: now,
                    sortOrder: minOrder
                )
            }
            let targetURL = try writeItemLocked(item)
            var categories = readCategoriesLocked()
            if !categories.contains(cleanCategory) {
                categories.append(cleanCategory)
                try writeCategoriesLocked(categories)
            }
            var saved = item
            saved.url = targetURL
            return saved
        }
    }

    public func delete(id: UUID) throws {
        try locked {
            let items = try listItemsLocked()
            guard let target = items.first(where: { $0.id == id }), let url = target.url else {
                throw Failure.notFound
            }
            try checkPath(url)
            try fm.removeItem(at: url)
        }
    }

    public func addCategory(_ name: String) throws {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw Failure.invalidInput }
        try locked {
            var categories = readCategoriesLocked()
            guard !categories.contains(clean) else { throw Failure.conflict }
            categories.append(clean)
            try writeCategoriesLocked(categories)
        }
    }

    public func renameCategory(from oldName: String, to newName: String) throws {
        let cleanOld = oldName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanNew = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanOld.isEmpty, !cleanNew.isEmpty, cleanOld != cleanNew else {
            throw Failure.invalidInput
        }
        try locked {
            var categories = readCategoriesLocked()
            guard !categories.contains(cleanNew) else { throw Failure.conflict }
            if let idx = categories.firstIndex(of: cleanOld) {
                categories[idx] = cleanNew
            } else {
                categories.append(cleanNew)
            }
            try writeCategoriesLocked(categories)

            let now = nowISO()
            for var item in try listItemsLocked() where item.category == cleanOld {
                item.category = cleanNew
                item.updatedAt = now
                _ = try writeItemLocked(item)
            }
        }
    }

    public func deleteCategory(_ name: String) throws {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw Failure.invalidInput }
        try locked {
            var categories = readCategoriesLocked()
            categories.removeAll { $0 == clean }
            let items = try listItemsLocked()
            let affected = items.filter { $0.category == clean }
            if !affected.isEmpty {
                let fallback = clean == Self.defaultCategoryFallback ? "默认" : Self.defaultCategoryFallback
                if !categories.contains(fallback) { categories.append(fallback) }
                let now = nowISO()
                for var item in affected {
                    item.category = fallback
                    item.updatedAt = now
                    _ = try writeItemLocked(item)
                }
            }
            try writeCategoriesLocked(categories)
        }
    }

    private func readCategoriesLocked() -> [String] {
        guard let data = try? Data(contentsOf: categoriesFile),
              let parsed = try? JSONDecoder().decode([String].self, from: data),
              !parsed.isEmpty else {
            return Self.defaultCategories
        }
        return parsed
    }

    private func writeCategoriesLocked(_ categories: [String]) throws {
        let data = try JSONEncoder().encode(categories)
        try commit(data, to: categoriesFile)
    }

    @discardableResult
    private func writeItemLocked(_ item: PromptItem) throws -> URL {
        let url = item.url ?? folder.appendingPathComponent(item.id.uuidString.lowercased() + ".md")
        try checkPath(url)
        let data = try PromptFormat.encode(item)
        try commit(data, to: url)
        return url
    }

    private func listItemsLocked() throws -> [PromptItem] {
        try checkPath(folder)
        let contents = try fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var result: [PromptItem] = []
        for entry in contents {
            let values = try entry.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isSymbolicLink != true else { continue }
            if values.isDirectory == true || entry.pathExtension.lowercased() != "md" { continue }
            let url = entry.resolvingSymlinksInPath()
            try checkPath(url)
            if let data = try? Data(contentsOf: url),
               let item = try? PromptFormat.decode(data, url: url) {
                result.append(item)
            }
        }
        return result.sorted {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private struct Preset {
        let title: String
        let category: String
        let badge: String?
        let content: String
        init(title: String, category: String, badge: String? = nil, content: String) {
            self.title = title; self.category = category; self.badge = badge; self.content = content
        }
    }

    private static let presetPrompts: [Preset] = [
        Preset(
            title: "1. 第一性原理找本质并修复",
            category: "深度思考",
            badge: kazikeBadge,
            content: "从第一性原理出发，找到最本质原因，修复一下。"
        ),
        Preset(
            title: "2. 对齐需求后出 3 版方案",
            category: "深度思考",
            badge: kazikeBadge,
            content: "先问一些不清晰的问题，对齐我的喜好，然后再出3版方案。"
        ),
        Preset(
            title: "3. 质疑问题定义、拆解底层需求",
            category: "深度思考",
            badge: kazikeBadge,
            content: "不要默认我提出的问题定义就是正确的。你先分析我真正想解决的底层需求，判断我有没有把症状误认为原因、把手段误认为目标。如果存在更值得解决的问题，直接指出来。"
        ),
        Preset(
            title: "4. 推演二阶、三阶系统影响",
            category: "深度思考",
            badge: kazikeBadge,
            content: "不要只考虑这个改动产生的直接效果。继续推演它的二阶、三阶影响，尤其关注对其他模块、用户行为、系统复杂度和长期维护成本的潜在影响。"
        ),
        Preset(
            title: "5. 跨领域类比寻找最优解",
            category: "深度思考",
            badge: kazikeBadge,
            content: "其他领域里有没有类似的方案，用跨领域的方式全面思考，找到最优解。"
        ),
        Preset(
            title: "6. 最强反对者红队反证",
            category: "深度思考",
            badge: kazikeBadge,
            content: "先假设你当前认为最合理的方案是错误的。站在最强反对者的角度，寻找能够推翻它的证据、反例和边界情况。然后重新评估方案，看看有没有更好的解法。"
        ),
        Preset(
            title: "7. Git 历史演变与历史包袱识别",
            category: "工程架构",
            badge: kazikeBadge,
            content: "深入分析整个代码库的Git历史、关键PR和架构演变过程。找出哪些设计是有意为之，哪些是历史遗留，哪些是为了解决已经不存在的问题而引入的。识别可以安全移除的历史包袱。"
        ),
        Preset(
            title: "8. 新工程师接手认知成本评估",
            category: "工程架构",
            badge: kazikeBadge,
            content: "假设明天有一个完全不了解项目、但是能力很强的工程师来接手。请评估他理解整个项目需要付出的认知成本，找出那些命名混乱、抽象过度、职责不清晰、需要大量上下文才能理解的代码，并提出简化方案。"
        ),
        Preset(
            title: "9. 分析近期 PR 性能瓶颈与卡顿",
            category: "工程架构",
            badge: kazikeBadge,
            content: "全面分析最近XX天里的所有的PR，找出最慢的那几个，看看有没有导致卡顿、可以优化的地方。"
        ),
        Preset(
            title: "10. 复盘 Bug 与返工并沉淀规则",
            category: "工程架构",
            badge: kazikeBadge,
            content: "全面复盘最近XX时间的 Bug、返工、回滚和重复修改。不要只统计发生了什么，要分析这些问题背后有没有共同的根因。把能够预防的共性问题沉淀成项目规则、自动化或者Skill，避免我们反复支付同样的成本。"
        ),
        Preset(
            title: "11. 独立重估既有设计取舍",
            category: "深度思考",
            content: "请重新回顾此前围绕 XXXXX 的设计讨论，独立重新评估该设计的取舍，并判断什么才是最佳方案；不要因为那些建议由我提出就倾向于接受，也不要为了迎合我而让步。给出你独立得出的推荐设计，说明理由、关键取舍和仍存在的不确定点或需要补充验证的信息。"
        ),
        Preset(
            title: "12. 跨领域搜索经典问题变体",
            category: "深度思考",
            content: "我的想法或目前存在的问题是否是其他领域经典问题的变体，有无成熟的解决方案，请进行跨领域的广度搜索核实这一点。"
        ),
        Preset(
            title: "13. 独立核验定位多方共错",
            category: "深度思考",
            content: "如果其他几方都错了，你这次做的哪项独立核验，有机会发现那个错误。"
        ),
        Preset(
            title: "14. 一手材料起手四问与任务改写",
            category: "深度思考",
            content: "动手前先去看一手材料，再答四问——这一行顶尖的人会多做哪一步（不做会错在哪）、从哪些能定位到的原件起手（不要汇总和别人的结论）、用什么叫得出名字的方法和工具、你我之外什么会说「不」的东西能证明结果对（写明什么结果算失败）——然后据此把任务改写成「交付物不变多、形态不变，只多出来源、方法和验证」的版本，给我看过点头后再做。"
        ),
        Preset(
            title: "15. 事实与推理讨论原则",
            category: "深度思考",
            content: "请在与我的讨论和回答中遵循以下原则：以事实、证据和合理推理为依据，不因我的立场或偏好而迎合我，也不为反对而反对。如果我的观点、前提或推理存在问题，请直接指出并说明理由；依据不足或存在不确定性时，请明确说明，区分事实、推断与意见。表达应简洁、专业、重点突出，同时保留必要的解释和限定条件。"
        ),
        Preset(
            title: "16. 不编造问题原则",
            category: "深度思考",
            content: "不要为了找问题，自己编造。"
        ),
        Preset(
            title: "17. 清理上下文噪声保留正向流程",
            category: "工程架构",
            content: "请检查刚刚的任务，确保任务中不留存非必要的上下文噪声、历史返工噪声，仅保留正向流程。"
        ),
        Preset(
            title: "18. 用户视角 UI/UX 极简化优化",
            category: "产品体验",
            content: "从用户体验的视角，去对整体产品UI、UX设计做优化，去掉无用说明、改掉用户不懂的晦涩文字、最大程度简化用户操作，优化后使产品达到可交付的标准状态。"
        ),
        Preset(
            title: "19. 保持简单与最短可验证路径",
            category: "工程架构",
            content: "保持简单，优先现成工具和最短可验证路径，新增复杂度必须有收益。"
        ),
        Preset(
            title: "20. 任务统筹与并串行调度",
            category: "工程架构",
            content: "需求：xxxx，你来负责任务整体的统筹规划和确认验收，能并行的并行，不能并行的串行。"
        ),
        Preset(
            title: "21. 低熵正向流程运行",
            category: "工程架构",
            content: "尽量保证低熵运行，确保任务中不留存非必要的上下文噪声、历史返工噪声，仅保留正向流程。"
        ),
        Preset(
            title: "22. 重复错误分级防错体系",
            category: "工程架构",
            content: "当同一类错误反复出现时，请按以下优先级寻找解决办法：首先改进代码或工作流程的结构、接口和约束，让正确做法更容易发生，让错误更难发生；其次通过类型、自动检查或测试及时拦截错误；再用简洁的文档、规则或 Skill 补充需要判断的部分；最后将关键取舍和未被覆盖的例外留给人工审查。根据问题的频率、影响和改进成本，选择最小且有效的措施，并验证它确实能阻止已发生过的错误，逐步减少重复人工纠正，避免为此引入不必要的复杂度。"
        ),
        Preset(
            title: "23. 外循环定义、内循环完成推进",
            category: "工程架构",
            content: "请按“外循环定义工作、内循环完成工作”的方式推进任务：在外循环中，从已有资料、反馈和讨论中识别真正的问题，明确目标、优先级、范围和可检查的完成条件；进入内循环后，依次核实或复现问题、实施改动、检查实际结果，并根据证据继续修正。达到完成条件后，将交付物、验证证据和遗留问题带回外循环，再依据实际反馈确定下一步。执行中的发现如果改变了问题定义或任务范围，应回到外循环重新判断。常规且已获授权的工作自主推进，关键取舍或超出授权的行动交给我决定；先让内循环可靠，再逐步扩大自动化范围。"
        ),
        Preset(
            title: "24. Three.js 单文件 3D 场景生成",
            category: "创意生成",
            content: """
            帮我做一个单文件的HTML网页，用Three.js实现一个可以自由浏览的3D场景。
            场景是：【你想要的画面，越具体越好。比如：重庆洪崖洞的夜景，层层叠叠的吊脚楼亮着暖黄色的灯，前面是嘉陵江，江上有游船，旁边是千厮门大桥，远处是城市的楼群】
            要求：
            1.所有模型和贴图都用代码生成，不要引用任何外部的图片和模型文件。
            2.支持鼠标拖动旋转视角、滚轮缩放。
            3.画面要有氛围感，重点处理光照、雾气和色调。
            4.在普通的笔记本上也要流畅，加载的时候显示进度。
            5.主要物体，都做成独立的组件，方便我后面单独修改。
            """
        ),
        Preset(
            title: "25. 子 Agent 挑剔美术指导逐轮迭代",
            category: "创意生成",
            content: """
            每改完一版，用浏览器打开它，从几个固定的角度各截一张图。
            再开一个子Agent，只给它看截图，不给它看代码，让它以一个挑剔的美术指导的角度，按严重程度列出画面问题。
            你按它的意见改，一直改到它只剩小问题为止。
            """
        ),
    ]
}
