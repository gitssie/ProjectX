# ProjectX Agent Engineering Contract

`AGENTS.md` 是 ProjectX 唯一规范的项目级 Agent 工程约束。任何 Agent 在分析、修改、测试、打包或部署本项目之前，都必须先阅读并遵守本文件。`AGENT.md` 与 `CLAUDE.md` 仅是指向本文件的兼容 symlink，不得建立独立副本。

## 1. 项目定位

ProjectX 是运行在 **Dopamine RootHide、iOS 15+** 真机上的本地 UIKit 工具，由三个共同交付的目标组成：

- `ProjectX`：设备端 UIKit 应用，负责状态展示与用户操作。
- `ProjectXTweak`：通过 ElleKit/CydiaSubstrate 注入目标进程，提供身份、环境及存储相关 Hook。
- `WeaponXDaemon`：仅在本机运行的 guardian/watchdog，负责必要的进程守护和本地特权操作。

`../Dopamine2-roothide/` 是已下载的 **RootHide 依赖基础和行为参考实现**。可以读取它来确认 `jbroot`、`rootfs`、launchd、bootstrap 和打包语义，但默认不得修改、格式化、构建或提交该依赖仓库。只有用户明确要求时，才可改动依赖项目。

## 2. 不可违背的产品约束

1. ProjectX 是单机、单所有者、直接使用的工具：不得新增登录、订阅、账户校验、本地 API 鉴权或其他使用门槛。
2. 控制入口仅是安装在设备上的 UIKit 应用：不得新增 LAN HTTP API、WebSocket 服务、桌面控制器或远程 Rootless Agent。
3. Profile 是隐藏的后端状态，由系统自动生成和激活：不得恢复让用户创建、命名、选择、切换或管理 Profile 的旧 UI。
4. 不实现 App 数据备份、恢复或快照功能，除非用户以后明确改变此决定。
5. `WeaponXDaemon` 只承担本地 guardian/watchdog 职责，不得演变成网络服务。
6. Profile schema 5 的地区身份由选定 Carrier 派生；目标进程中的地区 Hook 必须使用 generation-scoped、fail-closed 的缓存。
7. 身份值必须遵循真实生命周期和作用域，不允许在每次 getter 调用时重新随机：
   - 设备级值在 Profile 生命周期内稳定；
   - IDFV 按 Vendor/Profile 作用域稳定；
   - IDFA 按 ATT/Profile 策略稳定；
   - Boot UUID、Uptime 等遵守启动周期；
   - App Install ID 遵守目标 App 安装生命周期。
8. 同一 Profile 内的设备型号、硬件、屏幕、系统、地区、时区、Carrier 和网络信息必须自洽；禁止生成现实中不可能存在的组合。

## 3. RootHide-only 基线

ProjectX **只支持 RootHide**。不得重新引入 rootful、Dopamine 标准 rootless、palera1n rootless 或 `/var/jb` 兼容路径。

### 3.1 构建基线

以下设置属于项目契约，不可在普通修复中降级或删除：

```make
TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = roothide
THEOS_PACKAGE_ARCH = iphoneos-arm64e
```

- App、Tweak 和 Daemon 均必须链接 RootHide 支持；当前共享依赖是 `-lroothide`。
- 软件包 `control` 的架构必须与 RootHide 包格式一致，即 `iphoneos-arm64e`。
- 最低系统版本、`control` 中的 firmware 依赖以及 Theos deployment target 必须保持一致；本项目基线是 iOS 15+。
- 不得使用 `iphoneos-arm64` 包名通配符、标准 rootless scheme 或 `Rootless: true` 作为兼容开关。

### 3.2 路径命名空间

所有路径必须先判断属于哪个命名空间，再选择转换函数。不得以“文件是否存在”为条件在多个越狱布局间回退。

#### Bootstrap-owned 路径

RootHide bootstrap 内的文件使用逻辑绝对路径，并在 Objective-C 运行时代入：

```objc
PXJBRootPath(@"/logical/path")
```

典型路径包括：

- `/Applications/ProjectX.app`
- `/Library/MobileSubstrate/DynamicLibraries`
- `/Library/ElleKit/DynamicLibraries`
- `/Library/LaunchDaemons`
- `/Library/WeaponX`
- `/Library/libSandy`
- `/var/mobile/Library/WeaponX`
- bootstrap 内的 `/var/mobile/Library/Preferences`
- bootstrap 内的 `/usr/bin`

