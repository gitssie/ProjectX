# ProjectX 接入与验证范围

2026-10-06 UIKit 接入：用户确认 v23 后，新增正式账号备份页面与每次复制/签名的 scoped worker。实现详情见 `../../../docs/app-state-ui.md`。历史记录中的「未接入 UI」描述仅适用于对应实验时间；新链路已本地构建和单元验证，尚未部署真机。核心 `performExclusive` 将保存当前再恢复目标的序列置于同一 store lock 中；没有回滚事务。

诊断工具说明修正：pxas-prefs-probe 的 read 只调用 assertStopped 检测运行状态，不终止目标 App；ready 输出 stopped=true 仅表示当时没有检测到目标进程。显式终止由 pxas-stop-current 执行，restore/capture 真机脚本先调用它。不能把历史检查时 stopped=true 的输出表述为偏好读取探针主动停止了 App。

2026-10-06 凭据重放对照：先将 UTC 05:44:11 续期后的完整正常状态保存为 20261006-04，16 条钥匙串、主偏好和身份均独立回读一致。再次恢复同一份 02 测试版（仍装有 03 的同一对令牌），通过独立 LSApplicationWorkspace 正常启动 App；约 UTC 05:53:13 它生成新的 public 令牌，清掉 user_id，其他 14 条钥匙串未变。该输入此前已成功自动取得一对新 user 令牌，现在重复使用不能继续保持用户会话，强烈符合已使用旧刷新凭据的轮换/失效现象；未捕获 HTTP 拒绝码，不能将协议层拒绝原因或所有令牌严格单次使用写成定论。

随后仅将 04 的两条 Vintedfr v_Data 写入同一份 02，其他记录属性、容器、旧 token_expiration、Cookie 和身份不变；原始 02 的 records.original.plist/manifest.original.plist 保持完整，04 未改。恢复并正常启动后，当前 16 条仍与该测试归档一致，scope=user、user_id 存在，没有生成新令牌对，偏好 token_expiration 仍是原 02 旧值。这也说明不能将此前的偏好过期字段参与触发推断扩大成每次启动都会依此刷新，实际触发条件尚未解析。最终恢复完整 04，保留最新令牌及其配套状态；具体回读结果见本次执行输出。当前 02 实验文件含 04 令牌，不再含最初 03 令牌，原始 02 仍在两份 original 文件中。

推荐处理已有独立 CLI 支持的环境切换：明确当前快照归属，停止 App，先用 snapshot --replace 完整保存当前最新状态；保存成功后再恢复目标最新快照。不要在切换时丢弃 App 已续期保存的新凭据，也不能通过改 JWT 的时间字段恢复服务端有效性。不能保证不可变历史快照里的旧登录凭据可无限重复恢复。该策略尚未实现为原子 API 或接入 ProjectX UI，不应宣称已部署自动账号切换。

2026-10-06 令牌交叉测试结果：用户确认修改后的 02 打开仍已登录。UTC 05:45:43 读取发现 Vintedfr 两条 v_Data 都已从归档中的 03 令牌变成新用户令牌，iat=UTC 05:44:11，访问 exp=UTC 06:44:11，刷新 exp=2026-11-05 UTC 05:44:11；scope 均 user。其他 14 条钥匙串及可恢复属性仍与归档一致，user_id 保留，token_scope=user，偏好 token_expiration 从 02 旧值变成 UTC 06:44:09，API 与磁盘一致。用户未报告再次手工登录，结果表明恢复后的 App 自动获取了新用户令牌对。原 03 访问令牌本来还有效，而保留的 02 偏好有效期已过：这高度支持偏好 token_expiration 参与触发续期，但没有读取 App 内部判断代码或捕获请求，不能将其写成已证实的唯一触发条件。现已证实该恢复路径能读取并使用有效凭据自动续期，同时签发新的刷新令牌；仍未证实旧刷新令牌是否在使用后立即被撤销，不能宣称已证明一次性轮换或原 02 失败的服务端错误。03 和修改后的 02 仍保存续期前的令牌，当前手机保存续期后的令牌，不要再称当前令牌与这些归档字节一致。

