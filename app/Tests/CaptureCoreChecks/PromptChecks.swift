import Foundation
import CaptureCore

func checkPrompts(_ fixture: URL) throws {
    let root = fixture.appendingPathComponent("PromptLibrary")
    let store = try PromptStore(root: root)
    try store.seedIfNeeded()
    let initial = try store.loadAll()
    try require(initial.items.count == 25, "预置 Prompt 数量必须为 25")
    try require(initial.items.filter { $0.badge == PromptStore.kazikeBadge }.count == 10, "前 10 条必须标注为卡兹克精选")
    try require(initial.items.prefix(10).allSatisfy { $0.badge == PromptStore.kazikeBadge }, "1-10 条应全部带有卡兹克精选标注")
    try require(initial.items.dropFirst(10).allSatisfy { $0.badge == nil }, "非前 10 条不应误加卡兹克精选标注")
    try require(initial.categories == PromptStore.defaultCategories, "预置 4 个默认分类应一致")
    try require(initial.items.filter { $0.category == "深度思考" }.count == 12, "深度思考应有 12 条")
    try require(initial.items.filter { $0.category == "工程架构" }.count == 10, "工程架构应有 10 条")
    try require(initial.items.filter { $0.category == "产品体验" }.count == 1, "产品体验应有 1 条")
    try require(initial.items.filter { $0.category == "创意生成" }.count == 2, "创意生成应有 2 条")

    let first = initial.items[0]
    try store.delete(id: first.id)
    try store.seedIfNeeded()
    let afterDelete = try store.loadAll()
    try require(afterDelete.items.count == 24 && !afterDelete.items.contains(where: { $0.id == first.id }), "删除预置 Prompt 后重启不得复活")

    let created = try store.save(title: "自定义代码审查", category: "自定义分类", content: "逐行审查并发安全问题。")
    let reloaded = try store.loadAll()
    try require(reloaded.categories.contains("自定义分类"), "新建 Prompt 的新分类应自动注册")
    try require(reloaded.items.first?.id == created.id, "新建 Prompt 应排在最前")

    try store.renameCategory(from: "自定义分类", to: "代码评审")
    let renamed = try store.loadAll()
    try require(renamed.categories.contains("代码评审") && !renamed.categories.contains("自定义分类"), "分类重命名应同步分类列表")
    try require(renamed.items.first(where: { $0.id == created.id })?.category == "代码评审", "分类重命名应同步到所有关联 Prompt 文件")

    try store.deleteCategory("代码评审")
    let afterCategoryDelete = try store.loadAll()
    try require(afterCategoryDelete.items.first(where: { $0.id == created.id })?.category == PromptStore.defaultCategoryFallback, "删除分类后内容不得丢失，应归入未分类")

    let threeJS = try requireNotNil(afterCategoryDelete.items.first(where: { $0.title.contains("Three.js") }))
    try require(threeJS.content.contains("重庆洪崖洞") && threeJS.content.contains("5.主要物体"), "多行 Prompt 原文必须完整保留")

    // 模拟已安装旧版的存量库（无 badge，且第 3 条末尾无句号），升级后应幂等补标。
    let legacyRoot = fixture.appendingPathComponent("LegacyPromptLibrary")
    let legacyStore = try PromptStore(root: legacyRoot)
    let legacyPrompt = PromptItem(
        id: UUID(),
        title: "3. 旧版第3条",
        category: "深度思考",
        content: "不要默认我提出的问题定义就是正确的。你先分析我真正想解决的底层需求，判断我有没有把症状误认为原因、把手段误认为目标。如果存在更值得解决的问题，直接指出来",
        createdAt: "2026-11-17T00:00:00Z",
        updatedAt: "2026-11-17T00:00:00Z",
        sortOrder: 3
    )
    try PromptFormat.encode(legacyPrompt).write(to: legacyRoot.appendingPathComponent("Prompts/legacy.md"))
    try Data("1\n".utf8).write(to: legacyRoot.appendingPathComponent("Prompts/.seeded_v1"))
    try legacyStore.seedIfNeeded()
    let migrated = try legacyStore.loadAll()
    try require(migrated.items.count == 1, "存量升级不应复活其他已删条目")
    try require(migrated.items[0].badge == PromptStore.kazikeBadge, "存量卡兹克条目升级后应自动补标")
    try require(migrated.items[0].content.hasSuffix("直接指出来。"), "第 3 条应同步规范句号")

    print("PASS: 25 条预置 Prompt 幂等初始化、卡兹克 10 条精选标注与存量迁移、自定义增删改、分类操作与多行往返")
}

private func requireNotNil<T>(_ value: T?) throws -> T {
    guard let value else { throw NSError(domain: "Checks", code: 2, userInfo: [NSLocalizedDescriptionKey: "值不能为空"]) }
    return value
}
