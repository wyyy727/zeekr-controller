# C 档实施报告

> 任务书：`C档任务书.md`。视觉 + 功能真源：`preview/index-v2.html`（iPhone 390×844）。
> 本文件随阶段推进追加，**已知差异与未做项必须如实列出**，不写「已验证通过」除非真机跑过。

## 进度

| 阶段 | 内容 | 状态 |
|---|---|---|
| 1 | 地基（`V2Theme` / `GlassSurface` / `AssetSelfCheck` / 图标资产）+ 车况屏 | 代码完成，未编译验证 |
| 2 | 行程屏 + 自绘 `V2BarChart` | 代码完成，未编译验证 |
| 3 | 充电屏（汇总 / 三行推荐位 / 记录 / 金额补录 / OCR 徽章 / 三个自绘面板） | 代码完成，未编译验证 |
| 4 | 车控屏（14 颗按钮 + 5 项灰按钮 + 三态动效 + 双提示） | 代码完成，未编译验证 |
| 5 | 设置屏（头像 hero / 两列权限 / 登录态隐藏） | 代码完成，未编译验证 |
| 6 | 全局收口（底栏 v2 化 / `systemName` 清零 / v1 设计系统移除 / 报告定稿） | 代码完成，未编译验证 |

**截图：按用户指示跳过**（本机无 Xcode、无模拟器）。

## 逐屏完成度

| 屏 | 与 HTML 对齐的部分 | 差异 |
|---|---|---|
| 车况 | 2×2 指标合一卡、车身状态 3 列、位置卡四形态、充电中卡条件渲染、SOC 环、胎压卡、stale 横幅 | 见差异 1 |
| 行程 | 6 格汇总、7/30 段控件、月份胶囊、双图联动、点柱气泡、虚线占位、错峰入场、四态 | 见差异 5、7 |
| 充电 | 充入电量卡（大数字 + 金额 + 累计）、逐笔记录、金额补录三态、三行推荐位、完整列表面板、OCR 核对 | 见差异 8 |
| 车控 | 3 列网格 112×90、14 颗按钮（图标/配色/门控）、5 项灰按钮、三态动效、已连接胶囊、双提示 | 无 |
| 设置 | 头像 hero、远程车控 Toggle、账号登录、两列权限 + `…`/`收起`、关于、页脚、登录后隐藏两块 | 见差异 9、10、11 |

## 验证方式与边界

- 本机**没有 Xcode、没有真机**，所有 Swift 改动均为「静态核对」，**未编译**。
- 已做：
  - 括号逐行配平（跳过字符串与 `/* */` 块注释，24 个文件全 0）
  - 符号存在性（`V2Color` / `V2Type` / `V2Metrics` / `V2Font` 引用全部命中定义）
  - 图标引用存在性（`Image("…")` 63 个资产全命中，无悬空）
  - 禁改区 diff 为空（`server/`、`preview/index.html`、`preview/index-v2.html`、`.github/`）
  - 全仓 `systemName:` **0**、`.font(.system` **0**、v1 `Theme.`/`ChineseColor.`/`Metrics.` **0**
- **无头浏览器实测**：用本机 Edge（`playwright-core`，不下载浏览器）以 390×844 打开
  `preview/index-v2.html`，注入演示数据后用 `getBoundingClientRect()` 量真实几何。
  凡「CSS 写了但没生效」的地方一律以实测为准 —— 已因此修正：
  - X 轴与柱区间距 `4 → 0`（`.v2-plot{gap:4}` 只有一个子元素，实际间距是 0）
  - 图表 Y 轴「0」刻度对齐柱底（7 天视图被 flex 拉伸，是漏写）
  - 底栏侧边距 `21`（实测 inner `x=21 h=62`，5×62+4×4.5+20=348，正好是胶囊宽度）
- 图表数学：把 `v2NiceMax` / `v2BarBody` / `v2Chart` **原样在 Node 里执行**当基准，
  Swift 侧算法用 Python 复算，同一份 fixture 比对（刻度文字 / 柱高 / 拆分段高 / 内容宽 / 占位数量 / X 轴标签），
  5 组用例 **差异 0**。
- 图标：63 个 SVG 用 `sharp`（libvips + librsvg）逐个栅格化，确认无空图、无黑块。
- 结论口径：**未编译验证，仅静态核对**。CI 只在 push main / 手动 dispatch 时触发。

## 已知差异（诚实清单）