优先使用 `PXRootHidePath.h/.m` 中已有的语义化 helper，例如 `PXProfilesDirectoryPath`、`PXGuardianDirectoryPath`、`PXWeaponXDaemonPath` 和 `PXBootstrapCommandPath`。不得在多个模块重复拼接同一路径。

#### Real-rootfs 路径

Apple 真实文件系统中的容器和系统数据使用：

```objc
PXRootFSPath(@"/real/filesystem/path")
```

典型路径包括：

- `/var/mobile/Containers/Data/Application`
- `/var/mobile/Containers/Bundle/Application`
- `/var/mobile/Containers/Shared/AppGroup`
- `/private/var/containers`
- 真实系统日志、Caches、WebKit、Preferences 或其他目标 App 数据。

不得把目标 App 的真实容器路径送入 `PXJBRootPath`，也不得把 ProjectX 安装在 bootstrap 中的文件送入 `PXRootFSPath`。

#### 严禁事项

- 禁止硬编码 `/var/jb`。
- 禁止扫描 `/var/jb`、`/var/LIB` 等候选前缀来“探测”越狱类型。
- 禁止 `rootfulPath ?: rootlessPath`、standard/rootless 双写或双删。
- 禁止写入随机 RootHide 前缀；随机前缀只能由 RootHide API 解析。
- 禁止创建 `PXRootHidePath` 之外的通用“所有绝对路径都走 jbroot”转换器。

### 3.3 打包路径与运行时路径不同

Theos `roothide` scheme 会处理 package staging。以下文件中的安装位置应保持 **未加随机前缀的逻辑路径**：

- `Makefile` 的 `*_INSTALL_PATH`
- package staging tree
- `com.hydra.weaponx.guardian.plist`
- `DEBIAN/preinst`、`postinst`、`prerm`
- `setup_app.sh`、`weaponx-debug.sh`
- LibSandy policy 中的 bootstrap 逻辑路径

不要把 `jbroot(...)` 的运行时结果、`.jbroot-*` 或 `/var/jb` 写进 deb。维护脚本只能使用其 RootHide bootstrap 执行环境提供的逻辑路径，不能调用 Objective-C 的 RootHide API。

## 4. 架构边界

### 4.1 共享路径层

`PXRootHidePath.h/.m` 是路径语义的唯一入口：

- bootstrap-owned 路径集中为语义化 helper；
- real-rootfs 路径显式经过 `PXRootFSPath`；
- 新增常用路径时先扩展共享 helper，再迁移调用者；
- 测试通过注入 converter 验证随机 jbroot，而不是依赖开发机路径。

### 4.2 Profile 与身份

- `ProfileManager` 负责 Profile 持久化及当前 Profile 状态。
- `IdentifierManager` 负责读取、生成和保存身份值。
- 各 ID 管理器与 Hook 只消费确定后的 Profile 数据，不得建立互相冲突的第二套存储。
- 更新 Profile 时要保证磁盘状态、内存缓存和 Darwin notification 的顺序一致。
- 目标进程无法获得完整、合法、当前 generation 的身份时，应 fail closed，不得回退到随机值或旧 Profile。
- 用户选择的 Target App Bundle ID 是持久配置：App 暂时卸载时只从本次可执行目标集中排除，不得删除选择记录；同 Bundle ID 重装后必须自动恢复为可执行目标。

### 4.3 Hook

- 优先 Hook 最稳定、最高层且最小数量的 API；避免对同一语义在多层重复 Hook。
- 每个 Hook 必须保存并在不适用时调用原实现。
- 必须防止递归、重入和初始化顺序问题；不要在热路径进行磁盘扫描或同步网络工作。
- Bundle ID、Profile、generation 和作用域检查必须在返回 spoof 值之前完成。
- App、Tweak、Daemon 之间共享的数据格式必须向后兼容或带 schema/version 迁移。

### 4.4 数据清理安全边界

`AppDataCleaner`、Keychain 清理和容器清理属于高风险代码：

