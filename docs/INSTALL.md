# 安装与授权

## 安装

### 推荐：终端一行命令

```sh
curl -fsSL https://raw.githubusercontent.com/RichardPotter-Lai/catch-what-you-see-public/main/scripts/install-macos.sh | bash
```

脚本下载最新 Release 的 DMG 和 SHA256SUMS.txt，核对 SHA-256、应用签名、包标识与版本后安装并打开。默认使用 `/Applications`；目录不可写时使用 `~/Applications`。不会修改系统权限或 Gatekeeper 设置，也不碰你的资料库。想先看脚本内容，可以先下载再运行：

```sh
curl -fsSLO https://raw.githubusercontent.com/RichardPotter-Lai/catch-what-you-see-public/main/scripts/install-macos.sh
bash install-macos.sh --help
```

可选参数：`--upgrade`（替换已安装的旧版，旧版移到废纸篓）、`--version 0.1.1`、`--destination "$HOME/Applications"`、`--no-open`。通过管道运行时写成 `| bash -s -- --upgrade`。

用 curl 下载的文件不带浏览器加上的“隔离”标记，所以这样安装不会弹出“无法验证开发者”。

### 手动下载 DMG

从 [Releases](https://github.com/RichardPotter-Lai/catch-what-you-see-public/releases/latest) 下载 universal DMG 与 SHA256SUMS.txt，核对校验值后，将应用拖到 Applications，并从该目录启动。

### 首次打开被拦截

当前构建为 ad hoc 签名，没有 Developer ID 和 Apple 公证，所以从浏览器下载后首次打开，macOS 会提示“无法验证开发者”或“Apple 无法检查其是否包含恶意软件”。任选一种处理：

1. **系统设置**：先双击打开一次（会被拦），再到“系统设置 → 隐私与安全性”，页面底部点“仍要打开”，输入密码确认。macOS 15 起不再支持右键“打开”绕过。[Apple 说明](https://support.apple.com/102445)
2. **终端**：只清除这一个 App 的隔离标记（不会关闭 Gatekeeper）：

   ```sh
   xattr -dr com.apple.quarantine "/Applications/Catch what you see.app"
   ```

3. 改用上面的一行命令重新安装。

彻底消除这一步需要用 Apple Developer ID 签名并公证。`app/scripts/package-release.sh` 已支持：钥匙串中有 Developer ID 证书、并设置 `NOTARY_PROFILE`（`xcrun notarytool store-credentials` 创建的配置名）时，会自动签名、公证并装订 DMG。

目标为 macOS 14+。双架构包含 Apple 芯片与 Intel，但没有完成所有 Intel/旧系统实机验收。

## 交给桌面 Agent

[主页](../README.md#让-agent-帮你安装) 有可直接复制给 Codex 桌面版、Claude Code、WorkBuddy 的安装话术。执行任务的 Agent 需要能访问目标 Mac 的终端和文件；系统弹窗、密码或 Touch ID 由你本人完成。

Codex Cloud 通常在独立云端环境执行，见 [OpenAI 官方说明](https://learn.chatgpt.com/docs/environments/cloud-environments)。如果没有连接目标 Mac 的执行工具，可以让它准备命令，再交给本机 Agent。只在云端拉取源码不会完成本机安装。

## 升级

```sh
curl -fsSL https://raw.githubusercontent.com/RichardPotter-Lai/catch-what-you-see-public/main/scripts/install-macos.sh | bash -s -- --upgrade
```

脚本会正常退出正在运行的 Catch，把旧 App 移到废纸篓，再安装新版本。也可以手动：退出 Catch，下载新 DMG 并核对校验值，用 Finder 替换旧 App，从同一目录启动。

笔记保存在独立资料库中，替换 App 不需要删除资料库。更新后的临时签名可能需要重新完成辅助功能授权，处理方法见下文。不要同时运行多个副本或多个截图设置接管工具。

## 使用

- 选中文字后按下并松开 Option+C。
- 菜单可修改快捷键、关闭兼容复制，或显式收藏已有剪贴板文字。
- 显示晾衣绳：鼠标停在顶部菜单栏中部，或 Control+Option+T。
- 系统截图挂绳需显式启用；先退出其他正在接管系统截图设置的工具。

## 菜单栏图标

Catch 没有 Dock 图标，入口是菜单栏右侧的便笺图标（与应用图标同款，绳上有内容时变为实心）。首次启动会弹窗说明。看不到图标时：

- 刘海屏 Mac 的菜单栏图标过多时，部分图标会被刘海挡住。按住 Command 拖走其他图标腾出位置，或使用 Ice、Bartender 等菜单栏管理工具。
- macOS 26 及更新版本：“系统设置 → 菜单栏”中确认 Catch what you see 允许显示。
- 图标不可见时仍可用 Control+Option+T 拉下晾衣绳；在“应用程序”里再次打开 Catch 会打开资料库。

## 辅助功能授权与更新

Option+C 需要读取其他应用中的选区，必须开启 macOS 的“辅助功能”权限（macOS 27 中叫“设备控制和数据访问”）。应用会主动引导：

1. 首次启动、或按 Option+C 时尚未授权，Catch 会弹窗说明，点“去授权”；
2. 系统随即弹出授权提示，并把 Catch 加入权限列表，同时打开对应的系统设置页面；
3. 打开 Catch what you see 的开关，按提示输入密码或 Touch ID；
4. 开关打开后 Catch 会自动检测并提示“已获得权限”，无需重启。

菜单栏菜单中也有“授权辅助功能”入口，可随时再次打开引导。此系统权限的范围广于读取一段选中文字；应用仅在你主动收藏时按其采集流程使用。

如果升级后开关已开但仍提示无权限，系统可能仍保存旧临时签名指纹。正常退出 Catch，在列表中选中旧条目点“−”移除，再点“+”添加 /Applications/Catch what you see.app，重新打开。仅反复切换旧开关可能无效。不直接修改 TCC 数据库。

## 资料库

默认：

```text
~/Library/Application Support/CatchWhatYouSee/Library/
```

安装包不包含你的私人内容或权限。备份、迁移时正常退出应用，复制整个资料库，包括隐藏目录，再在新电脑选择该目录。