2026-10-06 用户指定的令牌交叉测试：用户明确要求将 03 令牌放入 02，并先备份 02 钥匙串。已在手机 20261006-02/keychain/records.original.plist 原字节保存原钥匙串，20261006-02/manifest.original.plist 原字节保存原清单；文件均 0600，已有不同原始备份时拒绝覆盖。按完整主键匹配，仅替换两条 Vintedfr 记录的 v_Data 为 03 的原始数据，其他 14 条记录和全部记录属性不变；更新 manifest.keychainSHA256，数量保持 16。03 的钥匙串和清单未变，02 容器、偏好（包括旧 token_expiration）、Cookie、身份未修改。随后恢复修改后的 02 成功，16 条钥匙串回读与修改归档一致，主偏好与 02 文件字节一致且缓存刷新，IDFV/IndexedDB 检查通过，App 未启动，等待用户界面测试。当前 02 是令牌替换实验版本；原始 02 的恢复需要使用保存的 records.original.plist 和 manifest.original.plist 成对还原，不能再把当前 records.plist 称为原始旧令牌。

2026-10-06 到期前对照第一阶段通过：用户打开恢复后的 20261006-03，确认原账号已登录。UTC 05:30:45 左右再次读取，16 条钥匙串数据和可恢复属性仍与 03 完全一致，两个用户令牌未被改写，访问令牌 exp 仍为 UTC 06:15:16，IDFV 一致；偏好 API 与磁盘均 234 项、user_id 存在、token_scope=user。检查辅助程序已停止目标 App，保留当前恢复状态供到期后打开测试。此阶段是直接快照恢复，未经过新一次基线清空；不能用此结果声称所有清空重建路径或到期后续期已验证。

2026-10-06 新快照恢复对照：UTC 05:28:46 开始恢复 snapshots/20261006-03，早于其访问令牌到期 UTC 06:15:16。原生恢复 complete；16 条钥匙串的数据及可恢复属性回读与快照一致（同步 9、非同步 7），身份一致，偏好 234 项与快照字节一致、user_id 存在、token_scope=user，偏好缓存已刷新且独立 API 与磁盘一致。tmp 顶层一致，SplashBoard 不存在，IndexedDB/v0 指向 . 且目标存在，快照钥匙串未改变，临时 worker 已清理。已请求用户打开 App 确认真实登录界面；尚不能将这些数据检查记为到期前登录测试通过，到期后续期测试也尚未执行。

2026-10-06 新登录对照快照：已在手机新建 snapshots/20261006-03，未覆盖 20261006-02。独立回读确认 16 条钥匙串全部数据及可恢复属性与当前状态一致，manifest 数量/hash 正确，身份一致，主偏好 234 项与当前文件字节一致、user_id 存在且 token_scope=user。与 02 比较，钥匙串仅 Vintedfr 两条 v_Data 改变，主偏好用户和 scope 相同、有效期及部分 SDK/会话字段改变；Library/Cookies/Cookies.binarycookies 也发生字节变化，未解析 Cookie 变化用途，不能据此断言它是故障原因。tmp 完整捕获、SplashBoard 按规则排除。当前刚登录访问令牌在 14:15:16 +08:00 到期，可以用此快照进行到期前恢复及后续续期对照；本次仅捕获，尚未恢复 03 或验证其 App 登录行为。

2026-10-06 用户重新登录后的检查：与 20261006-02 比较，声明范围三组五类的原始 Security 查询仍只有 16 条 generic-password（同步 9、非同步 7），没有新增或缺失条目。归档字段差异仅 Vintedfr 两条记录的 v_Data，其他 14 条数据与可恢复属性完全一致；deviceInfo、VintedSessionStorage、DeviceToken 及 Apple 格式服务记录均未变化。新访问/刷新令牌 JWT scope=user，iat=2026-10-06 13:15:16 +08:00，访问令牌 exp=14:15:16 +08:00，刷新令牌 exp=2026-11-05 13:15:16 +08:00。主偏好 234 项，user_id/token_scope 与原快照相同；变化包含 token_expiration、会话时间及部分 SDK 配置。独立偏好 API 与磁盘一致，IDFV 与原快照一致。未覆盖或创建快照，未恢复数据，临时 worker 已清理。此结果说明本次重新登录没有在已声明范围补出此前缺失的钥匙串记录，仍不能单独证明旧刷新令牌为何未被续用。