- 只能清理明确目标 Bundle ID 解析出的容器；不得扩大到父目录、全局 `/var/mobile` 或其他 App。
- 删除前必须 canonicalize 路径并验证其位于允许的 real-rootfs 根目录下。
- Bundle ID、UUID 和动态路径片段必须校验；不得直接拼接进 shell 命令。
- 优先使用 `NSFileManager`/POSIX 参数数组；禁止未转义字符串、通配符和 `rm -rf` 扩张删除范围。
- Keychain 清理使用按请求复制并签名的短生命周期 external worker；每次只授予从目标 App 已签名 entitlement 提取、且通过同 Team ID 与安全组名校验的 exact access groups（包括目标声明的自定义/shared group）。禁止 wildcard、Apple/system group、目标签名中不存在的 group、常驻广权限 daemon 或通过启动目标 App 完成清理；任一目标已声明 group 被跳过时必须把本次清理报告为失败，不能误报成功。
- 不删除 synchronizable Keychain 项。
- 每个 scope 删除后必须验证，再进行文件系统清理。
- 保留 fail-closed 行为：无法证明路径或权限正确时停止，而不是尝试更激进的删除。

### 4.5 Daemon 与 launchd

- `WeaponXGuardian`、`WeaponXDaemon` 和 launchd plist 必须共用相同的 daemon、日志与 label 契约。
- label 固定为 `com.hydra.weaponx.guardian`，修改时必须同步 plist、维护脚本、debug 脚本和代码。
- daemon 可执行文件位于 bootstrap 逻辑路径 `/Library/WeaponX/WeaponXDaemon`。
- 代码中启动真实系统工具时使用 `PXRootFSPath`；启动 bootstrap 内工具时使用 `PXBootstrapCommandPath`。
- 使用 `launchctl bootstrap/bootout/kickstart` 时保持幂等；重复安装不得留下重复任务或中断 dpkg。
- 日志和状态目录的 owner、group、mode 必须与实际运行用户一致。

## 5. 依赖与第三方边界

- `../Dopamine2-roothide/` 是 RootHide 真值参考，不是复制代码的来源。先理解接口和许可证，再决定是否复用。
- RootHide API 语义不确定时，必须查阅依赖源码和头文件，禁止猜测固定前缀。
- 优先使用仓库已有 framework/library；新增依赖前必须说明必要性、设备端体积和部署影响。
- 不修改 vendored headers、SDK、`.theos` 中间产物或解包出的第三方文件来“修复”编译。

## 6. 编码约束

- Objective-C 默认 ARC；保持现有 Foundation/UIKit 风格和 nullability 约定。
- 所有 target 继续以 warnings-as-errors 构建；不得通过关闭 warning、删 `-Werror` 或大范围 pragma 来绕过问题。
- 不吞掉关键错误。文件、进程、launchd、权限和持久化失败必须返回或记录可定位的错误。
- 不在业务代码中新增仅用于调查的永久日志；定位完成后删除临时日志。
- 不进行与当前需求无关的大规模重命名、格式化或目录重组。
- 不修改生成目录：`.theos/`、`packages/`、`build_check/` 和临时 deb 解包目录均不是源代码。
- 不覆盖或回滚工作区中已有的未提交修改；先确认 diff 的归属，再做最小增量修改。

## 7. 测试与验证

### 7.1 最低验证

任何代码、打包或部署相关修改至少执行：

```sh
/bin/sh scripts/check_build_warnings.sh
```

该脚本执行 clean、单线程 release package build，并拒绝 compiler、linker 和 Interface Builder warning。不得用普通 `make` 成功替代 warning gate。

### 7.2 按变更类型验证

- 路径层：运行/扩展 `PXRootHidePathTests.m`，验证注入的随机 jbroot 与 rootfs converter。
- App 数据清理：运行相关 cleaner/web/keychain 测试，覆盖允许路径、拒绝路径和失败后停止。
- Profile/身份：覆盖稳定性、scope、generation、持久化和通知后的缓存一致性。
- Hook：至少完成编译、目标 Bundle 过滤和原实现 fallback 的回归验证。
- Maintainer script：使用 `sh -n`，并验证重复执行的幂等性。
- Plist/entitlement：使用 `plutil -lint`。
- 打包：检查 control、架构、可执行权限、LaunchDaemon、App、Tweak、脚本、LibSandy policy 和 LaunchScreen。

### 7.3 Deb 验收

最终 deb 必须满足：

