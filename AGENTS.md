# MisaTV 项目协作指南

本文件适用于整个仓库。面向后续修改代码、排查问题和打包交付的代理；更深目录如有 `AGENTS.md`，按其作用域补充执行。用户当前指令优先于本文。

## 开始任务

1. 先查看 `git status --short` 和相关文件的差异，区分已有改动与本次任务。保留用户及其他任务的未提交代码、资源和文档；不要通过重置、清理或整文件回滚覆盖它们。
2. 阅读 [README.md](README.md) 了解功能与平台边界，再按任务查阅 [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) 的对应章节。本文记录关键约束，具体实现以当前源码为准。
3. 使用 `rg` 定位入口，限制搜索范围。`work/`、`build/`、`.dart_tool/` 和 `assets/windows-runtimes/` 包含本地工具、缓存或大体积二进制，不应纳入普通源码扫描。
4. 明确实际故障、预期行为与验证办法，再做必要改动；避免顺手重构、批量格式化和无关依赖升级。新增逻辑优先沿用项目现有方式。

使用中文沟通和编写维护说明，标识符沿用现有代码风格。文档采用 UTF-8，不记录 Cookie、Token、密码、真实订阅内容或本机登录数据。

## 项目与代码入口

MisaTV 是 Flutter 编写的 TVBox 客户端，Windows x64 是主要交付平台。Android、macOS 有独立构建流程，Web 主要用于界面预览。播放器使用 fvp / libmdk / FFmpeg，支持 CMS、JS、Python、JAR / DEX 源。

| 位置 | 职责 |
| --- | --- |
| `lib/main.dart`、`lib/app.dart` | 主窗口启动、服务装配、全局应用入口 |
| `lib/player_window_io.dart` | 独立播放器窗口的启动与服务装配 |
| `lib/core/` | 网络、代理、日志、主题、平台与窗口基础设施 |
| `lib/models/` | 配置、影片、直播及用户数据模型 |
| `lib/state/app_state.dart` | 全局状态 `AppState`，通过 `ChangeNotifier` / `AppScope` 驱动界面 |
| `lib/services/local_store.dart` | 偏好、订阅、收藏、历史及账户持久化 |
| `lib/services/` | 源解析与搜索、蜘蛛、播放解析、中继、字幕、网盘等业务实现 |
| `lib/ui/` | 页面、组件、沉浸模式与播放交互 |
| `assets/jvm/`、`assets/python_runner/` | JVM 兼容层及源码、Python 运行器与基类 |
| `windows/runner/`、`android/`、`macos/` | 各平台宿主、插件与构建配置 |
| `test/`、`tool/`、`.github/workflows/` | 回归测试、维护脚本、CI 与发布流程 |

项目没有额外状态管理框架或数据库。不要为局部需求擅自引入新状态管理、路由或持久化体系。应用展示名是 MisaTV，但 Dart 包名与存储键沿用 `kniephos`；不要把旧标识批量替换掉。

## 修改代码时的约束

- 界面负责交互与展示，源调用、网络、解析和持久化放在对应服务或 `AppState` 中。平台差异沿用现有条件导出与 IO / Web 实现，不把 `dart:io` 或桌面能力引入 Web 共用入口。
- 设置页拆分在 `lib/ui/pages/settings/`，部分文件使用 `part of`。新增项放入最接近的既有分类；父分类使用 `_Section`，可折叠且默认收起，提供摘要或状态。「关于」是不可折叠的例外。
- 异步界面更新检查生命周期；监听器、定时器、流订阅和进程应有明确清理位置。QuickJS 执行器不能用 `Isolate.immediate` 强杀，遵守现有退出方式。
- 主窗口和独立播放器是不同 Flutter 引擎，各有状态、服务、中继及缓存初始化。改播放依赖时同时检查两个入口。沉浸模式仍通过 `effectivePopOutPlayer` 禁用独立播放窗口。
- 搜索轮次取消应落实到排队、RPC 和进程启动前；过期结果不应更新新一轮界面，也不应计为源站失败。保持搜索并发与 JVM 执行器限流分层，不通过降低整个蜘蛛池并发掩盖进程管理问题。
- 持久化键集中维护在 `LocalStore`，保持 `kniephos.` 兼容。订阅刷新、导入合并和历史同步应保留墓碑语义，避免已删除的源或历史复活。

## Windows 四项运行时必须随包就绪

**已确定的产品要求：Windows 完整包内置 JVM、加固壳支持、Yaozhi MPV 和 Python，首次启动从本地初始化即可使用。** 不要改回需要用户逐项联网下载的默认交付方式。