| # | 差异 | 原因 | 处理 |
|---|---|---|---|
| 1 | 气温保留一位小数（HTML `Math.round` 取整） | 用户明确要求；与仓库既有口径一致 | 已确认的例外，`DashboardView.weatherTempText` 注释写明 |
| 2 | 行程空态与错误态都用柱状版 `ic-chart-bar`（HTML 运行时是折线版） | `chart` 键在 HTML 里被重复定义，运行时后者（折线）胜出；用户要求补柱状版 | **用户已拍板：两处统一用柱状**（错误态原本用折线，已改） |
| 3 | 卡片外阴影 `radius = 12`（CSS `0 8px 24px` 的 blur 是 24） | SwiftUI 的 radius ≠ CSS blur，需真机校准 | 单点常量 `V2Metrics.cardShadowRadius`，改一行 |
| 4 | 行高用 `lineHeight − size × 1.2` 近似 | SwiftUI 无 CSS line-height | 封在 `V2Type.lineSpacing`，真机校准 |
| 5 | 图表 Y 轴「0」刻度对齐柱底（HTML 7 天视图里「0」中线在柱底**下方 9.5pt**） | 实测确认是 HTML 漏写：30 天视图作者显式写了 `.v2-yaxis.d30{height:120px}`，「0」中线在柱底上方 6.5pt | **按柱底对齐**（与 30 天口径一致）。实测：7 天 yaxis 148 / 柱底 132 / 「0」中线 141.5；30 天 yaxis 120 / 柱底 120 / 「0」中线 113.5 |
| 6 | 双图横向联动用 `UIScrollView` 桥（`HScrollDriver`）+ 共用 offset | 两张图在两张独立玻璃卡里；`ScrollView` + `scrollTo` 无法逐像素同步 | 每图一个真 `UIScrollView`（原生惯性/回弹），两个 offset 绑同一 `@Binding` |
| 7 | 月份选择保持 iOS 原生双滚轮 sheet（HTML 是年份竖列 + 月份三列网格的自定义面板） | 用户明确要求：任何页面都保持原生 | **已定，不再重做**。行程页与充电页共用 `MonthPickerSheet` |
| 8 | OCR 核对弹层的**输入行**是 v2 白底胶囊，但单位跟在标签后而非绝对定位在输入框右侧 | HTML 用绝对定位的画法；iOS 用右对齐输入框，语义一致 | 视觉差异小，功能一致 |
| 9 | 设置页三块 iOS 独有内容（关于当前数据 / 待配置项 / 诊断）收进「高级与调试」折叠 | 这三块承载现有功能（任务书 1.5：现有功能是下限）；HTML 把同类信息放在 `advBlock` 折叠里 | **用户已拍板（第 3 条）：收进折叠**。位置按 HTML —— 页脚之后、登录后不渲染 |
| 10 | 设置页「退出登录」仍在「账号登录」卡内（HTML 在「关于」卡） | — | **用户已拍板：不用搬** |
| 11 | 权限「…」/「收起」按钮视觉高度约 33pt（HTML chip 的 padding 8 10） | 按真源复刻 chip | **用户已拍板：不用撑到 44pt** |
| 12 | 底栏两侧留白 **21pt**（任务书 3.1 写 14） | 任务书 3.1 的 14 是 **v1** 预览页的值；v2 实测侧边 21，且 390−21×2=348 正好等于胶囊宽度（写 14 会得到 362，与「胶囊 348」自相矛盾） | **用户已拍板：取 21** |
| 13 | `iconNames` 自检清单 63 项（28 原有 + 34 内联 + 1 `ic-chart-bar`） | HTML 的 `const SVG` 表是 35 条 / 34 键 | 已在此前阶段确认 |

## 阶段 6 做了什么（全局收口）

### 1. 底栏彻底 v2 化（原先还是 v1 的 SF Symbols + 高光药丸）

| 项 | 改前 | 改后（= HTML `.tabbar-inner` / `.tab`） |
|---|---|---|
| 图标 | `Image(systemName:)` + 21pt | `Image("tab-dashboard"…)` 24×24，`template` 染色 |
| 文字 | 10pt，选中 SemiBold | 11/500（`label11`），**选中也是 500** |
| 选中态 | 玻璃上叠一层高光药丸 + `scale 1.06` | **只有颜色变**（`#6742E8`）；HTML 明确写了「不做选中胶囊 / 底色 / 放大」 |
| 尺寸 | `padding 4/7` + `.capsule` | 高 62 / 圆角 36 / 内距 0 10 / gap 4.5 / 5×62×54 = 348 |
| 侧边距 | 14 | 21（实测） |
| 按下 | 无 | 整项 `opacity 0.72`（`.tab:active`） |

### 2. 顶栏数据来源胶囊按 `v2SourcePill()` 三档配色

| 状态 | 文案 | 底色 / 字色 |
|---|---|---|
| mock | 模拟数据 | `#FEF3E2` / `#8A5A12` |
| offline | 离线 · 模拟数据 | `#FFF1F4` / `#B23350` |
| 未登录 | 未登录 | `#EEF0F8` / `#5E6775` |
| live | 不显示 | — |

尺寸也按 `.v2-pill-src`：11/500/14、padding 4 8、最大宽 140。文案原来写「模拟数据 · 后端不可达」，已改回 HTML 的「离线 · 模拟数据」。

### 3. `systemName:` 清零（验收硬项）

6 处全部消除：
- 底栏 5 个 → `tab-*` 资产
- OCR 候选单选圆点 → 改成 HTML 的「整行铺紫底 + 右侧打勾 / 差 N 天」
- 设置页权限展开箭头 → 改成 HTML 的「…」/「收起」跨行 chip
- 另删了 3 个只剩 SF Symbol 的**零引用**旧组件：`ErrorBanner` / `StatCard` / `StatusChip`