- 文件名和 control architecture 为 `iphoneos-arm64e`；
- 不包含 `/var/jb` 或随机 `.jbroot-*` staging tree；
- 包含 `/Applications/ProjectX.app`；
- 包含 `/Library/MobileSubstrate/DynamicLibraries/ProjectXTweak.*`；
- 包含 `/Library/WeaponX/WeaponXDaemon`；
- 包含无静态特权 entitlement 的 `/Library/WeaponX/ProjectXKeychainWorker` template；
- 包含 `/Library/LaunchDaemons/com.hydra.weaponx.guardian.plist`；
- 包含所需维护脚本与 debug/setup 工具，并具有正确 executable bit；
- LaunchScreen 是编译后的 `LaunchScreen.storyboardc`，不是原始 storyboard；
- App、Tweak、Daemon 的签名与 entitlement 校验通过。

若因缺少 Theos、SDK、签名工具或真机而无法执行验证，必须报告具体缺失项和未验证范围；不得声明完整通过。

## 8. 部署约束

部署到真实设备是有副作用的操作，除非用户明确要求，否则只构建和检查 deb，不执行 `make install`、`scp`、`ssh`、respring、`ldrestart` 或 reboot。

获得部署授权后：

1. 先完成本地 clean package 和 deb 验收。
2. 明确目标设备，禁止猜测 IP、端口、用户或密码。
3. 只安装本次构建的 `iphoneos-arm64e` 包。
4. 安装后验证 dpkg 状态、App 注册、Tweak 文件、daemon 文件、launchd job 和日志权限。
5. 仅在需要加载 Tweak 时 respring；不得默认 reboot。
6. 部署失败时保留完整错误，停止重复破坏性重试。

不得把 SSH 密码、签名秘密、设备地址或其他凭据写入仓库、脚本、issue 或日志。

### 8.1 已验证的本机 RootHide + Sileo 部署流程

`scripts/deploy_sileo.sh` 是唯一规范的 ProjectX build、audit、APT publication、HTTP、SSH reverse tunnel 和 device-side repository verification 入口。不得再逐次拼接临时 Python、APT hash、HTTP 或 SSH 命令。脚本不会添加或打开 Sileo source，也不会安装 package。

#### 必填配置

首次使用时，把 tracked placeholder `scripts/deploy.env.example` 复制到 ProjectX 自己的 untracked `.deploy/deploy.env`，填入本机值并设为 `0600`。之后正常部署命令必须只有：

```sh
scripts/deploy_sileo.sh deploy
```

脚本从自身位置解析 ProjectX root，自动读取唯一固定的 `.deploy/deploy.env`，再验证 owner、permission、格式和必填值。它不会执行配置内容，只接受已知的 `NAME=value` 或 `export NAME=value` assignment；symlink、非当前用户 owner、group/other 可访问文件、未知/重复 key 和 shell expression 都会被拒绝。不会生成或自动填入 host、port、identity、source 或 credential。

一次性 setup：

```sh
mkdir -p .deploy
chmod 700 .deploy
cp -f scripts/deploy.env.example .deploy/deploy.env
chmod 600 .deploy/deploy.env
```

配置文件包含以下值：

- `THEOS`：RootHide Theos 的绝对目录，`deploy` 和独立 `publish` 必需；
- `PROJECTX_SILEO_SOURCE_URL`：Sileo 已配置的固定 device-loopback URL，必须为 `http://127.0.0.1:<device-port>/`；
- `PROJECTX_SILEO_HTTP_PORT`：Mac loopback HTTP port；
- `PROJECTX_SILEO_DEVICE_PORT`：device loopback reverse-forward port，必须与 source URL 一致；
- `PROJECTX_SILEO_SSH_HOST`：现有 iproxy SSH endpoint host；
- `PROJECTX_SILEO_SSH_PORT`：现有 iproxy SSH endpoint port；
- `PROJECTX_SILEO_SSH_USER`：固定为 `mobile`；
- `PROJECTX_SILEO_SSH_IDENTITY`：已授权 private key 的绝对路径；
- `PROJECTX_SILEO_PACKAGE`：可选；`publish` 时显式指定当前 package，且必须位于 ProjectX `packages/` 并与 `control` 完全一致。

