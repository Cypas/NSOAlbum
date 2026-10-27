# 历史文档导航（截至 2026-10-25）

> 旧版文档树保留作历史索引，不作为当前规范。当前入口为 `DOCUMENTATION-MAP.md`。

更新日期：2026-10-14

本页回答“某一层目录里的文档是做什么的、什么时候读、是否提交”。
文件存放位置以 [目录规范](REPOSITORY-LAYOUT.md) 为准，本页维护文档之间的关系，
不复制各文档的正文。面向开发者的总入口是 [文档索引](README.md)。

## 1. 标记与边界

- **公开**：应随源码维护并提交；不代表自动打包进应用。
- **本地**：按当前忽略规则保留，不提交、不上传、不随应用分发。
  本页只说明相对位置和用途，不公开内部正文、日志、账号或测试数据。
- **第三方**：原依赖或下载工具自带，保留来源和原许可证；
  是否提交取决于它属于源码依赖还是本地下载。
- **生成**：由构建、依赖或诊断工具产生，不作为人工维护的项目文档。

这是当前目录约定的文档树，不是新的产品实现计划。公开仓库可以没有标为
“本地”的文件；不要为了补齐文档树去强制添加被忽略的文件。

## 2. 项目文档树

```text
仓库根目录/
├─ README.md                              [公开] 产品和开发总入口
├─ CONTRIBUTING.md                        [公开] 贡献、分支、PR 和发布约定
├─ SECURITY.md                            [公开] 漏洞私下报告与安全沟通渠道
├─ LICENSE                                [公开] 原创代码许可证
├─ AGENTS.md                              [本地] 仓库开发边界及协作约束
├─ docs/
│  ├─ README.md                           [公开] 文档索引及打包/诊断导航
│  ├─ REPOSITORY-LAYOUT.md                 [公开] 文件存放和忽略规范
│  ├─ DOCUMENTATION-MAP.md                 [公开] 本文：完整文档树和用途
│  ├─ TESTING.md                          [公开] 测试分类、CI 和原生门禁
│  ├─ CHANGELOG.md                        [本地] 版本与历史实施记录
│  ├─ legal/
│  │  ├─ THIRD-PARTY-NOTICES.md            [公开] 依赖与字体等第三方声明
│  │  └─ ASSET-ATTRIBUTION.md              [公开] 图标、图片、字体来源与权利边界
│  ├─ design/                             [本地]
│  │  ├─ nso-photo-design.md              产品、架构、数据和交互设计基线
│  │  ├─ android-ui-redesign-spec.md       Android 独立界面层的专题设计
│  │  ├─ device-sync-spec.md               跨设备配对、数据及恢复的批准规格
│  │  ├─ device-sync-execution-spec.md     准入、缓存、本地交接及任务生命周期增补
│  │  ├─ device-sync-local-apply-design.md 网络到本地应用的授权和恢复技术设计
│  │  ├─ device-sync-throughput-design.md  同步吞吐、会话结果复用与测量的本地技术设计
│  │  ├─ ci-gate-progress.md               历史三平台 CI 实施过程，不是现行规则
│  │  └─ plans/
│  │     ├─ 2026-10-13-android-ui-redesign.md
│  │     │                                Android 界面改造的执行计划与状态
│  │     ├─ 2026-10-14-android-experience.md
│  │     │                                移动体验/同步下载的任务分解与实施记录
│  │     ├─ 2026-10-15-account-tools.md     三平台账号工具与移动同步展示的本地实施计划
│  │     ├─ 2026-10-16-device-sync.md       跨设备配对、同步及恢复的本地实施计划
│  │     ├─ 2026-10-17-device-sync-execution.md
│  │                                        执行增补第一切面：验证缓存及复用
│  │     ├─ 2026-10-17-device-sync-space.md   执行增补第二切面：分卷峰值空间预算
│  │     ├─ 2026-10-17-device-sync-local-apply.md
│  │                                        本地应用交接、原生所有权及账号收尾计划
│  │     ├─ 2026-10-17-device-sync-native-fixes.md
│  │                                        Windows 引擎前选主、TLS 背压及 Android 目录修正
│  │     ├─ 2026-10-18-device-sync-phone-control.md
│  │                                        手机单端控制、预览授权及容量/速度展示实施记录
│  │     ├─ 2026-10-18-device-sync-normal-entry.md
│  │     │                                  普通主入口USB双向复验与配置/SAF问题定位
│  │     ├─ 2026-10-18-device-sync-usb-discovery.md
│  │                                        USB 自动发现、WPD快照竞态、授权复用及双向账号实测计划
│  │     ├─ 2026-10-21-multiplatform-remainder.md
│  │                                        普通剩余需求原文、逐项验收及两大项会话协作边界
│  │     ├─ 2026-10-24-gallery-pagination-viewer-window.md
│  │                                        双端图库 keyset 分页、详情邻近窗口与游戏计数聚合计划
│  │     ├─ 2026-10-24-interrupted-sync-startup-feedback.md
│  │     │                                  [本地] 配对持久状态、异常恢复与日常启动退出反馈
│  │     ├─ 2026-10-24-media-details-controls-account-history.md
│  │                                        媒体详情/控制栏、时间精度与历史账号名称同步计划
│  │     └─ 2026-10-25-desktop-android-experience-share-background-sync.md
│  │                                        桌面/Android体验、分享、通知与后台同步计划
│  ├─ protocol/                           [本地]
│  │  ├─ nxapi-request-rules.md            NXAPI/Coral请求、好友码、链式token与特殊状态规则
│  │  └─ nintendo-implementacao-para-comunidade.md
│  │                                      外部 NSO/Coral 协议研究归档
│  └─ prototypes/                         [本地]
│     └─ squid-album-preview-v5.html       可浏览的历史界面原型，不是正式客户端
└─ flutter_app/
   ├─ README.md                           [公开] Flutter 子工程结构和开发命令
   ├─ assets/fonts/
   │  └─ SmileySans-OFL.txt                [公开/第三方] 历史字体的 OFL 许可证
   ├─ test/fixtures/android/
   │  └─ README.md                        [公开] 可选 Android 原生回归的运行说明
   └─ rust_builder/
      ├─ README.md                        [公开] Flutter/Rust 构建胶水层说明
      └─ cargokit/
         ├─ LICENSE                       [公开/第三方] Cargokit 来源及许可证
         └─ build_tool/
            └─ README.md                  [公开/第三方] 上游构建工具包的模板说明
```

