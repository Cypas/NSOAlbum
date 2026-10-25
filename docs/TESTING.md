# 测试与原生发布验收

测试分为可移植 Rust/Flutter 验证、平台专用测试和真实发布包冒烟。通过
`flutter test` 不等于真实桌面窗口、播放器、FFmpeg 或 USB 设备已通过验收。
所有测试均使用合成数据，不需要真实 Nintendo 账号或个人媒体。

`test/windows_media_viewer_device_test.dart` 需显式使用
`flutter run --debug -d windows -t test/windows_media_viewer_device_test.dart`
运行；它采用 Live binding、自制视频和内存后端，检查正式详情页的暂停、
过期编辑取消、编辑结果交接及有界相邻预载，并检查视频沉浸按钮在真实控制栏内的
位置/显隐和切换时播放器实例保持。普通宿主 `flutter test`
明确跳过这些原生用例。用例断言和原生进程退出分别记账，不能用测试输出成功
掩盖非零退出或用该入口代替 Rust 入库验收。运行后重新构建普通主入口。
`flutter run` 自身退出0也不能证明原生子进程退出0。验证普通窗口关闭时须先确认
进程/父命令行属于本次合成入口，保留该子进程句柄，再读取其真实退出码；
不能向用户普通窗口或仅按进程名匹配的窗口发送关闭请求。

## 本地构建空间约定

图库生成 Bridge 的实际 DLL 回归位于 `test/gallery_query_bridge_test.dart`。
仅在已验证为当前源码/生成接口的 Debug 库后，将其绝对路径放入
`NSOALBUM_DEVICE_SYNC_TEST_LIBRARY`，再单独执行该测试。它通过正式 Rust API
建立全新合成库，检查分页、录入日期/拍摄顺序、相册窄计数及媒体来源，不访问
安全凭据或个人图库；SQLite 进程句柄退出前可能仍占用文件，因此合成夹具保留在
约定的 C 盘 TEMP 内，不抢先删除。默认完整套件显式 skip，此单独结果另外记账，
不能据此声称系统窗口、播放器或手机已验收。

同一环境变量也可显式启用 `test/device_sync/account_bridge_test.dart`。它通过
实际 DLL、TLS/SQLite/journal 及内存安全存储边界验证账号 v2 名称历史传递、
v1 规范字节接收、授权、显式恢复及四键写入/读回故障补偿；不读取或写入真实
账号。`bridge_fault_matrix.dart` 属于该回归的辅助夹具，不是应用入口。
名称历史的纯 Dart 冲突规则在 `test/account_name_history_test.dart`，包括
保留原 RFC3339 精度以及亚微秒更新比较；宿主通过不代表系统安全存储或设备
多端互连已经验收。

异常已配对会话的本地持久状态回归位于 Rust `device_sync/startup_recovery.rs`、
`database.rs` 与 driver/headless 测试，覆盖精确会话清理、受控部分文件与缓存保留。
Flutter 的 `test/device_sync/startup_lifecycle_test.dart` 和
`startup_desktop_close_test.dart` 分别验证异常才显示校验提示、干净启动隔离、
关闭保留同一应用树、必要等待和失败后的显式重试；不能以这些合成结果声称
已验证系统杀进程、真实账号补偿或 macOS 窗口退出。

本地 Windows、Android 和 macOS Debug/原生验证优先在 C 盘独立构建副本中执行，
不要把大型 Rust target、Flutter build、Gradle 中间目录长期写入 F 盘源码工作区。
本地副本及工具缓存复用维护环境中已约定的固定基准目录，不按日期、轮次或
普通源码改动重复创建隔离构建根。使用其他隔离根须先说明原因、路径并取得
维护者同意；已有缓存及历史产物不得擅自清理、移动或删除。

Flutter 构建和测试在 C 盘构建副本的 `flutter_app` 下运行；不要使用
`flutter --build-dir …`，该全局参数并不适用于当前工具链。源码修改后用
非删除式复制更新副本，不用镜像删除覆盖其中保留的验收资料。例如：

```powershell
$env:CARGO_TARGET_DIR = Join-Path $buildRoot 'cargo-target'
$env:GRADLE_USER_HOME = Join-Path $buildRoot 'gradle-home'
$env:PUB_CACHE = Join-Path $buildRoot 'pub-cache'
$env:NSO_GRADLE_BUILD_DIR = Join-Path $buildRoot 'source\flutter_app\build'
Set-Location (Join-Path $buildRoot 'source\flutter_app')
flutter build windows --debug
flutter build apk --debug --target-platform android-arm64
flutter test
cargo test --manifest-path ..\rust_core\Cargo.toml --lib
```

