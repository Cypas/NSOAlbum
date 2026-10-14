# Flutter / Rust 构建接入

本目录是将 Flutter 各平台构建与 Rust Core 连接的胶水层，
不是另一份 Rust 业务实现。业务源码位于仓库的 `rust_core/`，
跨语言 API 仍通过 `rust_core/src/bridge.rs` 暴露。

`cargokit/` 是随工程保留的第三方构建工具，包含自己的 `LICENSE` 和
`build_tool/README.md`；后者是上游包的模板说明，不是 NSOAlbum 的功能文档。
不要将“构建胶水”理解为可删除目录：平台构建仍依赖其中的配置与工具。

上级入口：[Flutter 工程说明](../README.md) ·
[完整文档树](../../docs/DOCUMENTATION-MAP.md) ·
[目录规范](../../docs/REPOSITORY-LAYOUT.md)。