### 4. v1 设计系统移除

| 文件 | 处理 |
|---|---|
| `Core/Theme/Theme.swift`（中国传统色 + `Metrics`） | **删除**；`Color(hex:)` 唯一被 v2 依赖的部分搬到 `V2Theme.swift` |
| `Core/Components/ErrorBanner.swift` / `StatCard.swift` / `StatusChip.swift` | 删除（0 引用） |
| `Core/Components/LoadingView.swift` / `SoonBadge.swift` | 删除（0 引用） |
| `ToastBubble` / `NetworkProgressBar` / `SOCRing` | 颜色与字体换成 v2（Toast 字重按 HTML 从 500 改回 400） |

全仓 `.font(.system` 由 47 处降到 **0** —— 数字全部走 Inter。

### 5. 设置屏按 `renderSettings()` 重排

- **区块标题移进卡内**（`.v2-set-col` 的第一行就是标题），不再有「卡外小标题」
- 顺序：头像 → 远程车控 → 服务端连接（未登录）→ 账号登录 → 车辆权限 → 关于 → 页脚 → 高级与调试（未登录，折叠）
- 「关于当前数据 / 待配置项 / 诊断」三块 iOS 独有内容**收进「高级与调试」折叠**（用户确认第 22 条），
  与 HTML 的 `advBlock` 一致：位置在页脚之后、登录后整块不渲染
- 权限：两列等分网格、chip `r12 / padding 8 10 / 12.5-500`、`…`/`收起` 跨满整行、`未开通` 灰区
- 标题右侧补计数徽标（`20 项`，`.v2-set-badge`）
- 验证码弹窗从系统 sheet 换成 `V2BottomSheet`
- 修掉一个**会编译失败的遗留**：`capabilityHint` 里还在引用已删除的 `hiddenCommandNames`

### 6. 五屏四态复核

| 屏 | 加载 | 空 | 错误 | 未登录/无权限 | 下拉刷新 | 页脚「更新于」 |
|---|---|---|---|---|---|---|
| 车况 | 骨架 | `emptyState` | stale 横幅 + 重试 | `V2LoginWall` | ✓ | ✓ |
| 行程 | 骨架 | `emptyCard` | `errorCard` + 重试 | `V2LoginWall` | ✓ | ✓ |
| 充电 | 骨架 | `emptyMonth` | stale 横幅 + 重试 | `V2LoginWall` | ✓ | ✓ |
| 车控 | 骨架 | `emptyCard` | stale 横幅 | `V2LoginWall` | ✓ | ✓ |
| 设置 | — | — | 连接状态行 | 登录表单本身 | 不适用（无数据源） | 不适用 |

设置页没有下拉刷新与「更新于」是**设计如此**：它的数据是配置与登录态，不是会被轮询刷新的车辆数据。

## 全量审计与修复（第 7 轮）

对全部 32 个 Swift 文件做了一轮完整静态审计，查出 8 条，**全部已修**（用户逐条确认）。

| # | 问题 | 性质 | 修法 |
|---|---|---|---|
| 1 | 车控「寻车」跨两格失效 | **布局 bug**：`LazyVGrid` 不支持 `.gridCellColumns()`（该修饰符只对 `Grid` 生效），宽项静默退化成 1 格 | 改为按 CSS grid 自动放置规则自己分行（`GeometryReader` + 行数组），宽项占 `colW*2+gap` |
| 2 | 设置页头像卡上内距多 8pt | 视觉偏差：`.padding(.top, 8)` 写在 `.v2Card()` 之前，变成了卡内上内距（16+8=24）；HTML 是 `margin-top`（卡外） | 挪到 `.v2Card()` 之后 |
| 3 | 车控页头在 offline 模式显示「已连接」 | **判断错**：HTML 是 `mode === 'live'`，iOS 写成 `!= .mock` | 改为 `dataMode == .live` |
| 4 | 车控页脚缺「更新于 HH:MM」 | 漏项：HTML 该屏用 `v2Foot('')`（`withTime` 默认 true），只有车况屏是 `v2Foot('', false)` | 页脚补时间行（11/400、行间 2） |
| 5 | 车况「更新于」位置错 | 布局偏差：HTML 与来源胶囊**同一行**（`.v2-head--end`），iOS 是内容区单独一行，首卡低约 22pt | `ScreenContainer` 新增 `tailText` 参数，渲染在胶囊右侧；删掉 `updatedRow` |
| 6 | 总开关关闭时图标没有半透明 | 样式缺失：`.v2-ctrl[disabled] .v2-ci{opacity:.55}` 未实现 | `blocked` 时图标 `opacity(0.55)`；不支持能力行同样处理 |
| 7 | 车控空态描述写死一句 | 文案缺失：HTML 按 `statusError` 分两句 | 按 `store.errorMessage == nil` 分支 |
| 8 | 行程错误态图标与空态不一致 | 视觉不一致 | 统一 `ic-chart-bar`（用户确认） |

