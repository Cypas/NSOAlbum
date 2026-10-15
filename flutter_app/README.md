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
- `lib/src/state/`：设置和同步状态控制器。
- `lib/src/ui/account_tools/`：绑定指定账号的好友、鱿鱼圈和观星页面。
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
使用正式包名的 Android 设备运行后，必须重新覆盖安装普通 `lib/main.dart` 的 Debug 包，
不卸载或清空数据。探针不代表真实账号登录、网页代理或观星网站兼容已验收。

固定的 `flutter_inappwebview 6.1.5` Android 依赖仍调用旧 ProGuard 默认文件。
`android/webview_agp_compat.gradle` 仅为该库将这个调用映射到优化默认规则，以兼容
当前 AGP 9；不编辑插件缓存、不关闭 R8、不更改其他插件或应用规则。
回归测试通过实际 Gradle 项目验证 Debug/Release 配置，运行方法见
`test/fixtures/android/README.md`。