2026-10-06 会话一致性补查：20261006-02 的访问/刷新令牌在 sid、sub、account_id、client_id、app_id、scope、login_type、anid 上一致；主偏好 user_id 与令牌 sub 一致，token_scope 一致。VintedSessionStorage 的 49 字节内容为包含 anonId 的 JSON，anonId 与令牌 anid 一致，未发现这些核心数据混用不同会话的证据。另尝试只使用 App 原始签名 entitlements 启动独立读取探针，但探针未成功启动，结果不具备钥匙串权限判断意义；高权限回读成功仍不能证明真实 App 的查询路径成功。尚未获取真实 App 续期请求与响应，根因未确定，不能把数据恢复检查通过作为登录恢复通过。

2026-10-06 恢复后登录丢失仍未解决：两次恢复 20261006-02 的停止状态回读均与归档一致，但用户随后打开 App 均进入未登录页面。打开后对比，16 条钥匙串仍全部存在，14 条数据及可恢复属性未变，仅 Vintedfr 的访问/刷新令牌被替换；归档两个令牌的 JWT scope=user、包含用户声明，当前两个令牌 scope=public、不含用户声明。主偏好只删除 user_id，token_scope 从 user 改为 public，token_expiration 变化，其他差异仅 Facebook SDK 配置。归档访问令牌 exp=2026-10-06 11:58:29 +08:00，已过期；刷新令牌 exp=2026-11-05 10:58:29 +08:00 尚未到期，不能据此推断服务端仍接受它。手机本地核对 1,016 个归档路径，缺失仅一个 Crashlytics active report 目录及其六个文件，未发现其他路径缺失或类型变化；IDFV、deviceInfo 与归档一致，IndexedDB 链接有效。没有捕获刷新请求及错误响应，不能断言令牌轮换、服务端撤销或 Apple 登录错误为根因。手机没有可调用的 log/oslog 二进制；zsh 的 log 是同名 shell 函数，不能当作系统日志命令。诊断期间未覆盖快照，也未发起手工刷新请求。

2026-10-06 快照额外钥匙串清理：用户明确要求恢复不能保留归档没有的记录。首次恢复 20261006-02 在预检中止且没有写入；当前状态比归档多两条同步记录（服务 000199.050532b2d94c41ca9f269b58ef3dea31.0432）和一条非同步 DeviceToken-lt.manodrabuziai.fr-E9A3E227-8336-4877-8AD2-F4189DF1EC73。修正为按完整主键删除目标范围内额外同步条目，非同步条目继续清空重建。126 项核心、245 项原生测试及 iOS warnings-as-errors、ProjectX warning/package gate 通过，审查无阻塞项。真机恢复 20261006-02 成功，回读 16 条（同步 9、非同步 7）全部数据和可恢复属性与归档完全一致，额外记录已清除；偏好 234 项磁盘与独立 API 一致，user_id 存在、token_scope=user，已刷新缓存。IDFV 与归档一致，tmp 顶层与归档一致，SplashBoard 不存在，IndexedDB/v0 指向 . 且目标存在。归档钥匙串未修改，临时 worker 已清理，未启动 App。

2026-10-06 新快照对比：首次捕获在 Library/SplashBoard/Snapshots 的系统 .ktx 文件复制时报 EPERM，失败 capture 已自动清理，没有发布不完整快照。用户明确要求忽略整个主容器 Library/SplashBoard；捕获清单与 copyfile callback 同步排除此目录，移除 copyfile 创建的空目标占位目录前验证目标 Library 是真实规范目录，源 Library 为符号链接时不清理。tmp 和 App Group 不受影响，恢复继续完整验证实际归档。126 项核心、201 项原生测试、iOS warnings-as-errors 和 ProjectX warning/package gate 通过，审查无阻塞项。手机新建 snapshots/20261006-02，独立回读确认 16 条钥匙串及身份与当前状态一致；与 20261006-01 比较全部钥匙串数据和可恢复属性完全相同，包括两个令牌和 deviceInfo，IDFV 和登录偏好字段相同。主偏好 235 → 234 项，移除 vinted.domain_failover.open_until，更新部分 SDK/会话及 domain_failover.last_known_good_index；Library/Cookies/Cookies.binarycookies 字节变化。旧 20261006-01 manifest/keychain hash 未变，没有执行恢复或重新登录。