Rust 可从源码目录运行并使用 C 盘 `--target-dir`。不要为单次测试改写全局
Flutter 配置或并行启动争用同一构建目录的原生构建。

`$buildRoot` 必须在开始前解析到该维护环境已批准的 C 盘固定基准；示例不负责
创建或清理它。构建后核对 APK/EXE、Gradle 项目/用户缓存、intermediates、
Cargo/Cargokit 输出均位于基准内；发现意外写入立即报告，不自行清理。
这些路径不写入应用配置、发布包或 CI。CI runner 使用工作流自己的
临时构建目录和缓存；仓库中的 `flutter_app/build/`、`.dart_tool/`、
`rust_core/target/`、Android/Gradle 输出仍是可重建的忽略目录。

## 分支与触发规则

| 事件 | 工作流与检查 | 可下载产物 | 正式发布 |
| --- | --- | --- | --- |
| push 到 `dev` | Dev validation：Ubuntu Rust fmt/Clippy/单测、Dart 分析、完整 Flutter 测试、Git 历史敏感扫描 | 不构建安装包 | 否 |
| 新建/更新目标为 `main` 的 PR | Validate：Ubuntu/历史扫描及 Windows x64、macOS arm64/x64 各自完整测试、构建、签名和原生媒体验收；Android ARM64 测试构建/包体检查；Required validation 汇总 | Windows 运行目录、两种 DMG、Android CI 测试 APK；不编译 Inno | 否 |
| PR 合入后 push 到 `main` | 同一 Validate 完整门禁，并自动编译 Windows Inno 安装器；Android 通过后使用正式密钥签名 | 运行目录、安装器、两种 DMG、Android 测试/正式签名 APK，保留 7 天 | 否 |
| 手动 Dev validation | 对所选 ref 运行 Ubuntu 基础检查及历史扫描 | 不构建安装包 | 否 |
| 手动 Validate | 固定所选 ref 的提交，运行完整门禁；可信 main/dev 工作流的 `package_installer=true` 时额外编译 Inno 和签名 Android APK | 运行目录、两种 DMG、Android CI 测试 APK；开启时含安装器及正式签名 APK | 否 |
| 手动 Android ARM64 validation | 固定所选 ref 的提交，只运行 Android 构建/测试和静态包体检查；`sign_release=true` 时要求可信工作流/目标历史并正式签名，不代替完整 Validate | Android CI 测试 APK；开启时含正式签名 APK，保留 7 天 | 否 |
| push `v*` tag 或手动 Release | 稳定 tag/版本/main 祖先检查及完整门禁，含 Android 构建/测试/包体检查和正式签名 | 正式资产为安装器、两种 DMG、正式签名 ARM64 APK 和统一 SHA256SUMS.txt | 全部成功后发布 |
| 其他分支 push / 目标不是 `main` 的 PR | 当前没有自动触发；可手动指定 ref 验证 | 无自动产物 | 否 |

PR 更新时，dev push 的轻量检查和 PR 的完整检查都可能运行，范围不同。
PR 完整检查验收拟合并提交；合入后 main push 验收实际主分支提交并提供测试安装器，
因此两次运行各有用途。稳定 tag 流程重新验证该 tag 固定提交，不借用其他 run 的通过记录。
以运行事件、提交 SHA 和完整工作流结果区分各次检查，不以单个 artifact 判断正式发布。

三平台通过可复用工作流各自执行“构建与完整单测 → 同平台验收与打包”，
Windows 验收无需等待 macOS 构建完成，反之亦然。每个平台仅使用同次运行的
对应平台 artifact，提交、SemVer、构建号、文件哈希、链接及权限均须匹配。
各平台显式汇总构建与验收结果，上层再汇总桌面三平台、Android 构建/包体检查、Ubuntu 和历史扫描；
失败、取消或跳过均不能使 Required validation 或正式 publish 成功。
按平台独立验收只改变调度顺序，不改变三平台齐备和统一版本的正式发布要求。

## 本地下载的 CI 数据

完整文件分类与 Git 忽略边界见 [仓库目录规范](REPOSITORY-LAYOUT.md)。
本地下载的 Actions 产物、历史报告、截图和日志统一存放在
`dist/ci/history-downloads/`，新下载按 `<run-id>/<platform-or-artifact>/`
分目录，禁止在仓库根目录为每次检查新建 `ci-artifacts-*` 文件夹。
整理旧下载时保留原目录名称与文件内容，不凭目录名推测缺失的 run ID。
这些文件不参与应用编译和打包，也不提交 Git；失败报告仍可用于历史问题排查，
但不能代替当前提交的验证。Android 本地 `flutter_app/android/build/`
同样属于可再生成的忽略构建产物，不包含应提交的 Gradle 配置或 Kotlin 源码。

