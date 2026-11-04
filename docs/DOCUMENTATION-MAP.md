# 文档地图

> 更新日期：2026-10-26

本文说明各文档的当前职责和阅读顺序，不复制它们的正文。根目录本地 `AGENTS.md`
规定代码协作和本机工作流；本地图及历史记录不覆盖用户最新决定、当前源码或正式规格。

## 当前入口

| 需要了解 | 文档 |
| --- | --- |
| 项目、构建概览和公开开发说明 | 根目录 `README.md` |
| 贡献、分支、PR 和版本约定 | 根目录 `CONTRIBUTING.md` |
| 漏洞报告方式 | 根目录 `SECURITY.md` |
| 文件存放、忽略和本地资料边界 | `docs/REPOSITORY-LAYOUT.md` |
| 测试分类、本机开发构建、CI 和平台验收 | `docs/TESTING.md` |
| 设备同步 Debug 免扫码连接、邀请读取/注入与排障 | `flutter_app/README.md` 的“免扫码传递连接码”；验收边界见 `docs/TESTING.md` |
| 当前产品行为和架构基线 | `docs/design/nso-photo-design.md`（本地内部文档） |
| NXAPI/Coral 请求、token 阶段和好友码规则 | `docs/protocol/nxapi-request-rules.md`（本地内部文档） |
| 第三方依赖与字体声明 | `docs/legal/THIRD-PARTY-NOTICES.md` |
| 图标、图片、字体等素材授权 | `docs/legal/ASSET-ATTRIBUTION.md` |

Flutter 工程目录与子工程命令见 `flutter_app/README.md`；Rust/Flutter 接口变化
还须遵循 `flutter_app/tool/generate_bridge.ps1` 生成规则。Android 原生测试夹具
及启用条件见 `flutter_app/test/fixtures/android/README.md`。

## 内部设计与历史材料

`docs/design/`、`docs/protocol/` 和 `docs/CHANGELOG.md` 按仓库当前忽略规则
作为本地内部资料，不自动提交或打包。当前设计/协议文档定义行为；日期命名的
计划和验收报告记录用户原文、实施阶段与实际证据，不会自动变成最新需求。

| 材料 | 用途 |
| --- | --- |
| `docs/design/plans/` | 分项计划、用户原始需求核对及逐项实施记录 |
| `docs/REQUIREMENTS-CHECK-20261021.md` | 多阶段需求状态、测试、构建和设备验收总表 |
| `docs/design/nso-photo-design-history-20261025.md` | 已归档的旧版设计稿和历史实施说明；不作为现行指令 |
| `docs/DOCUMENTATION-MAP-history-20261025.md` | 已归档的旧版详细文档树，仅供追溯 |
| `docs/protocol/` | NXAPI/Coral 协议边界、参考资料和合成回归约定 |
| `docs/protocol/nxapi-request-rules-history-20261025.md` | 协议输入修正、历史对照及旧状态记录 |
| `.superpowers/`、`dist/` | 本地过程台账、诊断与验收证据；具体目录规则见仓库目录规范 |

历史材料中的版本号、计划状态、测试数量、构建路径和“待验收”描述只说明当时
情形。需要判断当前能力时，应核对当前实现、测试和当前 CI 运行，不从旧报告推断。

## 文档维护规则

- 新增或改名正式文档时，同步更新本文及父级索引。
- 产品行为以当前设计基线和有效专题规格为准；测试与 CI 以 `TESTING.md` 为准；
  路径和提交边界以 `REPOSITORY-LAYOUT.md` 为准。
- 内部计划逐字保留用户原始需求供核对；产品界面、安装器和分发说明不得展示
  用户需求、开发对话或内部验收过程。
- 不为补全文档树而创建空目录、公开本地内部文件或复制历史过程文档。
- 自动化产物、缓存、CI 包和个人数据不是项目文档；归档和忽略边界遵循
  `REPOSITORY-LAYOUT.md`。
