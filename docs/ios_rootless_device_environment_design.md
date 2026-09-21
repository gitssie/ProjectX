# iOS RootHide 真机环境管理系统设计需求文档

## 1. 文档说明

### 1.1 项目名称
**iOS RootHide 真机环境管理系统**

### 1.2 项目定位
面向使用 Dopamine RootHide 的 iOS 测试设备，提供一套可复用的设备环境 Profile 管理能力，用于在授权测试场景中统一管理：

- 设备基础环境
- App 级身份标识
- App 数据与持久化状态
- 地区、时区、定位与网络环境
- RootHide Hook 配置
- 多设备环境切换
- 远程控制与自动化扩展

系统目标不是简单修改单个设备参数，而是维护一套**内部一致、生命周期合理、可重复恢复的设备环境 Profile**。

---

## 2. 核心设计原则

### 2.1 Profile 优先
所有环境参数均归属于 Profile，不允许零散随机修改。

示例：

```text
Profile A
├── Device
├── OS
├── Identity
├── Storage
├── Region
├── Location
├── Carrier
└── Runtime
```

### 2.2 一致性优先
同一 Profile 内的参数必须保持合理关系。

例如：

```text
Model: iPhone XR
ProductType: iPhone11,8
Screen: 828 × 1792
Scale: 2x
CPU: A12
```

禁止生成如下矛盾组合：

```text
Model: iPhone XR
ProductType: iPhone15,3
Screen: 1179 × 2556
RAM: 6 GB
```

### 2.3 生命周期独立
不同字段必须按照真实 iOS 生命周期管理，不得统一“一次随机后永久固定”。

例如：

| 字段 | 生命周期 |
|---|---|
| ProductType | 设备生命周期 |
| iOS Version | 系统升级生命周期 |
| IDFV | Vendor / Profile 生命周期 |
| IDFA | ATT / Profile 生命周期 |
| Boot UUID | 单次系统启动周期 |
| Uptime | 当前启动周期动态变化 |
| Location | 实时变化 |
| Carrier | SIM / 网络变化 |
| App Install ID | App 安装生命周期 |

### 2.4 App 状态隔离优先于设备参数修改
App 自身产生的持久化标识通常比设备型号更重要。

新 Profile 必须优先处理：

- App Container
- Preferences
- Keychain
- App Group
- SQLite / CoreData
- WebKit 数据
- App 自生成 Install ID

### 2.5 RootHide 原生设计
目标环境：

```text
Dopamine RootHide
ElleKit
Theos roothide
随机化 jbroot
arm64e package architecture
iOS 15+
```

所有越狱引导文件使用 jbroot 逻辑路径，真实 iOS 文件使用 rootfs 转换路径；package 与 LaunchDaemon 中由 RootHide 翻译的路径保持未加前缀的逻辑形式。

---

# 3. 总体架构

```text
                         Desktop Controller
                     React / Vue / Tauri / Native
                              │
                       LAN / WebSocket / TCP
                              │
              ┌───────────────┼───────────────┐
              │               │               │
           iPhone 01       iPhone 02       iPhone 03
              │               │               │
        RootHide Agent   RootHide Agent   RootHide Agent
              │
      ┌───────┼───────────────────────────────────────┐
      │       │            │            │             │
   Control  Profile     Storage      Environment    Runtime
      │       │            │            │             │
   ioscpy   Identity     Keychain      Locale       Boot
   Touch    Device       Container     Timezone     Uptime
   Video    OS           WebKit        Location     Battery
                                  Carrier / Network
```

---

# 4. 系统模块

## 4.1 RootHide Agent

### 职责
运行于 iPhone RootHide 环境，负责：

- 接收中控命令
- 读取当前 Profile
- 应用 Profile
- 控制 App 生命周期
- 修改目标 App 可观察环境
- 管理 App 数据
- 提供状态查询
- 暴露 LAN API

### 建议组件

```text
RootHideAgent
├── AgentDaemon
├── ProfileManager
├── HookRuntime
├── StorageManager
├── AppManager
├── EnvironmentManager
├── DeviceCatalog
└── RuntimeManager
```

