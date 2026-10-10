# 测试与原生发布验收

测试分为可移植 Rust/Flutter 验证、平台专用测试和真实发布包冒烟。通过
`flutter test` 不等于真实桌面窗口、播放器、FFmpeg 或 USB 设备已通过验收。
所有测试均使用合成数据，不需要真实 Nintendo 账号或个人媒体。

## 本地基础验证

从仓库根目录分别进入对应目录，执行全部命令：

```powershell
cd rust_core
cargo fmt --all -- --check
cargo clippy --all-targets -- -D warnings
cargo test --lib
```

```powershell
cd flutter_app
dart analyze
flutter test
```

修改跨语言 API 时，先在 `flutter_app` 运行
`.\tool\generate_bridge.ps1`，再检查 Rust 和 Dart 两侧；不得手工修改生成桥接。
CI 使用完整测试套件，不通过排除平台测试隐藏不支持的平台行为。

## Flutter 测试分类

`flutter_app/dart_test.yaml` 声明以下标签。未标记平台专用标签的既有测试按
common 归类，新建可移植测试可显式使用 `common`。

| 分类 | 覆盖范围 | 不代表 |
| --- | --- | --- |
| `common` | 纯 Dart 规则、控制器、使用 FakeBackend 或模拟 channel 的 widget 行为；PowerShell 错误文本解析；标题栏组件渲染 | 实际 Rust DLL/dylib、原生窗口、真实输入法或媒体插件可用 |
| `platform-windows` | Windows 字体管理 UI、IME channel 生命周期、实际 PowerShell 5.1 UTF-8 清单读取 | 搜狗输入法候选窗口和 USB 真机已验收 |
| `platform-macos` | 当前 macOS 主机的窗口内容不插入 Windows 自绘标题栏、设置不显示 Windows 字体/安装器控制、Windows IME channel 不被启动、原生路径规则 | AppKit 窗口装饰、Gatekeeper 或真实播放器已验收 |

平台专用测试使用 `Platform.isWindows` / `Platform.isMacOS` 的实际主机判断，
不伪装 `TargetPlatform`。在其他平台通过 `skip` 显式说明原因，不能在测试体内
直接 `return` 后把未执行的断言计为通过。混合测试文件的专用测试标题使用
`[Windows]` / `[macOS]` 前缀，便于机器报告独立归类；专用文件使用库级标签。
纯 PowerShell 错误解析仍在所有系统执行。

本地只排查平台子集时可执行：

```powershell
flutter test --tags platform-windows
flutter test --tags platform-macos
flutter test --exclude-tags "platform-windows || platform-macos"
```

最后一个命令也包含尚未显式标记 `common` 的可移植测试，不能用
`--tags common` 代替完整通用套件。

## CI 主机矩阵

`.github/workflows/native-validation.yml` 是 PR、主分支和正式 tag 共用的验证流程。
Ubuntu 保留 Rust/Dart/Flutter 基础验证；原生矩阵必须分别在真实目标架构主机执行，
不能把交叉编译成功或 Rosetta 运行视作原生验收。

| 原生目标 | GitHub runner 标签 | Rust target |
| --- | --- | --- |
| Windows x64 | `windows-latest` | `x86_64-pc-windows-msvc` |
| macOS Apple Silicon arm64 | `macos-15` | `aarch64-apple-darwin` |
| macOS Intel x64 | `macos-15-intel` | `x86_64-apple-darwin` |

每台原生主机重新生成 bridge、执行 Rust fmt/Clippy/单元测试、Dart 分析和完整
Flutter 测试，然后构建当前提交的 Release 包。报告从当次 Rust libtest 摘要和
`flutter test --machine` 事件读取实际 total/passed/failed/skipped，并区分
common/Windows/macOS；不在文档、工作流或脚本中固定测试数量。
未运行、跳过、超时、缺少报告与测试失败必须如实显示，不能写成通过。

## 真实 Release 冒烟