## Android ARM64 CI

`android-validation.yml` 可被完整 Validate/Release 调用，也可单独手动运行。
使用 Flutter 3.47.6、JDK 17、Android SDK 36、Build Tools 36.0.0、
NDK 28.2.13676358，只安装 Rust `aarch64-linux-android`，APK 构建显式指定
`flutter build apk --release --target-platform android-arm64`。依赖缓存按
平台/架构、工具链和依赖锁隔离，不复用上次测试结果或最终 APK。
各 Android job 将 SDK 初始化的附加包显式设为 `platform-tools`，不请求已不可用的
旧 `tools` 包；构建 job 随后安装固定的 SDK、Build Tools 和 NDK，
验收及签名 job 安装固定的 Build Tools。

构建 job 重新生成 bridge、检查 Flutter/Rust 版本、执行 Rust fmt/Clippy/单测、
Dart 分析和完整 Flutter 测试。完整测试在 APK 构建后启用
`NSO_VERIFY_ANDROID_BUILD=1`，执行真实 Gradle ABI 配置、编译的应用入口、
品牌资源、Release 网络权限及最终 APK 权限检查；其他平台测试保留明确 skip。
原生 JVM 更新规则回归检查官方资产地址、包身份、签名、受限复制/哈希及后台任务生命周期。
同一 opt-in 套件显式执行通知权限协调器的 JUnit 回归，覆盖同步/更新共用权限弹窗、
待发摘要、拒绝后不重复请求及迟到回调；不是仅编译测试类，也不代替真实系统弹窗验收。
测试统计来自本次日志，报告 artifact 为 `validation-android-arm64`。

Android 构建与验收之间直接传递 APK、同提交的封存清单及 SHA-256 文件，
工作流不再自行创建 ZIP/TAR。中间 artifact 绑定平台、架构、版本、构建号和
提交；最终测试 artifact 名为 `android-arm64-ci-test-<version>-<build>`，
内容为可安装的 ARM64 测试 APK、同提交封存清单和 SHA-256 文件。
GitHub artifact 服务自身的下载容器不由仓库
控制，不代表 APK 仍需执行项目自定义解包步骤。正式签名 artifact 名称及
Release 签名、Secrets 门禁保持不变。

验收 job 只下载同次 run、同提交的中间 artifact，不重新构建。使用现有
`ci_bundle.ps1` 核对提交、平台、SemVer、构建号和所有文件 SHA-256，再通过
`verify_android_apk.ps1` 检查最终 APK 的应用 ID、启动 Activity、版本、
minSdk、非 debuggable、网络/受限权限和 v2 签名，并逐个读取 ELF 头验证
AArch64；Rust Core、Flutter AOT/引擎、libmpv 和 FFmpeg 必须存在。
静态报告 artifact 为 `verification-android-arm64`。

当前使用工程既有测试签名，产物明确命名为
`NSOAlbum-Android-arm64-CI-Test.apk`，artifact 为
`android-arm64-ci-test-<version>-<build>`。
它不是正式签名发布包，不能作为稳定升级渠道；不匹配 Release 的
`native-*` 下载范围，也不进入正式 Release 资产。
ARM64 运行节点尚未确认，本阶段不自动配置自托管 runner、
不新增 x86/其他 ABI，也没有安装、启动或真实媒体 smoke。
静态包体检查通过不等于 Android 真机或后台调度验收通过。

### 正式密钥签名

仓库配置 `ANDROID_KEYSTORE_BASE64`、`ANDROID_KEYSTORE_PASSWORD`、
`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD` 四个 Actions Secrets。
工作流显式逐级传递它们，PR 不接收正式密钥，构建和测试 job 不还原密钥。
main 自动打包、可信 main/dev 手动完整打包、稳定标签完整流程会请求签名；
单独 Android 手动入口默认不签名，需要显式打开 `sign_release`。
签名目标提交必须位于 main/dev 历史中，不能用可信工作流给任意未审核 ref 签名。

