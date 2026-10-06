# 手机目录和清单格式 v2

手机备份根目录统一约定为 `/var/mobile/Media/AppStateBackups/`。native helper 使用物理路径 `/private/var/mobile/Media/AppStateBackups/`；RootHide shell 经 rootfs 转换访问。测试可以注入临时目录。

```text
AppStateBackups/
└── lt.manodrabuziai.fr/
    ├── baselines/
    │   └── 26.38.0/
    │       ├── containers/
    │       └── manifest.plist
    └── snapshots/
        ├── 20261005-01/
        │   ├── containers/
        │   ├── keychain/records.plist
        │   ├── identity/state.plist
        │   └── manifest.plist
        └── 20261005-02/
```

基线以捕获时 App 版本号命名，只保存首次启动前容器，不含应用程序、钥匙串或固定 IDFV。快照保存可变状态，不依赖基线；两者都没有 application/ 或 .app 副本。

快照名为有效日期加当天序号，例如 20261005-01、20261005-02；序号 01–99。auto 或省略 CLI 名称时在锁内分配手机本地日期的下一个可用序号。version/build 只作来源记录，不另设 build 文件夹。快照不覆盖基线，也不自动成为基线。

## 容器与清单

containers/data/ 是主容器，containers/group-<signedGroupID>/ 是声明的共享容器。没有身份适配器时快照不包含 identity/。

主容器和 App Group 的 tmp/ 与其他目录使用同一规则：递归保存文件、目录、权限和符号链接，containerInventories 包含其后代。恢复清空当前容器内容，再恢复归档内容；符号链接使用统一的目标重定位规则。普通文件内部保存的路径字符串不会自动改写。

捕获排除主容器整个 Library/SplashBoard/，其他目录与 App Group 不排除。manifest 的 captureExclusions 记录此规则；恢复不增加过滤或兼容分支，仍验证和回放归档的实际清单。复制失败报告具体路径与 errno，不因未经授权的权限错误跳过文件。

manifest 保存 formatVersion=2、status=complete、kind、name、bundleID、version、build、containerIDs、containerSourcePaths、keychainGroups、keychainIncluded、identityIncluded 和核心校验信息。展示字段使用简单根级名称：title（用户名称）、note（备注）、idfv（身份索引）、date（本次完整备份时间）；name 仍为目录名。已有 v2 的 account/createdUTC/identity 文件可供列表读取，不改写旧归档。version/build 仅记录数据来源，不作为恢复限制；没有 baselineRef 或 applicationFingerprint。容器清单直接存于 containerInventories 字段，不重复存成独立文件。程序目录不生成 README.txt 或 verification/。

keychainGroups 是目标已签名 keychain-access-groups、application-identifier 和 com.apple.security.application-groups 的去重并集，自动推导，不按 App 或服务名列举。所有组都查询同步及非同步的五种 Security 记录类别；目前支持归档两种密码类别，其余类别存在记录时整次操作报错，不能静默跳过。恢复要求清单范围与当前推导范围完全一致，不做旧范围兼容。

归档引用是根目录内相对路径，不允许 ..、绝对路径或 symlink。恢复解析当前已安装 App 的容器和权限，不替换 bundle，不要求版本、build 或程序指纹相同；数据升级由 App 处理。解析当前容器 UUID，保留当前 .com.apple.mobile_container_manager.metadata.plist。归档核心文件计算哈希，其余记录类型、大小、mode 和 uid/gid。

容器内容允许符号链接。清单记录 type=symlink 与原始 target，遍历和复制不跟随链接、不重复复制目标数据。恢复先复制链接，再依据 containerSourcePaths 与当前容器位置将内部绝对链接及跨容器链接重新挂接为相对目标；同容器相对链接保持原文。链接串联中的 .. 不做盲目文本折叠，外部链接保持原文。通过 lchown/lchmod 还原链接本身的权限，最终回读链接文本和容器清单。IndexedDB/v0 指向自己的父目录时恢复为 v0 → .，不修改快照里的原链接。