`--ci-smoke` 是显式启用的诊断入口，普通启动不会运行。诊断还必须提供
`--ci-smoke-root=<绝对隔离目录>`；不得使用卷根目录、既有个人数据目录或符号链接/
目录联接指向的个人图库。首次目录必须不存在或为空，由诊断写入所有权标记；
重启场景只接受此前成功冒烟拥有的隔离库。

诊断直接启动打包后的 EXE 或 `.app`，加载真实 Rust 和桌面插件。使用应用内生成
的合成 PNG 和仓库自有的短 H.264/AAC 视频，不扫描用户图片目录，也不读取系统安全
存储中的账号令牌。自动同步、启动同步、更新器、Nintendo 登录和 MTP 扫描均被隔离/
禁用，诊断网络失败不能影响本地媒体测试。

驱动按以下顺序执行独立进程：

1. `normal`：Rust 初始化、首次 Flutter 帧、首次图库查询；真实窗口/托盘插件；
   合成文件导入和图片解码；播放器实际首帧、视频封面/时长及缓存；
   通过应用内 FFmpeg 插件剪辑和合并、Rust 入库、生成标签与输出回放；
   验证源文件 SHA-256 不变，并保存设置与图库状态。
2. `reopen`：重新打开同一隔离库，确认设置、媒体和缩略图缓存持久化。
3. `safe`：全新隔离库，通过 `--safe-mode` 确认降级启动、首帧和图库查询，
   并核对桌面生命周期、自动同步、视频预热/缩略图与 MTP 检测禁用。

无需用户自行安装系统 FFmpeg。widget 中的模拟播放器或 channel 不能代替这些步骤。

Windows 可在 `flutter_app` 中对已有、刚构建完成的运行目录执行：

```powershell
dart run tool/run_release_smoke.dart --launch-app "../dist/NSOAlbum-Windows-x64-<SemVer>/NSOAlbum.exe" --reports-dir "<绝对诊断报告目录>"
```

macOS 包装流程使用 `tool/package_macos.sh`，分别验证构建后的 `.app` 和挂载为
只读卷后的 DMG 内 `.app`，两次均运行真实冒烟。每种架构单独构建并校验 Mach-O
架构、依赖与签名。当前发行策略是 ad-hoc 签名、未 Developer ID 签名/未公证、
非 App Sandbox 的 DMG；ad-hoc 签名不是 Apple 信任背书，不宣称可直接通过 Gatekeeper。
不得发布 ZIP。

## 失败报告与发布门禁

`ci_native.ps1` 输出动态测试汇总；`run_release_smoke.dart` 输出总 `report.json`、
分场景 `native-*.json`、脱敏日志及可用的失败截图。CI 在失败时仍上传诊断报告。
日志不包含令牌、账号回调、代理凭据或个人媒体；上传前脱敏本机目录和敏感字段。
报告中的跳过项保留明确原因，不能把未支持的平台专用测试计入通过数。

Rust/Flutter 测试失败、分析失败、原生步骤失败、退出码非零、超时或缺少有效报告
均阻止发布。必须等待 Windows x64、macOS arm64、macOS Intel 三个矩阵目标以及
基础验证成功后，正式 tag 才能上传 Release 资产。版本一致性和 SHA-256 校验继续
执行；不修改已发布 tag，也不因为只有一个平台成功就发布部分资产。

## 仍需人工验收

CI 通过不能替代以下真机与真实用户流程。发布说明必须区分自动通过、人工通过和
尚未验证，不将这些项目列为自动覆盖：

- Windows 搜狗等第三方中文输入法：文本框切换、窗口失焦/恢复、中文组合输入、
  候选窗口位置；不记录用户输入内容。
- Switch / Switch 2 USB MTP 真机：只在进入 USB 子页后扫描，中文/日文目录与文件名
  原样读取，断连和重复导入得到可读结果。
- Nintendo 用户授权与多账号安全存储、真实云端同步、代理和限流，不在 CI 保存
  或使用真实账号令牌。
- Windows 安装器升级与用户确认更新；macOS 从浏览器下载后的 quarantine /
  Gatekeeper 首次打开提示、用户允许打开后启动，以及本地媒体目录选择权限。