签名 job 在 build/verify 均通过后，再次核对同次 artifact 的提交、版本、
构建号与全部 SHA-256。`sign_android_apk.ps1` 仅将私钥还原到 runner 的独立
临时目录，密码通过环境变量传给官方 keytool/apksigner，不写入命令行、
key.properties、Gradle 缓存或 artifact。结束时清理私钥；失败删除输出 APK，
缺失 Secret/错误密码/证书不匹配时不回退测试签名。

签名后重新核对 APK 的版本、架构、权限和 v2 签名，签名证书 SHA-256
必须等于配置密钥导出的证书，并拒绝 Android Debug 证书。
正式密钥签名后的 APK 命名为 `NSOAlbum-Android-arm64-<SemVer>.apk`，
与摘要上传 `android-arm64-signed` artifact；公开证书指纹与检查结果上传
`signing-android-arm64`。下载前仍需确认本次完整工作流成功。
稳定 Release 的 publish 在完整门禁成功后，单独下载同次 run 的
`android-arm64-signed`（不使用 CI 测试 APK），核对签名 job 的摘要只包含当前
版本 APK 且 SHA-256 匹配，再与 Windows Inno、两架构 macOS DMG 一并收集。
APK 缺失/为空、版本文件名不符、摘要缺失/不匹配或桌面包缺失/重复均阻止发布。
统一 `SHA256SUMS.txt` 包含四个安装包，不上传测试 APK、运行目录或 ZIP。
Validate 和单独 Android 手动工作流仍只输出 Actions artifacts，不发布 Release。
尚未运行 Android 设备 smoke，不能把“正式密钥签名”表述为“设备验收完成”；
Release 说明保留主机/静态检查与设备运行检查的区别。

每次 Android 构建使用临时生成的测试密钥执行真实签名回归，包括正常签名、
输入文件保持不变、错误密码、缺失 Secret、非法 Base64、拒绝覆盖和清理。
该回归不使用配置的正式密钥，不影响用户安装或数据。

任一 Android 构建/测试/包体检查失败、取消或跳过均使完整验证失败；
现有桌面原生运行及发布门禁保持不变。单独手动 Android 检查不能代替
`Required validation`。dev push 仍只有快速 Ubuntu 检查和历史扫描。
请求正式签名时，签名失败/取消/跳过同样使完整验证失败；未请求签名的
普通验证明确允许独立签名 job 不执行，不跳过任何构建或验收 job。

### Android 应用更新

Android 正式模式启动时按本地自然日自动检查稳定版本；发现新版后确认，
选择下载才交给系统 DownloadManager。正在下载的通知由系统显示，后台任务
不阻止页面导航；下载完成并验证后显示点击安装通知和应用内安装按钮。
通知被拒绝仍可使用应用内状态与安装入口。

仅接受官方仓库稳定 APK 的固定名称/URL、官方 SHA-256 和受限大小。
下载完成后复制到应用私有更新目录并核对包名、版本、递增构建号及当前安装
签名；完成广播仅调度 JobScheduler，耗时校验由可取消/重试的后台 job 执行，
不在广播时限内复制整个 APK。通知和应用内按钮都再次校验后调用系统安装器。未知来源安装权限由
系统设置确认，不静默安装、卸载、退出或清除数据；Debug 同包名测试应用
与正式签名不兼容时拒绝安装，不自动清理测试库。
更新功能需要 POST_NOTIFICATIONS 和 REQUEST_INSTALL_PACKAGES，
不允许 MANAGE_EXTERNAL_STORAGE 或 FOREGROUND_SERVICE。

官方元数据大小须大于零且不超过 512 MiB，前台查询到超限下载会取消，
完成复制也实行大小上限；应用进程不在时，DownloadManager 的网络下载
不能保证实时硬上限，超限文件会在恢复/完成校验时拒绝，不交给安装器。

既有稳定 Release 尚未包含 Android APK，客户端显示缺包状态、不下载 CI
测试 artifact。后续 Release 工作流将发布同版本正式签名 ARM64 APK；
跨版本更新仍要求递增构建号及兼容签名。真机通知点击、进程终止恢复、
未知来源权限及系统安装需另行验收，不以 widget/包体检查替代。

## 本地基础验证

### 本地应用运行模式

Windows/macOS 桌面端及 Android 的本地运行和交互测试默认使用 Debug。
只有用户明确要求时才使用 Profile 或 Release，性能测试也不例外；
Debug 性能数据不能作为正式包性能结论。此约定优先于既有本地非 Debug
验收建议，但不改写历史证据，也不改变 CI、正式打包及发布的 Release 门禁。