### 为什么内层也有 README

| 文档 | 就近保留的原因与阅读时机 |
| --- | --- |
| `flutter_app/README.md` | 只进入 Flutter 工程时即可找到 bridge、工具链和本机开发命令；不是另一份产品需求书 |
| `flutter_app/rust_builder/README.md` | 解释该目录只是 native 构建胶水，不是另一个 Rust 业务实现；改构建接入时阅读 |
| `flutter_app/rust_builder/cargokit/build_tool/README.md` | 上游脚手架自带的样例包说明；不代表应用增加命令行产品或要求照此开发 |
| `flutter_app/test/fixtures/android/README.md` | 夹具涉及实际 Gradle/JVM、合成视频及普通页面布局 Live 真机回归和显式启用条件，必须在运行前就近看见 |
| `flutter_app/assets/fonts/SmileySans-OFL.txt` | 是许可证，不是可删的使用指南；字体本地归档后仍保留声明供打包脚本使用 |

`rust_core/` 当前没有独立 Markdown 指南，业务架构由设计基线、
公开开发说明和 Rust 源码共同说明；不为了填满每层目录而新增重复 README。
`.github/` 和 `installer/` 的使用入口也在公开测试/打包文档中。
各平台的 `CMakeLists.txt` 是构建脚本，不是文本说明，不能当文档移动或忽略。

## 3. 本地工作记录与诊断文档树

