# 鱿型相册 Flutter 客户端

Flutter 负责跨平台界面与系统集成，Rust Core 负责 SQLite、媒体文件、Nintendo/NXAPI/Coral、导入与同步状态。

## 工程结构

- `lib/src/rust/`：由 `flutter_rust_bridge_codegen` 生成的绑定，不手工修改（动态库 stem 配置除外）。
- `lib/src/backend/`：Dart 后端门面、安全凭据存储与登录/同步流程。
- `lib/src/state/`：设置和同步状态控制器。
- `rust_builder/`：Cargokit 平台构建脚手架。
- `../rust_core/`：Rust 核心 crate。

## 本机工具链

- Flutter 3.47.6 / Dart 3.13.5
- Rust 1.99.0 stable，含 Cargo、rustfmt、Clippy
- flutter_rust_bridge 2.13.0
- Visual Studio 2022 C++ Build Tools 与 Windows SDK

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

Windows 使用 Flutter 插件前必须启用系统“开发者模式”，否则无法创建插件符号链接。Android 构建还需配置 Android SDK/NDK 和兼容 JDK。

若本机全局 Git/Cargo 代理指向未运行的 `127.0.0.1:7890`，只在当前终端清除代理后执行下载命令；不要把临时网络配置提交到项目。
