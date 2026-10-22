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
| Android 日志查看与常驻图库搜索 | `flutter_app/lib/src/ui/android/` | 是；日志按事件保留堆栈归属，局部选择/每错误块脱敏复制；搜索使用输入框提交 |
| 桌面界面与共享展示组件 | `flutter_app/lib/src/ui/` 中对应模块 | 是 |
| 视频首帧封面与受控邻近封面预取 | `flutter_app/lib/src/ui/video_preview*.dart` | 是；复用缩略图缓存；播放器准备归各媒体详情 PageView 所有，不由封面预取器创建；测试位于 `flutter_app/test/` |
| Dart 后端门面、状态控制器 | `flutter_app/lib/src/backend/`、`flutter_app/lib/src/state/` | 是 |
| 自动同步通知汇总与系统展示 | `flutter_app/lib/src/state/sync_notification_content.dart`、`lib/src/platform/sync_notifications.dart`；各平台 runner 窄通道 | 是；只发送汇总数，不发送账号或媒体内容；共享回归在 `test/state/` 与 `test/sync_controller_test.dart` |
| Windows 通知身份、COM 唤起与 DOM 展示 | `flutter_app/windows/runner/sync_notifications.{h,cpp}` | 是；使用系统 SDK，无第三方 toast 插件；COM 回调只投递既有无负载窗口唤起消息，退役后失效；真实 SDK DOM/线程/生命周期回归在 `test/windows_sync_notifications_test.dart` 和 `test/fixtures/notifications/native/`，合成探针不打开账号/图库 |
| Windows WebView 的系统 DLL 依赖与退出对照 | `flutter_app/windows/CMakeLists.txt`、`windows/runner/main.cpp`、`test/windows_webview_loader_test.dart`、`test/fixtures/webview_lifetime/` | 是；先可选加载系统 provider，再延迟加载 WebView 消费者，成品 PE 回归在原生验收阶段显式启用；SDK 子进程探针对照动态加载/导入/预加载与退出，不改依赖缓存、不增加 COM 引用、不访问图库或账号 |
| 视频页暂停/恢复/释放边界 | `flutter_app/lib/src/ui/video_viewer_lifecycle.dart` | 是；串行管理详情当前及相邻播放器的激活/暂停/销毁，不改变文件仓库；回归在 `test/video_viewer_lifecycle_test.dart` |
| Android 视频输出退役屏障 | `flutter_app/lib/src/ui/android/android_video_retirement.dart` | 是；停止当前版本插件的 surface/参数观察并排空既有锁内回调，再走正常 Player 清理；不修改依赖缓存；回归在 `test/android/android_video_retirement_test.dart` |
| Android 合成媒体原生页面时序回归 | `flutter_app/test/android/android_media_viewer_device_test.dart` | 是；用 Live widget binding 与自制视频运行正式详情/编辑及原生解码，覆盖暂停队列、过期编辑取消、失败后翻页与自动/手动播放；宿主套件明确跳过，不初始化 Rust 或读取个人图库/账号，临时测试包运行后恢复普通 Debug 包 |
| Android 普通页面真机布局矩阵 | `flutter_app/test/android/android_ordinary_layout_device_test.dart` | 是；显式 Live Debug 复用现有中英/窄屏/大字号回归，只用合成后端，不改系统字号、账号或图库，运行后恢复普通包；渲染/交互与人工视觉验收分别记录 |
| Windows 合成媒体原生页面时序回归 | `flutter_app/test/windows_media_viewer_device_test.dart` | 是；仅显式 Live Debug 运行正式播放器与自制视频，核对编辑时暂停和翻页取消过期编辑；普通宿主套件明确跳过，不初始化 Rust/账号/个人库，原生退出证据与用例断言分开记录 |
| 启动准备、桌面等待式关闭、受控设备恢复与启动反馈 | `flutter_app/lib/src/startup/`、`lib/src/backend/device_sync/`、`lib/src/ui/device_sync/` | 是，账号材料仅由后端安全存储拥有 |
| Windows 引擎前单实例选主与无负载窗口唤起 | `flutter_app/windows/runner/native_single_instance.{h,cpp}` | 是，锁文件属于系统用户本地数据，不放仓库 |
| Windows 单实例真实子进程回归 | `flutter_app/test/windows_native_single_instance_test.dart`、`test/fixtures/desktop_instance/native/` | 是，夹具使用独立临时目录，不启动个人图库 |
| 跨平台账号好友、观星与内嵌网页组件 | `flutter_app/lib/src/ui/account_tools/` | 是，平台外框与原生策略分离 |
| 好友头像展示复用、游戏图片公共缓存与保存预览 | `flutter_app/lib/src/state/account_tool_images.dart`、`lib/src/ui/account_tools/avatar_preview.dart`、`rust_core/src/nso/game_images.rs` | 是；网络仍通过 Rust transport，头像按账号隔离，公共游戏图片按游戏名和 URL 有界复用；好友码仅存系统安全存储 |
| Nintendo/Coral/SplatNet 特殊返回分类 | `rust_core/src/nso/conditions.rs`、`session.rs`、`auth.rs`、`splatnet.rs` 与共享 UI `account_tool_errors.dart` | 是；按请求阶段识别固定状态，不输出远端错误正文或凭据，不将未关联/会员/受限混作过期；合成回归归各模块及 `test/account_tools/` |
| 跨设备同步安全会话、清单与传输 | `rust_core/src/device_sync/` | 是，数据库访问仍集中 `database.rs` |
| 累计媒体回执、字节窗口和小文件批次 | `rust_core/src/device_sync/driver/flow.rs`、`files.rs` | 是；只管理当前会话流控，媒体校验及数据库应用仍由暂存/接收模块负责 |
| 同步网络到本地应用的一次性权限和取消裁决 | `rust_core/src/device_sync/local_apply.rs`、`local_apply/`、`driver/local_apply_tests.rs` | 是，权限仅内存持有，不放入缓存或普通备份；源码存在不代表设备验收完成 |
| 跨设备同步页面及平台目录/设备适配 | `flutter_app/lib/src/ui/device_sync/`、`lib/src/platform/` | 是，凭据不进入普通文件 |
| Debug 内部配对输入及页面回归 | `flutter_app/lib/src/ui/device_sync/debug_pairing.dart`、`flutter_app/test/device_sync/debug_pairing*_test.dart` | 是，仅认证 VM Service 输入，不新增产品权限或外部入口 |
| 邀请通道、网络提示及安装包版本匹配 | `rust_core/src/device_sync/connection.rs`、`flutter_app/lib/src/platform/device_sync_{network,build}.dart`、`lib/src/ui/device_sync/connection_info.dart` | 是，SSID 只作提示；版本从安装包读取，不保存网络历史 |
| 手机会话控制、接收预览授权和传输速度 | `rust_core/src/device_sync/driver/`、`flutter_app/lib/src/backend/device_sync/controlled_*.dart`、`lib/src/ui/device_sync/` | 是，手机授权绑定一次性会话和当前预览；账号凭据不进入普通文件 |
| 同步容量与显式模式组件 | `flutter_app/lib/src/ui/device_sync/capacity_format.dart`、`mode_selector.dart` | 是，支持原生大整数容量、本地化选项和系统字号 |
| 设备同步状态灯与方向图标 | `flutter_app/lib/src/ui/device_sync/display.dart`、`direction.dart` | 是；桌面/Android共享展示，不改变同步协议或权限；图标和圆点不重复朗读，回归位于 `test/device_sync/status_direction_test.dart` |
| 设备同步稳定进度与速度展示 | `flutter_app/lib/src/ui/device_sync/transfer_progress.dart` | 是；共享桌面/Android组件，传输计数独立更新，不将后台工作采样当作页面重载 |
| 桌面跨设备同步 MTP 隔离进程 | `rust_core/src/bin/nsoalbum_mtp_worker.rs` | 是，须与桌面分发的构建/签名验证一并接入 |
| USB 本次会话只读发现与目录授权复用 | `rust_core/src/device_sync/native_mtp.rs`、`usb.rs`、Android `DeviceSyncPicker.kt`/`DeviceSyncSafChannel.kt` | 是，不按设备名建立信任；已有授权失效时仍走系统目录授权 |
| 无账号设备文件通道探针 | `rust_core/examples/device_sync_native_probe.rs`、`flutter_app/tool/device_sync_saf_probe.dart` | 是，独立开发入口，不初始化正常账号或图库 |
| SAF 合成吞吐与校验探针 | `flutter_app/tool/device_sync_saf_benchmark.dart`、`flutter_app/test/android/device_sync_saf_benchmark_test.dart` | 是；受控新会话、最多四个在途块；只测试原生字节通道，不代表应用内同步验收 |
| 真实页面合成库 QA 与根目录归属 | `flutter_app/tool/device_sync_qa*.dart`、`flutter_app/test/device_sync/qa_{root,fixture}_test.dart` | 是；仅独立 Debug 开发入口、全新临时库、内存账号，PNG夹具须真实解码验证；不打包为产品入口；运行方法见 Flutter README |
| Rust 子进程行为夹具 | `rust_core/tests/fixtures/` | 是，只使用合成数据，不打包为产品功能 |
| Rust 数据库、文件仓库、协议、导入与同步 | `rust_core/src/` | 是 |
| Flutter 单元/widget 测试 | `flutter_app/test/`，Android 测试放其 `android/` 子目录 | 是 |
| Android JVM 测试 | `flutter_app/android/app/src/test/` | 是 |
| 可重复使用的合成测试夹具 | `flutter_app/test/fixtures/<模块>/` | 是 |
| Windows 系统通知显式 Live 验收 | `flutter_app/test/windows_sync_notifications_device_test.dart`、`test/fixtures/notifications/native/` | 是；仅合成摘要、不初始化账号/图库，系统通知历史仅比对本次摘要，不输出其他内容 |
| 构建、打包、校验和生成脚本 | `flutter_app/tool/` | 是 |
| Windows 固定插件的退出所有权兼容 | `flutter_app/tool/windows_plugin_lifetime.cmake` | 是；仅在构建树生成派生源码、精确匹配失败即停止，不修改依赖缓存 |
| 桌面 MTP helper 构建、Cargo 来源报告和无设备验包工具 | `flutter_app/tool/build_desktop_native.dart`、`desktop_mtp_worker.cmake`、`build_macos_mtp_worker.sh`、`verify_mtp_worker.dart`、`test_mtp_worker_bundle.dart` | 是，不改上游 Cargokit |
| 桌面 helper 行为回归及受控工具链夹具 | `flutter_app/test/mtp_worker_*_test.dart`、`test/fixtures/ci/` | 是，合成产物不进入应用包 |
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
| 跨设备同步本地验收 | `dist/device-sync-20261016/` | 合成库/传输探针/日志，不提交 |
| 跨设备同步执行增补 | `dist/device-sync-20261017-execution/` | 缓存、空间预算等分切面保存冻结源/中断日志/合成证据，不覆盖旧记录、不提交 |
| Windows/Android Debug 实机传输及窗口检查 | `dist/device-sync-deviceqa-20261017/round*/` | 本地忽略；按轮保留失败及复验，不以通道检查代替完整页面或 MTP 验收 |
| 内部配对输入的失败测试、复验及调试连接记录 | `dist/device-sync-debug-pairing-20261018/` | 本地忽略；不保存邀请或 VM Service 认证 URL，不将 widget 测试当作实机成功 |
| 自动选路、SSID 及跨版本拒绝的验证记录 | `dist/device-sync-auto-connection-20261018/` | 本地忽略，保存失败/复验与独立 Debug 构建证据，不记录邀请或凭据 |
| 手机单端控制及本地应用交接复验 | `dist/device-sync-phone-control-20261018/`，交接分任务放 `local-apply/` | 本地忽略，区分协议测试、真实预览和完整媒体传输；不保存二维码、凭据或认证调试地址 |
| 本地 Windows/macOS 安装包与运行目录 | 打包脚本生成的 `dist/` 子目录 | 不改成根目录散放，不提交二进制 |
| 本地 Debug/原生构建输出 | Flutter 使用 C 盘独立构建副本；Rust 使用 C 盘 `--target-dir` | 优先避开 F 盘源码工作区；当前使用中的副本不得在运行时清理 |
| Flutter 编译输出和 Android APK | 外部 C 盘构建目录内的 `flutter/build/` | F 盘 `flutter_app/build/` 仅为工具默认回退位置，生成后可重建且不提交 |
| Android Gradle 报告与测试编译输出 | 外部 C 盘构建目录；必要时才使用 `flutter_app/android/build/` | 忽略，但不忽略相邻原生源码和配置 |
| Rust 编译缓存 | C 盘外部 Cargo `--target-dir` | F 盘 `rust_core/target/` 仅为工具默认回退位置，生成后可重建且不提交 |
| helper Cargo JSON、绝对产物路径和逐目标构建报告 | `flutter_app/build/` 或指定本地验收目录 | 忽略，不放进应用分发根目录 |
| helper 打包回归的保留合成证据 | `flutter_app/build/test-fixtures/mtp-worker-packaging/run-*/` | 每次新建并记录；不自动删除/覆盖、不进 Runner Release 包，不含用户资料 |
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
- 设备同步吞吐设计位于本地 `docs/design/device-sync-throughput-design.md`，
  测量和失败/成功证据归档到相应 `dist/` 专题；内部设计不提交，
  正式可重复运行的源码及测试仍放对应 Rust、Flutter 和 Android 目录。

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

Windows 隔离打包只在本仓库 `dist/` 内创建全新叶目录，不覆盖已有同版本包；
macOS CI 最终签名 helper 的必要摘要在同次传输容器中与 `.app` 一起封存。
应用内必要摘要不得包含开发机绝对路径或完整 Cargo JSON，构建报告与可分发
应用仍是两个边界。