Dart 界面修改优先热重载，初始化变化使用热重启。Rust、Bridge、原生代码
或原生依赖变化仍需重新编译相应 Debug 原生组件并重启，不能通过 Dart
热重载替代。Android 本地构建继续仅使用既定 ARM64 目标。

### 桌面单实例

Windows/macOS 普通启动在准备 Rust Core 之前取得当前系统用户的应用实例锁。
重复启动只显示、恢复和聚焦原窗口，不重新加载当前页面或图库。
退出流程必须先安全关闭图库及窗口，再释放实例锁；关闭失败仍保留原实例。
Android 不使用该桌面入口；合法 `--ci-smoke` 仍使用独立新根，
不唤起或阻塞用户的普通应用。

`flutter test test/desktop_single_instance_test.dart` 使用真实 Dart 子进程、
OS 文件锁和回环连接验证选主、并发、退出/崩溃后重开与无效请求拒绝。
`test/device_sync/startup_desktop_close_test.dart` 覆盖关闭失败不能提前释放锁。
这些 Common 测试不代替 Windows/macOS 真实窗口的托盘、最小化及聚焦验收。

磁盘空间不足时，可在空间充足的位置建立独立源码构建副本，核对源码摘要后
沿用副本内的工具默认输出路径。保留主工作区及原缓存，不以目录联接绕过测试
对构建路径的检查，也不拿旧编译产物代替新源码验证。

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

### Windows WebView DLL 生命周期

Windows 原生验证固定运行于 `windows-2022`：当前锁定的
`flutter_inappwebview_windows` / `Microsoft.Windows.CppWinRT` 组合会在 C++17
target 上自动添加 `/await`；VS 2026 STL 已对该依赖包含的
`<experimental/coroutine>` 报 STL1011 编译错误。不要通过关闭诊断、提高整个旧插件
到其不兼容的 C++20 语法或绕过编译来放行；更换 runner 前须先升级/修复该依赖并以
Windows 最新 runner 完整构建验证。

Windows runner 先从 System32 可选加载 CoreMessaging，再通过延迟加载注册
WebView 消费者，使 provider 先初始化、后卸载。未提供该系统组件时保留插件
原有的运行时能力检查，不把较新的队列 API 硬绑定为程序加载入口。不通过额外
AddRef、跳过析构、固定 pin 或修改包缓存规避退出失败，也不复制系统 DLL。

`flutter_app/tool/windows_plugin_lifetime.cmake` 对固定版本插件的析构边界生成
构建树内派生源码：WebView 先销毁消费者，再释放所属线程的 composition/
dispatcher 资源；FFmpeg 在卸载库前停止并等待原生回调消费线程结束。
源片段或目标文件列表变化时 CMake 必须失败，升级依赖时重新审查，不静默套用。
它不修改共享 pub 缓存，也不表示活跃编码任务已完成退出验收。
仅 Android Wi-Fi 使用的权限实现不注册到桌面，以免创建无用途的定位订阅。

原生关闭验收须保留测试子进程句柄，核对其 EXE 和合成入口父进程后发送
WM_CLOSE，等待并读取该子进程的实际退出码。`flutter run` 或交互式 `q`
返回 0 只能证明工具正常结束，不能证明原生应用析构成功。
SDK-only 探针、成品 PE 检查、视频断言及实际窗口关闭分别记结果。

在准备好的构建副本中，对普通 Debug 包或同次 CI 已验摘要的 Release 包执行：

```powershell
$env:NSO_VERIFY_WINDOWS_WEBVIEW_LOADER = '1'
$env:NSO_WINDOWS_WEBVIEW_BUNDLE = '<prepared bundle directory>'
flutter test test/windows_webview_loader_test.dart --reporter expanded
Remove-Item Env:NSO_VERIFY_WINDOWS_WEBVIEW_LOADER, Env:NSO_WINDOWS_WEBVIEW_BUNDLE
```

该回归读取实际成品 PE 的延迟加载关系，不启动账号或图库。CI 原生 Windows 验收 job
在还原、核验同次包后显式执行此门禁，再执行已有正常/重开/安全模式冒烟；
普通宿主完整测试明确跳过需要预先构建包的用例，不把 skip 计为通过。

`test/fixtures/webview_lifetime/run_probe.ps1` 是额外的 SDK-only 诊断，
以子进程对照动态加载/显式导入与静态卸载/提前释放/关闭排空三种方式：

```powershell
./test/fixtures/webview_lifetime/run_probe.ps1 `
  -ApprovedBuildRoot $buildRoot -OutputDirectory (Join-Path $buildRoot 'temp')