本地 `docs/design/plans/2026-10-18-multiplatform-sync-experience.md` 记录多端同步、
认证复用、日志、好友与 Android 搜索的批准行为和实施状态；执行账本位于
`.superpowers/sdd/2026-10-18-multiplatform-sync/`，不提交或随应用分发。
普通剩余需求的逐项核对表位于本地 `docs/REQUIREMENTS-CHECK-20261021.md`；
对应批准计划和完整原始需求登记位于本地
`docs/design/plans/2026-10-21-multiplatform-remainder.md`，同时约定另外两个
大项会话的文件所有权和主会话集成门禁，不随应用分发。
图库动态加载、详情邻近窗口和游戏统计聚合的后续计划位于
`docs/design/plans/2026-10-24-gallery-pagination-viewer-window.md`；
其中完整保留新增原始描述、分页/聚合接口边界和最终验收模板。
其实现使用 `gallery_page_controller.dart` 和 `media_window_controller.dart` 管理
查询代数、有限详情窗口及迟到响应；SQLite 的时间索引、相册规则编译和窄计数仍
集中在 `database.rs`。本地核对表分别登记软件回归、Debug 构建与未验收平台。
后续详情布局、视频控制栏、秒级时间和历史账号名称映射的需求原文及实施顺序位于
`docs/design/plans/2026-10-24-media-details-controls-account-history.md`。
该计划为本地未实施方案，分离 UI 小项、名称缓存和账号载荷版本/恢复验证；
其存在不表示已经修改账号同步格式、完成实机验收或发布。
账号工具、系统通知、视频详情与代理缓存的后续证据持续记在该表，代码与测试
位置见目录规范。该表包含内部原始需求与未验收说明，不作为产品材料或发布证明。
同一本地计划还记录 Android 详情页和跨平台视频首帧封面的已批准增补、测试及未验收边界。
桌面与 Android 体验、系统字体、日期/分享、通知跳转、启动同步及后台任务的
后续原始需求和逐项状态位于
`docs/design/plans/2026-10-25-desktop-android-experience-share-background-sync.md`；
该计划保留 17 条用户原文，并区分代码、自动测试、Debug 构建和实机验收。
后续使用 `plan` 命令生成计划时，必须依照 `AGENTS.md` 的原始需求保留规则，
在计划、核对表和最终验收记录中逐字保留用户原文；结构化摘要不能替代原始描述。
`docs/design/device-sync-throughput-design.md` 是后续传输优化的本地设计，
用于区分协议边界、测量口径和分阶段验收；不提交或随应用分发，
其存在不代表新协议已经实现或通过实机测试。对应本地实施计划为
`docs/design/plans/2026-10-19-device-sync-throughput.md`。
两份本地材料也记录连续传输、增量校验、业务回执与信箱回收解耦的后续设计；
当前获准的窗口/累计回执与USB v3切面也在同两份材料中分列，明确能力协商、
小文件批次及字节/回收硬预算，实施记录不表示已经取得新设备测速结论。
已实现切面、候选协议及未验收项分开标记，不在公开索引复制内部方案正文。
该专题的本地测量、RED/GREEN 与设备对照记录放在
`dist/device-sync-throughput-20261019/RESULTS.md`（本地、不提交），
须区分纯模型、原生通道、预热和正式三轮基准，不能以预热替代优化验收。
二进制媒体与 USB 大载荷的后续台账另存为同目录 `BINARY-V4-RESULTS.md`，
由上述历史入口链接；只归档实际完成的检查与设备证据，不把设计参数当作实测结果。
SAF 合成吞吐工具与回归的位置见目录规范的“无账号设备文件通道探针”条目；
其结果仅覆盖原生字节通道，不能替代二维码授权、图库应用或真实账号验收。
真实同步页面的独立合成图库 QA 用法、进程级 Rust Core 的热重启边界和
恢复普通 Debug 包的要求见 `flutter_app/README.md` 的“独立图库协议 QA”。

以下目录均为 **本地、不提交**。它们保存实现证据和历史过程，
与源码中可重复运行的正式测试不是同一种材料。

