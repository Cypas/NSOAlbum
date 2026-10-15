# 仓库目录与文件存放规范

更新日期：2026-10-14

本文规定开发文件放在哪里、哪些内容提交 Git，以及本地资料如何归档。
新增文件、下载 CI 数据或调整目录时先按本文分类；不要在仓库根目录临时堆放
报告、字体、安装包或测试数据。产品功能与架构以内部设计文档为准，
验证流程见 [测试文档](TESTING.md)，素材权利见 [素材授权说明](legal/ASSET-ATTRIBUTION.md)。
各层 README、专题设计、内部验收和第三方工具文档的完整关系见
[文档树与阅读导航](DOCUMENTATION-MAP.md)，包括本地不提交文档的用途。

## 1. 顶层目录

```text
仓库根目录/
├─ .github/                       CI 工作流与共享 Actions
├─ docs/                          文档索引、目录规范、测试和法律声明
├─ flutter_app/                   Flutter 客户端、平台 runner、测试和构建工具
├─ rust_core/                     Rust 业务核心与测试
├─ installer/                     Windows 安装器源码和模板
├─ dist/                          本地构建包、验收与诊断资料，忽略
│  └─ ci/
│     └─ history-downloads/       所有本地下载的 CI 历史数据
├─ local-assets/
│  └─ unused-fonts/               未使用字体的本地归档，忽略
├─ .gitignore                     仓库级忽略规则
├─ README.md                      项目入口
├─ CONTRIBUTING.md                贡献说明
├─ SECURITY.md                    安全政策
└─ LICENSE                        原创代码许可证
```

本地还可能存在被忽略的 IDE、代理工作记录和内部 `AGENTS.md`。
上图是存放约定，不表示每个目录都必须存在，也不要求创建空目录。

## 2. 源码、测试与工具

| 内容 | 存放位置 | 是否提交 |
| --- | --- | --- |
| Flutter 启动入口 | `flutter_app/lib/main.dart` | 是 |
| Android 独立页面和移动布局 | `flutter_app/lib/src/ui/android/` | 是 |
| 桌面界面与共享展示组件 | `flutter_app/lib/src/ui/` 中对应模块 | 是 |
| Dart 后端门面、状态控制器 | `flutter_app/lib/src/backend/`、`flutter_app/lib/src/state/` | 是 |
| 跨平台账号好友、观星与内嵌网页组件 | `flutter_app/lib/src/ui/account_tools/` | 是，平台外框与原生策略分离 |
| Rust 数据库、文件仓库、协议、导入与同步 | `rust_core/src/` | 是 |
| Flutter 单元/widget 测试 | `flutter_app/test/`，Android 测试放其 `android/` 子目录 | 是 |
| Android JVM 测试 | `flutter_app/android/app/src/test/` | 是 |
| 可重复使用的合成测试夹具 | `flutter_app/test/fixtures/<模块>/` | 是 |
| 构建、打包、校验和生成脚本 | `flutter_app/tool/` | 是 |
| 无账号 WebView 原生生命周期探针 | `flutter_app/tool/account_tools_webview_smoke.dart` | 是，独立开发入口，不访问账号/图库 |
| Android/macOS/Windows runner 源码与配置 | `flutter_app/android/`、`macos/`、`windows/` 的对应源码目录 | 是 |
| Windows 安装器模板 | `installer/` | 是 |
| GitHub 工作流与共享 Action | `.github/workflows/`、`.github/actions/` | 是 |

Rust 独占 SQLite 和内容寻址原件；不得以整理目录为由把业务移入 Flutter
或增加 Python 运行时。Android 原生能力保持范围明确的 Kotlin bridge。

Android 功能测试（页面、品牌、更新、APK 契约及 Gradle 配置）统一放在
`flutter_app/test/android/`，共享的合成夹具继续在 `test/fixtures/android/`。
共享控制器状态测试保留在 `test/state/`，不按文件名中的平台词强行迁移。
移动测试时同步相对导入、显式运行命令及文档；完整 CI 的递归发现和
平台分类统计规则见 [测试文档](TESTING.md)。

`flutter_app/lib/src/rust/` 与 `rust_core/src/frb_generated.rs` 是生成代码：
需要提交，但不能手改。修改 bridge/跨层 DTO 后使用
`flutter_app/tool/generate_bridge.ps1` 统一重新生成并验证两侧签名。
“生成文件”不等于“应忽略文件”。

## 3. 素材与字体

应用实际使用的图片、教程、图标和合成媒体资源放在
`flutter_app/assets/` 的对应子目录，并由 `pubspec.yaml` 明确声明。
默认字体仅保留 `flutter_app/assets/fonts/default/` 中当前使用的三份：
`DFPT_ZY9.ttf`、`DFP_GBZY9.ttf`、`BlitzMain.otf`。Android 使用平台默认字体；
这些内置字体仍是桌面运行资源，不能移进忽略目录。

未被应用或测试使用的字体统一放在 `local-assets/unused-fonts/`，
保留原文件名和必要的子目录，许可证与来源说明一并保留。该目录不提交、
不打包；不把闲置字体重新堆到 `assets/fonts/`。测试应优先使用自制合成数据，
不要为错误格式校验依赖完整第三方字体。

