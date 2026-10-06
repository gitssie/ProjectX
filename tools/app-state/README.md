# 通用 App 状态备份、基线与恢复

独立的 Objective-C 模块，保存手机本地状态；没有网络服务、Hook、UIKit 页面或固定目标 App。接口可以供 ProjectX 后续集成，也可以由独立短生命周期工具执行。

基线和快照完整备份主容器 tmp/ 的内容和权限；恢复时与其他容器数据一起替换，符号链接使用统一的目标重定位规则。

按用户要求，捕获时排除主容器整个 Library/SplashBoard/；其他目录与 App Group 不受影响。恢复仍按归档清单完整回放。

## 源码组织

```text
tools/app-state/
├── core/PXAppState.h,m            通用流程、目录格式、校验与锁
├── adapters/PXASNative.h,m        当前容器解析、签名权限、钥匙串、身份接口
├── cli/main.m                    app-state 命令行入口
├── cli/VendorWorker.m            单次特权 IDFV 修改与 lsd 重载
├── tests/                        临时目录、模拟钥匙串/身份、故障注入
├── docs/FORMAT.md                手机目录与 v2 清单格式
├── docs/INTEGRATION.md           ProjectX 接入方式和适用范围
├── build.sh                     本地测试 / iOS 编译
├── make_entitlements.py          按目标已签名权限生成 exact group worker 权限
└── describe.entitlements.plist   只读目标解析权限，无钥匙串组
```

## 已实现

- 任意受支持的 Bundle ID，实时解析当前安装文件、数据容器及所有声明的 App Group。
- 每个 App 下只有 baselines/ 和 snapshots/。两者均只保存数据，不保存 application/ 或 .app；快照不依赖基线。
- 快照名为日期加当天序号，例如 20261005-01；支持 auto 自动分配。基线名为捕获时 App 版本号，版本和 build 仅记录来源。
- snapshot 保存容器、同步与非同步密码钥匙串、可选身份；保留系统返回的同步标记和属性，不转换凭据内容。baseline 不导出钥匙串、不回放固定 IDFV。
- 快照恢复清除目标范围内归档没有的全部条目，包括新增的同步记录和 DeviceToken；恢复后钥匙串必须与快照完整一致。
- 用户授权的基线恢复清空目标同步及非同步钥匙串，并生成新的 IDFV。同步条目按具体记录主键删除，不删除其他 App/系统组；删除可能同步到同一 iCloud 钥匙串。基线建立本身不删除手机当前钥匙串。
- 恢复核对 Bundle ID、权限范围和归档核心文件，不限制已安装 App 的版本、build 或程序指纹；保留当前容器管理元数据，按清单还原内容权限。
- 备份保存符号链接本身；恢复复制后按当前容器位置重挂链接，不重复复制链接目标数据。
- 已确认属于目标的更早安装容器通过 manifest 的 containerSourceAliases 重定位，处理链接 UUID 与快照来源 UUID 不一致的情况。
- 先校验备份与身份写入权限，再直接替换状态；不创建 rollback、README 或单独的 verification/metadata 目录。
- root/容器 inode 固定检查、操作锁、路径校验；恢复不保存先前状态，失败立即停止并报告是否已开始写入。
- 身份适配器独立；原生实现支持 capture-only，或通过显式配置的单次特权 helper 恢复 IDFV。

## 构建和本地测试

```sh
/bin/sh tools/app-state/build.sh test
/bin/sh tools/app-state/build.sh ios
```

`test` 只使用临时目录和模拟适配器，不访问真实 App 或系统钥匙串；`ios` 编译未签名的 arm64/iOS 15+ 工具，不部署。

## 真机入口

在手机上由 mobile 执行，ROOT 约定为 `/private/var/mobile/Media/AppStateBackups`，需为 mobile 所有的 0700 目录。先停止目标 App/扩展，按本次操作临时签名；代码不启动 App，也不自动终止进程。