### 审计中确认没问题的部分

- 括号配平（24 文件，跳过字符串与块注释）全 0
- `V2Color` / `V2Type` / `V2Metrics` / `V2Font` 引用无未定义；`store.` 成员无悬空
- 图标资产 63 ↔ 自检清单 63 ↔ Swift 引用全命中
- 组件参数顺序（`V2BarChart` / `V2ControlGrid` / `V2BottomSheet` / `ScreenContainer`）与声明一致
- 车控 14 颗按钮的 cmd / 图标 / 颜色 / 门控 / `disabled` / `wide` 与 `renderControls()` **逐项一致**
- 充电页卡片顺序（汇总 → 附近站 → 记录 → 费用）与 HTML 一致
- 行程 6 格汇总为 3 行 × 2 列、行距 14 / 列距 12，与 HTML 一致
- 三个自绘弹层均 `presentationBackground(.clear)`，不会白屏；OCR 的 `records` 已传入
- 所有强制解包点都有 `guard` / `count` 保护，无越界风险
- 禁改区（`server/`、`preview/`、`.github/`）diff 为空

## Bug 修复与 HIG 收口（第 8 轮）

前面几轮都是「照着 HTML 对齐视觉」，这一轮是**代码质量专项**：先审出问题，再逐条修。

### 三个功能 bug

| # | Bug | 根因 | 修法 |
|---|---|---|---|
| 1 | 车控「翻转类」按钮成功后**没有绿勾**（车锁 / 空调 / 充电） | 按钮的 `id` 与三态键都用了会变的 `cmd`（`lock`→`unlock`）；`send()` 内部还会 `await refresh()` 让状态先行翻转，于是刚写的 `phases["lock"] = .done` 当场就没人读了 | `V2ControlItem` 的 `id` 改为**语义固定 key**（`doorLock` / `climate` / `charge` …），三态与视图身份都跟着 key，`cmd` 只负责「这次发什么」 |
| 2 | 连点「重试」或下拉时轮询在跑 → 多轮刷新并发，旧数据覆盖新数据、骨架屏提前消失 | `refresh()` 无互斥，10+ 个入口各自起一轮；`defer { isLoading = false }` 先完成的那轮先复位 | 新增 `refreshTask`，第二个调用者 `await` 同一个 Task；原逻辑搬进 `performRefresh()` |
| 3 | 定位可能永久停在「正在定位…」，按钮再也点不动 | `withCheckedThrowingContinuation` 没有超时；再点一次会把新 continuation 覆盖旧的 → 旧的永久泄漏 | 15 秒超时兜底；进入前先收掉上一次未完成的请求；`finish()` 统一取消超时任务 |

### 交互与 HIG

| # | 项 | 修法 |
|---|---|---|
| 4 | 车控按钮按压态在滚动时卡住 | `simultaneousGesture(DragGesture(minimumDistance: 0))` → 自定义 `ButtonStyle`（`configuration.isPressed` 会被系统在滚动开始时复位）；顺带让 `reduceMotion` 真正生效（之前声明了没用） |
| 5 | 自绘面板不能下滑关闭 | 把手 + 标题区接管 `DragGesture`：拖过 120pt 或预测位移超 240pt 即关闭，否则弹回。手势只挂在**不可滚动的顶部区域**，不与内容 ScrollView 抢 |
| 6 | 面板「关闭/收起/取消/保存」只有 ~18pt 高 | 两个按钮都补 `.frame(minHeight: 44)` + `contentShape`，视觉字号不变 |
| 7 | 深色模式未适配（自绘浅色 + 系统控件变深的撕裂） | **锁浅色**：`Info.plist` 加 `UIUserInterfaceStyle = Light`。理由写进 plist 注释：真源是 HTML 浅色渲染，真要深色需给 `V2Color` 全量补 dark 变体，是独立工作 |
| 8 | 零触觉反馈 | 车控指令成功/失败各一次 `UINotificationFeedbackGenerator`（`.success` / `.error`） |
| 9 | `OcrRow.id` 每次访问都生成新 UUID | 改为「时间+金额+电量+站点」拼稳定标识（否则 `ForEach` 会把整行当新元素） |

## Swift 最佳实践收口（第 9 轮）

审了并发隔离、内存、错误处理、重复代码、死代码五类，改了 3 项（都不影响运行，属整洁度）。

| # | 项 | 改动 |
|---|---|---|
| 1 | `SettingsStore` 缺 `@MainActor` | 补上，并写明理由：它是 UI 状态（地址 / 指令开关），读它的是 View、4 个 `@MainActor` VM 与 `AppStore`。补上之后严格并发检查不会再把它算成跨 actor 访问 |
| 2 | 4 处 `staleBanner` 完全重复 | 抽成 `Core/Components/V2StaleBanner.swift`（text / detail / onRetry 三个参数），四屏各删 20 行、共减约 40 行 |
| 3 | `VehicleCommand.systemImage` 是死代码 | 删除（20 行 switch，全工程 0 引用；v1 用 SF Symbols 时的残留） |

