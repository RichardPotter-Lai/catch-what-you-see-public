# 从源码开发

需要 Mac 与 Swift 工具链。Package 的 tools-version 为 5.9；0.1.1 在 Swift 6.1.2 / SDK 15.5 下完成本机编译，AppKit 相关验收仍需真实 Mac。

从项目根目录：

```sh
cd app
swift run CaptureCoreChecks
swift build -c debug
bash scripts/build-app.sh debug
```

构建产物为 app/build/Catch what you see.app。不要覆盖你正在使用的安装包来跑实验。

## 隔离运行

```sh
bash scripts/run-development.sh --show-library
```

脚本创建独立临时库，关闭截图监听/接管和默认捕获热键。只有明确需要测试时加 --enable-capture-hotkey。临时目录可能被系统清理，不能用作正式私人资料库。

快速复制回归：

```sh
swift run CaptureCoreChecks --copy-selection-only
```

原生适配器、Line 和资料库检查通过应用的 --development --library 诊断入口运行。必须使用新建的独立合成目录，每项检查独立一个目录，避免条目互相干扰。不要对私人库运行诊断，也不在未取得使用者授权时测试真实选区。

## 打包

```sh
bash scripts/package-release.sh
```

release 脚本构建 arm64/x86_64、验证签名与架构，再生成 DMG/校验值。没有 Developer ID 时是 ad hoc 签名，不是 Apple 公证。构建机身份不等于接收者机器授权；更新可能需要按 INSTALL.md 刷新对应签名的许可。

只复用本项目的 make-capture-icon.swift。上游旧品牌素材与闲置生成器没有包含在公开快照中。

## 结构

- app/Sources/CaptureCore：文件、笔记、复制事务和状态边界。
- app/Sources/CaptureNative：系统文本服务。
- app/Sources/Tendedero：继承并扩展的原生 UI、AX、快捷键与截图入口。目录名是来源结构，不是另一份应用。
- app/Tests：合成行为检查与独立复制窗口。
- openspec/specs：当前行为约定，包含 0.1.1 已接受的复制和反馈规则。