运行时处理链路：

1. `tool/prepare_windows_runtimes.ps1` 在构建机下载并检查公开依赖，生成 `assets/windows-runtimes/`，含各组件 `bundle.json` 和总清单 `ready.json`。
2. `windows/CMakeLists.txt` 把准备好的内容复制到 EXE 同目录的 `runtimes/`。这不是 Flutter 通用资源，不能因此把 Windows 二进制塞进 Android / Web 包。
3. `lib/services/bundled_runtime.dart` 从随包原件初始化可写的工作副本；主窗口和独立播放器都要接入。默认工作目录为 `userdata/`，安装目录不可写时使用系统应用数据目录。
4. 设置页识别随包组件并显示「已内置」。缺少内置包的源码构建保留既有下载修复流程；完整包初始化不应访问网络。

维护要求：

- 下载缓存可复用，支持中断后继续；存在上游校验值时验证完整性。初始化成功标记只能在文件准备完整后写入，恢复时保留 MPV 用户配置。
- 随包 Python 要包含运行器、基类和声明的依赖库，并用嵌入式解释器实际导入验证；仅存在 `python.exe` 不代表完整就绪。保留 Python 资源版本与锁定依赖的标记规则。
- 更新 JVM 兼容层时递增 `JvmRuntime._shimsRev`。修改 `ContextWrapper` / `Application` 桩后使用 JDK 17 执行 `tool/build_jvm_stubs.ps1`，同步提交对应源码及本项目构建的 `stubs.jar`，运行脚本内回归验证。
- `assets/jvm/shell-real/*.jar` 是可选预解包载荷，不属于公开运行时依赖。缺失不能阻断安装或兼容层升级，也不能删除用户已有载荷；必需 shim 缺失则应报告失败。
- 加固源自身首次解包、转换与 payload 缓存仍然需要执行；“运行时内置”不意味着所有第三方源无需首次处理。升级清理 JVM 旧版本时保留 `jvm/native/`。
- 准备过程与发布包保留组件许可文件，新增或替换第三方依赖时同步 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)。

## 播放、中继与用户数据

- `LocalRelay` 默认监听 `127.0.0.1:9978`，端口被占用时改用实际分配值。不要把 `9978` 当作所有路径的固定端口。
- 加固壳和部分 Python 源的播放地址依赖常驻取流进程。拿到本机地址后立即结束 JVM / Python 会导致播放失败；保留现有 hold、pin 与退出回收机制。
- 外部播放器需要短 token 中继 URL，避免 Cookie / UA / Referer 拼接后超出 FFmpeg 地址长度。网盘 Range 限流与分片缓存边界有专门逻辑，修改时覆盖 Range、seek、HLS、并发读写与缓存关闭场景。
- 中继敏感路由的跨站访问控制不能放宽为全局 `Access-Control-Allow-Origin: *`。保留 `/proxy?do=ck` 返回 `ok` 的壳握手。蜘蛛调试口默认关闭，不能为方便调试在正式包默认启用。
- `PortablePrefsStore` 必须保持临时文件加原子替换、必要时从完整临时文件恢复的流程。迁移只能合并或移动到不存在的目标，不能删除已有 `userdata`。
- 凭据统一走 `credential_vault`；Windows DPAPI 数据绑定当前电脑 / 用户。日志使用已有脱敏方式，不输出完整凭据和带认证信息的 URL。
- 关窗按现有顺序清理 Dart 服务与常驻进程，再结束原生宿主。各退出步骤和流取消保留超时，避免卡死。不要移除 Windows runner 的 Skia 回退或随包 VC++ DLL 处理。

详细原理、网盘凭据注入、搜索语法及壳缓存索引约束见 [开发约定](docs/DEVELOPMENT.md)；涉及这些模块时先读对应章节。

## 工具链与验证

各平台 CI 当前使用 Flutter 3.47.9；Dart SDK 约束以 `pubspec.yaml` 为准。Windows 原生构建使用 Visual Studio 2022 的 C++ 桌面工具链；现有 WebView 插件与 VS 2026 有已知兼容问题。准备完整运行时需要 PowerShell 7、Python / pip 与 `curl.exe`，构建机需要网络。

在仓库根目录执行：

```powershell
flutter pub get
flutter analyze lib test
flutter test --reporter compact --concurrency=1
```

如 `flutter` 不在 PATH，先检查本地 `work/sdk/flutter/bin/flutter.bat` 是否存在。若使用已有的 `work/pub-cache/`，在当前终端设置 `PUB_CACHE`；这些是可选本地工具，不是克隆仓库后的必备文件，不要提交本机绝对路径。