./test/fixtures/webview_lifetime/run_probe.ps1 `
  -ApprovedBuildRoot $buildRoot -OutputDirectory (Join-Path $buildRoot 'temp') `
  -PreloadProvider
```

先按仓库本地构建约定设置 `$buildRoot`，输出目录必须已存在且位于该根内。
脚本要求 PowerShell 7。探针使用 Debug C++ 运行库、真实 Windows SDK 与独立 DLL，不创建 UI、不初始化
Flutter/Rust、不访问任何应用账号或个人库；动态加载负对照可能故意以原生异常
退出，不代表正式应用已修复。报告保存实测退出码，SDK 初始化失败不能作为
复现成功；只允许终止自己创建且超时的探针子进程，不操作用户应用。
`-StaticDependency` 和 `-DescriptorOnly` 仅供链接方式对照，不是产品当前配置；
空导入描述符未必能建立有效的 provider 生命周期，不能仅凭编译成功判定有效。

### Windows 系统通知 Live 验收

先在已准备的构建副本运行 `flutter test test/windows_sync_notifications_test.dart`，
构建既有 `TEMP/nsoalbum-sync-notification-native` 内的 SDK 夹具。显式 Live
入口不初始化 Rust、账号或图库；只发送合成的中英多账号汇总，比对系统
通知历史中的固定 tag/group 和确切文字，再通过实际 COM 激活恢复同一个
隐藏窗口。它可能显示测试通知，不更改系统通知权限；只在当前通知仍与
本次合成文字完全匹配时删除，不清空其他应用或本应用的其他历史。

```powershell
$env:NSOALBUM_VERIFY_SYSTEM_NOTIFICATIONS = '1'
$env:NSOALBUM_NOTIFICATION_NATIVE_FIXTURE = Join-Path $env:TEMP `
  'nsoalbum-sync-notification-native/Debug/sync_notification_fixture.exe'
flutter run -d windows --debug --no-pub `
  -t test/windows_sync_notifications_device_test.dart
```

遵守仓库固定 C 盘输出约定，先确认没有用户应用实例。此入口不得附加
`--ci-smoke`，因为该 runner 模式有意禁止系统通知注册。普通宿主套件
明确 skip，系统通知关闭/不支持时保留实际失败，不能以模拟成功代替。
COM 激活是系统回调路径验收，不等同于人工点击通知横幅；结束后核对测试
子进程真实 WM_CLOSE 退出码并恢复普通 `lib/main.dart` Debug 入口。

## Flutter 测试分类

`flutter_app/dart_test.yaml` 声明以下标签。标签区分被测功能，运行主机限制由
测试实际依赖及显式 skip 决定；未标记平台分类标签的既有测试按 common
归类，新建共享测试可显式使用 `common`。

| 分类 | 覆盖范围 | 不代表 |
| --- | --- | --- |
| `common` | 纯 Dart 规则、控制器、使用 FakeBackend 或模拟 channel 的 widget 行为；PowerShell 错误文本解析；标题栏组件渲染 | 实际 Rust DLL/dylib、原生窗口、真实输入法或媒体插件可用 |
| `platform-windows` | Windows 字体管理 UI、IME channel 生命周期、实际 PowerShell 5.1 UTF-8 清单读取 | 搜狗输入法候选窗口和 USB 真机已验收 |
| `platform-macos` | 当前 macOS 主机的窗口内容不插入 Windows 自绘标题栏、设置不显示 Windows 字体/安装器控制、Windows IME channel 不被启动、原生路径规则 | AppKit 窗口装饰、Gatekeeper 或真实播放器已验收 |
| `platform-android` | Android 页面 widget、导航、品牌、更新解析器/控制器及 APK 契约；纯 Dart/widget 检查继续在各主机运行 | 已在 Android 设备安装、启动、播放或更新 |
| `native-android` | 安装 Android SDK/JDK 后显式启用的真实 Gradle ABI、应用身份、品牌资源和 Release 权限检查 | 设备启动、播放、导入、编辑或后台调度已验收 |

Android 功能测试集中在 `flutter_app/test/android/`。原先位于 `test/` 根目录的
`android_apk_contract_test.dart`、`android_branding_test.dart`、
`android_build_configuration_test.dart`、`android_release_update_test.dart`
和 `android_update_controller_test.dart` 现位于该目录；测试间相对导入与
运行命令同步使用新路径，夹具仍位于 `test/fixtures/android/`。
其中构建配置测试同时带 `platform-android` 和 `native-android`，
保留 `NSO_VERIFY_ANDROID_BUILD=1` 启用条件。双标签只计一次；
`ci_native.ps1` 将任一 Android 标签计入同一个 Android 分类，JSON 与
Actions 摘要分列 Common、Windows、macOS、Android。共享状态测试不因文件名
包含 Android 而归为 Android 功能或被限制主机。

macOS 的 About 包含版本检查入口，但不提供应用内安装器执行。
`macos_release_update_test.dart` 标记为 `common`，在各主机上以明确的 macOS
更新分支和合成 Release 元数据验证提示、架构 DMG 可用性、浏览器链接、
每日节流、忽略版本及失败回退；真实解析器和临时目录状态文件保持启用。
浏览器 channel 是模拟边界，不代表已验证真实 Mac 浏览器打开或 DMG 安装。
`macos_platform_test.dart` 则只在原生 macOS 检查 About 入口和平台 UI。
`macos_renderer_test.dart` 在原生 macOS 使用真实 PlistBuddy/plutil 验证 Intel
最终包的布尔渲染设置、缺省字段补充、arm64 元数据保持不变及错误架构拒绝。

依赖 Windows/macOS 原生能力的测试使用 `Platform.isWindows` /
`Platform.isMacOS` 的实际主机判断，不伪装 `TargetPlatform`。
在其他平台通过 `skip` 显式说明原因，不能在测试体内
直接 `return` 后把未执行的断言计为通过。混合测试文件的专用测试标题使用
`[Windows]` / `[macOS]` / `[Android]` 前缀，便于机器报告独立归类；
分类文件使用库级标签。Android widget 的显式 `TargetPlatformVariant` 仅用于
覆盖移动界面，不冒充设备验收。纯 PowerShell 错误解析仍在所有系统执行。

本地只排查平台子集时可执行：

```powershell
flutter test --tags platform-windows
flutter test --tags platform-macos
flutter test --tags platform-android
flutter test test/android/android_release_update_test.dart
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
common/Windows/macOS/Android；不在文档、工作流或脚本中固定测试数量。
未运行、跳过、超时、缺少报告与测试失败必须如实显示，不能写成通过。
`ci_test_summary_test.dart` 用合成套件标签与 machine 事件执行真实汇总脚本，
覆盖 Android 分类、路径分隔符、跳过原因、失败/缺失/截断状态以及总数不重复；
完整 CI 仍运行 `flutter test` 递归发现所有目录，不按分类排除测试。

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

