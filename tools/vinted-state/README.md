# Vinted 真机状态实验工具

用于保存 2026-10-05 在 Dopamine RootHide 真机上使用过的检查、备份、基线和恢复源码，以及操作知识。属于独立维护工具，不会随 ProjectX deb 打包，不启动或注入 Vinted。

## 目录

- `src/`：8 个原实验工具的脱敏、参数化源码；`VSTContext.h` 提供当前容器解析和设备路径参数校验。
- `docs/VALIDATION.md`：实际验证结果、适用范围和未验证部分。
- `docs/RUNBOOK.md`：构建、授权签名、手机内备份与恢复步骤。
- `build.sh`：本机编译，不部署；产物在 Git 忽略的 `build/`。
- `make_entitlements.py`：从目标 App 已签名权限生成短生命周期 worker 权限文件；目标签名改变时拒绝继续。
- `restore-idfv.sh`：手机端执行，只暂停并重启 mobile 的 LaunchServices daemon，修改指定 Vendor 的 IDFV。

所有备份内容、凭据、完整系统 plist 和实际钥匙串数据继续留在手机。本目录只保存代码和说明，不包含 SSH 地址、密码、设备序列号、固定容器 UUID 或实际 IDFV。

## 构建

在 macOS 安装 Xcode/iPhoneOS SDK 后：

```sh
/bin/sh tools/vinted-state/build.sh
```

默认编译 arm64 / iOS 15+，ARC、`-Wall -Wextra -Werror`。生成的可执行文件未签名。真机执行前必须按 RUNBOOK 核对目标签名、停止 App，并按本次操作范围签名。

## 工具用途

| 工具 | 用途与副作用 |
|---|---|
| `LSIDFVCheck` | 默认读系统 API；`set` 模式由 root 修改指定 Vendor 字段，要求旧值匹配 |
| `KeychainCheck` | 读取统计、内存序列化；创建两个随机临时条目，验证删除恢复并清理；不删除既有记录 |
| `VintedInspect` | 只读目录、版本、IDFV、钥匙串统计，与指定旧备份在内存中比较 |
| `VintedBackup` | 手机内结构化复制、导出非同步钥匙串、保存 IDFV；不修改原数据 |
| `VintedFinalize` | root 导出指定系统 Vendor 记录，完成备份清单 |
| `VintedBaseline` | 手机内首次启动前模板；不导出钥匙串、不保存固定 IDFV，不清理现有记录 |
| `VintedRestore` | 默认清空访问组并恢复容器与钥匙串；`check` 参数只核对容器核心文件 |
| `RestoreVerify` | 核对钥匙串内容/ACL 和 IDFV，输出验证结果 |

实验阶段的代码保留了原来的独立程序结构与重复辅助函数，方便追溯。参数化后的版本通过本地编译，但未重新在手机执行；原实验流程已完成真机验证，二者不能混同。正式集成时应复用 ProjectX 路径层与 one-shot worker 协议。
