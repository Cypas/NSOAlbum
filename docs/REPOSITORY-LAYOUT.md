# 仓库目录与文件存放规范

> 更新日期：2026-10-25

本文规定项目文件放置、Git 提交边界和本地数据保护。产品规则以当前设计文档为准；
测试/构建以 [测试文档](TESTING.md) 为准；文档职责见
[文档地图](DOCUMENTATION-MAP.md)。

## 1. 仓库结构

```text
仓库根目录/
├─ .github/                  GitHub Actions workflows 和共享 actions
├─ docs/                     公开开发/测试/法律说明及本地内部设计
├─ flutter_app/              Flutter 客户端、各平台 runner、测试和工具
├─ rust_core/                Rust 核心库、bridge、数据库、同步及测试
├─ installer/                Windows 安装器模板
├─ dist/                     本地构建、CI 历史与诊断资料（忽略）
├─ local-assets/             本地素材归档（忽略）
├─ README.md                 项目入口
├─ CONTRIBUTING.md           贡献规则
├─ SECURITY.md               安全漏洞报告方式
└─ LICENSE                   原创代码许可
```

不要求仓库始终包含所有本地目录；不要仅为补目录树创建空目录。

## 2. 源码、生成文件与测试

| 文件类型 | 位置 | 规则 |
| --- | --- | --- |
| Flutter 应用和页面 | `flutter_app/lib/` | Windows/macOS 使用桌面界面，Android 使用 `lib/src/ui/android/` |
| Flutter/Rust Bridge 生成绑定 | `flutter_app/lib/src/rust/`、`rust_core/src/frb_generated.rs` | 需要提交但不得手工编辑；通过 `flutter_app/tool/generate_bridge.ps1` 生成 |
| Rust 核心业务 | `rust_core/src/` | SQLite 访问只在 `database.rs`；媒体仓库归 Rust 所有 |
| Flutter 测试 | `flutter_app/test/` | Android 页面、品牌、更新和 Gradle 测试位于 `test/android/` |
| Rust 测试与合成夹具 | `rust_core/src/`、`rust_core/tests/fixtures/` | 只使用合成数据，不放个人图库、token 或账号资料 |
| Android JVM 测试 | `flutter_app/android/app/src/test/` | 不将测试辅助代码混入产品运行入口 |
| 平台 runner 和原生桥 | `flutter_app/windows/`、`macos/`、`android/` | 原生行为变化按测试文档进行平台验证 |
| 构建/打包/验收工具 | `flutter_app/tool/` | 开发入口与正式产品入口须明确区分 |
| 法律与素材声明 | `docs/legal/` | 原创代码 MIT 不覆盖第三方字体、库、图像或商标 |

新增目录职责优先放在已有模块；避免重复实现相同业务和测试。生成代码也需
随源码验证和维护，不能因“自动生成”而忽略或从提交中剔除。

## 3. 内部资料、CI 下载与构建产物

- 本地忽略的 `AGENTS.md`、`docs/design/`、`docs/protocol/`、
  `docs/prototypes/`、`docs/CHANGELOG.md` 和需求核对表按
  `.gitignore` 及 `DOCUMENTATION-MAP.md` 的当前标记处理。不要把内部资料
  自动公开、打包或复制进用户可见界面。
- CI 验收时本机不得下载、解压、复制或安装 workflow artifacts/打包产物；
  应检查 GitHub Actions run/job/step 结果、日志和产物元数据。Workflow runner
  内部为自动构建、验包和发布传递 artifact，不属于本机下载。
- 如果本地已经存在历史 CI 下载，保留在
  `dist/ci/history-downloads/<run-id>/<platform-or-artifact>/`。不得猜测
  缺失的 run ID、合并覆盖目录或散放在仓库根目录。归档规则不授权新增下载。
- 本地构建输出和临时验收材料放在固定构建根或 `dist/<专题>/`；按
  本机 `AGENTS.md` 指定的源码与构建副本规则操作。不得把构建缓存、APK/EXE、
  数据库、日志或截图作为源码提交。
- 忽略的构建目录可再生成，但“忽略/未提交”不等于“可以删除”。不得为清理目录
  擅自删除本地凭据、账号数据、用户图库、历史证据或既有构建产物。

## 4. 忽略与隐私边界

仓库级忽略规则位于根 `.gitignore`，平台/工具专用规则位于对应子目录。忽略项
应尽量限定路径，不使用宽泛模式隐藏源码或测试。常见忽略内容包括：

- `target/`、Flutter `build/`、`.dart_tool/`、Gradle `.gradle/`、
  Android build 和平台 ephemeral 输出。
- `dist/`、本地未使用素材、内部设计/验收资料和 IDE 工作区。
- 用户数据库及 WAL/SHM、应用日志、备份、本机环境配置和 Gradle 本地密钥配置。
- 令牌、代理凭据、签名密钥/证书、用户媒体及个人账号资料。

忽略规则不影响已跟踪文件；凭据扫描不能只依赖扩展名或 `.gitignore`。
提交前检查目标文件列表及敏感内容，不全量暂存，不包含开发机绝对路径。

移动或归档文件前确认具体路径、用途、引用和目标冲突；删除需单独授权。
本规范只适用于开发仓库，不改变应用私有目录、系统安全存储、用户选择图库
或安装器目录的安全边界。
