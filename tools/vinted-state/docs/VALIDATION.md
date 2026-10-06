# 真机验证记录：2026-10-05

## 环境与目标

- Dopamine RootHide，已越狱设备；独立 native helper，无 Vinted Hook 或注入。
- Vinted bundle ID：`lt.manodrabuziai.fr`；版本 `26.38.0`，build `30255`。
- 已签名 application identifier：`4Y2CNF6C99.lt.manodrabuziai.fr`。
- 已签名钥匙串组：`4Y2CNF6C99.com.vinted.keychain-group`，当时只声明这个组。
- App Group：`group.lt.vinted.vinted`。

## 实测结论

| 操作 | 实际结果 |
|---|---|
| 默认钥匙串查询 | 6 条 generic-password；internet-password、certificate、key、identity 均为 0 |
| 导出内容 | 6 条内容全部可读，所有 6 条 ACL 序列化/反序列化后一致 |
| 临时条目测试 | generic-password 和 internet-password 分别完成创建、备份、删除、恢复、内容比对、清理；既有记录不变 |
| 不用 Hook 修改 IDFV | 精确修改 LaunchServices 的 Vinted Vendor 字段、重启 mobile lsd 后，系统 API 两次读取新值；还原后恢复旧值；其他 Vendor 记录未变 |
| 完整备份 | 手机 `Media/VintedBackups/20261005-structured-01`，约 368 MB；App bundle、主容器、共享容器、6 条钥匙串和指定 Vendor 记录 |
| 卸载重装且从未启动 | 主容器/App Group UUID 和 IDFV 均更换；旧 6 条钥匙串仍在，与原备份一致 |
| 首次启动前目录 | 主容器 6 个文件约 47 KB：系统元数据、4 个 SplashBoard 文件、StoreKit receipt；Documents、Preferences、Caches、tmp、SystemData 无业务数据 |
| App Group | 一个系统元数据文件，Library/Caches 为空 |
| 基线 | 手机 `Media/VintedBackups/baselines/26.38.0`，约 300 MB；没有钥匙串目录和固定 IDFV |
| 实际恢复 | 钥匙串清空并验证，再恢复 6 条；内容与 ACL 一致；两容器核心文件与备份一致；保留当前容器 UUID；系统 IDFV 与备份一致 |
| 用户确认 | 用户随后确认恢复可用 |

## 格式与关键经验

1. `keychain/*.plist` 保存可写属性及 secret bytes；ACL 单独保存为 `PXArchivedACL` NSData。
2. 恢复 ACL 时用 `SecAccessControlCreateFromData`；移除 `PXArchivedACL`；使用 `kSecAttrAccessControl` 时移除 `kSecAttrAccessible`，避免二者同时提交。
3. 所有钥匙串查询和清理显式指定 exact group、class、synchronizable=false。数据不输出到日志。
4. 只删除备份/恢复流程已确认的目标组。拒绝未知签名组和当前未支持的非密码项；不处理 synchronizable 项。
5. 恢复容器内容时保留当前 `.com.apple.mobile_container_manager.metadata.plist`，不回放旧 UUID；原 uid/gid/mode 由 inventory 保存。
6. `verification/` 是文件清单；仅核心文件计算哈希，其余只记录路径、类型、大小与权限。
7. native helper 使用系统物理路径；RootHide bootstrap shell 访问系统文件需用 rootfs 转换。不要写随机 bootstrap 前缀。
8. 仅 platform/no-container 的 helper 读取主容器元数据曾失败；增加 AppDataContainers/AppBundles 存储权限后成功。
9. SCP 必须传输完成后才运行 ldid。曾在传输期间签名触发文件长度断言；等待完成后正常。
10. Windows iproxy 无法连接 SSH 时，曾由 Dopamine 签名过期、越狱未生效导致；恢复签名并重新越狱后可连。
11. 恢复检查中曾出现 Vinted 进程；停止后重新核对钥匙串、IDFV 和容器核心文件仍一致。后续操作应在前后检查目标进程，避免并发写入。

## 范围限制

- 证明的是这次同设备、同 App 版本的本地状态恢复；不保证服务端认定新设备。
- 没有证明跨设备、跨 iOS、跨 App 版本恢复；Secure Enclave 密钥和同步钥匙串不在范围内。
- 基线不含钥匙串不等于手机当前钥匙串已空。首次启动会创建哪些记录尚未验证。
- App bundle 是已安装文件副本，不是可独立安装的 IPA。版本/build 相同的恢复没有替换已安装 bundle。
- ACL 私有序列化函数只在当前环境验证；不应推断为跨系统版本稳定格式。
- Current restore code follows the user's no-rollback requirement: preflight, direct replacement, immediate stop on error. Earlier successful device restore predates this change; this revised path has been compiled, not executed on the phone.
- 基线状态必须由操作者确认从未启动；工具本身不能证明历史上没启动过 App。
- 参数化源码的编译验证与当时实际使用的临时源码真机验证分别记录，未声称新的源码已经重新部署。

## Archive validation

All eight parameterized helpers compiled for arm64/iOS 15 with ARC and warnings-as-errors. Both shell files passed syntax checks. Entitlement generation passed role, exact scope, 0600 permissions and wildcard-rejection checks. The full ProjectX scripts/check_build_warnings.sh gate passed. No new device deployment, Git commit or push was performed during archiving.
