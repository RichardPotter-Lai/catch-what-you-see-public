<p align="center"><img src="docs/assets/icon.png" width="80" alt="Catch what you see"></p>

# Catch what you see

[中文](#catch-what-you-see) · [English](#english)

基于 [Tendedero](https://github.com/alejandrobujan/tendedero) 做的一个改版，主要加了文字收藏和 Markdown 笔记。

原项目会把截图挂在屏幕上方的晾衣绳上。我很喜欢这个设计，也想把读文章时选中的几句话放上去，于是在原有代码上加了文字采集。现在，截图和文字便笺可以挂在同一根绳上，想再看或复制时，把晾衣绳拉下来就行。

[下载](https://github.com/RichardPotter-Lai/catch-what-you-see-public/releases/latest) · [安装说明](docs/INSTALL.md)

## 安装

需要 macOS 14 或更新版本。到 [Releases](https://github.com/RichardPotter-Lai/catch-what-you-see-public/releases/latest) 下载 `.dmg`，打开后把应用拖到 Applications。安装包同时包含 Apple 芯片和 Intel 版本。

也可以在 Mac 的终端里运行下面几行，不需要 Homebrew 或 Swift。脚本会下载 0.1.1 安装包、核对 SHA-256，再复制并打开应用；目标位置已有同名应用时会停止。

```sh
mkdir -p "$HOME/Downloads/Catch-what-you-see-install"
cd "$HOME/Downloads/Catch-what-you-see-install"
curl --fail --location --proto '=https' \
  https://raw.githubusercontent.com/RichardPotter-Lai/catch-what-you-see-public/main/scripts/install-macos.sh \
  --output install-macos.sh
bash install-macos.sh
```

脚本默认安装到 `/Applications`，目录不可写时使用 `~/Applications`。可以先打开下载的脚本看看。首次打开可能需要在“系统设置 → 隐私与安全性”中确认来源，文字收藏还需要辅助功能授权，具体见[安装与升级](docs/INSTALL.md)。

## 让 Agent 帮你安装

在要安装的那台 Mac 上，把下面这段发给 Codex 桌面版、Claude Code，或已经具备本机终端与文件权限的 WorkBuddy：

```text
请帮我在这台 Mac 上安装并打开 Catch what you see：
https://github.com/RichardPotter-Lai/catch-what-you-see-public

先阅读仓库 README.md 和 docs/INSTALL.md，确认系统为 macOS 14+。
优先安装 Releases 的 universal DMG，核对 SHA256SUMS.txt；可以使用仓库的 scripts/install-macos.sh。
如果本机已有安装，先核对路径和版本，保留我的资料库，告诉我是否需要升级。
不要修改系统权限数据库、关闭 Gatekeeper，或上传我的笔记、截图和剪贴板。
安装后从实际安装目录打开应用，说明 Option+C 怎么用。需要我完成的系统确认或 Touch ID 验证，请指出具体步骤。
只有真实完成安装和启动后才报告成功；若没有本机执行能力，请把可执行命令和待我完成的步骤列出来。
```

如果你用的是 **Codex Cloud**，任务通常在云端环境执行。安装这个 macOS 应用需要目标 Mac 的本机执行能力；仅拉取仓库到云端不会把 App 装到你的电脑上。云端可以先帮你读代码、整理安装步骤，下面这段适合发给它：

```text
请读取 https://github.com/RichardPotter-Lai/catch-what-you-see-public 的 README.md 和 docs/INSTALL.md，
为我的 Mac 整理安装步骤、下载地址、校验方法，以及可交给本机 Agent 的安装指令。
先确认你是否能执行目标 Mac 上的命令；如果只能在云端运行，就交付步骤，不要声称已经替我安装或测试了 macOS 界面。
```

WorkBuddy 的具体操作取决于你给它开放的工具。上面的文字是任务说明，不会替 Agent 增加本机权限。Codex Cloud 的执行方式可参阅 [OpenAI 官方说明](https://learn.chatgpt.com/docs/environments/cloud-environments)。

## 怎么用

选中一段文字，按下并松开 **Option+C**。保存成功后，屏幕顶部会挂上一张便笺，完整文字写入本地 Markdown 文件。

把鼠标停在顶部菜单栏中部，或按 **Control+Option+T**，就能展开晾衣绳。单击便笺复制正文；双击打开对应的 MD。截图沿用 macOS 原来的快捷键，先临时挂上，需要留下时再点收藏。

有些软件可以复制文字，却不提供系统选区。遇到这种情况，Catch 可以尝试复制一次，取到新文字后尽力还原原剪贴板。这个后备方式可以关掉。也可以自己先复制，再从菜单选择“收藏剪贴板文字”。

## 文字和图片怎么保存

每次主动收藏都是一份独立的 `.md`。图片放在附件目录，通过相对路径引用。默认资料库在：

```text
~/Library/Application Support/CatchWhatYouSee/Library/
```

你可以用自己的 Markdown 编辑器改摘录、补笔记，Catch 会重新读取。卡片上只显示摘要，文件里保留完整内容。

收起卡片不会删文档。绳子满了也只影响显示；没收藏的截图不会自动到期，要自己清理。需要找旧内容时，可以打开资料库搜索和预览。删除笔记与收起是分开的，误删后可从资料库回收站恢复。

## 这个改版加了什么

截图、晾衣绳、夹子和原来的动画交互来自 Tendedero。在这些基础上，这里主要增加了：

- Option+C 收藏选中文字，以及受控复制后备和剪贴板收藏入口。
- 文字便笺、Markdown 文件保存，以及本地搜索、预览和外部编辑刷新。
- 文字与图片共用的删除、回收和恢复流程。

保留了晾衣绳的样子，也补了悬停时的小幅摆动、删除音效和半秒提示。

## 安装前看一下

构建目标是 **macOS 14+**。安装包包含 Apple 芯片和 Intel 架构；目前我在 Apple 芯片 Mac 上测试过微信和常用网页，能够正常收藏。不同软件的选区和复制方式不一样，PDF 和其他控件还需要逐项验证，见 [兼容性记录](docs/COMPATIBILITY.md)。

不使用 OCR。图片或扫描件里没有可选文字时，按截图保存。

当前界面为简体中文。安装包是临时签名，没有 Apple Developer ID 和公证。首次打开、辅助功能授权，以及更新后“开关已开却仍提示无权限”的处理，写在 [安装说明](docs/INSTALL.md)。

## 关于隐私

笔记和截图保存在本机，应用没有内容上传、账户或分析服务。剪贴板只在你主动收藏时读取，不记录剪贴板历史。

复制后备的旧内容只在内存中短暂备份。检测到你又复制了别的内容时，会保留新内容；系统没有跨进程原子回滚，还原只能尽力而为。更多细节见 [隐私说明](docs/PRIVACY.md)。

## 从源码构建

需要 Mac 和 Swift 工具链：

```sh
git clone https://github.com/RichardPotter-Lai/catch-what-you-see-public.git
cd catch-what-you-see-public/app
swift run CaptureCoreChecks
swift build -c debug
bash scripts/build-app.sh debug
```

开发时用隔离资料库，具体方法见 [开发说明](docs/DEVELOPMENT.md)。遇到兼容性问题，欢迎用无敏感内容的例子提交 Issue。提交代码前可先看 [贡献说明](CONTRIBUTING.md)。

## 来源和许可

原项目是 Alejandro Buján 的 [Tendedero](https://github.com/alejandrobujan/tendedero)，本项目基于其 1.8.1 代码修改。感谢原作者把这套截图晾衣绳做出来并开放代码。

代码沿用 [MIT 许可](LICENSE)，保留上游版权声明。Catch 使用自己的名称和新绘制的图标。上游名称、图标及原始宣传图片不在其 MIT 授权范围内，这份公开源码快照没有包含这些素材。[第三方声明](THIRD_PARTY_NOTICES.md) 中列出了来源和许可范围。

## English

<details>
<summary>Read in English / 展开英文介绍</summary>

A modification of [Tendedero](https://github.com/alejandrobujan/tendedero), adding text collection and Markdown notes.

Tendedero hangs screenshots on a clothesline at the top of the screen. I liked that idea and wanted to put selected passages there too. This version keeps the original screenshot interaction and lets text notes hang beside the images.

[Download](https://github.com/RichardPotter-Lai/catch-what-you-see-public/releases/latest) · [Install](docs/INSTALL.md)

## Install

On macOS 14+, download the universal DMG from [Releases](https://github.com/RichardPotter-Lai/catch-what-you-see-public/releases/latest), open it, and drag the app to Applications. Or download and run the installer in your Mac's terminal:

```sh
mkdir -p "$HOME/Downloads/Catch-what-you-see-install"
cd "$HOME/Downloads/Catch-what-you-see-install"
curl --fail --location --proto '=https' \
  https://raw.githubusercontent.com/RichardPotter-Lai/catch-what-you-see-public/main/scripts/install-macos.sh \
  --output install-macos.sh
bash install-macos.sh
```

You can read the script before running it. It downloads version 0.1.1, checks SHA-256, and refuses to replace an existing app. It uses `/Applications`, or `~/Applications` when the former is not writable. Opening an ad hoc signed app and granting Accessibility access may require your confirmation in System Settings. See [installation and updates](docs/INSTALL.md).

## Ask a local agent

Give this to Codex desktop, Claude Code, or WorkBuddy with access to your Mac's terminal and files:

```text
Install and open Catch what you see on this Mac:
https://github.com/RichardPotter-Lai/catch-what-you-see-public

Read README.md and docs/INSTALL.md first. Check macOS 14+ and prefer the universal DMG in Releases, verifying SHA256SUMS.txt. You may use scripts/install-macos.sh.
If an installation already exists, check its path/version and preserve my library before proposing an update.
Keep Gatekeeper enabled and use normal system permission prompts; do not edit permission databases or upload private content.
Open the installed app and explain Option+C. Tell me which system confirmations require my input. Report only installation and launch steps you actually completed.
```

Codex Cloud normally runs in a cloud environment. Installing this app needs execution on the target Mac. Without that access, ask the agent to inspect the repository and prepare commands for a local agent; cloning the source in a cloud workspace does not install a macOS app on your computer. See [OpenAI's cloud environment documentation](https://learn.chatgpt.com/docs/environments/cloud-environments).

## Use it

Select text, then press and release **Option+C**. Catch saves a local Markdown note and hangs a preview on the clothesline. Move the pointer to the middle of the menu bar, or press **Control+Option+T**, to bring it down. Click a text note to copy its excerpt; double-click to open the MD file.

Screenshots use the usual macOS shortcuts. They stay temporary until you choose to collect them. Hiding a card or filling the line does not delete its file.

Some apps allow copying without exposing an Accessibility selection. An optional fallback runs one Copy command after you request collection, reads the new text, and tries to restore the previous clipboard. You can disable it, or copy text yourself and choose the explicit clipboard collection command.

## What changed from Tendedero

The screenshot clothesline, clips and original animation interaction come from Tendedero. This version mainly adds text capture, text cards, Markdown storage, and a local library for search, preview and external editing. Text and images share the deletion/recovery flow.

Each intentional collection creates a separate `.md`; images use relative attachment paths. The default library is:

```text
~/Library/Application Support/CatchWhatYouSee/Library/
```

Edit it with your usual Markdown tools. Back up the entire library, including hidden folders. There is no built-in account, content upload, analytics service or passive clipboard history. Clipboard restoration is best effort; known newer copies are kept. See [privacy](docs/PRIVACY.md).

## Requirements and limits

The build target is macOS 14+. Universal packages contain arm64 and x86_64, but Intel and older systems have not received full device testing. WeChat and commonly used web pages were manually tested on an Apple silicon Mac; this is not a claim that every app or PDF view works. There is no OCR. See [compatibility](docs/COMPATIBILITY.md).

The current UI is in Simplified Chinese. Builds are ad hoc signed, not Apple notarized. Follow the normal opening and Accessibility authorization steps in [INSTALL](docs/INSTALL.md).

## Build

On a Mac with the Swift toolchain:

```sh
cd app
swift run CaptureCoreChecks
swift build -c debug
bash scripts/build-app.sh debug
```

Use an isolated development library. See [development](docs/DEVELOPMENT.md) and [contributing](CONTRIBUTING.md).

## Attribution and license

Based on Tendedero 1.8.1 by Alejandro Buján. Thank you for creating and sharing the original project.

Code is [MIT licensed](LICENSE), retaining upstream notices. Catch uses a different name and an independently drawn icon. Upstream branding and promotional artwork are not included in this public source snapshot or relicensed here. See [third-party notices](THIRD_PARTY_NOTICES.md).

</details>