```text
仓库根目录/
├─ .superpowers/sdd/2026-10-14-android-experience/
│  ├─ progress.md                         工作进度台账
│  ├─ task-1-brief.md                      核心任务约束与交接说明
│  ├─ task-1-report.md                     核心任务实施报告
│  ├─ task-4-brief.md                      移动端任务约束与交接说明
│  ├─ task-4-report.md                     移动端任务实施报告
│  ├─ root-integration-report.md          集成验证和遗留项
│  ├─ final-fix-report.md                  修正记录及相关验证
│  └─ final-scoped-review.md               指定范围的复核结论
├─ dist/
│  ├─ android-ui-2026-10-13/
│  │  ├─ RESULTS.md                        Android 界面改造的本地验证
│  │  └─ device-s20/DEVICE-RESULTS.md       对应真机检查
│  ├─ android-branding-2026-10-13/
│  │  ├─ RESULTS.md                        应用身份、名称、图标的验证
│  │  └─ device-s20/
│  │     ├─ DEVICE-RESULTS.md              品牌相关设备检查
│  │     ├─ LOGIN-NETWORK-DIAGNOSIS.md     登录联网问题诊断
│  │     └─ DEBUG-AND-PERMISSIONS.md       调试模式与权限核对
│  ├─ android-experience-2026-10-14/
│  │  ├─ RESULTS.md                        移动体验/任务反馈的实施验收
│  │  ├─ PERFORMANCE.md                    性能采样方法、结果与限制
│  │  ├─ NAVIGATION-DIAGNOSIS.md           页面返回红屏的定位证据
│  │  ├─ ALBUM-RETURN-FIX.md               相册返回修复和回归结果
│  │  └─ COMPACT-CARD-FOLLOWUP.md          卡片尺寸、单列和标签的后续验证
│  └─ ci/
│     ├─ history-downloads/
│     │  ├─ README.md                     CI 历史下载归档规则
│     │  └─ <run-id 或旧目录名>/          下载报告/日志/截图，不逐个复制成项目文档
│     ├─ cache-benchmark/RESULTS.md       CI 缓存与耗时对比，含适用条件
│     ├─ android-signing-update-20261014/RESULTS.md
│     │                                  签名与更新相关的本地验证
│     └─ branch-migration-tools/
│        ├─ pr-body.md                    既往分支迁移的 PR 描述草稿
│        ├─ gitleaks/README.md            [第三方] 下载的凭据扫描工具说明
│        └─ actionlint/                   [第三方] 下载的工作流检查工具
│           ├─ README.md                  工具入口
│           └─ docs/
│              ├─ README.md              上游文档导航
│              ├─ usage.md               调用方式
│              ├─ reference.md           参数/行为参考
│              ├─ install.md             安装说明
│              ├─ config.md              配置说明
│              ├─ checks.md              检查规则
│              └─ api.md                 上游 API 说明
└─ local-assets/unused-fonts/
   ├─ README.md                           闲置字体归档、来源和再分发边界
   └─ SmileySans-OFL.txt                   [第三方] 随本地归档字体保留的许可证副本
```

这些是目前已有的专题记录。将来增加同类验收主题时继续放在对应 `dist/` 专题，
不把过程报告提升为现行规范。新的外部下载统一走
`dist/ci/history-downloads/`；已有工具包保留其上游文档结构。
不以本页中某份历史报告的存在推断当前功能或 CI 已通过。

## 4. 构建和分发目录里的文档

以下内容按类别列出，不逐个登记每个版本的依赖许可证或自动生成 HTML：