**明确不改的**（并写明理由，避免以后有人当 bug 修）：

- 单文件过大（`ChargesView` 1074 行）：大头是内嵌的 3 个弹层，拆分只是组织问题，回归风险高于收益
- 39 个 `Task {}` 只有 5 个存引用：绝大多数是「发一次就完」的短任务；真正需要取消的三处（轮询 / Toast / 定位超时）都存了
- `try?`（11 处）：集中在 `Task.sleep` 与 JSON 解码，都是有意为之
- `SWIFT_STRICT_CONCURRENCY: minimal`：迁 Swift 6 才需要提高

### 明确没做的一项：`SettingsStore` 的注入方式

第 9 轮已经给它补了 `@MainActor`（并发标注解决），但**依赖注入**这一项仍然没做：
`SettingsStore.shared` 在 4 个 ViewModel 里被直接读（而不是走 `@Environment` 注入）。**没有改**，原因：
它的创建时机在 `@State private var model = XxxViewModel()`，那一刻拿不到 SwiftUI 环境；要真正注入得把 VM 的依赖改成「创建后再 set」或改造所有创建点，收益只是风格统一，而运行期本来就是同一个实例。记在这里，需要时可以单开一项。

## 顶栏对齐与玻璃折射（第 10 轮）

起因：核对「底部导航离屏幕多远 / 有没有液态玻璃折射」时发现两处结构问题。

### 1. 顶栏高度不定 —— 四屏首卡不一致（真问题）

| 屏 | 顶栏内容 | 顶栏高 | 首卡距屏幕顶 |
|---|---|---|---|
| 车况 / 车控 / 设置 | 数据来源胶囊 22 | 8+22+8 = 38 | **97** |
| 行程 / 充电 | 月份胶囊 32 | 8+32+8 = 48 | **107** |

HTML 的 `.v2-head` 是 `position: absolute; top: -36px`（**不占文档流**），所以四屏首卡都从 64 起。
iOS 把它放进 `safeAreaInset` 的流里，高度随内容变，于是行程/充电比车况低 10pt。

**修法**：`V2Metrics.topBarHeight = 36` 定高，胶囊在两个尺寸下都居中 → 四屏首卡统一 **95**。

**为什么不是 64**：HTML 的 64 是「距视口顶」，其中 0–52 被 `.v2-head` 占着。iOS 的状态栏就占 0–59，
胶囊必须放在 59 以下 —— 照搬 64 会把胶囊推进状态栏。iOS 的等效值只能是 `59 + 顶栏高`。
这条换算关系记在这里，避免以后再把「97 vs 64」当成 bug。

### 2. 底部胶囊：改用原生 `safeAreaBar`（第 11 轮修正）

第 10 轮我写过「`safeAreaBar` 会把滚动内容挡在胶囊上方」——**这句是错的**，没查文档就下的结论。
Apple 文档原文：

> Similar to the `safeAreaInset(edge:alignment:spacing:content:)` modifier, the `content` view is
> anchored to the specified horizontal edge of the parent view and its width insets the safe area.
> **Additionally, it extends the edge effect of any scroll views affected by the inset safe area.**

`safeAreaBar` 就是 `safeAreaInset` 的 bar 版本：**只内缩安全区、不裁剪内容**，滚动时页面照常从胶囊
下面穿过；「extends the edge effect」这句本身就说明它预期内容会经过 bar 下方。

所以第 10 轮那套「删掉 safeAreaBar + 内容自带 105pt 留白」是**在 iOS 上照抄网页机制**
（`position:fixed` 的 tabbar + `.wrap{padding-bottom:105}`）—— 视觉规格该照 105，机制不该照抄。

**最终实现**

```swift
ZStack { backgroundLayer; activeScreen; toastLayer }
.safeAreaBar(edge: .bottom, spacing: V2Metrics.tabBarContentGap) { tabBar }
```

| 项 | 值 | 说明 |
|---|---|---|
| `spacing` | 29 | 内容末端与胶囊上沿的间隙（= 网页 105 − 胶囊 76），由安全区内缩实现 |
| 胶囊下沿 | 距**屏幕物理底** 22 | 实测系统电话 app 为 21.7pt；仍保留 `ignoresSafeArea` 让 bar 锚在物理边缘 |
| 内容底部留白 | 无手写 | 全部交给系统（内容静止位置 = 22+62+29 = 113pt） |

`V2Metrics.contentBottomInset(105)` 删除 → `tabBarContentGap(29)`；Toast 底距按物理底重算 = 92。

### 3. 底距：第 11 轮「推到 48」是错的，按系统电话 app 实测回到 22

第 11 轮我按「悬浮栏必须待在 34pt 安全区之上」把胶囊推到距屏幕底 48，真机一看明显偏高。

拿 iPhone 16 Pro（402×874pt @3x，截图 1206×2622px）的系统**电话 app** 逐像素量：

