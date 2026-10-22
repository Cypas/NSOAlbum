# NSOAlbum Flutter 客户端

本页只说明 Flutter 子工程结构、构建接入和本机开发命令，不是独立产品设计。
上级入口：[文档索引](../docs/README.md) ·
[完整文档树](../docs/DOCUMENTATION-MAP.md) ·
[目录与忽略规范](../docs/REPOSITORY-LAYOUT.md)。

简体中文界面显示名为“鱿型相册”；英文界面和 Windows 可执行文件使用
`NSOAlbum`。Flutter package、Rust crate、数据库和既有用户数据目录保持兼容名称。

Flutter 负责跨平台界面与系统集成，Rust Core 负责 SQLite、媒体文件、Nintendo/NXAPI/Coral、导入与同步状态。

## 工程结构

- `lib/src/rust/`：由 `flutter_rust_bridge_codegen` 生成的绑定，不手工修改（动态库 stem 配置除外）。
- `lib/src/backend/`：Dart 后端门面、安全凭据存储与登录/同步流程。
- `lib/src/backend/device_sync/`：同一图库的设备同步与受控恢复生命周期；安全材料不传给页面。
- `lib/src/startup/`：核心准备、启动恢复、桌面等待式关闭与普通应用初始化的编排；
  原生关闭拦截先于核心准备安装，普通桌面窗口仅委托关闭策略，不接管原生退出。
- `lib/src/state/`：设置和同步状态控制器。
- `lib/src/ui/account_tools/`：绑定指定账号的好友、鱿鱼圈和观星页面。
- `lib/src/ui/device_sync/`：可绘制的启动检查、恢复反馈与设备同步展示。
- `test/device_sync/`：合成安全存储、生命周期及显式启用的真实 Bridge 回归测试。
- `rust_builder/`：Cargokit 平台构建脚手架。
- `../rust_core/`：Rust 核心 crate。

## 本机工具链

- Flutter 3.47.6 / Dart 3.13.5
- Rust 1.99.0 stable，含 Cargo、rustfmt、Clippy
- flutter_rust_bridge 2.13.0
- Visual Studio 2022 C++ Build Tools 与 Windows SDK
- Windows 原生 WebView 构建需要 NuGet CLI 在 `PATH`；运行鱿鱼圈需要 Microsoft Edge WebView2 Runtime。运行时缺失会显示官方安装入口，不自动安装。

## 常用命令

```powershell
cd rust_core
cargo fmt --all
cargo clippy --all-targets -- -D warnings
cargo test --lib

cd ..\flutter_app
dart format lib test
dart analyze
flutter test
```

重新生成绑定：

```powershell
.\tool\generate_bridge.ps1
```

当前生成器在此目录结构下无法自动推断动态库 stem，脚本会在生成后把 `UNKNOWN` 修正为 `squid_album_core`。

当前 Windows 开发机已启用系统“开发者模式”，因此可以直接运行 `flutter build windows --release` 创建插件符号链接。若在未启用开发者模式的机器上构建，请使用 `tool/package_windows.ps1` 中的 CMake/目录联接回退流程。Android 构建还需配置 Android SDK/NDK 和兼容 JDK。

若本机全局 Git/Cargo 代理指向未运行的本地地址，只在当前终端清除代理后执行下载命令；不要把临时网络配置提交到项目。

## 原生 WebView 验证

`tool/account_tools_webview_smoke.dart` 是独立开发入口，不启动 Rust、不读取账号或图库。
在 Windows/macOS 上执行 `flutter run -t tool/account_tools_webview_smoke.dart -d <设备ID>`；
Android 先用 `flutter build apk --debug --target-platform android-arm64 -t tool/account_tools_webview_smoke.dart`。
探针验证实际系统 WebView 的创建、JavaScript 回调、释放和重建，结果以
`ACCOUNT_TOOLS_WEBVIEW_SMOKE PASS` 为准，不以编译或进程存活代替。
运行前将 `TEMP`/`TMP` 指向仓库规定的已有本地构建根内 `temp`；Windows
探针仅在系统临时目录创建本次独占 profile，不复用真实应用会话缓存。
PASS 之后还须核对测试窗口实际进程的正常关闭退出码，不使用 Flutter
工具本身的退出码替代；结束后恢复普通 `lib/main.dart` 入口。
使用正式包名的 Android 设备运行后，必须重新覆盖安装普通 `lib/main.dart` 的 Debug 包，
不卸载或清空数据。探针不代表真实账号登录、网页代理或观星网站兼容已验收。

