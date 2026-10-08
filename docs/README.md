# 鱿型相册项目文档

仓库根目录只保留工程入口与仓库级约束，项目文档统一存放在本目录。

- [第三方声明](legal/THIRD-PARTY-NOTICES.md)
- [项目素材授权说明](legal/ASSET-ATTRIBUTION.md)

正式运行时代码位于 `flutter_app/` 与 `rust_core/`。内部设计文档、原型和本地变更记录不随公开快照提交。

当前 Windows 开发环境已启用 Developer Mode，Flutter 插件可以直接创建符号链接；其他开发机若未启用，可使用 Windows 打包脚本的 CMake/目录联接回退流程。

当前发布候选版本为 Flutter `0.2.6+38`、Rust `0.2.6`，发布标签为 `v0.2.6`。升级时会优先使用 `NSOAlbum` 应用支持目录；若新目录没有有效数据库，则继续使用 `squid_album_library`、`FreshAlbum` 或 `squid_album` 中检测到的旧库。Windows 默认图库目录按 `Pictures\NSOAlbum`、`Pictures\FreshAlbum` 的顺序探测，已有设置中的手动路径始终优先。Rust 会在单个 SQLite 事务中显式补齐历史缺失列并回滚失败迁移。

## Windows 打包

在 `flutter_app` 目录生成 Windows 运行目录：

```powershell
.\tool\package_windows.ps1
```

发布目录中的说明文档位于 `docs\`，第三方声明和字体许可证位于 `licenses\`。

安装 Inno Setup 6 后，可基于已经生成的目录版创建安装器：

```powershell
$version = (Select-String .\pubspec.yaml -Pattern '^version:\s*(\d+\.\d+\.\d+)\+' | Select-Object -First 1).Matches[0].Groups[1].Value
.\tool\package_inno.ps1 `
  -PackageDirectory "..\dist\NSOAlbum-Windows-x64-$version"
```

安装器会根据 Windows 显示语言自动选择简体中文或英文界面；也可以通过 Inno Setup 的 `/LANG=chinesesimplified` 或 `/LANG=english` 参数强制指定。

## Windows 启动诊断

遇到启动后卡住、闪退或只留下核心初始化日志时，可以在安装目录执行：

```powershell
.\NSOAlbum.exe --safe-mode
.\NSOAlbum.exe --safe-mode=no-video
.\NSOAlbum.exe --safe-mode=no-ime
.\NSOAlbum.exe --safe-mode=software
```

完整 `--safe-mode` 会关闭托盘、自动同步、视频缩略图和第三方输入法适配；其他参数只关闭对应组件。诊断日志仍写入应用日志目录；若发生 Windows 原生未处理异常，额外日志会写到 `%TEMP%\squid_album_native_crash.log`。

安装 Windows SDK 后，可生成 MSIX：

```powershell
$version = (Select-String .\pubspec.yaml -Pattern '^version:\s*(\d+\.\d+\.\d+)\+' | Select-Object -First 1).Matches[0].Groups[1].Value
.\tool\package_msix.ps1 `
  -PackageDirectory "..\dist\NSOAlbum-Windows-x64-$version" `
  -Publisher 'CN=Cypas'
```

MSIX 默认生成未签名包；用于实际安装或分发时，需要提供与 `-Publisher` 完全一致的 `.pfx`：

```powershell
$certificatePath = Join-Path $env:USERPROFILE 'certs\NSOAlbum.pfx'
$version = (Select-String .\pubspec.yaml -Pattern '^version:\s*(\d+\.\d+\.\d+)\+' | Select-Object -First 1).Matches[0].Groups[1].Value
.\tool\package_msix.ps1 `
  -PackageDirectory "..\dist\NSOAlbum-Windows-x64-$version" `
  -Publisher 'CN=Cypas' `
  -CertificatePath $certificatePath
```