| 项 | 电话 app 实测 | 我们 |
|---|---|---|
| 胶囊下沿距屏幕底 | 65px / 3 = **21.7pt** | 22 |
| 胶囊高度 | 180px / 3 = **60pt** | 62（v2 规格，未改） |
| 胶囊两侧留白 | 61px / 3 = **20.3pt** | 21 |

**结论：Apple 自己的悬浮底栏就是压进安全区的**（22 < 34）。
真正要避开的是 Home Indicator 那条 5pt 高的白条（约距底 8–13pt），不是整个 34pt 安全区 ——
22pt 的下沿落在白条上方约 9pt，不会被盖住。

所以现在的做法是：`ignoresSafeArea(.container, edges: .bottom)` 让 `safeAreaBar` 锚在屏幕物理底边，
再用 `padding(.bottom, 22)`。**「待在安全区之上」是错的判断，已作废。**

**没有显式设置 `scrollEdgeEffectStyle`**：`automatic` 就是系统按场景自适应的默认值，显式写
`.soft` / `.hard` 属于审美选择且没有参考值。若真机上胶囊上方的淡出显得脏，可加
`.scrollEdgeEffectStyle(.hard, for: .bottom)`，或用 `.scrollEdgeEffectHidden(true, for: .bottom)` 关掉。

### 需要真机确认

- 折射强度（玻璃材质是系统的，只能保证"背后有会动的内容"，强度调不了）
- 48pt 底距 vs 网页 14pt 的观感 —— 这是 HIG 合规换来的差异
- 胶囊上方那条边缘淡出的强度
- 顶栏 36pt 下，32pt 的月份胶囊距状态栏只剩 2pt —— 是否显得挤

## 导航确认弹框改自绘（第 13 轮）

原来用系统 `.alert`，与 `index-v2.html` 的 `.v2-alert` 既不同文案也不同样式。

### 文案（逐字对齐 `index-v2.html:5921–5927`）

| 项 | HTML | 改前 iOS | 现在 |
|---|---|---|---|
| 标题 | 用地图导航？ | 导航到这个充电站？ | **用地图导航？** |
| 说明 | 将打开地图 App 规划到「X」的驾车路线，会离开 ZeekrDash。 | 只有站名 | **同 HTML** |
| 左按钮 | 取消 | 取消 | 取消 |
| 右按钮 | 打开地图 | 导航 | **打开地图** |

站名回退用 `name`（缺省「充电站」），**不是 `displayName`**（后者缺省「未命名站点」）。

### 样式（`Core/Components/V2Alert.swift`，新增）

| 属性 | HTML `.v2-alert` | 实现 |
|---|---|---|
| 遮罩 | `rgba(15,23,41,.38)` + `blur(6)` | 同色；**不做 6px 模糊**（cover 下材质采样不到被盖内容，会变死灰） |
| 卡片宽 | `min(300, 100vw−48)` | `maxWidth 300` + 两侧 24 |
| 底 | 白 .94 | 同 |
| 圆角 | 20 | 20 |
| 内距 | 20 / 18 / 14 | 同 |
| 标题 | 16 / 600 / 21.6 | `alertTitle16` 16/600/22 |
| 说明 | 12.5 / 400 / 18.75，上距 8 | `alertMsg` 12.5/400/19，上距 8 |
| 按钮 | 并排、各 flex1、高 40、r12、13/600 | 同（`alertBtn` 13/600/18） |
| 按钮配色 | 左白 .50 + 白描边 .90，右 `#6742E8` | 同 |
| 阴影 | `0 12 40 rgba(74,87,120,.30)` | `radius 20, y 12`（CSS blur 40 ≈ SwiftUI radius 20） |

### 呈现方式与一处已知差异

触发点在「附近充电站」卡片里，而卡片在 `ScreenContainer` 的 ScrollView 内 ——
`.overlay` 的布局尺寸等于卡片本身、还会被 ScrollView 裁掉，遮罩盖不住整屏。
所以用 `fullScreenCover` + `.presentationBackground(.clear)`（与 `V2BottomSheet` 同一套）。

**已知差异**：cover 带系统上滑过场，HTML 的 alert 是原地出现；遮罩与卡片会一起上滑。
要完全一致得改成窗口级 overlay（UIKit 挂到 key window），本轮没做。

因为弹框是 cover，同一份状态挂两处会撞车，所以 `v2Alert` 加了 `isEnabled`：
页面里的宿主用 `!showSheet`、面板里的宿主用 `showSheet`，同一时刻只有一处 present。

## OCR 核对弹框按真源重做（第 14 轮）

上一版的核对框是「v2 风格的近似」：标题 14、按钮在右上、字段竖排、无置信度/黄条/兜底入口。
按 `index-v2.html`（CSS 1139–1220、结构 5150–5245）逐项重做。

### 容器（新增 `V2BottomSheet` 参数）