固定的 `flutter_inappwebview 6.1.5` Android 依赖仍调用旧 ProGuard 默认文件。
`android/webview_agp_compat.gradle` 仅为该库将这个调用映射到优化默认规则，以兼容
当前 AGP 9；不编辑插件缓存、不关闭 R8、不更改其他插件或应用规则。
回归测试通过实际 Gradle 项目验证 Debug/Release 配置，运行方法见
`test/fixtures/android/README.md`。

## 跨设备原生字节探针

### Debug 配对输入接口

正常应用的设备同步页在 Debug 模式下注册 VM Service 扩展
`ext.squid_album.deviceSyncPairing`。这是带认证调试连接中的页面输入接口，
不是额外的网络服务或产品配对方式；Release/Profile 不注册且不接受调用。

- `action=status`：读取当前页面的 `generation`、`mobile`、`transport`、
  `canInject` 和 `canRead`，不返回邀请材料。
- `action=read,generation=<当前代次>`：仅桌面当前未过期、未确认的邀请可读；
  返回 `generation` 和 `invitation`。
- `action=inject,generation=<当前代次>,invitation=<邀请>`：仅前台、可操作的
  手机设备同步页接受，走相机扫码返回后的同一连接及目录授权流程。
  成功返回 `accepted=true`，不代表配对确认或传输完成。

每次调用先检查页面代次；离页、被其他路由覆盖、手机退后台、忙状态、
过期邀请及空/超过 8192 UTF-8 字节的输入均受限制。接口不能确认配对、
配置同步范围、授权账号或批准接收预览。真实双方确认及接收确认仍使用原 UI。
邀请和调试服务认证 URL 仅在受控调试器内存中传递，不写命令行、文件或日志，
不对外暴露调试端口。该接口不替代相机识别验收。

源码在 `lib/src/ui/device_sync/debug_pairing.dart`；接口及真实页面接线测试为
`test/device_sync/debug_pairing_test.dart` 和 `debug_pairing_page_test.dart`。
手机由 Rust 校验邀请及软件版本后选择邀请中的连接方式；内部注入与相机扫码
使用相同路径，不接收独立的通道覆盖参数。

### 连接提示与应用版本匹配

桌面选择 USB 或局域网地址并创建二维码；手机不再重复选择通道。
邀请中的 `app_build` 包含平台安装包实际 `version` 和 `build_number`，
与协议版本 `version` 分开。正常页面要求两端两项完全一致；
缺少版本字段的旧邀请同样拒绝，不进入同步预览、传输或写入。
应用版本还绑定到 TLS exporter 上下文和认证消息；仅篡改二维码字段不能通过认证。
这不是自动升级能力，也不把底层无版本的合成协议夹具用于普通应用配对。

网络快照由 `lib/src/platform/device_sync_network.dart` 按需读取。
Android 仅在 Wi-Fi 配对操作中请求前台位置权限以读取 SSID，不读取位置坐标、
BSSID、附近网络或后台定位。拒绝、系统限制、读取失败和网络切换显示未知；
同名只是提示，不同名或未知仍尝试原邀请的安全连接，不静默切换 USB/Wi-Fi。
桌面只把与所选地址可靠对应的 SSID 写入邀请。所锁定插件在 macOS 上的
SSID/IP 接口可能不同，因此只显示可读名称和关联未知，不假装已确认对应关系。

邀请投影不按手机墙上时钟拒绝配对，继续沿用主机过期与单调期限保护和现有
时钟偏差冲突处理。USB 是否连到对应电脑仍由邀请绑定的安全握手与双方确认决定，
不把“插着一根线”当作设备身份。页面在权限请求前复核前台，权限弹窗恢复后才继续连接。

