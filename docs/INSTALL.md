# 安装与授权

## 安装

从本项目 [Releases](https://github.com/RichardPotter-Lai/catch-what-you-see-public/releases/latest) 下载 universal DMG 与 SHA256SUMS.txt，核对校验值后，将应用拖到 Applications，并从该目录启动。

目标为 macOS 14+。双架构包含 Apple 芯片与 Intel，但没有完成所有 Intel/旧系统实机验收。当前构建为 ad hoc 签名，没有 Developer ID 或 Apple 公证。若系统拦截，请确认来源后按“系统设置 → 隐私与安全性 → 仍要打开”的正常流程处理，不关闭 Gatekeeper。[Apple 说明](https://support.apple.com/102445)。

## 使用

- 选中文字后按下并松开 Option+C。
- 菜单可修改快捷键、关闭兼容复制，或显式收藏已有剪贴板文字。
- 显示晾衣绳：鼠标停在顶部菜单栏中部，或 Control+Option+T。
- 系统截图挂绳需显式启用；先退出其他正在接管系统截图设置的工具。

## 辅助功能授权与更新

按应用提示在系统权限列表中添加 Applications 内的 Catch。macOS 27 的入口叫“设备控制和数据访问”，其他版本可能叫“辅助功能”。此系统权限的范围广于读取一段选中文字；应用仅在主动收藏时按其采集流程使用。

如果升级后开关已开但仍提示无权限，系统可能仍保存旧临时签名指纹。正常退出 Catch，在列表移除旧 Catch，再添加 /Applications/Catch what you see.app，按系统提示验证并重新打开。仅反复切换旧开关可能无效。不直接修改 TCC 数据库。

## 资料库

默认：

```text
~/Library/Application Support/CatchWhatYouSee/Library/
```

安装包不包含你的私人内容或权限。备份、迁移时正常退出应用，复制整个资料库，包括隐藏目录，再在新电脑选择该目录。