| 位置 | 文档用途 | 提交边界 |
| --- | --- | --- |
| `flutter_app/android/build/reports/` | Gradle 自动生成的问题与构建诊断，例如 `problems-report.html` | 本地/生成，忽略 |
| `flutter_app/build/`、`rust_core/target/` 及其他平台临时构建目录 | 工具链和依赖生成的说明、报告或元数据 | 本地/生成，忽略 |
| `dist/` 中打包好的运行目录之 `docs/` | 打包脚本挑选的面向使用者说明 | 输出本地忽略；来源文档按其自身规则维护 |
| 同一分发目录的 `licenses/` | 随应用依赖或素材一起分发的法律声明 | 输出本地忽略；不能因目录忽略就漏发许可证 |
| 下载的 CI artifact 内部 `native-reports/` 等目录 | 本次或历史运行的检查结果；可能是 JSON、JSONL、图片而非 Markdown | 本地下载归档，不上传真实账号/媒体 |
| IDE/包管理缓存中的 README、LICENSE | 对应工具或依赖自己的文档，不是本项目需求或架构说明 | 服从缓存目录忽略规则，不手工维护 |

忽略不等于可以删除。唯一历史证据、许可证和本地未公开记录是否清理，
仍需按 [目录规范](REPOSITORY-LAYOUT.md) 的安全要求另行确认。

## 5. 阅读顺序与维护责任

- 了解软件：根 `README.md` → `docs/README.md`。
- 判断文件放哪里、是否提交：`REPOSITORY-LAYOUT.md` → 本页。
- 修改产品交互/业务：本地设计基线 → 对应专题设计/计划 → 源码与测试。
  公开 checkout 缺少内部材料时，依据公开说明和现有代码确认范围，
  不把缺失材料当成验收通过或自行编造内部决策。
- 修改测试/CI/打包：`TESTING.md` → 相关子工程或夹具 README → 脚本与工作流。
- 处理字体/图标/依赖：`docs/legal/` → 对应原始许可证；
  历史报告不能替代素材授权。

本页是文档导航，目录规范负责位置规则，设计基线负责产品与架构，
测试文档负责验证流程。专题历史记录只解释当时过程，不覆盖这三者。

新增、改名或归档文档时，同时更新本页及父级索引；
子目录 README 说明本层用途并提供回到总索引的相对链接。
第三方原文、许可证和生成文档不为统一样式而擅改。
公开索引对本地文档只写路径、用途和“不提交”标记，不建立必须存在的公开链接，
也不复制敏感内容。这样本地维护者能查到完整树，公开源码不会因缺少内部文件
出现一批失效链接。

跨设备同步批准规格保存在本地 `docs/design/device-sync-spec.md`；
实施台账在 `.superpowers/sdd/2026-10-16-device-sync/`，本地传输/设备证据在
`dist/device-sync-20261016/`。这些内部材料不提交，不存放真实账号凭据或作为发布证明。
执行增补台账在`.superpowers/sdd/2026-10-17-device-sync-execution/`，
起始冻结源/中断日志及新合成证据在`dist/device-sync-20261017-execution/`；
均本地保留不提交，不覆盖旧计划证据。
空间预算台账在`.superpowers/sdd/2026-10-17-device-sync-space/`，
合成预算/页面/复验与修正证据在`dist/device-sync-20261017-execution/space/`；
本地交接技术设计及计划也属于本地不提交文档，不代表已实现或设备验收通过。
对应源码中，`flutter_app/lib/src/startup/` 负责页面无关的启动准备及桌面等待式关闭，
`lib/src/backend/device_sync/` 拥有设备恢复生命周期，
`lib/src/ui/device_sync/` 放置启动反馈与设备同步展示；测试位于
`flutter_app/test/device_sync/`。这些目录的存放边界仍以目录规范为准。

桌面 helper 的普通三模式/双架构构建、来源摘要、独立验包和无设备 IPC 边界见
`docs/TESTING.md` 的“桌面 MTP helper”；构建胶水入口见
`flutter_app/rust_builder/README.md`。本地 `task-5c-brief.md`、
`task-5c-report.md` 与 `dist/device-sync-20261016/task5c/` 分别保存合同、
作者报告和 before/after、补丁、构建及负面检查证据，不提交、不随应用分发，
不作为真实 MTP 或 macOS 验收通过声明。
有界二进制载荷 IPC 的源码、独立参考夹具及验包探针位置见目录规范对应条目；
后续协议演进、定向回归和未验收平台仍记录于本地同步吞吐设计与计划，
不把无设备的子进程回归视为 MTP 实机测速。