`SmileySans-OFL.txt` 等已保留的法律声明不因字体归档而删除。
是否打包、是否提交及是否获得再分发许可是三个独立问题；
放进忽略目录不代表获得授权，也不会清除已有 Git 历史。

## 4. 本地输出与历史资料

| 内容 | 目录规范 | 注意事项 |
| --- | --- | --- |
| CI 下载的包、报告、截图和日志 | `dist/ci/history-downloads/<run-id>/<platform-or-artifact>/` | 一次运行一个 run ID；不散建根目录文件夹 |
| 无法核实 run ID 的旧 CI 下载 | `dist/ci/history-downloads/` 下保留原目录名 | 不猜测身份，不合并覆盖同名文件 |
| 本地 CI/原生验收输出 | `dist/ci/<专题或版本>/` | 与下载归档区分，记录提交和平台 |
| 临时诊断截图、日志和一次性复现材料 | `dist/<专题>/` | 脱敏；可复用测试应移入正式测试目录 |
| 本地 Windows/macOS 安装包与运行目录 | 打包脚本生成的 `dist/` 子目录 | 不改成根目录散放，不提交二进制 |
| Flutter 编译输出和 Android APK | `flutter_app/build/` | 保持工具默认路径，不手工搬动正在使用的缓存 |
| Android Gradle 报告与测试编译输出 | `flutter_app/android/build/` | 忽略，但不忽略相邻原生源码和配置 |
| Rust 编译缓存 | Cargo 的 `target/` 目录 | 忽略；不把旧编译产物当作本次验证结果 |
| 本地未使用字体 | `local-assets/unused-fonts/` | 本地保留，可另行备份，不属于构建依赖 |

根目录 `/ci-artifacts-*/` 的忽略规则仅防止旧命名产物误提交，
不是允许继续在根目录下载。后续下载仍必须使用统一归档目录。
CI 历史失败报告可用于排错，但不能代替当前提交的测试与原生门禁；
Actions 远程 artifact 可能过期，本地独有证据需要单独备份。

## 5. 文档的公开与本地边界

- `docs/README.md` 是索引，本文是目录规则入口；
  `docs/TESTING.md` 记录测试、构建和验收规范。
- `docs/legal/` 保存许可证、第三方及素材声明，随源码维护；
  不把素材统一视为 MIT。
- 当前仓库的 `docs/design/`、`docs/prototypes/`、`docs/protocol/`、
  `docs/CHANGELOG.md` 与内部 `AGENTS.md` 按现有规则本地保留、Git 忽略。
  内部设计文档通过相对路径引用本文，不复制一套容易失效的目录规则。
- 任务沟通、需求原文、诊断过程和内部验收记录不搬入应用界面或用户安装材料。

## 6. 忽略规则如何使用

仓库级规则在根 `.gitignore`，平台/工具特有规则放在对应子目录的
`.gitignore`。新增忽略项应尽量限定路径，不用宽泛模式隐藏整个源码目录。

目前主要忽略以下内容：

- 编译与缓存：`target/`、Flutter `build/`、`.dart_tool/`、Gradle
  `.gradle/`、Android `build/`、Flutter `ephemeral/` 和平台依赖输出。
- 本地资料：`dist/`、`local-assets/unused-fonts/`、旧根目录
  `ci-artifacts-*`、内部设计资料、IDE 设置及工作记录。
- 私有数据：用户数据库及 WAL/SHM、日志、备份、环境配置、
  `local.properties` 和 `key.properties`。
- 凭据：令牌、代理认证、签名私钥、证书和密钥文件不得提交；
  不能仅依赖扩展名规则防止泄露。

忽略规则仅影响未跟踪文件，不能自动停止跟踪已提交文件。
把已跟踪字体移动到忽略目录后，Git 会显示旧路径删除，这是移出版本控制的
预期差异；本地归档副本仍在。提交前核对副本和引用，不重写历史。
需要保留的锁文件、平台源码、生成 bridge、测试和许可证不能因“看起来像自动生成”
而随意忽略。

可使用以下只读命令核对：

```powershell
git status --short --untracked-files=all
git check-ignore -v -- dist/ci/history-downloads/<文件>
git check-ignore -v -- local-assets/unused-fonts/<文件>
git check-ignore -v -- flutter_app/android/build/<文件>
```

示例中的 `<文件>` 需替换为实际相对路径。

## 7. 整理与清理安全

“不提交”“未打包”和“可以删除”不是同一件事。忽略目录可能保存唯一历史报告、
本地素材或重要工作记录，不自动等同于可清空缓存。

移动前确认用途、精确源/目标、是否已跟踪及是否有路径引用；
保留结构，避免覆盖，必要时核对文件数和 SHA-256。
删除需另行明确确认，不因加入忽略规则而顺手清理。
不清空账号、图库或旧库，也不触发应用数据迁移。

本目录规范只约束开发仓库。软件安装目录、手机应用私有目录、
用户选择的图库和系统安全存储是另外的存储边界；
不得把用户数据库、真实媒体或凭据作为普通项目文件归档。