2026-10-06 访问范围修正：resolver 和 make_entitlements.py 从已签名显式同 Team 钥匙串组、App ID、声明的 group.* App Groups 自动推导去重并集；worker 校验 exact 集合，并要求共享组同时出现在自身 App Group 签名中。核心 120 项、原生 201 项测试、iOS warnings-as-errors 编译及 ProjectX warning/package gate 通过，审查无阻塞项。真机新 adapter inspect 成功读取 16 条；独立原始 Security 查询三组五类确认新增的 App ID/App Group 范围均为空。已将手机 baselines/26.38.0、snapshots/20261005-01 和 snapshots/20261006-01 清单的 keychainGroups 整理为完整推导范围，钥匙串及身份归档 hash 未变，未添加兼容分支、未修改当前 App 数据或登录状态。类型查询仍覆盖五类，导出恢复支持两种密码类，存在不支持类别时整次操作失败，不能把查询范围修正表述为已实现证书/密钥导出。

2026-10-06 当前规则：用户要求 tmp 完整备份，已撤销此前排除临时内容的规则。主容器统一使用递归 Inventory/CopyVerified，恢复不再要求 tmp 为空；现有符号链接重定位适用于 tmp，普通文件内嵌路径不改写。本地 120 项核心、196 项原生测试及 iOS warnings-as-errors 编译通过，ProjectX warning/package gate 通过，审查无阻塞项。手机 snapshots/20261006-01 重新完整捕获，清单包含 tmp、tmp/instrument、tmp/models（捕获时两个子目录为空）；独立回读确认 16 条钥匙串全部数据和可恢复属性一致（同步 9、非同步 7），deviceInfo 已包含，清单 hash/count 正确，偏好 235 项与当前文件一致、user_id 存在、token_scope=user，IDFV 一致。20261005-01 未修改；历史归档中已删除的 tmp 内容无法凭空补回。本次未恢复或启动 Vinted。

## 模块边界

PXAppStateEngine 只依赖 Foundation/POSIX/CommonCrypto，使用 PXASResolver、PXASKeychain、PXASIdentity 三个协议。UIKit 调用者在后台队列执行，不在主线程复制文件；界面只消费结果/错误，不持有广权限 worker entitlement。

- Resolver：用 PXRootHidePath 的 rootfs/jbroot 语义与现有 App 生命周期实现，解析当前签名、容器和 scope，确认 App/扩展已停止。共享容器如果还被其他安装 App 使用，接入方必须确认所有写入者已停止并明确包含这些共享数据的范围。
- Keychain：扩展现有短生命周期 external worker 的请求/响应协议，增加 export、validate、replace 与回读验证。现有 PXKeychainSecurityAdapter 仅计数/删除，不能直接冒充此接口。签名从目标 executable 推导显式同 Team groups、App ID 和声明的 group.* App Groups 并集，任何声明组不支持就失败。
- Identity：可用 PXASBlockIdentity 包装本地一次性特权操作，或独立 vendor-worker。当前具体原生实现只处理 IDFV，不提供 IDFA、序列号、Secure Enclave 或服务器设备状态恢复。

本次代码不改 Makefile/UI/daemon/现有 worker 协议，不发布或安装 deb；只增加独立工具。严禁把模块变成 LAN API 或常驻广权限进程。RootHide 正式部署继续使用项目既有流程。

## 测试入口

```sh
/bin/sh tools/app-state/build.sh test
/bin/sh tools/app-state/build.sh ios
/bin/sh scripts/check_build_warnings.sh
```

本地测试使用临时目录和模拟钥匙串/身份：不保存应用副本、快照独立于基线、跨版本/build 恢复、基线排除身份、基线清空钥匙串、恢复到新容器路径、保留元数据、钥匙串清空后失败、身份写入后失败、失败状态报告、运行中拒绝、核心损坏、路径逃逸、symlink、并发锁，以及恢复不创建额外目录。

对象互斥与跨进程锁同时使用，测试覆盖同对象重叠调用。用户明确不需要 rollback 后，已移除先前状态导出、恢复暂存、journal 和自动回退。恢复先校验备份，直接替换状态，失败立即停止并返回 stateMayBePartial；测试验证失败后可重试，且不会自动撤销已执行的写入。

2026-10-05 用户明确授权后，已使用本模块在 Vinted 真机执行基线恢复。后续正式接入仍需验证其他声明 scope、完整快照循环和更多 App；不借用本次单 App 基线结果声称全部范围已验证。

## 当前支持范围

