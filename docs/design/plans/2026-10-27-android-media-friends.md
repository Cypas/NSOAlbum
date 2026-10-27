# 好友查询、Android 流体滚动、Splatoon 状态与媒体详情实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修正好友码 9402 提示，改善 Android 图库与相册滚动，统一一级页面切换表现，增加可选的 Splatoon 3 好友状态查询，并明确 Android 媒体详情的跨对话交接边界。

**Architecture:** Flutter/Dart 负责页面状态、设置气泡、错误文案和滚动物理；Rust Core 负责 Coral endpoint 错误分类、好友列表请求顺序和 Splatoon 状态融合。好友状态开关通过正式 Flutter-Rust Bridge 传递，关闭时只请求 NS 好友列表，开启时才追加 SplatNet 查询。

**Tech Stack:** Flutter/Dart、Rust、flutter_rust_bridge、现有设置存储、Android/Windows Debug 测试。

**Spec:** `docs/design/nso-photo-design.md`；媒体详情视觉与交互参考 `dist/prototypes/android-media-viewer/index.html`，产品媒体详情由另一对话负责。

## Global Constraints

- 实施前先提交本次已授权源码和文档的范围受控基线；不全量暂存，不提交日志、缓存、对象文件、凭据、账号资料、个人图库或构建输出。
- 源码权威为 `F:\PycharmProjects\nso_photo`；构建、热重载和安装前只将本次修改文件非破坏式覆盖到 `C:\Users\cypas\.codex\tmp\nsoalbum-multiplatform-remainder-20261021\source`。
- 保留与本计划无关的已有改动；不得使用 `git reset --hard`、`git checkout --` 或镜像同步删除。
- Rust/Bridge 改动必须运行 `flutter_app/tool/generate_bridge.ps1`；不得手工编辑生成文件。
- 9402 只在 `/v3/Friend/GetUserByFriendCode` 映射为好友不存在；其他 endpoint 的 9402 保持通用失败。
- Splatoon 好友状态开关默认关闭；关闭时不得建立或查询 SplatNet 会话。
- 桌面与 Android 统一切换表现，但仍按需销毁旧一级页面，不改为 IndexedStack 全量常驻。
- 不执行好友申请、备注写入或其他账号写操作；真实探针只允许只读好友码查询，日志不得包含 token、Cookie、完整授权 URL、好友码或个人路径。
- 本计划不修改 Android 媒体详情产品代码、视频播放器、原型或其测试；这些由另一对话负责。
- 整份多需求计划完成后只递增一次版本：Flutter patch +1、Android build number +1、Rust crate SemVer 与应用版本一致，并更新 `Cargo.lock`。

---

## 原始需求核对项

以下内容必须逐字保留，最终验收逐项对应：

> 1.多端，查询好友返回code为9402的时候，页面提示词换为 没有找到对方，2.安卓的图库，以及相册内层，我希望上下滑动时，带有一点流体效果，也就随滑动结束后，再往下速度逐渐降低的滑动一点距离，滑动速度越快，滑动的距离就远一些，如果滑动速度很低，那就几乎不滑行3.以及左侧导航栏的活跃加载也可以改为和安卓一样的全部加载，4.多端在设置页面都可以加上一个splatoon3的设置气泡，加一个 好友列表展示spl3好友具体状态(以及一个小字解释：会增加一些好友列表查询时间)，开关默认为关，当开启了之后，好友列表才会像目前的先请求ns好友列表，再融合sp3的好友具体游戏状态，如果这个开关关闭，就仅是展示通用的ns好友状态，5.请按 Android 媒体详情原型实现，并复用现有播放器与控制器，不要因切换布局重建播放器：普通态顶部只保留返回和详情入口，不显示“媒体预览 1/3”；媒体预览上移约 12dp，播放控件与缩略条上移约 18dp，底部操作栏保持原位，视频操作顺序为“剪辑、分享”。用户上滑媒体区域或在“更多”中选择“查看媒体详情”后，以动画切换为上下分区布局：预览移至上方约 39% 的可用高度，隐藏进度控件、缩略条和底部操作栏，下方显示可滚动的媒体详情，包括录入时间、拍摄时间、文件名、媒体信息、标签和备注，并保留编辑及添加标签入口；Android 不展示媒体绝对路径。详情区滚到顶部后下滑可返回普通态，滚动详情内容时不能误触关闭；左右滑动切换媒体时保持当前布局状态，并保留播放位置、播放状态和当前媒体。图片不提供沉浸入口；图片“更多”中提供复制到剪贴板，图片和视频都提供复制/移动到相册；这些操作接入现有业务能力，不做空壳交互。视频应用内沉浸只切换控件和背景：全黑、隐藏状态栏及所有上下控件，不显示提示文字，也不改变媒体位置和尺寸。适配 320×640、360×800 等窄屏，确保控件不遮挡媒体、详情内容可滚动。原型在 [index.html](</F:/PycharmProjects/nso_photo/dist/prototypes/android-media-viewer/index.html>)。

> 视频详情页面的改动和设计我交给了其他对话，你去按照plan实现里面其他不涉及视频详情页的改动

### 范围解释

