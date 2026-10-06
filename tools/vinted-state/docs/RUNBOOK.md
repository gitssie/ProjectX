# 操作手册

## 1. 本机构建与真机授权

运行 `build.sh`。使用现有 SSH 配置/identity，命令显式指定目标并使用 BatchMode；不把连接信息写进本目录。备份、导出和恢复数据直接在手机处理，不下载到开发电脑。

在 RootHide bootstrap 上创建短生命周期工具目录，上传完成后，先从当前 Vinted **已签名可执行文件**用 `ldid -e` 提取 entitlement。把这个权限描述（不含钥匙串内容）交给 `make_entitlements.py`：

```sh
python3 make_entitlements.py SIGNED_TARGET.plist WORKER.plist --role keychain
```

- `keychain`：用于 KeychainCheck、VintedInspect、VintedBackup、VintedRestore、RestoreVerify。
- `filesystem`：用于 VintedBaseline、VintedFinalize，不授予钥匙串组。
- `idfv`：用于 LSIDFVCheck，不授予钥匙串组。

工具只接受已验证的 Team/App/group。目标签名变化时停止并检查，不授予通配组，不略过新增组。权限文件是短生命周期产物；用 `ldid -S权限文件` 签名对应副本，任务后移除权限文件与工具。

执行备份或恢复前检查并停止 Vinted 及其扩展；不可在 App 正在写数据时进行。权限提示或锁屏导致读取失败时停止，不回报成功。不要为本工具配置常驻 daemon。

## 2. 路径参数

所有路径参数是**手机物理路径**，不是本机路径。原固定 App/data/group UUID 已改为从 LaunchServices 动态解析。

| 参数 | 用途 |
|---|---|
| `VST_BACKUP` | 已存在的完整备份，例如 `/private/var/mobile/Media/VintedBackups/<snapshot-name>`；Inspect、Restore、RestoreVerify 使用 |
| `VST_LSD_PLIST` | 系统登记的 com.apple.lsdidentifiers.plist 物理路径；VintedFinalize 使用 |

参数无默认 UUID，不存在或非规范路径时拒绝继续。不要扫描或猜测 RootHide bootstrap 前缀。系统组路径应从系统登记/RootHide 工具确认；仅指定目标 plist，不复制整个系统钥匙串数据库。

## 3. 只读检查与临时钥匙串测试

- `LSIDFVCheck` 默认读取系统 IDFV。
- `VintedInspect` 检查当前目录、版本、IDFV、钥匙串条数；VST_BACKUP 用于与旧备份比较，比较在内存完成。
- `KeychainCheck` 会在 exact group 内创建两个独立随机临时条目，验证导出/删除/恢复，再清理；不输出 secret、不删除既有条目。它不是完全只读命令。

## 4. 完整备份（手机内）

1. mobile 执行 `VintedBackup /private/var/mobile/Media/VintedBackups/<new-name>`；目的目录必须不存在。
2. 复制应用 bundle、主容器、共享容器；导出非同步密码项和 API IDFV。
3. Validate current signed target entitlements; do not store a duplicate entitlement file in the backup.
4. A restore error stops immediately and reports state_may_be_partial. No automatic undo is performed.
5. `manifest.plist` 必须是 complete，钥匙串文件回读成功；不完整备份不得用于恢复。

原始工具保存 application、containers、keychain、identity；清单放在 manifest.plist 的 inventories 字段，不生成 README.txt 或 verification/，不做 zip/tar。当前手机资料已共享基线中的 App，路径见第 8 节。

## 5. 首次启动前基线

操作者确认重装后从未启动，检查 Documents/Preferences 等无业务数据，再执行：

```text
VintedBaseline /private/var/mobile/Media/VintedBackups/baselines/<当前App版本号>
```

目录名称必须等于实际版本号；build 另存清单。无钥匙串目录、无固定 IDFV；此操作不清理当前手机钥匙串。后续应用基线时需另外授权 exact group 的初始化清理，本目录尚无直接应用基线的一键命令。

## 6. 从完整备份恢复

