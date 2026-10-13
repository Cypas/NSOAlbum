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

macOS 的 About 包含版本检查入口，但不提供应用内安装器执行。
`macos_release_update_test.dart` 标记为 `common`，在各主机上以明确的 macOS
更新分支和合成 Release 元数据验证提示、架构 DMG 可用性、浏览器链接、
每日节流、忽略版本及失败回退；真实解析器和临时目录状态文件保持启用。
浏览器 channel 是模拟边界，不代表已验证真实 Mac 浏览器打开或 DMG 安装。
`macos_platform_test.dart` 则只在原生 macOS 检查 About 入口和平台 UI。
`macos_renderer_test.dart` 在原生 macOS 使用真实 PlistBuddy/plutil 验证 Intel
最终包的布尔渲染设置、缺省字段补充、arm64 元数据保持不变及错误架构拒绝。

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

目标为 `main` 的 PR 和 `main` push 执行完整检查；`dev` push 只执行快速
Ubuntu Rust/Flutter 检查和历史扫描，避免每次开发提交重复构建三个原生平台。
固定汇总检查 `Required validation` 只有提交解析与全部平台工作流成功时才
通过；失败、取消或跳过均不得通过。维护者通过 `dev → main` PR 合并。
正式 Release 除验证标签提交不可变和版本一致外，还验证提交属于 `main`
历史；手动 Validate 可指定 ref 生成测试产物，不创建标签或 Release。

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

### 缓存、构建与验收分离

Ubuntu 基础验证和三个原生构建使用平台/架构隔离的 Cargo 缓存；Rust cache
同时区分工具链与 Cargo 依赖配置。Flutter SDK/Pub cache 继续复用；Bridge
generator 单独按架构、Rust 工具链和固定版本缓存，命中后仍核对实际版本。
macOS 的 SwiftPM binary artifact / CocoaPods 缓存按架构、Xcode、Flutter
及依赖锁隔离，不缓存整个 Xcode 工程或最终 `.app` 来替代本次构建。

原生流程分为两个 job：

1. `Build and test <platform>`：准确提交 checkout、完整本机测试、一次
   Windows Release 目录构建或 macOS 最终签名应用构建。Windows 的显式 Cargo
   Release 和 Cargokit 分别缓存其编译目录，不混用 Debug DLL。MSBuild 环境
   变化可能让 C 依赖重编译；不强行共享指纹或压制 Cargo 的失效判断。
   发布 DLL 仍使用本次显式 Release 构建结果替换并逐项核对。
2. `Verify and package <platform>`：只下载当前 workflow run 的对应中间
   artifact，验证提交、版本、构建号、平台和全部文件 SHA-256，拒绝缺失/
   新增文件和越界链接。tar 只作为内部传输容器，保留 macOS framework 链接和
   执行权限，不是用户发布包。随后重新检查签名、依赖和架构，执行原生
   normal/reopen/safe、故障拒绝、Inno 或 DMG 挂载检查，不重新编译应用。

`built-<platform>-<commit>` 保留 3 天，仅供同次运行复用；测试报告为
`validation-<platform>`，运行报告为 `smoke-<platform>`。正式输出仍为
`native-<platform>`。只有完整验收成功后才能上传正式产物，Release publish
和 `Required validation` 同时等待两个阶段；中间 artifact 不是通过证明。
同次工作流的验收 job 失败可用 `gh run rerun <run-id> --failed` 重跑，构建
job 成功的 artifact 可复用；若 artifact 已过期则完整重跑，不使用其他提交的包。
等待结果使用 `gh run watch <run-id> --exit-status --interval 60`。

SwiftPM 不再无条件清空全缓存。构建包装器仅在日志明确指向该缓存内的
FFmpeg `.xcframework` 同名下载冲突时删除对应条目，最多重试一次；其他
构建错误立即失败，再次冲突仍失败。它不声称修复所有 SwiftPM 并发或网络问题。
缓存未命中、缓存过期或丢失时正常从头构建；所有测试和发布门禁照常执行。
实际加速效果必须由原生 CI 冷/热缓存报告确认，不能根据本地单测估算。

