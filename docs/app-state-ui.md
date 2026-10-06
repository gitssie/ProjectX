# 账号环境备份页（v31）

2.5.3-58：首页应用宫格改为每行固定四列，数量增加自动换行，最后一行按固定列靠左排列，不拉宽少量应用。列宽适配屏幕，图标保持 48pt，列间距 8pt，名称最多两行；保留原应用图标读取与入口行为。7 个应用的隔离预览已检查 375pt 和 402pt 两种屏幕。

2.5.3-57：备份页和 Modal 统一使用与首页相同的 systemBlueColor 强调色、labelColor 文字、systemGroupedBackgroundColor 背景与 secondarySystemGroupedBackgroundColor 面板，去掉独立背景装饰。当前面板边框在外观变化时重新解析动态蓝色；备份、切换、左滑编辑、确认 checkbox、进度条与处理指示使用同一蓝色。成功／警告／删除语义色保留。浅色备份页及深色切换 Modal 已在模拟器检查，截图 `app-state-theme-light-implemented.png`、`app-state-theme-dark-modal-implemented.png`。不改变业务操作。

2.5.3-56：首页所有有标题的 section 采用统一的 16pt 图标、7pt 图文间距和跟随系统方向的标题边距，修正应用备份的额外左缩进。当前环境用 iphone、应用范围用 square.stack.3d.up、隐私清理用 hand.raised、设备用 cpu；无标题的操作区不额外添加标题。375pt 备份模式与 402pt 清理模式预览均已检查，截图 `app-state-home-section-icons-implemented.png`、`app-state-home-cleanup-section-icons-implemented.png`。仅调整标题外观。

2.5.3-55：所有正常切换均展示默认勾选的自动备份选项，包括已有账号备份和使用基线。取消勾选明确跳过当前账号的新增/覆盖；后端顺序断言与模拟器真实确认 Modal 的勾选/取消检查通过。截图 `app-state-modal-assigned-checkbox-implemented.png`。

无基线时提供「创建基线」确认与进度，生成当前安装版本空白容器模板，不读取当前业务数据或导出钥匙串/身份；运行中的目标也可创建，发布前校验安装与容器未变化。首次目录创建、无当前账号副作用、重复创建不覆盖以及模板恢复清理/重置均通过原生隔离测试。168 核心、245 钥匙串、43 会话、30 服务断言与模拟器 20 项 Modal 检查通过；clean 构建、RootHide 包审计通过并发布本地源，未改动真机应用数据。

用户于 2026-10-06 确认按 `app-state-backup-ui-v27.png` 调整，并要求在模拟器检查列表行大小。

入口：首页目标应用区块保留原来的选择行及其布局，在下方额外加入统一背景的三列应用宫格，只展示已选择的应用图标与名称，点按支持的已安装用户应用进入「账号备份」。未安装或不支持备份的目标以不可用图标保留选择记录，不删除配置。目标应用列表的左滑入口也保留，首页其他区域保持原样。

页面顶部是当前关联账号的操作面板，使用首页传入的已安装目标应用真实图标和绿色状态点，包含名称、备注、最近备份时间和「备份 / 使用基线 / 编辑」。列表不显示应用图标或头像，名称加备注/时间两行，常规字体下实测行高 53pt（内容 52pt 加分隔线），切换图标触控区域 44×44pt。点击行或切换图标执行切换；左滑直接显示重命名、备注、删除，禁用全滑直接删除，删除仍确认。重命名与备注独立修改，并保留另一字段。大字体允许行高增加以完整显示文字。重复备份使用独立提示区域，整理入口只列对应冲突备份并提供有确认的删除。右上角提供刷新。未关联环境第一次备份填写账号名称；从基线登录另一个账号后采用同一流程，不覆盖之前账号。一个 IDFV 只对应一个账号备份目录，后续备份持续更新该目录，不提供同 IDFV 的「保存为另一个账号」。

「使用中」根据当前系统 IDFV 与已存快照推导，不是检测目标 App 的实际登录账号或进程是否运行。唯一匹配时自动关联并使用当前系统容器路径，包括通过外部 CLI 恢复后的环境。既有重复 IDFV 会显示冲突，阻止继续生成或覆盖备份，不任意选择或自动删除历史数据。恢复开始前在 ProjectX 私有配置保存 pending 标记，完整恢复和偏好回读成功才清除；失败/崩溃后禁止 IDFV 推导和保存，重试恢复不会因同一 reference 跳过操作。

## 数据与操作