- 受支持的第三方 iOS App，已安装 thin arm64 Mach-O，有可解析的已签名 XML entitlements。
- 同设备、同 Bundle ID 的数据恢复，允许安装版本/build 不同；不备份或替换 App 程序，数据迁移由 App 自身处理。
- 所有声明的同 Team exact keychain groups 与 App Groups；Apple/system/wildcard/跨 Team 组拒绝。
- 同步及非同步 generic-password、internet-password，原始同步属性保留；出现其他 class 数据则整体拒绝。快照恢复删除 exact scope 内归档没有的同步记录，重建非同步记录，完整回读必须与归档一致。用户明确授权的基线恢复逐条清理 exact scope 的同步项目，全部回读为零才继续。
- 普通文件、目录和符号链接；不跟随链接复制目标数据，恢复时重挂内部链接、还原链接本身的权限并回读验证；设备文件和 socket 等特殊文件仍不支持。
- 原生进程检测依赖 sysctl/proc_pidpath，可用性或 live-process 路径无法确认时拒绝，不猜测进程状态。
- Native helper 是独立物理路径模式；ProjectX 正式路径转换和权限边界必须由接入适配器提供。

## 尚未承诺

这不是跨设备或跨 iOS 的移植备份，也不保证 App 服务端认定新设备。没有基线“从未启动过”的自动证明、所有共享 App 的自动停止、全资源签名验证、并发攻击下所有目录项的 openat 事务、断电恢复重放、库引用垃圾回收或旧 v1 格式自动迁移。当前仓库格式是私有、受信任目录中的本地恢复资料，不接受外部来源快照。

vendor-worker 暂停 mobile lsd 后只修改单 App Vendor，并重新加载服务；异常路径恢复被暂停进程。强杀 root worker 的崩溃路径尚未验证，可能需要人工恢复 daemon，不能把它作为无监督后台任务。调用方必须使用非交互启动器和单次签名副本。

## 当前验证记录

2026-10-05：93 个本地断言通过，覆盖基线自动生成新 IDFV、每次生成不同值、旧格式基线依赖拒绝、故障报告和恢复不生成额外目录，以及链接不跟随复制、v0 → .、相对/绝对跨容器链接、断开的链接、链接串联与 ..、非默认链接权限、外部目标数据未改动。arm64/iOS 15+ CLI 与 vendor-worker 编译通过。

同一套断言也编译成 iOS 工具，在真机临时目录和模拟钥匙串/身份适配器中运行；不访问真实 Vinted 数据或系统钥匙串。临时测试目录和工具在测试后清理。

真机：先一次性将已有首次启动前基线重建为新格式清单，未在通用代码中添加兼容逻辑。随后直接执行 app-state restore，目标版本 26.38.0/build 30255，基线引用 lt.manodrabuziai.fr/baselines/26.38.0。结果 status=complete、keychainCount=0、identityRegenerated=true。独立 inspect 确认钥匙串从 6 条变为 0 条，独立进程的身份 API 回读确认 IDFV 与执行前不同。容器内容、原始权限和当前容器管理元数据由引擎回读校验通过；没有启动 Vinted。

快照 20261005-01 的整理先前在 WebKit IndexedDB/v0 链接处停止。实现链接支持后继续一次性整理为新格式，备份中的链接保持原文；没有再次切换实际 Vinted 状态。未提交或推送 Git。

后续真机快照恢复发现：归档的 WebKit IndexedDB/v0 指向比 containerSourcePaths 更早的安装 UUID。原重定位把它当成外部链接保留，容器清单校验也接受了这个断开目标。新增明确的 containerSourceAliases 绝对根映射后，本地及真机临时容器的 100 项断言通过，iOS 编译和 ProjectX warning/package gate 通过。仅在现有手机 manifest 中登记经确认的目标历史根，归档链接原文不变。随后实际重新恢复 20261005-01，独立原生 readlink 确认 v0 → . 且当前目标存在；两个容器清单一致，无缺失或多余项；偏好文件哈希与快照一致、user_id 存在，6 条钥匙串内容与 IDFV 均一致。工具已清理，未启动 App；恢复后的登录效果仍须用户启动验证，不能由文件校验直接推断。

