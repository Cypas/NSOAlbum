# 鱿型相册项目文档

本目录集中保存项目设计、测试、许可与开发指南。按主题阅读对应文档；
不要将计划、历史验收报告或内部诊断材料视为当前产品行为或发布证据。

- [测试、构建、CI 触发和原生验收](TESTING.md)
- [仓库目录与忽略规则](REPOSITORY-LAYOUT.md)
- [完整文档树、职责和公开/本地边界](DOCUMENTATION-MAP.md)
- [第三方依赖与字体声明](legal/THIRD-PARTY-NOTICES.md)
- [图片、图标和其他素材授权](legal/ASSET-ATTRIBUTION.md)
- [Flutter 子工程与本机开发流程](../flutter_app/README.md)
- [贡献指南](../CONTRIBUTING.md)
- [安全漏洞报告](../SECURITY.md)

目录规范说明文件放置与忽略边界；文档树说明每份文档的职责及公开/本地属性。
内层 README 负责相应子工程或夹具的具体操作，法律声明保留其原始来源和许可。

正式运行时代码位于 `flutter_app/` 与 `rust_core/`。当前工作流触发条件、门禁、
包体和验收范围以 [测试文档](TESTING.md) 及 `.github/workflows/` 为准；
本页不复制易过期的 CI 触发清单，也不记录某次构建或设备验收状态。

应用版本以 `flutter_app/pubspec.yaml` 为准，Rust crate 使用一致的 SemVer，
稳定发布 tag 为 `v<SemVer>`。数据迁移与旧库兼容行为以当前实现及测试为准。

## Windows 打包

在 `flutter_app` 目录生成 Windows 运行目录：

```powershell
.\tool\package_windows.ps1
```

发布目录中的说明文档位于 `docs\`，第三方声明和字体许可证位于 `licenses\`。
脚本只创建全新目录，已有同版本目录不会被删除；本地隔离输出可用
`-PackageDirectory "..\dist\<专题>\<新目录>"`，必须位于本仓库 `dist\`
内且不能经目录联接越界。桌面 helper 的正常构建、同次产物来源和独立
验包规则见 [测试文档](TESTING.md#桌面-mtp-helper)。

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