`ci_bundle_test.dart` 使用真实 PowerShell 和 tar 验证元数据/内容校验、
链接及传输；Unix 权限及符号链接用例在 Windows 明确跳过，Windows 仍验证
普通文件的完整 tar 往返。`macos_cache_retry_test.dart`
执行真实 bash 包装器，但构建命令为可控 fixture；只证明有限重试控制流程，
不代表真实 macOS 打包已验收。

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

每个原生检查步骤在执行前、完成或失败时写入隔离诊断日志，便于定位没有最终
报告的原生崩溃。进程输出按行脱敏，保留有界捕获范围内的后续错误；日志和
进度记录只用于排错，不能代替成功报告与零退出码。

合成 PNG 使用纯 Dart CPU 编码，素材生成不依赖 GPU。隔离检查复用一个播放器，
但原视频、剪辑和合并结果必须分别获取并解码新的原生播放器截图；仅复用已完成
的首帧信号或播放位置推进不能通过。Windows 另检查截图像素内容；macOS 使用软件
视频输出，不把解码帧验证描述为 Flutter GPU 画面像素验收。

Intel 最终包在签名前通过 `Info.plist` 的布尔 `FLTEnableImpeller=false` 选择
Skia 渲染器，arm64 保留原配置。该设置保存在 DMG 内同一应用中；传给 Dart 的
启动参数不能替代 macOS Release 引擎配置。构建后的应用与挂载后的 DMG 均执行
完整媒体检查，不能用安全模式代替。

Windows 可在 `flutter_app` 中对已有、刚构建完成的运行目录执行：

```powershell
dart run tool/run_release_smoke.dart --launch-app "../dist/NSOAlbum-Windows-x64-<SemVer>/NSOAlbum.exe" --reports-dir "<绝对诊断报告目录>"
```

macOS 包装流程使用 `tool/package_macos.sh`；构建 job 的 `--build-only` 仅产生
签名后的中间 `.app`，验收 job 用 `--reuse-app` 检查同一个包，不再改写或重签。
完整流程分别验证构建后的 `.app` 和挂载为
只读卷后的 DMG 内 `.app`，两次均运行真实冒烟。每种架构单独构建并校验 Mach-O
架构、依赖与签名。当前发行策略是 ad-hoc 签名、未 Developer ID 签名/未公证、
非 App Sandbox 的 DMG；ad-hoc 签名不是 Apple 信任背书，不宣称可直接通过 Gatekeeper。
不得发布 ZIP。

所有分支、手动测试打包与正式标签流程都执行 ad-hoc 签名及签名验证。原生签名
回归使用合成版本化 framework，验证签名、启动及资源篡改拒绝；全部 Mach-O 的
路径清理完成后，签名从嵌套叶子/容器开始，主应用最后签名，不以 `--deep` 代替
明确签名顺序。

签名前移除已确认的 Xcode 工具链与 `/usr/local/lib` 宿主机回退 RPATH，再检查每个
动态依赖都能从应用包或允许的系统库解析；未知外部搜索路径仍拒绝。可移植策略
回归验证只删除允许清理的路径，macOS 原生回归另验证真实 Mach-O 修改后签名和启动。
第三方 universal framework 的依赖解析只读取缩进的依赖记录，排除每个架构的标题，
去重跨架构依赖/RPATH；双架构合成 framework 验证真实解析、清理和签名。

无需创建新版本或标签即可测试打包：在 Actions 的 **Validate → Run workflow**
选择分支，可填写 `ref` 为提交/分支并勾选 `package_installer`。也可执行：

```sh
gh workflow run validate.yml --ref dev \
  -f ref=dev -f package_installer=true
```

测试产物仅上传 Actions artifacts，没有 publish job、写入 Release 权限或标签
操作。`package_installer=false` 仍执行完整签名/测试/运行检查，只省略 Inno 编译。
失败后修复代码并再次手动运行即可；正式 tag 仍绑定固定提交，不覆盖已有标签。

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