- 原始第 5 项完整保留用于跨对话核对，但本计划只记录交接边界，不修改媒体详情产品代码。
- “左侧导航栏的活跃加载也可以改为和安卓一样的全部加载”已明确选择为统一桌面/Android 淡入淡出切换体验，继续只保留当前页面，以避免额外内存和平台视图常驻。

## Task 0：范围受控基线提交

**Files:** Git index only；不修改产品文件。

- [ ] 审阅 `git status --short`、`git diff --name-only` 和未跟踪文件，建立本计划 allowlist。
- [ ] 只暂存本计划相关源码、测试和文档；排除日志、缓存、`*.obj`、构建输出、凭据、个人数据和无关历史改动。
- [ ] 运行 `git diff --cached --check` 与 `git diff --cached --stat`。
- [ ] 创建本地基线提交：

```powershell
git commit -m "chore: checkpoint authorized work before friends improvements"
```

- [ ] 不推送、不创建 tag 或 Release。

## Task 1：好友码 9402 endpoint 专用映射

**Files:**

- Modify `rust_core/src/nso/conditions.rs`
- Modify `flutter_app/lib/src/ui/account_tools/account_tool_errors.dart`
- Test `rust_core/src/nso/conditions.rs`
- Test `flutter_app/test/account_tools/account_tool_errors_test.dart`

- [ ] 增加失败测试：`9402 + /v3/Friend/GetUserByFriendCode` 映射为 `nintendo_friend_code_not_found`。
- [ ] 增加反例：其他 endpoint 或无 endpoint 的 9402 仍为 `nintendo_request_failed`；9408 的既有 endpoint 规则不变。
- [ ] 断言错误不包含远端 `errorMessage`。
- [ ] 实现最小 endpoint 分支。
- [ ] 将中文文案改为“没有找到对方”，英文为 `No user found.`。
- [ ] 运行：

```powershell
cargo test --manifest-path rust_core/Cargo.toml nso::conditions --lib
Set-Location flutter_app
flutter test test/account_tools/account_tool_errors_test.dart
```

- [ ] 若执行真实探针，只使用 Windows 当前已授权账号只读查询；只记录 endpoint、数字状态、错误类别和耗时，不记录好友码、token 或响应正文。

## Task 2：Android 图库与相册流体滚动

**Files:**

- Create `flutter_app/lib/src/ui/android/android_fluid_scroll_physics.dart`
- Modify `flutter_app/lib/src/ui/android/android_library_page.dart`
- Modify `flutter_app/lib/src/ui/android/android_albums_page.dart`
- Test `flutter_app/test/android/android_fluid_scroll_physics_test.dart`

**Interface:**

```dart
const AndroidFluidScrollPhysics({ScrollPhysics? parent});
```

- [ ] 先写测试，覆盖低速近乎停止、高速惯性单调增加、方向保持和边界 simulation。
- [ ] 运行 focused test，确认实现前失败。
- [ ] 继承 `BouncingScrollPhysics`，低于约 180 logical px/s 不追加 carried momentum，高速使用有限上限的额外 momentum。
- [ ] 将同一 physics 应用于图库 `CustomScrollView` 和相册 `GridView.builder`。
- [ ] 不修改 `AndroidMediaSwipeRegion`，不影响详情左右切换、图片缩放、视频进度拖动、分页或刷新。
- [ ] 覆盖 320×640、360×800、412dp、中英文和 2 倍字号。
- [ ] 运行：

```powershell
Set-Location flutter_app
flutter test test/android/android_fluid_scroll_physics_test.dart
flutter test test/android/android_library_test.dart test/android/android_experience_test.dart
```

## Task 3：桌面与 Android 一级导航切换统一

**Files:**

- Modify `flutter_app/lib/src/ui/active_page_host.dart`
- Modify `flutter_app/lib/src/ui/android/android_shell.dart`
- Test `flutter_app/test/active_page_host_test.dart`
- Test `flutter_app/test/android/android_navigation_test.dart`

- [ ] 增加回归断言：切换期间旧页和新页短暂共存，动画完成后旧页销毁。
- [ ] 确认隐藏页面不会保留播放器、平台视图或异步监听。
- [ ] 让 Android shell 和桌面使用同一 `ActivePageHost` 入口、时长、曲线和淡入淡出语义；若当前实现已等价，只补测试和注释。
- [ ] 明确不引入 `IndexedStack` 全量常驻。
- [ ] 运行：

```powershell
Set-Location flutter_app
flutter test test/active_page_host_test.dart test/android/android_navigation_test.dart
```

## Task 4：Splatoon 3 好友状态设置与正式 Bridge

**Files:**

- Modify `rust_core/src/settings.rs`
- Modify `rust_core/src/nso/account_tools.rs`
- Modify `rust_core/src/bridge.rs`
- Generate `rust_core/src/frb_generated.rs` and `flutter_app/lib/src/rust/**` only through the bridge script
- Modify `flutter_app/lib/src/backend/nintendo_account_tools_backend.dart`
- Modify `flutter_app/lib/src/backend/rust_backend.dart`
- Modify `flutter_app/lib/src/state/settings_copy.dart`
- Modify `flutter_app/lib/src/ui/home_shell.dart`
- Modify `flutter_app/lib/src/ui/android/android_settings_page.dart`
- Modify `flutter_app/lib/src/ui/account_tools/account_tools_actions.dart`
- Modify `flutter_app/lib/src/ui/account_tools/nintendo_friends_page.dart`
- Test existing account-tools, settings and Android/Desktop settings suites