### 独立合成通道

`tool/device_sync_saf_probe.dart` 是独立 Android 开发入口，不初始化 Rust Core、
账号或图库。使用
`flutter build apk --debug --target-platform android-arm64 -t tool/device_sync_saf_probe.dart`
构建。系统目录选择器只接受外部存储提供方的 `Documents/NSOAlbumSync` 精确目录，
需要使用者明确授权；不申请全盘权限。探针仅在新建随机会话中交换合成字节，
不能当作 TLS、媒体同步或发布验收。设备运行后覆盖安装普通 Debug 包，不卸载或清空。

桌面独立探针在 `../rust_core/examples/device_sync_native_probe.rs`。先从 Rust
目录执行 `cargo build --bin nsoalbum_mtp_worker`，再执行
`cargo run --example device_sync_native_probe [32位小写十六进制合成会话ID]`。
仅应连接一台明确用于合成测试的 MTP 设备；省略参数时创建随机新会话。
Windows 强制使用 WPD，macOS 使用原生 USB；没有驱动替换、后台进程终止或传输回退。
只终止本探针创建的 Rust 工作进程。普通桌面构建通过工程自身胶水生成并放置
工作进程，发布验包显式检查包内固定 sibling、架构、来源摘要及无设备 Close；
该检查不枚举手机。macOS 原生运行和实际授权、读写、拔线重连须单独验收；
这些入口不表示 USB 同步已可交付。详见
[桌面 helper 构建与验包](../docs/TESTING.md#桌面-mtp-helper)。

SAF 探针另提供双向合成吞吐按钮，逻辑在
`tool/device_sync_saf_benchmark.dart`，回归在
`test/android/device_sync_saf_benchmark_test.dart`。每块 64 KiB，最多四块在途；
接收端校验字节后才确认，发送端按对端实际移除的连续前缀计数。
等待超过一分钟无进展会失败，取消保留已发布的合成块，不访问图库或账号。
此结果仅是 SAF/MTP 字节通道性能，不是应用内 TLS 同步的传输速度。

### 独立图库协议 QA

`tool/device_sync_qa.dart` 仅供 Debug 开发测试。每个进程创建全新的受控临时
图库，账号安全存储替换为该进程的空内存实现，不打开个人库或系统凭据。
它复用正常设备同步页面、Rust 协议、手机确认、空间检查与入库；没有跳过授权。
“检查合成图库”入口禁用启动同步、更新和桌面托盘策略。

在独立构建副本中运行：

```powershell
flutter run -d windows --debug -t tool/device_sync_qa.dart --dart-entrypoint-args=--ci-smoke
flutter build apk --debug --target-platform android-arm64 -t tool/device_sync_qa.dart
```

这里桌面参数仅让原生 runner 为该独立入口创建窗口；正常主入口的 CI 诊断
仍要求独立根参数并执行完整校验。该开发入口不属于正常应用、安装器或发布入口。
支持 Dart 热重载；不要对本入口热重启来换库：Rust Core 是进程级拥有者，
目录归属检查会拒绝这种不一致，重新开始请新启测试进程。
测试结束须覆盖恢复完整普通 Debug 包，不卸载、不清空、不自动启动个人账号同步。

吞吐对照可在同一独立入口增加
`--dart-define=DEVICE_SYNC_THROUGHPUT_QA=true`：两端从空合成库开始。
仅在发送端的受控 QA 根调用 `prepareThroughputFixture`，准备一份 64MiB
及 64 份各 256KiB 的有效 PNG 合成文件；每次生成的文件字节一致且不同文件
SHA-256 不同。生成及导入不计入传输用时，不更改正常入口的启动行为。
新的接收轮次必须新建进程，不能热重启或复用已含这些原件的库冒充全量传输。
阶段和原生 I/O 汇总使用单调计时，仅含固定字段及数字；原生 provider 用时、
Bridge 往返与完整同步用时不能互相替代或简单相加。