---

# 5. Profile 数据模型

## 5.1 Profile 基本信息

```json
{
  "id": "profile_xxx",
  "name": "France-iPhoneXR-01",
  "status": "active",
  "createdAt": "",
  "updatedAt": ""
}
```

字段：

- Profile ID
- Profile 名称
- 状态
- 创建时间
- 更新时间
- 关联设备
- 关联 App
- 备注

---

## 5.2 Device Identity

### 字段

- Device Name
- Device Model
- Product Type
- Hardware Model
- Screen Width
- Screen Height
- Native Resolution
- Scale
- CPU Family
- Physical Memory
- Storage Capacity

### 示例

```json
{
  "modelName": "iPhone XR",
  "productType": "iPhone11,8",
  "screen": {
    "width": 828,
    "height": 1792,
    "scale": 2
  },
  "cpu": "A12",
  "memory": "3GB"
}
```

### 约束

用户选择：

```text
iPhone XR
```

系统自动关联：

```text
ProductType
Screen
Scale
CPU
RAM
HardwareModel
```

不允许逐字段制造不可能存在的组合。

---

# 6. OS Identity

## 字段

- iOS Version
- Build Version
- OperatingSystemVersion
- System Name
- Kernel 相关可观察版本
- Locale 相关系统版本信息

### 示例

```json
{
  "systemVersion": "16.7.1",
  "buildVersion": "20H30"
}
```

### 要求

以下信息必须一致：

```text
UIDevice.systemVersion
NSProcessInfo.operatingSystemVersion
BuildVersion
MobileGestalt OS 信息
```

---

# 7. Identifier 管理

## 7.1 IDFV

### 要求

- 每个 Profile 固定
- Profile 重建时可重新生成
- 不应每次调用随机
- 应与目标 App / Vendor 作用域设计一致

---

## 7.2 IDFA

### 要求

必须同时考虑：

- IDFA 值
- ATT Authorization 状态
- Tracking enabled 状态

禁止：

```text
ATT = denied
IDFA = 正常随机 UUID
```

如果环境定义为未授权，应遵循系统正常行为。

---

## 7.3 Boot UUID

### 生命周期

```text
一次系统启动期间固定
重新启动后变化
```

### 数据结构

```json
{
  "bootUUID": "...",
  "bootTime": "...",
  "uptimeBase": 0
}
```

### 一致性

Boot UUID、Boot Time、Uptime 必须属于同一运行会话。

---

## 7.4 App Install UUID

用于模拟 App 第一次安装后生成的安装标识。

要求：

- Profile 生命周期内稳定
- 重置 App 环境时重新生成
- 支持持久化
- 支持按 App 独立管理

---

## 7.5 Container UUID

管理：

- App Container UUID
- App Group UUID
- Shared Container UUID

要求：

- Profile 间隔离
- App 重装/重置行为符合预期
- 不与真实 Container 物理路径逻辑冲突

---

# 8. App Storage 管理

## 8.1 App Container

覆盖：

```text
Documents/
Library/
tmp/
```

支持：

- 清理
- 备份
- 恢复
- Profile 隔离
- 快照

---

## 8.2 NSUserDefaults

管理：

```text
Library/Preferences
```

要求：

- 按 Bundle ID 管理
- Profile 切换时隔离
- 支持清理
- 支持备份恢复

---

## 8.3 数据库

覆盖：

- SQLite
- CoreData
- Realm
- App 自定义数据库文件

功能：

- 全量删除
- Profile 快照
- 恢复

---

# 9. Keychain 管理

## 9.1 目标

解决 App 删除/重装后 Keychain 仍保留旧安装标识的问题。

## 9.2 功能

- 查询目标 App 相关 Keychain Item
- 按 Access Group 管理
- 选择性清理
- Profile 隔离
- 备份与恢复

## 9.3 安全约束

禁止“一键清空整个系统 Keychain”。

必须限定：

```text
Bundle
Access Group
Service
Account
```

避免影响：

- Apple ID
- Wi-Fi
- 系统凭证
- 其他 App