账号工具的原生 WebView 探针及其运行前提见 `flutter_app/README.md`；
Windows 系统 DLL 依赖的成品 PE 回归与无 UI SDK 子进程对照见 `docs/TESTING.md`
的“Windows WebView DLL 生命周期”；对应源码位于
`test/windows_webview_loader_test.dart` 和 `test/fixtures/webview_lifetime/`，
探针结果不代替正式应用的进程退出与媒体功能验收。
同节说明 `tool/windows_plugin_lifetime.cmake` 的构建树派生源码、升级失败关闭
规则及真实子进程 WM_CLOSE 退出验收，不能以 Flutter 工具退出码代替。
同页“Windows 系统通知 Live 验收”列出显式合成入口、系统历史比对和
实际 COM 激活边界；其宿主 skip 不代表真实系统通知已通过。
本地实施、审查和设备验收记录分别归档于
`.superpowers/sdd/2026-10-15-account-tools/` 与 `dist/time-sync-display-20261015/`，
均不提交，不包含公开发行验收结论或真实账号导出文件。

`dist/device-sync-deviceqa-20261017/` 保存 Windows/Android Debug 实机通道检查，
其 `round2/` 保存桌面单实例和后续传输测试的过程、失败与最终结果；
均为本地忽略资料，不包含个人图库或账号凭据，不能以局部通道通过代替完整同步验收。
本地 `docs/design/plans/2026-10-17-device-sync-native-fixes.md` 记录上述失败后的
原生启动拦截、有界输入背压及 Android 目录句柄修正计划；新增证据在同专题
`round3/`，不覆盖前轮结果，不提交内部计划及设备日志。
该轮 `RESULTS.md` 分别记录两轮双向融合/覆盖与重复启动通过、完整软件回归、
手机原包恢复，以及仍未解决的诊断主窗口退出异常；局部通过不代表整体验收完成。
同专题 `round4-full-app/` 记录正常主入口的两端完整 Debug 构建、Android
覆盖安装与后续应用内验收进度；构建/安装记录不代表已完成传输或授权个人库写入。

内部配对输入接口及调用边界见 `flutter_app/README.md` 的“Debug 配对输入接口”；
本地失败测试、生命周期回归及完整 Flutter 复验见
`dist/device-sync-debug-pairing-20261018/RESULTS.md`，不提交、不随应用分发。
调试输入不绕过配对、账号及接收预览确认；其验证结果不能替代扫码或真实传输验收。

后续连接方式自动选择、SSID 提示与安装包版本/构建号严格匹配的接口说明同在
`flutter_app/README.md`；本地失败测试、审查修正、合成 Bridge 验证和两端 Debug
构建/设备记录放在 `dist/device-sync-auto-connection-20261018/`，本地、不提交。
这些记录须分别标明源码测试、原生构建和实机步骤，不将一个阶段当作其余阶段通过。

桌面相册、导入与同步、设置的标题栏溢出修正记录在本地设计基线对应章节，
真实字体的失败复现、定向分析及页面回归日志存于
`dist/desktop-header-overflow-20261018/`（本地、不提交）。
正式回归用例为 `flutter_app/test/desktop_page_header_test.dart`；
widget 通过不表示正在运行的应用包已更新。

手机单端控制和后续本地交接的真实 Debug 设备证据保存在
`dist/device-sync-phone-control-20261018/`。本地交接继续既有批准计划，
其任务台账/brief/独立审查放在
`.superpowers/sdd/2026-10-17-device-sync-local-apply/`，
源码 before/after 与分任务验证放在上述设备专题的 `local-apply/`；
均本地、不提交。旧失败和冻结快照不覆盖，真实 USB、Wi-Fi、非零媒体、
本地应用及账号安全存储分别记录，不能相互替代验收。
