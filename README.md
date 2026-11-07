<p align="center"><img src="docs/assets/icon.png" width="80" alt="Catch what you see"></p>

# Catch what you see

基于 [Tendedero](https://github.com/alejandrobujan/tendedero) 做的一个改版，主要加了文字收藏和 Markdown 笔记。

原项目会把截图挂在屏幕上方的晾衣绳上。我很喜欢这个设计，也想把读文章时选中的几句话放上去，于是在原有代码上加了文字采集。现在，截图和文字便笺可以挂在同一根绳上，想再看或复制时，把晾衣绳拉下来就行。

[下载](https://github.com/RichardPotter-Lai/catch-what-you-see-public/releases/latest) · [安装说明](docs/INSTALL.md) · [English](README.en.md)

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