---

# 10. App Group 管理

覆盖：

```text
group.*
Shared Container
Extension Data
```

要求：

- 主 App 与 Extension 一起处理
- 同一 App Family 的 Shared Group 保持一致
- Profile 切换时同步切换

---

# 11. WebKit / Safari 数据

## 11.1 WKWebView

管理：

- Cookies
- LocalStorage
- IndexedDB
- Cache
- WebsiteData
- Service Worker

### 用途
很多第三方 App 使用 WKWebView，单纯清 Documents 不足以恢复新环境。

---

## 11.2 Safari

Safari 数据单独管理，不与目标 App WebKit 数据默认混在一起。

支持：

- Cookie 清理
- 网站数据清理
- LocalStorage 清理
- Cache 清理

---

# 12. 地区环境

## 12.1 Language

字段：

- Preferred Languages
- App Language
- System Language

---

## 12.2 Locale

字段：

```text
Language
Country
Region
Calendar
Number Format
Date Format
Currency
```

---

## 12.3 Timezone

字段：

```text
Europe/Paris
Asia/Shanghai
America/Los_Angeles
```

要求：

- Profile 稳定
- 可单独修改
- 与定位建议匹配但不强制绑定

---

# 13. Location

## 字段

- Latitude
- Longitude
- Altitude
- Horizontal Accuracy
- Vertical Accuracy
- Course
- Speed
- Timestamp

### 模式

```text
Fixed
Route
Follow
Disabled
```

### Fixed 示例

```json
{
  "latitude": 48.8566,
  "longitude": 2.3522,
  "accuracy": 10
}
```

---

# 14. Carrier / Cellular

## 14.1 Carrier Profile

字段：

- Carrier Name
- MCC
- MNC
- ISO Country Code
- Cellular Service Identifier
- Radio Access Technology

### 示例

```json
{
  "country": "France",
  "carrier": "Orange",
  "mcc": "208",
  "mnc": "01",
  "radio": "LTE"
}
```

---

## 14.2 网络类型

支持：

```text
Wi-Fi
4G / LTE
5G
Offline
```

要求：

Carrier 与网络状态应独立但可关联。

例如：

```text
SIM = Orange
当前连接 = Wi-Fi
```

属于正常状态。

---

# 15. Network

管理目标：

- Wi-Fi / Cellular 状态
- Reachability
- VPN 状态
- Interface Type
- Radio Type

注意：

```text
Public IP
```

属于真实网络出口信息。

本地 Hook 不能真正改变服务端观察到的出口 IP，因此代理/VPN属于系统外部网络层。

---

# 16. Runtime Environment

## 16.1 Boot Session

字段：

- Boot UUID
- Boot Time
- Uptime

要求：

```text
bootTime + uptime ≈ currentTime
```

保持逻辑一致。

---

## 16.2 Battery

字段：

- Battery Level
- Charging State
- Low Power Mode

优先级低。

不建议长期固定完全不变。

---

## 16.3 Storage

字段：

- Total Capacity
- Available Capacity

Total 与机型 Profile 对应。

Available 应允许动态变化。

---

# 17. Graphics Environment

低优先级模块。

可能涉及：

- Metal Device Name
- GPU Family
- Screen Characteristics
- Canvas 相关结果
- OpenGL 信息

要求：

必须与设备型号保持对应。

---

# 18. App 生命周期控制

Agent 应支持：

```text
list_apps
launch_app
terminate_app
restart_app
foreground_app
```

参数：

```json
{
  "bundleId": "com.example.app"
}
```

---

# 19. Profile 应用流程

## 19.1 一键应用 Profile

推荐流程：

```text
选择目标 App
      ↓
停止目标 App
      ↓
保存当前状态（可选）
      ↓
加载 Profile
      ↓
切换 App Storage
      ↓
处理 Preferences
      ↓
处理 Keychain
      ↓
处理 App Group
      ↓
处理 WebKit
      ↓
应用 Identity
      ↓
应用 Device / OS Profile
      ↓
应用 Locale / Timezone
      ↓
应用 Location
      ↓
应用 Carrier / Network Profile
      ↓
重新启动目标 App
```