1. 确认当前签名、version/build 与 manifest 一致，停止 App；设置 VST_BACKUP。
2. Run VintedRestore as mobile: preflight the snapshot, clear and verify the exact keychain group, replace container contents and restore keychain records. No previous-state backup is created.
3. 保留当前容器管理元数据；不能将旧容器 UUID 原样覆盖到新容器。
4. A restore error stops immediately and reports state_may_be_partial. No automatic undo is performed.
5. 从系统读取当前 IDFV 和备份期望值，确认系统 Vendor 记录只含目标 App。使用已签名 LSIDFVCheck 和 `restore-idfv.sh HELPER PHYSICAL_LSD_PLIST EXPECTED_UUID REPLACEMENT_UUID`，mobile 环境已有 sudo 授权。只修改 Vinted Limited 字段；暂停 mobile lsd，原值匹配时原子写入，再让 launchd 重启 daemon。失败路径恢复被暂停 daemon。
6. Recheck target processes, run VintedRestore check and RestoreVerify. Compare keychain contents/ACL, IDFV and core files; require complete.
7. Remove temporary signed tools, then let the user verify the business state in the app.

IDFV 操作与容器/钥匙串事务是分开的：IDFV 失败时不要把整体报告为完成，可按 EXPECTED/REPLACEMENT 反向恢复。helper 不自动处理 daemon 或其他 Vendor。

## 7. 后续正式集成

按 ProjectX/AGENTS.md 复用 PXRootHidePath 路径语义和短生命周期 keychain worker。当前代码是实验参考，尚未实现完整并发/崩溃恢复、全部元数据保真、基线应用、跨版本迁移、自动进程阻止和 daemon 事务。不要直接纳入正式产品自动流程。

## 8. Current phone directory layout (2026-10-05)

The existing phone backups were reorganized at the user's request:

```text
/var/mobile/Media/AppStateBackups/
└── lt.manodrabuziai.fr/
    ├── baselines/26.38.0/
    │   ├── application/Vinted.app/
    │   ├── containers/
    │   └── manifest.plist
    └── snapshots/20261005-01/
        ├── containers/
        ├── keychain/
        ├── identity/
        └── manifest.plist
```

The original `20261005-structured-01` snapshot is now `20261005-01`. The two original application inventories matched; executable, Info.plist and CodeResources hashes were checked on the phone before removing the duplicate snapshot application directory. The snapshot manifest records `baselineRef` and a relative shared application path. Do not delete a referenced baseline.

The prior restore rollback directory was deleted at the user's explicit request. Baseline and snapshot data remain intact. No installed application state was changed.

README.txt and verification/ were also removed from both baseline and snapshot. Required inventories are stored once inside manifest.plist under inventories. Application inventory belongs only to the baseline. Restore tools now read the embedded container inventories.

The payload remains **formatVersion=1**. This is directory organization, not a v2 conversion; do not feed these files to the generic v2 engine. For future v1 restore, rebuild the archived helpers (their path validators now support this location), sign temporary copies for the current target and use:

```text
VST_BACKUP=/private/var/mobile/Media/AppStateBackups/lt.manodrabuziai.fr/snapshots/20261005-01
```

No updated helper binary was deployed during this organization task. The v1 restore tool consumes containers/keychain/identity rather than reinstalling the application bundle. Future generic format and integration requirements are documented in `../../app-state/docs/FORMAT.md`.

Metadata is flattened into the top-level manifest.plist. Baseline initialization policy is embedded as initializationPolicy. Redundant signed-entitlements.plist copies were removed; current target entitlements are checked when signing/using a helper. There is no metadata directory.

Subsequent update: both baselines/26.38.0 and snapshots/20261005-01 were rebuilt once as formatVersion=2, with the group container renamed to containers/group-group.lt.vinted.vinted. The baseline was restored through app-state. Snapshot links remain unchanged in the archive; the new module reattaches them at restore time. Both current device archives must use app-state, not the archived v1 tools. This runbook's earlier v1 commands are historical experiment documentation.