整个 `.deploy/` 已被 `.gitignore` 排除并由操作者管理：config 位于 `.deploy/deploy.env`，supervisor PID/start identity/fingerprint 与 generation 位于 `.deploy/state/`，稳定 APT symlink 位于 `.deploy/repo`，scrubbed logs 位于 `.deploy/logs/`，temporary/atomic files 位于 `.deploy/tmp/`。脚本使用 `umask 077` 和限制权限，并在每次 cleanup 前验证 canonical parent；除正常 `.theos/` 与 `packages/` build output 外，拒绝在 `.deploy/` 之外写入、迁移或清理任何 host path。

诊断时，调用进程中显式设置的 connection/build 同名环境变量优先于文件值，但 config/state/repo/log location 不可 override。先用 `scripts/deploy_sileo.sh --dry-run deploy` 验证配置而不 build、publish 或启动 process；`--help` 和 `status` 不显示配置内容、SSH identity、host 或 port。

#### 子命令与不变量

- `deploy`：按 config validation → `scripts/check_build_warnings.sh` → fresh package selection/audit → `publish` → `start` → `verify` 执行。只接受该次 build 产生的唯一 `iphoneos-arm64e` package。
- `publish`：拒绝 stale、ambiguous、wrong-version 或 wrong-architecture artifact；在固定 state 目录生成完整 generation，并通过 atomic stable symlink 一次发布 `Packages`、gzip/xz/zstd indexes、`Release` 和唯一 deb。不会复用旧 hash。
- `start`：通过 `nohup` 启动一个 stdin 来自 `/dev/null` 的 detached supervisor；只有该 supervisor 启动和监控 HTTP、SSH tunnel 与诊断清洗子进程。HTTP 只 bind Mac `127.0.0.1`，SSH 只使用 non-interactive mobile identity。相同配置且两个真实 endpoint 健康时重跑会复用 supervisor；任一关键子进程退出时 supervisor 会终止其余子进程、记录失败并退出，后续 `start` 可清理 stale ownership 后重建。supervisor PID、process start identity、command fingerprint 和 config signature 必须匹配；foreign port/tunnel 会被拒绝，不会被接管或终止。不得用 launchd、LaunchAgent、`launchctl`、`setsid`、tmux、screen 或其他 service manager 代替此 project-local supervisor。
- `verify`：从 device loopback 读取 `/`、`Release`、所有 Packages index 和 `Packages` 中的精确 deb filename；逐字节比较 repository 内容，并验证 version、architecture、size 和 SHA256。
- `status`：同时验证 supervisor PID/start/fingerprint、HTTP listener 的 parent ownership、Mac loopback Release 和 device-loopback Release，区分 healthy、unhealthy、stale、foreign 和 down，并显示 owned log 路径；不显示 SSH host、port、identity 或 credential，不能仅凭 PID 文件声明健康。
- `stop`：只向 state 中 PID、start identity 与 command fingerprint 全部匹配的 owned supervisor 发送 TERM；由 supervisor trap 终止并 wait 自己的子进程。不得直接终止未验证 PID 或 foreign process；重复执行安全，logs 与最后的 supervisor outcome 保留。

稳定 source URL 不随 build 改变。新 package 必须重新运行 `deploy`；不得改变 Sileo 中已配置的 URL。脚本成功后，唯一用户动作是 Sileo `Refresh → Project X → Modify/Reinstall → Confirm`。安装完成后仅使用 mobile SSH 做 read-only package/App/Tweak/Daemon/launchd/log verification；不得远程运行 `dpkg -i`。

验收完成后运行 `scripts/deploy_sileo.sh stop`，避免遗留 HTTP 或 tunnel。若 `status` 报告 `foreign`，先由该 foreign process 的原始 owner 处理；本脚本不会 kill 它。

#### 仅用于故障诊断的手动边界

需要定位 script failure 时，可只读检查 `.deploy/logs/` 中的 `supervisor.log`、`http.log`、`tunnel.log`，以及 `.deploy/state/run/supervisor.status` 和 `status` 输出。手动调用 build audit、APT compression/hash、`python3 -m http.server` 或 `ssh -R` 仅用于隔离脚本自身故障，不能作为可发布结果；修复脚本后必须重新运行完整 `deploy`。

#### 已排除的失败方向

