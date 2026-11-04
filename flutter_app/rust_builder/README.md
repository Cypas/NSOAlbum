# Flutter / Rust 构建接入

本目录是将 Flutter 各平台构建与 Rust Core 连接的胶水层，
不是另一份 Rust 业务实现。业务源码位于仓库的 `rust_core/`，
跨语言 API 仍通过 `rust_core/src/bridge.rs` 暴露。

`cargokit/` 是随工程保留的第三方构建工具，包含自己的 `LICENSE` 和
`build_tool/README.md`；后者是上游包的模板说明，不是 NSOAlbum 的功能文档。
不要将“构建胶水”理解为可删除目录：平台构建仍依赖其中的配置与工具。

桌面 MTP helper 也来自同一 Rust crate，不在本目录复制业务代码。
Windows 的应用 CMake 在 Cargokit 库目标之后调用自身 helper 构建目标，
将工作进程放到 Runner EXE 同级；macOS 的 Runner phase 在 Flutter embed
之后、应用最终 CodeSign 之前构建和复制到 `Contents/MacOS`，而不是 Pod
输出目录。Debug 对应 Cargo debug，Profile/Release 对应 Cargo release。
普通 macOS 双架构按两个实际 Rust target 构建并以 lipo 合并；helper
在根应用之前签名，Android 不携带它。

自身胶水和 `tool/build_desktop_native.dart` 消费本次 Cargo JSON，
不依赖 Cargokit 函数内未导出的环境变量，不修改 `cargokit/` vendor。
构建报告留在 ignored 输出；独立验包、签名和设备验收的区别见
[测试文档](../../docs/TESTING.md#桌面-mtp-helper)。

上级入口：[Flutter 工程说明](../README.md) ·
[完整文档树](../../docs/DOCUMENTATION-MAP.md) ·
[目录规范](../../docs/REPOSITORY-LAYOUT.md)。