验证按改动范围选择：

- 只改文档：检查 UTF-8、链接、路径、命令与当前实现的一致性，无需重新构建应用。
- 修改逻辑：运行相关测试及源码静态分析；新增测试覆盖实际行为、边界或回归问题，避免照抄实现。
- 准备发布或修改跨模块行为：运行全量测试。CI 对偶发整体中止最多重试三次；持续失败必须排查，不能把重试视作忽略断言失败的理由。
- 修改原生宿主、播放生命周期或打包：构建目标平台，并按影响范围验证真实窗口 / 进程 / 文件行为。普通单测通过不能替代真实源站或播放验证。
- 未执行、跳过或失败的检查要在交付说明中明确记录，不能描述为通过。

运行时相关回归入口：

```powershell
flutter test test/bundled_runtime_test.dart test/jvm_runtime_assets_test.dart test/source_picker_runtime_test.dart
```

真实组件离线检查依赖已准备的完整运行时；缺失时该测试会跳过，**跳过不算离线验证成功**：

```powershell
./tool/prepare_windows_runtimes.ps1
flutter test --no-pub test/bundled_runtime_offline_test.dart
```

## 构建与交付

Windows 完整包按以下顺序处理：依赖准备 → 静态分析与所需测试 → 准备四项运行时 → 真实组件离线检查 → Release 构建 → 检查发布文件 → 压缩与校验。

```powershell
flutter build windows --release
```

- 产物目录为 `build/windows/x64/runner/Release/`。必须分发整个运行目录，包括 `data/`、插件 DLL、`runtimes/ready.json` 及四个组件，不能只交付 EXE。
- EXE 同目录必须含 `msvcp140.dll`、`vcruntime140.dll`、`vcruntime140_1.dll`，使用项目构建流程提供的版本，不从 JRE 随便取旧 DLL。
- **压缩包排除所有 `userdata/`**，并检查 ZIP 条目，防止订阅、历史、登录态和缓存泄漏。运行时必须从专用准备目录取得，不从用户数据目录整体复制。
- CI 发布资产名称为 `MisaTV-windows-x64.zip`；本地版本化交付可放入 `build/packages/MisaTV-<version>-windows-x64-bundled.zip`。报告实际文件路径、大小、验证结果，交付压缩包时附 SHA-256。
- `assets/windows-runtimes/`、下载缓存、SDK、构建目录和发布压缩包不入库。`assets/aria2/aria2c.exe` 与私有壳载荷也不应强行加入 Git。仓库已跟踪的本项目自建 shim JAR 按其构建流程维护。
- Fork 的应用与发布版本采用 `X.Y.Z.R`。前三段是所基于的官方版本，第四段从 `1` 开始，同一官方版本内逐次递增。基于官方 `1.2.0` 时依次用 `1.2.0.1`、`1.2.0.2`。跟进官方 `1.3.0` 后从 `1.3.0.1` 开始。
- `lib/core/app_version.dart` 的 `kAppVersion` 记录完整四段版本，GitHub Release 和标签使用 `vX.Y.Z.R`。Flutter 的 `pubspec.yaml` 保持 `X.Y.Z+N` 格式，前三段与应用版本一致，平台构建编号 `N` 随每次新发布递增。
- 校验应用版本与 Flutter 版本的一致性。普通修复或文档任务不自动升级版本。
- 提交仅暂存本次任务相关文件；不要用 `git add .` 把其他任务或用户文件一并带入。不在未获授权时推送、打标签、发布 Release 或上传外部平台。

Android / macOS 构建分别参考 [.github/workflows/build-android.yml](.github/workflows/build-android.yml) 和 [.github/workflows/build-macos.yml](.github/workflows/build-macos.yml)。Android 使用 ART / DexClassLoader，不能套用 Windows JRE 安装逻辑；macOS 的 `.app` 打包需保留权限与符号链接。Windows 构建和打包检查见 [.github/workflows/build.yml](.github/workflows/build.yml)。

## 文档维护

- 用户可见行为、安装与使用方式更新 [README.md](README.md)；实现约束和排查结论更新 [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)；第三方内容更新 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)。
- 用户确定的长期项目要求及能避免重复故障的约束记录在本文件。只记录可复用结论，不复制整段会话、临时进度、过期测试计数或本机凭据。
- 保持“本地优先、不内置影视源与解析接口”的项目边界。内置运行时、播放器和公开依赖，不等于内置第三方内容源或私有蜘蛛载荷。