| 项 | HTML | 现在 |
|---|---|---|
| 圆角 | 18（`.sheet`） | 18 |
| 底色 | `--surface` = **纯白** | `.white` |
| 遮罩 | `rgba(0,0,0,.28)` + blur 2 | 黑 28%（无 blur，同 V2Alert 的理由） |
| 把手 | **无** | `showsGrip: false` |
| 高度 | 内容 hug，正文区 `max-height: min(58vh, 430)` | `hugContent: true` + 量高封顶 |
| 内距 | 面板 4/10，正文再 4/2/2 | header 12、正文 12、footer 10 |

`V2BottomSheet` 因此新增 `titleType` / `headerInset` / `showsGrip` / `cornerRadius` /
`panelBackground` / `maskColor` / `hugContent` / `bodyMaxHeight(Ratio)` / `footer`；
`closeTitle` 改为 `String?`（传 nil 就没有右上按钮）。默认值保持原行为，其它面板不受影响，
唯一变化是副标题挪到了标题右侧（HTML `.v2-sh .r` 本来就在右）。

### 标题区

| | HTML | 现在 |
|---|---|---|
| 标题 | 识别充电小票 16/600 | 同（`ocrTitle16`） |
| 副标题 | 已识别 N 张 · HH:MM（12，右） | 同；时刻来自 `ChargesViewModel.ocrAt`（识别成功时记） |

### 行内

| 项 | HTML | 现在 |
|---|---|---|
| 行头 | 左「第 N 笔」12、中站名 13/600、右「置信度 N%」胶囊（11/500 `#08789F` on `#E9F6FD`） | 同；站名缺省「未识别到站点」 |
| 需核对 | 整块黄条，固定句式「需要核对：{note}。金额请按「实付」填，别填服务费原价。」 | 同（note 缺省「这一项读得不准」） |
| 字段 | **两列** grid gap 8；标签 10.5 在上；输入框 38 高、r10、`rgba(27,34,51,.04)`、内白环；金额/电量带「元」「kWh」 | 同 |
| 占位 | `2026-10-16 22:10` / `选填` | 同 |
| 候选行 | 12.5/400（选中 600 白字紫底） | 同（`ocrCand` 字重由 500 改回 400） |
| 无候选 | 居中块「没匹配到充电流水」14/600 + 说明 + 「重选截图」「手写录入」胶囊按钮 | 同；最后一颗候选文案变「仍要保存这笔金额」且不高亮 |
| 改绑提示 | 改过时间/电量 → 撤销自动匹配 + 黄条「时间和电量改过了…请重新选一次」；用户亲手点过的行不动 | 同（`userPicked` / `rebinding` 两个集合） |

### 底部

`取消`（白 45% 底、48 高、r12、15/600）+ `确认补录`（accent、48 高、r12、15/600，无效时 50% 透明），
横向 10、上 8、下 `10 + 安全区`（面板铺到屏幕底，安全区要自己补回来）。

「重选截图 / 手写录入」退出核对框后再打开对应入口：先记意图，等 cover 真的退场再延时 0.4s present
（cover 还没消失就 present 下一个会丢）。

### 已知差异

- `确认补录` 在「没有一笔有效金额」时是**禁用**的；HTML 不置灰，点了才 toast「至少填一笔金额」。
  这里选择禁用（少一次无效请求），属交互差异，不影响结果。
- hug 高度靠 PreferenceKey 量出：第一帧先给 1pt，随即到位（无可见跳动，但严格说有一帧）。

## 未做项

| 项 | 原因 |
|---|---|
| 五屏截图 | 用户指示跳过（本机无 Xcode / 模拟器，产出不了可信截图） |
| 编译验证 | 同上；只做了静态核对，CI 只在 push main / 手动 dispatch 时触发 |

## 用户已拍板的决定（全部确认完毕，无待定项）

> 以下每一条都是用户明确答复过的，不是我的自行判断。凡与 HTML 或任务书冲突的，均在此标注以哪一边为准。

### 全局与地基

| # | 决定 | 用户确认内容 |
|---|---|---|
| 1 | 内联 SVG 图标**一次性补齐** | 不按屏增量补，34 个 `ic-*` 一次转完；与既有 28 个同规格 |
| 2 | 额外提供 `ic-chart-bar` | `chart` 键在 HTML 被重复定义，运行时生效的是折线；用户要求把柱状那版也补上（总数 63） |
| 3 | 两处待真机校准值**保持现状** | `cardShadowRadius = 12`、`lineSpacing` 近似算法都不动，等真机再定 |
| 4 | 气温**保留一位小数**（覆盖 HTML 的 `Math.round` 取整） | 明确要求；`DashboardView.weatherTempText` 注释已写明这是确认过的例外 |

### 行程与图表