绝对链接也可能指向比快照来源更早的安装容器。经确认属于同一容器的历史根路径记录在可选 containerSourceAliases 中，格式为容器 ID 到绝对路径数组的字典。恢复将这些明确的历史绝对链接根同样映射到当前容器，不能只替换 containerSourcePaths 中的 UUID。别名必须与该来源容器具有相同父目录，不得重复或指向其他已声明来源、当前容器；预检完成后才开始写入。不凭未知 UUID 推断其他 App 的容器归属。此字段不改变原始备份链接，也不增加目录或旧格式兼容。相对链接仍按 containerSourcePaths 处理；同容器相对链接中写死更早根目录名称的情况尚未纳入历史别名重定位。

## 钥匙串

基线没有 keychain/ 或 identity/；建立基线不删除手机当前钥匙串。恢复基线时 desired records=[]，清空授权目标 App exact 访问组内同步与非同步记录，并通过身份适配器生成和写入新的 IDFV。基线不保存或回放固定身份值。

快照使用 kSecAttrSynchronizableAny 查询全部同步与非同步密码条目，保存密码内容、原始同步标记、可写属性和 PXArchivedACL。系统返回的同步数值 0/1 与布尔值均接受；已有 generic 字符串或数据均保持原样。恢复时解码 ACL，用 kSecAttrAccessControl，移除归档字段和 kSecAttrAccessible。不支持 certificate/key/identity 数据时整体拒绝，不静默跳过。敏感文件 0600，目录 0700。

快照恢复先检查同步记录是否可按原保护属性恢复。非同步部分清空后重建；同步记录按 class/group/account/service 或互联网凭据完整主键更新，新记录按原属性加入。归档没有的当前同步条目按具体主键删除，不能保留新增 DeviceToken 或其他额外记录。保护属性冲突或不能安全更新的属性，在清理记录或替换容器前拒绝。完整回读必须匹配归档的条目数量、内容和属性。

2026-10-06 用户明确授权基线全量清理及快照额外记录清理。基线恢复使用独立的 baseline reset 接口：只在已签名目标 exact group 中逐条删除同步记录，再清理非同步记录；全部回读必须为零，才继续替换容器并生成 IDFV。快照恢复只删除归档没有的同步记录。同步记录的更新/删除可能同步到同一 iCloud 钥匙串，不能将其当作纯本地文件写入。

## 内部临时处理

备份时在对应 baselines/ 或 snapshots/ 内用隐藏的 .capture-<UUID> 暂存，成功后 rename 为最终名称，普通失败时清理。恢复直接使用选定备份，不创建 work、journal 或恢复前副本。

显式 snapshot --replace 先完整验证当前状态 capture，再移除指定旧快照并发布到原名称。删除/发布失败后保留完成的新 capture，并报告 archiveMayBePartial 与 pendingCaptureReference；不生成旧快照副本。默认 snapshot 仍拒绝覆盖。快照名称可保留原日期，date 记录本次实际捕获时间。UIKit 账号环境会话按当前 IDFV 唯一关联固定目录，重复 IDFV 拒绝新建账号备份；原有多份历史资料不被自动删除。

按用户要求不实现 rollback。先校验 Bundle ID、权限范围、核心文件和归档，再清空目标钥匙串、替换容器内容并恢复身份。错误时立即停止，返回 stateMayBePartial；发生写入后失败不会自动恢复先前状态，可从选定备份重新执行恢复。

## 手机原有备份

2026-10-05 经用户要求，手机旧资料已整理到 `/var/mobile/Media/AppStateBackups/lt.manodrabuziai.fr/`：基线为 `baselines/26.38.0`，快照由 `20261005-structured-01` 改名为 `snapshots/20261005-01`。App 核心文件与两份原清单核对一致后，删除快照中重复的 application/，清单记录 baselineRef。此前保留的恢复前副本已按用户要求删除。基线和快照的 README.txt、verification/ 已删除，必要清单合并到现有 manifest.plist 的 inventories 字段；快照不重复存基线的 App 清单。

本模块只接受 formatVersion=2，不兼容旧清单。手机基线已一次性重建为 v2 清单，共享容器目录也改为 containers/group-group.lt.vinted.vinted，以便直接交给通用引擎。

快照 20261005-01 的旧格式整理先前因符号链接暂停。在实现链接重挂后，继续一次性整理为 v2；快照保存原始链接，重定位仅在之后执行恢复时发生。

手机 v1 资料的 manifest.plist 已移至基线和快照顶层，初始化策略并入 initializationPolicy，冗余签名权限副本已删除，不再有 metadata/。