---

# 20. 一键新环境

按钮：

```text
新建环境
```

系统自动执行：

```text
生成新的 Profile ID
生成新的 IDFV
生成新的 Install UUID
生成新的 Container Profile
生成新的 App Storage
生成新的 Keychain Scope
生成新的 WebKit Scope
选择 Device Profile
选择 Region Profile
初始化 Runtime
```

---

# 21. 清理功能

## 21.1 清理 App 数据

清理：

- Documents
- Library
- tmp
- Preferences
- Cache
- Database

---

## 21.2 清理 Keychain

必须按目标 App 范围。

---

## 21.3 清理 WebKit

清理：

- Cookies
- LocalStorage
- IndexedDB
- WebsiteData

---

## 21.4 清理 App Group

处理目标 App 对应 Shared Container。

---

## 21.5 全面清理

组合执行：

```text
App Data
+
Preferences
+
Cache
+
Database
+
Keychain
+
App Group
+
WebKit
+
Pasteboard
```

执行前必须停止目标 App。

---

# 22. 远程控制

推荐结合 ioscpy。

## 22.1 控制能力

- Screen Stream
- Tap
- Swipe
- Long Press
- Keyboard
- Clipboard
- Home
- Lock
- App Switcher

---

## 22.2 LAN 模式

目标架构：

```text
Desktop
   │
   │ LAN
   ▼
192.168.x.x
   │
RootHide Agent
```

不依赖 USB 作为日常控制链路。

---

# 23. 多设备管理

设备模型：

```json
{
  "deviceId": "",
  "name": "iPhone-01",
  "ip": "192.168.1.101",
  "status": "online",
  "profileId": "",
  "currentApp": ""
}
```

功能：

- 在线状态
- IP
- 当前 Profile
- 当前 App
- 电池
- 网络
- RootHide 状态
- Agent 状态
- 重连

---

# 24. 中控 UI

## 24.1 设备列表

字段：

- 设备名称
- IP
- 型号
- iOS
- RootHide 状态
- Agent 状态
- 当前 Profile
- 当前 App
- 网络
- 操作

---

## 24.2 Profile 编辑

Tabs：

```text
基础
设备
系统
身份
应用数据
地区
网络
定位
高级
```

---

## 24.3 快捷操作

```text
应用 Profile
新建环境
清理数据
清理 Keychain
清理 WebKit
重启 App
打开控制
```

---

# 25. RootHide 技术要求

目标：

```text
Dopamine
ElleKit
Theos
RootHide
```

编译：

```make
THEOS_PACKAGE_SCHEME = roothide
THEOS_PACKAGE_ARCH = iphoneos-arm64e
```

运行时路径需按命名空间转换：

```text
jbroot("/Library/...")
rootfs("/var/mobile/Containers/...")
```

package staging 与 LaunchDaemon 保持 RootHide 逻辑路径：

```text
/Library
/Applications
```

这些路径由 Theos roothide 与 RootHide runtime 转换，不得手工加入固定 bootstrap 前缀。

---

# 26. Hook Runtime 设计

推荐拆分：

```text
HookRuntime
├── DeviceHooks
├── OSHooks
├── IdentifierHooks
├── LocaleHooks
├── TimezoneHooks
├── LocationHooks
├── CarrierHooks
├── NetworkHooks
└── RuntimeHooks
```

Hook 模块只负责：

```text
读取 Profile
↓
返回对应值
```

不要在 Hook 内随机生成数据。

---

# 27. Profile Store

Profile 必须持久化。

建议：

```text
/var/mobile/Library/<Product>/Profiles/
```

结构：

```text
Profiles/
├── profile-a/
│   ├── profile.json
│   ├── identifiers.json
│   ├── environment.json
│   └── storage.json
│
└── profile-b/
```

Hook 进程和 daemon 应读取同一份 Profile 数据。

---

# 28. Device Catalog

维护真实 iPhone 型号数据库。

示例：