- 直接把 deb SCP 到 `/var/mobile` 后运行 `uiopen file:///var/mobile/...deb`：Sileo 不会获得正常的 iOS document handoff。
- 调用 `uiopen` 添加、打开或重复配置 source：用户已经配置固定 source，脚本不得操作 Sileo。
- 为自动安装要求 root SSH、猜测 root 密码或使用默认 `alpine`：不符合本设备和已确认部署方式。
- 未通过本地 build/package/signature audit 就把 deb 交给 Sileo：禁止。

版本、文件名和 hash 必须由脚本从当次 build artifact 读取，不得硬编码历史值。任何手工生成的 deb/repository metadata 都不是可部署 artifact。

## 9. 工作流程

1. 开始任务时运行 `bd prime`、`bd ready`，并使用 `bd` 追踪所有持久工作。
2. 修改前先检查当前工作区，区分用户已有修改、其他 Agent WIP 与本任务内容。
3. 先定位调用链和测试 seam，再编辑；RootHide 行为优先参考本项目共享 path layer 和依赖源码。
4. 保持一个功能单元一个 issue，完成后运行相应测试和 warning/package gate。
5. 只有全部必要验证通过才关闭 issue；受环境阻塞时保持 issue 打开并记录 blocker。
6. 未经用户明确授权，不 commit、不 push、不执行 Dolt remote sync。

## 10. 关键文件索引

| 范围 | 关键文件 |
|---|---|
| 构建与打包 | `Makefile`, `control`, `DEBIAN/*` |
| RootHide 路径 | `PXRootHidePath.h`, `PXRootHidePath.m`, `PXRootHidePathTests.m` |
| App 入口 | `main.m`, `ProjectXApplication.m`, `ProjectXSceneDelegate.m` |
| Tweak 入口 | `Tweak.x` 及各 `*Hooks.x` |
| Profile/身份 | `ProfileManager.*`, `ProfileManifest.*`, `IdentifierManager.*`, `AppIdentity.*` |
| 清理 | `AppDataCleaner.*`, `KeychainCommand.*`, `tests/` |
| 地区/位置 | `RegionIdentity.*`, `RegionEnvironment.*`, `LocationSpoofingManager.*` |
| Daemon | `WeaponXDaemon.m`, `WeaponXGuardian.m`, `com.hydra.weaponx.guardian.plist` |
| 权限 | `ent.plist`, `ProjectX.entitlements`, `layout/Library/libSandy/` |
| 验证与 Sileo publication | `scripts/check_build_warnings.sh`, `scripts/deploy_sileo.sh` |

当旧设计文档、注释或历史实现与本文件冲突时，以本文件和用户最新明确要求为准，并在相关修改中同步修正文档。

## 11. Non-Interactive Shell Commands

Always use non-interactive flags with file operations so aliases cannot block on confirmation prompts:

```bash
cp -f source dest
mv -f source dest
rm -f file
rm -rf directory
cp -rf source dest
```

Other commands that may prompt must also be non-interactive:

- `scp`: use `-o BatchMode=yes`.
- `ssh`: use `-o BatchMode=yes`.
- `apt-get`: use `-y`.
- `brew`: use `HOMEBREW_NO_AUTO_UPDATE=1`.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:970c3bf2 -->
## Beads Issue Tracker

This project uses **bd** (beads) for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   bd dolt push
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->

<!-- BEGIN BEADS CODEX SETUP: generated by bd setup codex -->
## Beads Issue Tracker

Use Beads (`bd`) for durable task tracking in repositories that include it. Use the `beads` skill at `.agents/skills/beads/SKILL.md` (project install) or `~/.agents/skills/beads/SKILL.md` (global install) for Beads workflow guidance, then use the `bd` CLI for issue operations.

### Quick Reference

```bash
bd ready                # Find available work
bd show <id>            # View issue details
bd update <id> --claim  # Claim work
bd close <id>           # Complete work
bd prime                # Refresh Beads context
```

### Rules

- Use `bd` for all task tracking; do not create markdown TODO lists.
- Run `bd prime` when Beads context is missing or stale. Codex 0.129.0+ can load Beads context automatically through native hooks; use `/hooks` to inspect or toggle them.
- Keep persistent project memory in Beads via `bd remember`; do not create ad hoc memory files.

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.
<!-- END BEADS CODEX SETUP -->