**Interfaces:**

```rust
#[serde(default)]
pub show_splatoon_friend_activity: bool

Friends { include_splatoon_activity: bool }

pub async fn nintendo_friends(
    account_id: String,
    session_token: String,
    operation_id: String,
    proxy_url: Option<String>,
    include_splatoon_friend_activity: bool,
) -> Result<NintendoFriendsSnapshot, String>
```

```dart
Future<NintendoFriendsSnapshot> loadNintendoFriends(
  String accountId,
  String operationId, {
  bool includeSplatoonActivity = false,
});
```

- [ ] 测试旧设置 JSON 可读，新默认值为 false，保存后可恢复 true。
- [ ] 测试关闭时只出现 Coral `/v4/Friend/List`，不出现 SplatNet 请求。
- [ ] 测试开启时请求顺序为 Coral 好友列表后 SplatNet Friends query。
- [ ] 测试 SplatNet 失败仍返回基础 NS 好友和安全 `activityError`。
- [ ] 在 Rust 正式接口中传递 flag；关闭分支直接返回基础好友 snapshot。
- [ ] 运行 `flutter_app\tool\generate_bridge.ps1`，核对两侧签名，禁止手改生成文件。
- [ ] Dart 从 `AppSettings.showSplatoonFriendActivity` 传入当前好友请求；测试 fake 默认 false。
- [ ] 桌面和 Android 设置增加独立气泡：

```text
好友列表展示 Splatoon 3 好友具体状态
开启后会增加一些好友列表查询时间
```

- [ ] 开关默认关闭；切换只影响下一次好友刷新，不与当前请求并发。
- [ ] 运行：

```powershell
cargo test --manifest-path rust_core/Cargo.toml nso::account_tools settings --lib
Set-Location flutter_app
flutter test test/account_tools/rust_backend_account_tools_test.dart
flutter test test/account_tools/account_tools_pages_test.dart
flutter test test/android/android_settings_test.dart test/home_shell_test.dart
```

## Task 5：文档、版本与完整验证

**Files:**

- Modify `docs/design/nso-photo-design.md`
- Modify `docs/CHANGELOG.md`
- Modify this plan and its acceptance table
- Modify `docs/DOCUMENTATION-MAP.md` only if document responsibilities change
- Modify version metadata only after implementation passes

- [ ] 记录 9402 文案、流体 physics、导航按需销毁和 Splatoon NS→SplatNet 开关行为。
- [ ] 在本计划核对表逐项记录实现、测试、构建/Debug、设备验收和未完成原因；不把另一对话的媒体详情验收冒充本计划证据。
- [ ] 运行：

```powershell
Set-Location rust_core
cargo fmt --all -- --check
cargo clippy --all-targets -- -D warnings
cargo test --lib

Set-Location ..\flutter_app
dart analyze
flutter test
git diff --check
```

- [ ] 实施开始时重新读取 `flutter_app/pubspec.yaml`；全部任务完成后只递增一次 patch/build，保持 Rust crate 与 Cargo.lock 一致。
- [ ] 若随后要求本机 Debug 构建或热重载，先按 AGENTS 规则将修改覆盖到固定 C 盘副本并核对关键文件哈希；Rust/Bridge 改动必须重编译并重启。
- [ ] CI 只查看 run/job/step/日志和 artifact 元数据，不下载、解压、复制或安装 workflow artifacts。

## Acceptance Checklist

- [ ] 好友码 9402 在好友码查询页面显示“没有找到对方”，其他 endpoint 不受影响。
- [ ] Android 图库和相册低速近乎停止、高速带有限惯性，分页、边界和窄屏正常。
- [ ] 桌面与 Android 一级页面淡入淡出一致，旧页面按需释放，没有 IndexedStack 内存回归。
- [ ] Splatoon 3 设置气泡双端存在且默认关闭；关闭不请求 SplatNet，开启按 NS 后 SplatNet 融合。
- [ ] Rust/Bridge/Dart 签名和生成文件一致。
- [ ] Android 媒体详情由另一对话单独验收，本计划不声称已完成。

## 实施核对表

| 项目 | 实现状态 | 测试证据 | 构建/Debug | 设备验收 | 未完成原因 |
| --- | --- | --- | --- | --- | --- |
| 9402 好友码错误 | 待实施 | 待补 | 待记录 | 未验收 | — |
| Android 流体滚动 | 待实施 | 待补 | 待记录 | 未验收 | — |
| 导航切换表现 | 待实施 | 待补 | 待记录 | 未验收 | — |
| Splatoon 3 好友状态 | 待实施 | 待补 | 待记录 | 未验收 | — |
| Android 媒体详情 | 另一对话负责 | 本计划不运行 | 本计划不构建 | 本计划不验收 | 已明确交接 |