### 桌面 MTP helper

设备同步使用固定 sibling：Windows 为 `nsoalbum_mtp_worker.exe`，
macOS 为 `.app/Contents/MacOS/nsoalbum_mtp_worker`；不从 PATH、远端
材料或手机文件选择可执行程序。Android 不打包这个桌面进程。
Windows 工程自身 CMake 在 Cargokit 库目标之后构建 helper，并使 Runner
依赖它。Runner 与 helper 共用显式配置输出目录，避免旧 CMake policy
作用域中的反向目标依赖；回归测试使用真实可编译 Runner 目标覆盖三种模式。
macOS Runner 在 Flutter embed 之后、最终应用 CodeSign 之前
构建并复制 helper，不把 Pod 产物目录当成应用目录。

普通 Debug 使用 Cargo debug，Profile/Release 使用 Cargo release。
macOS 普通双架构构建分别消费两个 Rust target 的本次成功 Cargo JSON，
校验每个 slice 后在私有构建目录运行 lipo，再复制最终 helper；显式单架构
发布仍要求完全匹配的 thin Mach-O。普通签名构建先签 helper，再由 Xcode
签 Runner；发布脚本先完成复制、RPATH 修正及全部依赖检查，最后由嵌套
Mach-O 到根应用签名。签前和签后摘要分开记录。

`build_desktop_native.dart` 只从本次成功 Cargo JSON 选择当前 crate、模式
和目标的实际产物；绝对路径及原始 JSON 留在 ignored 构建报告。
Windows 打包同时替换并核对该次 Release DLL/helper，在 `data/` 保存不含
开发机路径的必要摘要。`package_windows.ps1 -PackageDirectory <目录>`
只接受本仓库 `dist/` 内不存在的新目录，逐层拒绝 reparse point 和越界路径；
默认版本目录已存在时也拒绝，不再删除历史同版本包。

原生构建与独立验包都显式要求 helper 的架构、摘要、同次来源和无设备 IPC。
macOS 最终 helper 摘要由 producer 在签名后生成，随同一 sealed artifact
流转；`--reuse-app` 只验证该包，不补文件、不修依赖、不重建或重签。
全文件 seal 不能替代 helper 必需条件。验包还调用
`test_mtp_worker_bundle.dart`，在自有隔离副本中真正拒绝缺失、空、损坏和
错架构 helper，不把一般 seal 拒绝当作产品检查成功。