2026-10-06：启动后仍未登录。只读核对发现 user_id 被移除、token_scope 从 public user 改为 public，偏好 API 与磁盘仍一致；原 6 条非同步钥匙串、IDFV 和当前 IndexedDB 链接均正常。进一步查询发现目标组还有 9 条同步密码记录，包括 Vintedfr 的 token/refresh-token 和 VintedSessionStorage，原查询 @NO 未归档它们。App ID 与声明的 App Group 范围当时查询为空；不把原 6 条回读一致解释为登录凭据完整。

用户重新登录后，核对同一账号，使用更新后的原生 CLI 执行 snapshot 20261005-01 --replace，完整更新当前容器、偏好、Cookie、全部受支持钥匙串及 IDFV；不是把新 token 拼到旧文件状态中。原生回读确认 15 条密码记录（同步 9、非同步 6）的数据、属性和 ACL 均与当前钥匙串一致；登录相关三条记录均在归档中。偏好和 Cookie 字节与当前文件相同，user_id 存在、token_scope=user；清单 count/hash/当前来源容器匹配。只保留原快照名称，createdUTC 为此次实际捕获时间。临时签名工具均已清理，没有修改手机钥匙串或执行实际恢复。

新增模拟原生 Security 调用边界的测试，覆盖全量查询、同步标记数值 0/1、generic 字符串原样保留、同步 token 按完整主键更新、互联网密码主键、删除仅限非同步条目、错误在写入前停止，以及完整覆盖现有快照。核心 112 项、原生 adapter 172 项本地断言通过，iOS warnings-as-errors 编译通过；模拟测试不证明同步写入或 iCloud 的真实效果。下一步实际基线/快照恢复尚未执行；现有禁止删除同步钥匙串的契约会使包含同步登录条目的基线恢复在预检时停止。

2026-10-06 后续：用户明确要求恢复基线并清空 Vinted 范围内全部钥匙串。基线分支按目标范围和完整主键删除同步条目，再清理非同步条目；快照恢复分支不变。真机实际恢复 26.38.0 返回 complete、keychainCount=0、identityRegenerated=true。独立进程检查声明的钥匙串组、App ID 与 App Group 共三组的五种类别，全部返回 errSecItemNotFound；同步与非同步均为空。主容器及 App Group 无偏好文件，刷新后偏好 API 和磁盘计数均为零、user_id 不存在。独立身份 API 确认 IDFV 已改变，App 保持停止，原快照钥匙串哈希未变，临时工具已清理。

首次执行在 IDFV 回读处报告部分变更：worker 写入后终止 mobile lsd，立即回读尚未得到新值。adapter 增加最多 20 次、间隔 100 毫秒的 API 回读；仍要求身份完全一致，不以磁盘写入成功替代 API 验证。重试实际恢复成功。核心 112 项与原生 adapter 196 项断言、iOS warnings-as-errors 编译通过。

本次修改后的 ProjectX warning/package gate 与 git diff --check 通过；构建产物未安装到手机。

用户启动基线后，只读检查发现 10 条密码记录（同步 3、非同步 7）、主偏好 62 项、token_scope=public、无 user_id，偏好 API 与磁盘一致。随后按用户要求执行 restore snapshots/20261005-01 --identity，返回 complete、keychainCount=15。独立精确权限工具确认全部 15 条记录的数据和属性与快照一致（同步 9、非同步 6），IDFV 与快照一致；主偏好字节与快照相同，229 项、user_id 存在、token_scope=user，刷新后 API 与磁盘完全一致。IndexedDB/v0 为相对链接 .，目标存在；引擎两容器清单校验通过。未启动 Vinted，等待用户实际登录状态测试；原快照未修改，临时工具已清理。

用户确认恢复后登录正常。只读检查发现 tmp/WebKit/MediaCache/diskcacherepository.plist 留有历史容器路径；随后按用户要求仅清空当前 tmp（33 个顶层条目），保留目录权限，主偏好不变。用户再次启动并确认正常；只读回查 tmp 已重建 5 个顶层条目，MediaCache 为空。

据用户要求，捕获主容器时不遍历或复制 tmp 内容，只保留空目录元数据；发布前源数据校验同样排除临时内容，App Group 不受影响。恢复仍完整验证归档，在写入前拒绝未整理的 tmp 内容，然后按原流程恢复空目录。手机 baselines/26.38.0 与 snapshots/20261005-01 已一次性整理，快照删除 30 个顶层临时条目并更新清单，保留原 uid/gid/mode 描述；归档非 tmp 内容校验一致，钥匙串哈希未变。未停止或修改当前 App 数据，当前主偏好哈希未变，临时整理工具已清理。核心 119 项、原生 196 项测试及 iOS warnings-as-errors 编译通过；代码审查无阻塞项。