```text
app-state describe ROOT BUNDLE_ID
app-state inspect ROOT BUNDLE_ID
app-state snapshot ROOT BUNDLE_ID [YYYYMMDD-NN]
app-state snapshot ROOT BUNDLE_ID YYYYMMDD-NN --replace
app-state supplement-keychain ROOT BUNDLE_ID RELATIVE_SNAPSHOT_REFERENCE
app-state baseline ROOT BUNDLE_ID [APP_VERSION]
app-state restore ROOT BUNDLE_ID RELATIVE_REFERENCE
app-state restore ROOT BUNDLE_ID RELATIVE_REFERENCE --identity
```

基线和快照可以独立保存。省略快照名称时自动分配当天序号；省略基线名称时使用当前版本。恢复始终使用手机上已安装的 App，旧版本数据也允许恢复到新版，数据迁移由 App 处理。

`describe` 从当前安装 executable 的 Mach-O 签名读取权限，输出描述 plist，不读取钥匙串；用该描述交给 `make_entitlements.py`。角色 keychain 用于 inspect/snapshot/restore；filesystem 用于 baseline；vendor-worker 只用于单次 root 身份 worker。

访问组从已签名权限自动推导：显式同 Team 钥匙串组、App 自身 application-identifier，以及声明的 group.* App Groups，合并去重。单次 worker 只授予这个 exact 集合和对应已签名 App Groups；未支持的声明组不会跳过。工具副本和签名权限任务后必须清理，不能放进常驻特权进程或授予 UIKit 广泛钥匙串权限。

`snapshot --replace` 完整更新指定的已有快照，包含当前偏好、Cookie、容器数据、全部受支持钥匙串条目与身份。先完成和验证新 capture，再删除指定旧快照并发布；无 rollback。发布失败时保留完成的暂存 capture，错误输出包含 pending_capture_reference。基线和 auto 名称不能覆盖。

账号环境切换时，调用方需要知道当前运行环境对应的快照。先停止目标 App，再用 `snapshot --replace` 完整更新该当前快照；成功后才恢复目标环境的最新快照。保存失败就停止切换。不要把当前环境的凭据保存到其他账号的快照，不覆盖基线，也不只补两条令牌而遗漏配套偏好和 Cookie。不可变历史快照保留历史数据，但不能保证其中已被续用或撤销的登录凭据仍可重复使用；令牌内部的到期字段不是服务端有效性的证明。现有独立 CLI 支持这两个步骤，恢复后仍需按真机流程调用独立偏好缓存刷新 helper 并回读验证；CLI 本身不自动刷新偏好缓存。尚未实现自动识别当前账号、原子切换接口或 ProjectX UI 接入。

`supplement-keychain` 仅修补快照的同步钥匙串部分，不写手机钥匙串；只有当前非同步记录与归档一致才允许合并。重新登录后需要完整匹配状态时使用 `snapshot --replace`，不要把新 token 与旧偏好、Cookie 混合。

快照默认记录 API IDFV；快照恢复只有指定 `--identity` 才回放该值。基线恢复始终生成新 IDFV，不需要 `--identity`。基线恢复或带 `--identity` 的快照恢复需要两个由操作者提供的设备参数：

- `PXAS_IDFV_COMMAND`：JSON argv 数组，包含当前 RootHide 解析出的特权启动器、非交互参数和已签名 vendor-worker 路径。例如 `["<resolved-sudo>","-n","<signed-vendor-worker>"]`，不拼接 shell。
- `PXAS_LSD_PLIST`：实际系统组内的 `com.apple.lsdidentifiers.plist` 物理路径；不设置任何默认 UUID，不猜越狱前缀。

root worker 在只读 `--check` 预检中确认当前 Vendor 只登记该 Bundle ID、原值匹配并且 mobile lsd 可定位。通过后才开始恢复。真正写入时再次核对原值，只更新目标 Vendor ID，保留其他记录，重启 mobile lsd；调用方再核对 API。

所有实际备份和钥匙串文件只写在 ROOT 对应的手机目录。本机项目不存任何密码或设备地址。

## 验证状态

本地故障注入测试与原生 iOS warnings-as-errors 编译通过。此模块只读取 formatVersion=2，包含所引用的基线；没有旧格式兼容或自动迁移。手机资料的一次性格式整理与真机恢复结果见 INTEGRATION.md。

正式集成前还需真机验证权限、进程枚举、所有目标组与身份 worker。见 INTEGRATION.md 的明确边界。