`verify_mtp_worker.dart` 从包内固定路径启动 helper，使用原有四字节网络序
长度和有界 JSON 发送 `{"method":"close"}`，要求成功 null 响应及自然零退出。
初始 worker 没有 device，Close 不枚举或打开手机；ready 日志不能通过验证。
探针限制响应和 stderr，异常、超时或取消只回收自己创建的进程；子进程工作
目录固定在 helper 目录，Windows 搜索路径限包内和系统目录，macOS 不继承
开发用 DYLD 注入变量。macOS 另外验证 lipo、执行位、链接、依赖与签名。

`mtp_worker_packaging_test.dart` 执行真实 PowerShell、CMake/MSBuild、
Cargo JSON 消费、PE 校验和受控进程；Cargo/编译工具边界使用合成产物。
该文件每次在 `flutter_app/build/test-fixtures/mtp-worker-packaging/run-*`
新建独立证据目录并输出位置，编译夹具和每个用例均使用新路径；不自动删除、
覆盖或复用既有运行。内容仅为小型合成文件/工具，不含账号或用户媒体，
不进入 Runner Release 包。删除证据不是功能断言；子进程退出/drain 和
精确异常回收仍必须完成。此保留策略不表示已定位 Windows 瞬时删除拒绝的原因。
`mtp_worker_binary_test.dart` 检查实际二进制头解析，POSIX 执行位在 Windows
明确 skip。`mtp_worker_macos_packaging_test.dart` 使用合成 macOS 工具链运行
真实包装脚本，覆盖签名顺序、普通配置/双架构、reuse 不改写与具名失败；
它不是原生 macOS、真实签名、系统快捷方式或 DMG 验收。
无设备 Close 也不代表 MTP 授权、媒体读写、拔线或重连通过。

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

合入 `main` 后，现有 Validate 自动生成 Windows Inno 安装器及两种 macOS DMG，
复用该次验证中的构建产物，不额外触发构建工作流。PR 仍执行完整原生门禁，
但不自动编译 Inno；手动运行继续由 `package_installer` 控制。
测试安装包可在该次 Actions 运行的 `native-windows-x64`、
`native-macos-arm64` 和 `native-macos-x64` artifacts 中下载，保留 7 天。
下载前须确认整个工作流和 `Required validation` 成功；某个平台先上传了
artifact 不代表其他平台或完整验证已通过。

测试产物仅上传 Actions artifacts，没有 publish job、写入 Release 权限或标签
操作。`package_installer=false` 仍执行完整签名/测试/运行检查，只省略 Inno 编译。
失败后修复代码并再次手动运行即可；正式 tag 仍绑定固定提交，不覆盖已有标签。

## 失败报告与发布门禁

`ci_native.ps1` 输出动态测试汇总；`run_release_smoke.dart` 输出总 `report.json`、
分场景 `native-*.json`、脱敏日志及可用的失败截图。CI 在失败时仍上传诊断报告。
日志不包含令牌、账号回调、代理凭据或个人媒体；上传前脱敏本机目录和敏感字段。
报告中的跳过项保留明确原因，不能把未支持的平台专用测试计入通过数。

Rust/Flutter 测试失败、分析失败、原生步骤失败、退出码非零、超时或缺少有效报告
均阻止发布。必须等待 Windows x64、macOS arm64、macOS Intel 三个矩阵目标、
Android 构建/验包/正式签名以及基础验证与历史扫描成功后，正式 tag 才能上传
Release 资产。版本一致性和 SHA-256 校验继续执行；不修改已发布 tag，
也不因为只有一个平台成功就发布部分资产。

`release_asset_collection_test.dart` 在隔离临时目录执行 Release 工作流的实际
收集脚本，验证四个安装包的字节及统一摘要，并检查缺失/空 APK、篡改、错误
版本/摘要、测试产物替代、桌面包缺失/重复及既有输出目录拒绝。输入均为合成
文件；此测试只证明发布收集边界，不代表真实签名或设备安装验收。
运行前检查 Bash 4+ 与 GNU sha256sum；不兼容的系统 shell（例如 macOS
默认 shell）明确 skip 并说明原因。Ubuntu 发布主机及 Windows Git Bash
继续执行真实行为测试，不将缺工具造成的失败计为负面用例通过。

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
