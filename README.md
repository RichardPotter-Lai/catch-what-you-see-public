<p align="center">
  <img src="docs/assets/icon.png" width="80" alt="Catch what you see">
</p>

<h1 align="center">Catch what you see</h1>

<p align="center">
  基于 <a href="https://github.com/alejandrobujan/tendedero">Tendedero</a> 做的一个改版，主要加了文字收藏和 Markdown 笔记。
</p>

<p align="center">
  <strong>中文版</strong> · <a href="docs/i18n/en.md">English</a>
</p>

<p align="center">
  <img src="docs/assets/clothesline-preview.png" width="960" alt="功能示意图：文字便笺、截图与 Markdown 笔记挂在同一根晾衣绳上 / Text notes, screenshots and Markdown on one clothesline">
</p>

<p align="center">
  <a href="https://github.com/RichardPotter-Lai/catch-what-you-see-public/releases/latest">下载 macOS 版</a> ·
  <a href="docs/INSTALL.md">安装说明</a> ·
  <a href="#从源码构建">从源码构建</a>
  <br>
  <sub>macOS 14+ · 功能示意图 / Feature illustration</sub>
</p>

原项目会把截图挂在屏幕上方的晾衣绳上。我很喜欢这个设计，也想把读文章时选中的几句话放上去，于是在原有代码上加了文字采集。现在，截图和文字便笺可以挂在同一根绳上，想再看或复制时，把晾衣绳拉下来就行。

## 怎么用

选中一段文字，按下并松开 **Option+C**。保存成功后，屏幕顶部会挂上一张便笺，完整文字写入本地 Markdown 文件。

| 操作 | 会发生什么 |
| :-- | :-- |
| Option+C | 收藏当前选中的文字。 |
| 鼠标停在顶部菜单栏中部，或 Control+Option+T | 展开晾衣绳。 |
| 单击文字便笺 | 复制摘录正文。 |
| 双击文字便笺 | 打开对应的 MD 文件。 |
| 使用 macOS 截图快捷键 | 截图先临时挂上，需要长期保存时再点收藏。 |

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

<details>
<summary>展开并复制安装话术</summary>

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

</details>

<details>
<summary>使用 Codex Cloud 时</summary>

如果你用的是 **Codex Cloud**，任务通常在云端环境执行。安装这个 macOS 应用需要目标 Mac 的本机执行能力；仅拉取仓库到云端不会把 App 装到你的电脑上。云端可以先帮你读代码、整理安装步骤，下面这段适合发给它：

```text
请读取 https://github.com/RichardPotter-Lai/catch-what-you-see-public 的 README.md 和 docs/INSTALL.md，
为我的 Mac 整理安装步骤、下载地址、校验方法，以及可交给本机 Agent 的安装指令。
先确认你是否能执行目标 Mac 上的命令；如果只能在云端运行，就交付步骤，不要声称已经替我安装或测试了 macOS 界面。
```

</details>

WorkBuddy 的具体操作取决于你给它开放的工具。上面的文字是任务说明，不会替 Agent 增加本机权限。Codex Cloud 的执行方式可参阅 [OpenAI 官方说明](https://learn.chatgpt.com/docs/environments/cloud-environments)。

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
