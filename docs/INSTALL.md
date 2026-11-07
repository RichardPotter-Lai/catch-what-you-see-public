# 安装与授权

## 安装

从本项目 [Releases](https://github.com/RichardPotter-Lai/catch-what-you-see-public/releases/latest) 下载 universal DMG 与 SHA256SUMS.txt，核对校验值后，将应用拖到 Applications，并从该目录启动。

目标为 macOS 14+。双架构包含 Apple 芯片与 Intel，但没有完成所有 Intel/旧系统实机验收。当前构建为 ad hoc 签名，没有 Developer ID 或 Apple 公证。若系统拦截，请确认来源后按“系统设置 → 隐私与安全性 → 仍要打开”的正常流程处理，不关闭 Gatekeeper。[Apple 说明](https://support.apple.com/102445)。

## 终端安装

在要使用这款应用的 Mac 上运行：

```sh
mkdir -p "$HOME/Downloads/Catch-what-you-see-install"
cd "$HOME/Downloads/Catch-what-you-see-install"
curl --fail --location --proto '=https' \
  https://raw.githubusercontent.com/RichardPotter-Lai/catch-what-you-see-public/main/scripts/install-macos.sh \
  --output install-macos.sh
bash install-macos.sh
```

脚本下载 0.1.1 的 DMG 和 SHA256SUMS.txt，核对 SHA-256、应用签名与版本后安装。默认使用 `/Applications`；目录不可写时使用 `~/Applications`。不会覆盖目标位置已有的 App，也不会更改你的收藏或系统授权。安装前可以自行阅读下载的脚本。

如需指定目录，或只安装、稍后自己打开：

```sh
bash install-macos.sh --destination "$HOME/Applications" --no-open
```

如果下载失败，确认能访问 GitHub 及其下载服务，再重试或手动下载 DMG。这里没有 Homebrew cask，也不要求为安装 App 配置 Swift 开发环境。

## 交给桌面 Agent

[主页](../README.md#让-agent-帮你安装) 有可直接复制给 Codex 桌面版、Claude Code、WorkBuddy 的安装话术。执行任务的 Agent 需要能访问目标 Mac 的终端和文件；系统弹窗、密码或 Touch ID 由你本人完成。

Codex Cloud 通常在独立云端环境执行，见 [OpenAI 官方说明](https://learn.chatgpt.com/docs/environments/cloud-environments)。如果没有连接目标 Mac 的执行工具，可以让它准备命令，再交给本机 Agent。只在云端拉取源码不会完成本机安装。

## 升级

先正常退出正在运行的 Catch。确认现有 App 的实际路径，从 Releases 下载新 DMG 并核对校验值，再用 Finder 替换该目录中的旧 App，从同一目录启动。终端安装脚本会在同名 App 存在时停止，避免直接覆盖。

笔记保存在独立资料库中，替换 App 不需要删除资料库。更新后的临时签名可能需要重新完成辅助功能授权，处理方法见下文。不要同时运行多个副本或多个截图设置接管工具。

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