```json
{
  "iPhone11,8": {
    "name": "iPhone XR",
    "chip": "A12",
    "screen": "828x1792",
    "scale": 2,
    "memory": "3GB"
  }
}
```

作用：

- 自动生成一致设备环境
- 禁止非法参数组合
- 简化 UI

---

# 29. Region Catalog

示例：

```json
{
  "FR": {
    "locale": "fr-FR",
    "timezone": "Europe/Paris",
    "currency": "EUR",
    "carriers": [
      {
        "name": "Orange",
        "mcc": "208",
        "mnc": "01"
      }
    ]
  }
}
```

---

# 30. API 设计

示例：

```text
GET  /device/status
GET  /profiles
POST /profiles
POST /profiles/{id}/apply

POST /apps/{bundleId}/launch
POST /apps/{bundleId}/terminate

POST /apps/{bundleId}/clear-data
POST /apps/{bundleId}/clear-keychain
POST /apps/{bundleId}/clear-webkit

POST /location/set
POST /environment/set
```

---

# 31. MVP 范围

第一阶段建议只做真正重要的能力。

## P0

- RootHide Agent
- Profile Manager
- Device Catalog
- IDFV
- IDFA 状态
- App Install ID
- App Container
- Preferences
- Keychain
- App Group
- WebKit
- Locale
- Timezone
- Location
- App Launch / Kill
- Profile 持久化

---

# 32. 第二阶段

## P1

- Device Model
- ProductType
- iOS Version
- Build Version
- Screen Profile
- Carrier
- MCC / MNC
- Radio Technology
- Network State
- LAN Agent
- ioscpy 集成
- 多设备管理

---

# 33. 第三阶段

## P2

- Boot UUID
- Boot Time
- Uptime
- Storage
- Battery
- GPU
- Graphics Profile
- 自动设备发现
- 多设备同步控制
- Profile 批量下发

---

# 34. 不建议优先实现的项目

以下信息不应作为 MVP：

- IMEI
- ECID
- Secure Enclave Key
- App Attest 伪造
- DeviceCheck 伪造
- Push Token 伪造
- Baseband 真实硬件标识

原因：

- 普通 App 通常无法直接读取
- 涉及硬件安全域
- 本地 Hook 无法等价替代服务器或硬件验证
- 实现成本高且收益有限

---

# 35. 验收标准

## 35.1 Profile 稳定性

同一 Profile：

```text
同一字段重复读取结果稳定
```

---

## 35.2 Profile 隔离

Profile A 与 Profile B：

```text
App Data 不共享
Preferences 不共享
Keychain 范围正确隔离
WebKit 不共享
Install Identity 不共享
```

---

## 35.3 一致性

例如选择：

```text
iPhone XR + iOS 16.7.1 + France
```

系统返回的：

```text
ProductType
Screen
CPU
OS Version
Build
Locale
Timezone
```

不存在明显矛盾。

---

## 35.4 生命周期

Boot UUID：

```text
当前 Boot Session 固定
```

Uptime：

```text
随时间增长
```

Location：

```text
按照运行模式变化
```

---

## 35.5 RootHide

要求：

- Dopamine RootHide 正常安装
- ElleKit 注入正常
- Respring 后 Agent 自动恢复
- 随机化 jbroot 下的 package 文件路径正确
- package architecture 为 `iphoneos-arm64e`
- 真实 iOS 文件统一通过 rootfs 命名空间访问

---

# 36. 最终目标

系统最终形态：

```text
                  iOS RootHide Device Center
                           │
          ┌────────────────┼────────────────┐
          │                │                │
      Device Farm       Profiles        Automation
          │                │                │
       ioscpy        Environment       Vision / Script
          │                │                │
          └────────────────┼────────────────┘
                           │
                    RootHide Agent
                           │
            ┌──────────────┼───────────────┐
            │              │               │
          Hooks          Storage        Runtime
```

核心价值：

> 用一套可管理、可恢复、生命周期合理且内部一致的 Profile，管理 RootHide iOS 测试设备的 App 数据、设备环境和运行环境，而不是单纯堆叠随机 Hook。