- 真实数据仍在手机 `/Media/AppStateBackups/<bundleID>/baselines/<version>` 和 `snapshots/YYYYMMDD-NN`；无额外层级、压缩包、README、验证目录或 application 副本。
- 列表的版本及日期仅用于展示。已有 `createdUTC` 的 plist Date 和 ISO 8601 字符串都能读取；缺失的展示字段不阻断列表或恢复，也不重写手机归档。恢复仍执行原有核心数据与目标范围校验。
- 原生 worker 的实际目录为 `/var/mobile/Media/AppStateBackups`。RootHide `rootfs()` 生成虚拟 bootstrap 路径后，通过 `jbroot()` 转回原生 Foundation/POSIX 可操作的真实路径；SystemGroup 扫描也使用这一转换。
- 用户信息保存为根级 `manifest.plist` 的 `title`、`note`、`idfv`、`date`、`version`、`build`；`name` 是目录名，`title` 是用户名称，`date` 为本次完整备份时间。覆盖备份时保留标题及备注；没有引入 SQLite。已有 v2 快照的 `account`、`createdUTC` 和 `identity/state.plist` 仍能读取，不在列表读取时改写归档。
- 当前关联单独保存在 RootHide bootstrap 的 ProjectX 私有偏好文件 `com.weaponx.app-state-associations.plist`，不随快照回放。
- 备份停止目标及扩展，完整保存容器、目标密码型钥匙串和 IDFV。保留 tmp，排除主容器 `Library/SplashBoard`。证书/密钥类非空时当前原生核心会报错停止，不能宣称全部钥匙串类型均支持。
- 每次正常切换（含使用基线）在同一确认弹窗显示默认勾选的「切换前自动备份当前环境」。已关联账号更新原固定目录，未关联账号按应用名和时间自动命名，无须填写名称；取消勾选直接切换，不新增或覆盖当前账号备份，弹窗提示未保存数据将丢失。保存失败不继续恢复。基线恢复后没有当前账号关联；恢复失败的 pending 环境只允许恢复重试，不显示自动备份选项、不保存部分恢复的数据。
- 整个保存/恢复序列持有核心同一个 store lock，阻止其他使用该核心的 CLI/worker 插入；没有自动回滚。恢复失败时保持未关联。
- 原生核心验证容器、钥匙串和身份；产品 worker 另刷新主/共享容器的偏好缓存，回读与磁盘对比后才报告成功。
- UIKit 主进程不带目标钥匙串组。钥匙串 worker 从无静态权限 template 复制至私有短生命周期目录，签入目标签名推导的 exact groups，并验证签名。IDFV 使用固定 root 所有的 Vendor worker，不带钥匙串组；安装脚本只为此受限 helper 配置免密权限。切换前先只读检查授权与身份，失败则停止，保留具体原因。
- 备份、切换和基线恢复共用 Modal Progress。执行端回传真实阶段、已复制文件数/字节数和钥匙串条目数；文件、钥匙串、IDFV、偏好缓存验证同样展示，最终验证及清理成功后才显示完成。没有总量时使用不定进度动画，不编造百分比。
- 无基线时操作栏显示「创建基线」，同一 Modal 确认并创建当前安装版本的空白数据模板，不复制或修改当前账号数据、钥匙串与身份，不需要 IPA。自动初始化缺失的归档目录，模板仅包含空容器目录与根级 manifest；创建后按钮变为「使用基线」。使用基线才按切换流程保存当前环境（可取消勾选）、清空目标账号数据及钥匙串并重置身份。没有旧格式兼容或应用包副本。

## 验证

`tests/run_app_state_tests.sh` 覆盖核心数据、目录/链接迁移、钥匙串范围、固定目录更新、账号切换顺序、失败停止、关联失效、异常退出与错误透传；`scripts/check_build_warnings.sh` 执行 arm64/arm64e clean release 构建及 deb 审计。

`tests/app-state-ui/build-preview.sh` 用真实页面和明确隔离的模拟数据构建可运行的模拟器预览，供窄屏、空状态、字体和颜色检查。预览不使用任何真实备份或设备权限。

本次只在本地构建、测试及模拟器检查；尚未安装到真机验证新 UIKit worker 链路。

v27 已在 iPhone 17 Pro（402pt）及 SE（375pt）模拟器使用生产控制器检查：普通字体列表行均为 53pt，切换触控区域 44×44pt；大字体允许内容自适应增高。截图见 `app-state-backup-ui-v27-implemented.png`、`app-state-backup-ui-v27-se-implemented.png`、`app-state-backup-ui-v27-duplicate-implemented.png`。预览同时回读左滑操作配置（删除、备注、重命名）及禁用全滑标志；桌面自动化权限阻止实际滑动手势测试，不把配置检查当成手势验证。2.5.3-43 已通过 clean warning gate、回归及包审计并发布本地源，尚未安装真机。