该修改后的 ProjectX warning/package gate 通过。用户随后要求重新测试基线：使用更新后的 CLI 实际恢复 26.38.0 返回 complete、keychainCount=0、identityRegenerated=true；独立检查三组五类钥匙串全部为空，偏好文件为空、刷新后 API 计数为零，IDFV 与执行前不同，原快照钥匙串未修改。两次目标进程运行预检均在写入前停止，后续使用重新编译的停止/检查工具执行成功；未绕过进程检查，未启动 Vinted。

用户明确要求基线不保存 Vinted.app，允许 App 自行处理升级后的数据。核心已移除 application/ 捕获、applicationFingerprint、baselineRef 和已安装版本/build 相同要求；快照可独立捕获，恢复与补充钥匙串不再依赖程序副本或其他基线。version/build 仅记录捕获来源，Bundle ID、签名权限范围、容器范围、归档核心哈希和身份范围校验保留。核心 120 项、原生 196 项测试及 iOS warnings-as-errors 编译通过；审查无代码阻塞项。USB 已由用户断开，本次仅修改代码与文档，尚未删除手机基线的 application/ 或清理手机清单中的旧字段。

USB 重连后按用户要求在手机删除 baselines/26.38.0/application，并从两份清单移除 applicationFingerprint/baselineRef；整理前检查两容器归档清单和钥匙串/身份哈希，整理后数据和原钥匙串未变。随后使用新 CLI 实际恢复 snapshots/20261005-01 --identity，返回 complete。独立检查 15 条钥匙串（同步 9、非同步 6）全部数据及属性、IDFV 与归档相同；主偏好字节相同，229 项、user_id 存在、token_scope=user，刷新后 API 与磁盘相同。tmp 为空，IndexedDB/v0 → . 且目标存在。恢复使用当前系统容器 UUID 并保留容器管理元数据，不替换成归档目录 UUID；App 未启动，临时工具已清理。

再次基线/快照循环后，用户报告启动进入登录页。保留现场只读检查：恢复结束时 15 条钥匙串、229 项偏好、IDFV 与归档一致；启动后偏好为 228 项，user_id 消失、token_scope=public，API 与磁盘一致。15 条钥匙串中仅 Vintedfr 的 access/refresh 两条被替换，其余 13 条全部数据和属性仍与归档一致，VintedSessionStorage、设备记录与 IDFV 未变，IndexedDB/v0 → . 且存在。快照 access token 的 exp 为北京时间 2026-10-06 10:01:36，检查时已过期；refresh token 的 exp 为 2026-11-05 09:01:36，尚未到期。新令牌的 iat 与本次启动相近，当前偏好显示匿名范围。证据把排查重点指向登录令牌续期流程，但尚未获得刷新请求/响应，不能认定服务器已撤销旧 refresh token；JWT exp 未到也不保证服务器仍接受该凭据。当前未发现恢复遗漏或偏好缓存/IDFV/IndexedDB 回读错误；未修改手机数据、快照或令牌，临时只读工具已清理。

用户要求进一步检查 Sign in with Apple。快照有三个符合 Apple 用户标识格式的服务名，各保存邮箱及姓名，共六条，启动后仍与归档一致；这些缓存的个人资料不能等同于 Apple 当前授权凭据。VintedSessionStorage 的 JSON 仅含 anonId，没有 Apple 授权状态字段。Apple 官方的 getCredentialStateForUserID 可查询授权关系，但独立签名 CLI 复制目标签名中的 application-identifier、applesignin/team 权限后，对三个候选均返回 AuthenticationServices.AuthorizationError 1000；未取得 authorized/revoked/notFound 状态，不能用该结果推断 Vinted 的真实状态或将错误原因归于服务器。先前 App ID 与声明 App Group 的只读钥匙串查询也未发现额外密码记录。现有快照覆盖 App 范围内数据，不包含 Apple 系统/服务器授权状态。本次不修改授权、登录状态、手机数据或快照，诊断工具已清理；Apple 授权与 Vinted 续期失败的因果关系尚未确认。