| # | 决定 | 用户确认内容 |
|---|---|---|
| 5 | 双图联动用 **每图一个 `UIScrollView` + 共用 offset** | 明确要求「UIscrollView 能实现的话就去用」，且要逐像素联动；已据此实现 `HScrollDriver` |
| 6 | 图表 Y 轴「0」**对齐柱底**（不照抄 HTML 7 天视图的偏低 9.5pt） | 答复「如果你的更对就以你的为准，但你必须确定你的不能错」。已用无头浏览器实测两组数据证明 7 天那处是漏写（30 天作者显式修正过） |
| 7 | iOS 演示数据**与 HTML `mockEnergy()` 逐公式一致** | 7 天用 `[24.8, 41.2, 18.6, 33.5, 12.4, 56.0, 27.3]`，其他天数用 `9 + jitter*47`；不再用自造曲线 |
| 8 | `ChartCard` **保持删除** | 改造后全仓 0 引用 |
| 9 | 三个自绘面板的高度比例 **0.70 / 0.74 / 0.86 不改** | 知道是估值，先不动 |
| 10 | 月份选择面板**任何页面都保持 iOS 原生** | 行程页、充电页共用 `MonthPickerSheet`，不做 HTML 的自绘年月网格 |
| 11 | 7 天视图**点柱也弹气泡** | 按 HTML 实际代码（`toggleChartTip` 里没有「7 天跳过」的判断），注释与代码不一致时以代码为准 |

### 充电

| # | 决定 | 用户确认内容 |
|---|---|---|
| 12 | 附近充电站完整列表**改成自绘面板** | 不用系统 sheet；已用 `V2BottomSheet`（遮罩 + 24 圆角 + 把手 + 固定高度） |
| 13 | OCR 核对弹层**整体 v2 化** | 外框、标题栏、输入行全改，不留 v1 表单 |
| 14 | 手写录入 / 待确认配对**也改 v2 面板** | 同页三种弹层观感统一 |
| 15 | 月份选择器 bug 修复（mock 24 个月 / `monthsAreLive` / 请求改 `try?` / 选中项回退本月） | 用户确认「修」 |

### 车控与设置

| # | 决定 | 用户确认内容 |
|---|---|---|
| 16 | 服务端 `allowCommands` 提到 `AppStore`（方案 A） | 要那条「即便本地开关打开也会被拒绝」的提示，改数据层也要做 |
| 17 | 「退出登录」**不搬到**「关于」卡 | 保持现状，仍在「账号登录」卡内 |
| 18 | 权限灰项改按 `capabilities[key] == false` 列 | 不用「被车控能力集裁掉」反推；取不到能力集时不列（「不知道」≠「确认没有」） |
| 19 | 免责声明加上 | 关于卡含版本号 + 「非官方、与极氪/吉利无关」+「车辆数据仅存本机」 |

### 阶段 6 收口

| # | 决定 | 用户确认内容 |
|---|---|---|
| 20 | 底栏侧边距取 **21** | 与 HTML 实测一致；任务书 3.1 的 14 是 v1 值 |
| 21 | 权限「…」/「收起」**不用撑到 44pt** | 保持 HTML 的 chip 尺寸（约 33pt） |
| 22 | 三块 iOS 独有内容**收进「高级与调试」折叠** | 位置按 HTML：页脚之后、登录后不渲染 |
| 23 | **跳过五屏截图** | 本机无 Xcode / 模拟器，明确说不必产出截图 |

### 第 7 轮审计修复

| # | 决定 | 用户确认内容 |
|---|---|---|
| 24 | 审计查出的 **1–7 条全部修** | 「1-7都修」 |
| 25 | 行程**错误态也统一用柱状** `ic-chart-bar` | 「8统一吧用柱状」 |

### 第 8 轮：bug 与 HIG 收口

| # | 决定 | 用户确认内容 |
|---|---|---|
| 26 | 3 个 bug + 交互/HIG + 非无障碍建议改进**全部修** | 「你提到的3个bug和之前提到的交互\HIG问题，建议改进这些都去修了吧」 |

### 第 9 轮：Swift 最佳实践

| # | 决定 | 用户确认内容 |
|---|---|---|
| 27 | 建议调整的 **3 项全部改**（`@MainActor` / 抽公共横幅 / 删死代码） | 「建议调整的那三项都去改了吧」 |

### 第 10–11 轮：顶栏与底部胶囊

| # | 决定 | 用户确认内容 |
|---|---|---|
| 28 | 底部胶囊**改用原生 `safeAreaBar`**，接受「距安全区底 14（物理底 48）」而非网页的 14 | 「A 换原生」 |

### 工作方式

| # | 决定 | 用户确认内容 |
|---|---|---|
| 29 | 每个阶段**做完并自检通过再汇报**，不中途停 | 「每个阶段做完后自己严谨地完整验证一遍，确定没问题再告诉我结果，我同意后再开始下一阶段」 |
| 30 | 不擅自做决定，需拍板的一律先问 | 「切记不要自作主张」。凡遇到与 HTML / 任务书冲突的，先列出来问，不写「已定」 |
| 31 | `preview/index-v2.html` 是唯一真源 | 「不要擅自决定做出跟 HTML 差异很大的效果」；CSS 写了但没生效的地方以实测渲染为准，并在报告里单列数值 |
| 32 | 不自动提交 / 推送 | 改完停下汇报，git 操作由用户自己执行 |

## 待用户拍板

**无。** 上面 32 条已覆盖全部需要决策的点；剩余事项均为「未编译验证」这一类客观条件限制，不属于待定项。