v28：首次目录查询完成前不显示会改变布局的加载文字；150ms 后才出现无文字的加载指示器。当前面板左侧边框使用与背景一致的 continuous 圆角，操作栏保留 44pt 触控高度并缩小额外间距。

一次备份显示「准备应用 → 保存数据 → 验证备份 → 完成」；一次切换显示「准备应用 → 保存当前账号（按实际保存结果或跳过）→ 恢复目标账号 → 验证恢复结果 → 完成」。内部目录处理不会增加独立容器流程。文件复制全部完成后才推进最终验证步骤；文件、钥匙串、IDFV 和偏好检查展示正在执行的具体阶段。复制数量来自 copyfile 完成回调；状态轮询外在 worker 结束前读取最后事件，避免快速验证失败丢失具体阶段。未成功的操作保留错误弹窗，只有所有检查及私有临时目录清理完成才显示成功。

ImageGen 设计及提示词：`app-state-progress-modal-v2.png`、`app-state-progress-modal-v2-prompt.txt`。生产 UIKit 控制器的隔离模拟器截图：`app-state-backup-ui-v28-implemented.png`、`app-state-progress-backup-implemented.png`、`app-state-progress-switch-implemented.png`、`app-state-progress-failed-implemented.png`、`app-state-progress-switch-se-implemented.png`。402pt 和 375pt 窄屏普通字体均保留 53pt 列表行与 44×44pt 切换触控区域。

真机只读诊断确认 43 的 IDFV 失败为 sudo 非交互授权缺失（`sudo -n` 返回需要密码）；45 的安装脚本改为授权固定 root 所有、限制参数与目标作用域的 IDFV helper，并在切换发生改动前检查权限。修复尚需在手机通过 Sileo 安装后验证，未执行手工安装或账号恢复。

2.5.3-45 已通过 clean warning gate、RootHide 包/依赖审计及 161 核心、245 钥匙串、39 切换流程、30 服务断言，发布至现有局域网 Sileo 源；HTTP 包版本和校验值复核通过。

2026-10-06 真机安装 45 后的授权诊断：dpkg 为 `half-configured`，ProjectX sudoers 规则不存在。`visudo` 无法加载 `@rpath/libsudo_util.0.dylib`；该库实际由 sudo 包安装在 `/usr/libexec/sudo`，而当前 visudo 的 rpath 指向 `/usr/lib`。对固定 visudo 验证进程设置 `DYLD_LIBRARY_PATH="$(jbroot /usr/libexec/sudo)"` 后，既有规则和新规则均可解析。RootHide 的 realpath CLI 还会把原生 bootstrap 路径转换为逻辑路径，因此保留 jbroot 返回的原生 helper 路径，不再调用该 CLI。

46 安装脚本使用上述局部库路径，验证通过后原子发布规则，再只读检查 mobile 对固定 helper 的策略。已在真机单独执行相同授权配置代码，ProjectX 的 NOPASSWD 规则生效；`sudo -k -n` 清除授权缓存后，用原生路径和 `/private` 等价路径启动 helper 的只读检查模式，均到达 helper 参数/path 检查（故意不存在的检查路径返回 65，而原先在 sudo 阶段返回 1）。此验证不修改 IDFV、容器或钥匙串。46 已通过同样 clean 构建/回归/包审计并发布本地源；手机完整安装状态仍需用户通过 Sileo 升级完成。

v29 / 2.5.3-48：移除 Modal 底部的自动关闭及重试说明文字。备份、切换、基线确认、首次账号表单、编辑、重命名、备注及删除确认均使用 `PXAppStateProgressViewController` 的同一圆角弹窗外壳；基线版本选择、重复备份整理和普通提示也使用相同风格。备份/切换确认后在原实例内展示真实进度，编辑/删除仅显示对应处理状态，不显示备份验证步骤。首次账号信息直接在弹窗内填写；未关联环境可保存后切换，或显式放弃当前数据。取消不执行操作，确认/放弃/选择均只处理一次；输入错误保留表单并就地提示，执行错误保留同一 Modal 的错误状态。失败关闭按钮保留，没有新增底部提示。

模拟器隔离交互模式 `PX_PREVIEW_MODE=modal-tests` 已完成 13 项生产控制器检查：确认前不提交、取消后不提交、复用同一弹窗、首次账号校验与单次提交、显式放弃不提交账号描述、独立编辑保留另一字段、允许清空备注、删除仅作用于选中 reference、基线共用切换流程。SE（375pt）执行这些检查；日志查询未发现弹窗冲突或 Auto Layout 冲突。表单使用 keyboardLayoutGuide 适应键盘，小屏截图包含模拟器首次键盘介绍区域。新截图：`app-state-modal-confirm-switch-implemented.png`、`app-state-modal-edit-implemented.png`、`app-state-modal-edit-keyboard-se-implemented.png`、`app-state-progress-v29-implemented.png`。48 已通过 clean warning gate、核心回归和 RootHide 包/依赖审计，发布本地源并复核 HTTP 版本与包校验值。尚未在手机安装验证这版 Modal。

2.5.3-49：用户打开手机编辑弹窗后，通过 SSH 转发 ZXTouch 读取了实际屏幕（`app-state-modal-device-20261006.jpg`），确认原先保存/取消上下排列占用过多高度。普通确认操作改为同一横排，取消在左、主要操作在右；未关联账号的取消、放弃并切换、保存后切换三个操作同排。保留 44pt 最小触控高度，采用 15pt 动态字体及较小文字内边距；无障碍大字号允许竖排以保证可读性。基线版本等内容选择仍按条目显示。生产控制器模拟器截图：`app-state-modal-horizontal-edit-implemented.png`（402pt）、`app-state-modal-horizontal-unassigned-se-implemented.png`（375pt）。此次只调整按钮布局，没有在手机提交保存、删除或切换。

2.5.3-50：active card 首段 header 为 8pt，表格已贴 safe area，不再叠加自动 inset；「其他备份 / 已有备份」标题增加叠层图标。未关联环境切换不再要求手填名称或提供第三个放弃按钮，改为默认选中的自动备份 checkbox，名称采用应用名和当前时间，确认后先保存再恢复。取消选中显示数据替换警告，提交时删除自动生成的 account 描述并显式传入 discardCurrent。已有账号始终更新原备份，pending 恢复仍只重试恢复。SE 模拟器 16 项确认/提交断言通过，布局检查顶部间距 8pt、列表行 53pt、切换触控 44×44pt，日志未发现布局或呈现冲突。截图：`app-state-top-spacing-implemented.png`、`app-state-modal-auto-backup-implemented.png`。未在真机执行备份或切换。

2.5.3-51：中英文确认提示缩为简短一句。备份为「保存当前数据，更新这份备份。」；切换为「先保存当前数据，再切换。」；未关联环境为「当前环境还没有备份。」，自动保存行为直接由默认勾选的 checkbox 表达。取消勾选的提示为「切换后，未保存的数据将丢失。」。仅调整文字，操作顺序及备份范围不变。

2.5.3-52：确认文案描述程序执行的默认行为，避免被理解为要求用户手动保存。备份为「将用当前数据更新这份备份。」；已关联环境切换为「将自动更新当前备份，再切换。」；未关联环境为「默认自动备份当前数据后切换。」。自动备份仍默认勾选，关闭后仍明确提示未保存数据将丢失。

2.5.3-54：按 `app-state-home-backup-mode-v2.png` 开发。设置的应用范围区增加「应用环境模式」，备份／清理两个带勾选的选项，缺省为备份。模式保存到现有环境配置 `appMode`，不清理数据、不删除归档，也不改变 generation 和 pending 状态。首页不显示模式标识；备份模式仅调整应用区标题、选择行（13pt／11pt）及整体宫格（48pt 图标），隐藏一键清理及应用钥匙串／Web 清理，保留剪贴板。清理模式保留原清理布局且隐藏宫格。其他首页内容配置保持原样。UI 和生产 environment operations 均拦截备份模式下的应用清理，清理模式关闭选择页备用备份入口；执行中禁止由首页进入设置。

「其他备份」左滑改为编辑／删除；编辑与 active 面板共用 square.and.pencil 和同时编辑名称、备注的 Modal，全滑删除仍禁止。Progress 的业务提示包括保存账号、恢复应用数据、检查应用／账号数据、同步应用设置；UI 不显示 IDFV、钥匙串、容器、偏好缓存和 manifest 等术语，未知阶段使用通用准备提示。失败原始信息仅记内部日志，弹窗只显示业务失败及必要的恢复提示，不显示归档路径。

验证：真实 policy store 的缺省、持久化、保留其他环境字段、非法值拒绝及安全回退检查通过；模拟器复用生产首页布局方法、真实 mode selector／policy 和生产 operations（仅破坏性 adapter 换为计数器），备份模式零应用清理调用、剪贴板可用、切换设置零清理、清理模式放行及切回拦截检查通过。375pt 模拟器选择行实测 53pt、字号 13／11pt；清理模式保留原 17／15pt。6 项业务进度文案检查通过。截图：`app-state-home-backup-mode-implemented.png`、`app-state-home-cleanup-mode-implemented.png`、`app-state-settings-mode-implemented.png`。54 完成 clean warning gate、原生核心回归、RootHide 包审计、本地源发布及 HTTP 包校验；未操作真机应用数据。
