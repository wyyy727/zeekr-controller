# AGENTS.md — 给 AI 编码助手的项目须知

> 本文件面向在此仓库工作的所有 AI agent（Claude Code / Codex / Cursor / Copilot / WorkBuddy 等）。
> 人类读者请直接看 [`README.md`](README.md)。

## 项目一句话

极氪 001 车主自建的车控看板：**iOS App（SwiftUI） + Python 后端（FastAPI）**，
绕开臃肿的官方 App，直连极氪国区网关，补齐能耗统计 / 行程历史 / 充电账单归集。

---

## ⚠️ 三条铁律

### 铁律零：真车数据 = 隐私，只留本地，禁止入库 / 禁止上网

**VIN、车牌、GPS 坐标、里程、令牌等极氪接口返回的任何数据，都是用户隐私。**

| 规则 | 说明 |
|---|---|
| 存放位置 | **只允许在本机**（`server/data/`、仓库外的临时脚本目录）。`server/data/` 已在 `.gitignore` 中 |
| 禁止 | 写进任何**会被 git 跟踪**的文件（测试夹具、文档、示例、日志样本）；贴到对话/网页/任何联网处 |
| 测试要用真车结构时 | **只复刻字段名与值类型，取值一律换成同形状的假值**（见 `tests/test_adapter_shape.py` 顶部注释） |
| 临时探针脚本 | 写在**仓库外**（如 `D:\workspace\nanamikiki\_probe*.py`），**用完即删**，不要把响应 dump 到仓库内 |
| 验证手法 | 令牌落盘后直接驱动 `LiveZeekrClient` 打真实网关即可，不需要 dump 报文到文件 |

### 铁律一：接口与字段，一律以官方 APK 为唯一权威

- 官方原版极氪 App **实际发出的 HTTP 请求**（host / path / 请求头 / 字段名）是**唯一**权威来源。
- 社区逆向实现（`zeekr_ev_api`、`openzeekr`、`zeekr_ha` 等）**只作旁证，不作结论**。
- 不采信"按服务名猜"的路径。
- 取证结论已固化在 `docs/zeekr-apk-reference.md` —— **先查它，不要重新逆向**。

### 铁律二：改动纪律

| 改动类型 | 怎么改 |
|---|---|
| **新功能** | **先只改 `preview/index.html`**（用户在 Windows 上没 Mac，靠预览页看效果）。预览页在浏览器里被看过、确认过之后，才允许改 iOS 与后端 |
| **把预览页已有的功能对齐到 iOS** | 可以直接改 —— 用户已明确放行（2026-10-19：「去改 iOS 代码吧」） |
| **接口路径 / 字段名纠错** | 属于修复而非新功能，**可直接改后端**（`server/app/adapters/live_client.py`） |
| iOS 小组件（Widget） | **一律不做** —— 用户明确表示不需要臃肿功能 |

> iOS 改动**无法在本机验证编译**：这台机器是 Windows，没有 Xcode / Swift 工具链。
> 所以写 Swift 时一律用**最保守的语法**，并且要在提交信息里写明"未编译"。
> 验证只能靠 push 后看 GitHub Actions，或由用户在有 Xcode 的机器上过一遍。

---

## 🚫 不要重复做 APK 逆向 —— 结论已经固化了

逆向极氪 APK 是一次性的重活（加固、几百 MB、加壳），**结论已经写进仓库**。
任何时候需要这些信息，直接用现成的，不要从头再来一遍：

| 你想要什么 | 用什么 | 说明 |
|---|---|---|
| 官方接口路径 / 字段名 / 主机 | **先读 `docs/zeekr-apk-reference.md`** | 人读；含字段名 ↔ ZeekrDash 归一化键对照表 |
| 机器可读的原始情报 | `docs/zeekr-apk-intel.json` | 网关 87 · 服务 130 · 路径 1089 · 请求头 283 · 能力标志 810 |
| 重新提取 / 刷新情报 | `python scripts/apk_intel.py <apk>` | 纯标准库，无依赖 |
| **极氪 App 更新后对比验证** | `python scripts/apk_intel.py <新apk> --compare docs/zeekr-apk-intel.json` | 见下节 |
| 6 个网关密钥 | `python scripts/extract_keys.py <apk> --write-env` | 需 `capstone` + `pyelftools` |

### 官方 App 已加壳 —— 换个问法绕开它

包内有 `libconch.so`(31 MB)、`libHHSecurity.so`、`libNetHTProtect.so` 等加固，
**JADX 只能解析出 23 个类，类级反编译不可用** —— 读不到 DTO、注解与请求体结构。

但这些是**可判定命题**，仍然可靠：

- DEX 的**字符串表是明文可读的** → "某条路径是否存在"、"某字段名是否存在"能给出确定答案。
- 判定方式：对原始字节做精确 `count()`，而不是靠肉眼或模糊匹配。
- native 层（`libenv.so`）可以反汇编——HMAC 密钥就在里面。

> 教训：ZeekrDash 曾用 `/zeekrlife-app-vehicle/...` 前缀，而官方 APK 里
> 该前缀**出现 0 次**；还有 28 个自造字段名（如 `doorStatusFrontLeft`）也从未存在过，
> 导致车门、胎压等字段长期静默取不到值。**字段名别猜。**

---

## 🔄 极氪 App 更新后的回归流程

官方发新版 App 时，用这个流程判断"我们的实现会不会被打断"：

```bash
# 1. 下载新版整包 APK（CN 包名 com.zeekrlife.mobile，PC 上从应用宝下，无需安卓设备）
# 2. 与上次的快照对比
python scripts/apk_intel.py <新版.apk> --compare docs/zeekr-apk-intel.json
```

产出 `docs/zeekr-apk-diff.md`，重点看**第一节「契约回归」**：
它逐条检查 ZeekrDash 正在使用的路径与字段（脚本里的 `CONTRACT_PATHS` /
`CONTRACT_FIELDS`，与 `server/app/adapters/live_client.py` 一一对应）是否还在。

- **契约项消失 = 破坏性变更** → 脚本以**退出码 1** 结束，方便 CI 拦截。
  要做的不是删掉那一行，而是按参考文档找到官方新名字并改 `live_client.py`。
- 无破坏性变更 → 报告末尾会给出替换快照的命令。

> 设计意图：只有"契约项消失"才算阻断级。每次 App 更新都会带来成百上千条
> 无关字符串，把噪声当风险会让这个检查失去意义。

---

## 🛠 本机环境（Windows，已验证可跑）

| 用途 | 路径 / 命令 |
|---|---|
| **服务端 venv** | `server/.venv/Scripts/python.exe`（已装运行依赖 + pytest） |
| 起后端（Windows） | `scripts\server.cmd start` / `logs` / `status` / `stop` —— 双击也行，不依赖 Git Bash |
| 起后端（bash） | `./scripts/server.sh start` / `logs` / `status` / `stop` |
| 跑测试 | `cd server && .venv/Scripts/python.exe -m pytest tests -q` |
| APK 分析（有 capstone） | `C:\Users\Administrator\.workbuddy\binaries\python\envs\zeekr\Scripts\python.exe` |
| 可用 JDK（21） | `D:\develop\jdk21\jdk-21.0.9`（**全局 `JAVA_HOME` 指向 Java 11，不够用，别改全局**） |

**已知环境坑**：

- **`server.cmd` 必须保持纯 ASCII，注释也一样。** `cmd.exe` 按控制台 ANSI 代码页
  （中文 Windows 是 GBK）解析脚本字节，不是 UTF-8 —— 里面写中文会被误解码，
  进而**破坏命令解析**（实测整个脚本乱套：`set` 被截成 `et`、注释行被当命令执行）。
  想让提示显示中文，只能把文件本身存成 GBK。改这个文件时务必注意这一点。
- **`server.cmd` 必须是 CRLF 换行**：`cmd.exe` 在 LF 换行下解析 `call` / `goto` 会出错，
  表现很隐蔽 —— 子过程收不到参数，报「找不到操作数」，而不是报语法错误。
  写文件的工具默认产出 LF，改完要转回 CRLF；`.gitattributes` 已声明 `*.cmd text eol=crlf`。
- **`server.sh` 与 `server.cmd` 是同一功能的两平台实现，改一处要同步另一处** ——
  尤其端口反查与停止逻辑。
- **不要用 `find /c /v "" < file` 取行数、也不要用 `more +N` 显示增量**：
  前者输出是 `---- 文件名: 123`（数字不在第一个 token，`set /a` 会拿到 `----`），
  后者需要交互式控制台，stdout 一旦被重定向就报「管道不存在」。
  日志跟随已交给 `scripts/logs_tail.py`（顺带把 UTF-8 日志转成控制台编码，中文才不乱码）。
- `git clone` GitHub 会因证书吊销检查失败 → 用 `git -c http.schannelCheckRevoke=false clone ...`，或走镜像。
- 下载大文件优先用 `gh-proxy.com`；`ghproxy.net` 会**静默截断**（HTTP 200 但文件不完整）。
- 服务端在**密钥未配置**时自动回落**模拟数据模式** → 前端调试不依赖真实网关。
- **登录手机号不要写进 `.env`**：它在客户端登录时输入（设置页 → 账号与凭据），
  服务端既不保存也不依赖它。`is_configured` 只判断密钥是否齐全，
  「换账号登录」是纯客户端行为，不需要改配置或重启服务。

---

## 📁 关键文件

| 路径 | 作用 |
|---|---|
| `server/app/adapters/live_client.py` | 极氪网关对接**全部实现**（路径、字段解析、车控、能力集、附近站点） |
| `server/app/adapters/zeekr_signing.py` | 三网关签名（GW1 SHA1 / GW2 HMAC-SHA1 / GW3 HMAC-SHA256 + AES-128-CBC）。**GW2 已停用**，回退分支是历史遗留 |
| `server/app/adapters/haohan.py` | 第三方充电网关（站名 + 电价来源），与极氪侧零耦合 |
| `server/app/api/stations.py` | `GET /api/stations/nearby` —— 两跳合并、并发取价、降级与缓存 |
| `server/app/api/trips.py` | `GET /api/trips/energy` —— **官方「行程与能耗」日统计**（`h5/getDailyStatisticsInfo`，≤31 天），行程页的数据源 |
| `server/app/adapters/tencent_map.py` | 腾讯位置服务（逆地理编码 + 静态图 + **天气**）。**key 只在服务端** |
| `server/app/core/coords.py` | WGS-84 ↔ GCJ-02。车坐标 `marsCoordinates="0"` 时必须转，否则地图偏约 500 米 |
| `server/app/api/location.py` | `GET /api/vehicle/location`、`.../map.png`、**`.../weather`** —— **全项目唯一把车坐标发给第三方的出口** |
| `server/app/adapters/mock_client.py` | 模拟数据（字段形状必须与 live 保持一致 —— 有测试守着） |
| `server/tests/test_adapter_shape.py` | 防漂移：两个适配器输出形状必须一致 |
| `server/tests/test_stations.py` | 附近充电站：字段裁剪、降级语义、缓存网格 |
| `server/app/api/charges.py` | `POST /charges/sync` + `GET /charges/sessions|months` —— **充入电量**（官方 `charge/log/queryGroupMouth`）；以及金额补录：`receipts/ocr|commit`、`payments/*` |
| `server/app/adapters/vision_ocr.py` | 充电账单截图识别（DeepSeek Vision）。**图片不落盘**，回传前按白名单 + 正则再刮一遍隐私 |
| `server/app/bills/matching.py` | 金额 ↔ 充电流水配对：电量 ±5% 且时间 ±10 分钟才算强匹配 |
| `server/tests/test_charge_sessions.py` | 充电流水：口径一致性、幂等同步、不编造金额 |
| `server/tests/test_charge_receipts.py` | 金额补录：配对口径、不吞钱、隐私过滤 |
| `preview/index.html` | **单文件设计预览页 + 调试台**（功能改动的唯一落点）。`?debug=1` 调出调试浮层 |
| `scripts/server.cmd` / `server.sh` | 服务管理（Windows / bash 两版，功能对应，须同步改） |
| `scripts/logs_tail.py` | 实时跟随服务日志（`server.cmd logs` 调用），并做 UTF-8 → 控制台编码转换 |
| `ZeekrDash/Features/Charges/NearbyStationsViewModel.swift` | 附近充电站：定位（一次性）→ 取站点 → 排序 |
| `ZeekrDash/Features/Charges/NearbyStationsView.swift` | 附近充电站卡片 UI |
| `ZeekrDash/Features/Charges/ChargesViewModel.swift` | 充入电量（月份 / 流水 / 同步）+ 金额补录（OCR / 手工 / 待确认配对） |
| `ZeekrDash/Features/Charges/ChargesView.swift` | 充电页 UI：充入电量单卡（大数 + 双轴趋势图）、充电记录、充电费用 |
| `ZeekrDash/Features/Dashboard/DashboardView.swift` | 车况主页：电量 / 胎压 / 车身状态 / **车辆位置**（车控面板已独立成 tab） |
| `ZeekrDash/Features/Controls/ControlsView.swift` | 车控 tab：只放 `ControlsPanel` + 未登录引导 / 空态 / 脚注 |
| `ZeekrDash/Features/Controls/ControlsPanel.swift` | 快捷车控面板本体（15 个按钮、三组、动效与安全开关都在这里） |
| `docs/zeekr-apk-reference.md` | 官方接口情报（**先查这里**） |
| `docs/真机验证清单.md` | 真车逐条核对清单 |

---

## ⛽ 附近充电站：改这块之前先读

数据要**两跳、两套完全独立的认证体系**才凑得齐，拆成两个适配器是有原因的：

1. 极氪 GW1 `…/bubble/charge/getListV2` —— 坐标、枪数、运营商 logo（要 JWT + `x_ca_*` 签名）
2. 第三方浩汉网关 `find/station/detail` —— 站名、地址、评分、**电价**（只要一个 `channelId` 请求头）

| 边界 | 说明 |
|---|---|
| **价格缺失 ≠ 免费** | 取不到就给 `null`，界面显示「价格 --」，**绝不落成 0**。把"没查到"画成"不要钱"是安全事故级的误导 |
| **坐标绝不发给第三方** | 只把 `stationId` 转给浩汉；坐标只发给极氪自己的网关。前端同理：不落盘、不进日志、登出即清 |
| **第三方挂了要降级** | 列表照常返回，只丢站名与价格，并置 `priceAvailable=false` 让界面明确提示 |
| **缓存是唯一的风控手段** | 两侧限流阈值未知：站点按坐标 3 位小数网格缓存 300s，价格按 `stationId` 缓存，**只缓存成功结果** |

三个反直觉点（别再试错一遍）：

- 极氪侧**必须 POST** —— GET 一律 `200 + 999999 服务异常`，极易误读成"服务挂了"；
  路径里**没有** `/toc/` 段。
- 浩汉缺 `channelId` 头时报的是 `52003 渠道信息缺失` 或 `1027 当前站点暂未开放`
  —— **两个错都在骗人**，与站点是否开放无关。
- 成功码位数不同：浩汉是四位 `0000`，极氪是六位 `000000`。

浩汉**没有**"一次返回多站价格的列表接口"。它自己的前端是**逐站预取 detail 再合并**，
`server/app/api/stations.py` 照这个做（并发上限 6）。

**分页是服务端切片，不是上游分页**：极氪 `getListV2` 一次就把视野内的站点全给了
（它自己没有分页参数），所以 `limit` / `offset` 是在排好序的列表上切。
首屏取 10 条而不是 20 —— 取价是按站请求的，10 个只要 2 轮、20 个要 4 轮，
这是"加载慢"的主要来源。

翻页只认服务端字段 **`nextOffset` / `hasMore`**，不要用 `offset + count < total` 推算。
原因：筛选分两类，"枪型/自营"来自气泡接口（零成本，切片**之前**过滤，
`total` 是筛选后的真实条数）；"电价上限/停车免费"必须先逐站问浩汉才知道，
只能在切片后逐批取价再筛，并受 `PRICE_SCAN_MAX`（30）限制扫描范围 ——
此时中间被扫描掉、不符合条件的候选**不返回**，`nextOffset` 会大于
`offset + count`，自己推算就会重复请求同一段。响应里的 `priceFilterApplied`
就是用来告诉前端"此时 total 只是候选数，别当匹配数显示"。

界面上目前只暴露 **快充 / 极氪自营 / 停车免费** 三个 chip：
电价档位（≤1.0/1.5/2.0 元）与"慢充"试过一版，一行铺 7 个 chip 太占地方，已去掉。
`max_price` / `connector=ac` 这两个**接口参数保留**（有测试），要恢复只改 `filterRow`。

**卡片固定高度、列表自己滚**：站点卡放在充电页上半部分，若列表不限高且自动翻页，
用户想去下面的「充入电量」「充电记录」时，每次接近列表底部就会触发下一页，
卡片一直往下长 —— 表现为"分页停不下来、下面的卡永远看不到"。
现在的做法（网页与 iOS 一致）：
- 列表 `max-height: 384px` + `overflow-y: auto`（iOS：`ScrollView { LazyVStack }` 的 `frame(maxHeight:)`）
- **没有「展开全部/收起」** —— 卡片一进来就是最终高度，位置不跳
- 分页只由**内层列表**滚到底触发（`document` 上 capture 监听 `.st-list` 的 scroll），
  页面滚动完全不参与 ⇒ 手指在列表外滑就是正常翻页
- 列表底部保留「加载更多」兜底：某页条数很少时列表不需要滚动，那条"滚到底"永远等不到

**登录后不要一次性打满全部接口**：网页改成按 tab 懒加载（`TAB_NEEDS` + `ensureTabData`），
切到哪个 tab 才取哪个 tab 的数据，失败的下次进页面重试（`loadedKeys` 只记成功）。
iOS 本来就分散：`AppStore.refresh()` 只取车况那批（status/caps/location），
行程与账单由各自 ViewModel 的 `.task` 触发。

**导航必须带 `callnative=1`**：高德 URI 文档里该参数**默认是 0**，不传就只在浏览器
打开 H5 网页版（用户报过"跳到浏览器高德"）。另外要用 `navigation` 而不是 `marker`
—— 后者只标点、不规划路线。iOS 优先走 `iosamap://navi` scheme，失败再退回 H5。

---

## 🔌 充入电量（charge_sessions）：改这块之前先读

**数据源只有一个**，且它是官方 App「充电记录」页的接口：

```
POST /ms-charge-manage/api/v2.0/charge/log/queryGroupMouth
body: {"startTimeStart": null, "chargeType": ""}   // 一次给约两年
```

三个必须记住的点（少一个就失败，且报错会误导人）：

1. 除 GW3 签名头外**必须带** `X-TENANT-ID: ZEEKR` + `X-VEHICLE-BRAND: ZEEKR`，缺一个报 `079001`
   （看起来像"没权限"，实际是缺头）；
2. `X-VIN` 必须是**加密后的** VIN，明文报 `079025 Decrypt X-VIN failed.`；
3. 返回是「年 → 月 → 记录」三层，`power` 是电量（度），`chargedTime` 是**分钟**。

**口径（改 UI 前先对齐这张表）**：

| 展示项 | 算法 | 坑 |
|---|---|---|
| 充入电量 | Σ`power` | 单位度 |
| 充电次数 | 记录条数 | **含电量缺失的记录**；次数与电量是两个维度 |
| 快 / 慢充 | `chargeTypeName` 含「直流」/「交流」 | 上游有时给空名 ⇒ 落 `unknown`，别猜 |
| 平均功率 | 电量 ÷ (时长/60) | 比"充了多久"更能说明桩快慢 |
| 每次充电时长 | 逐笔的 `chargedTime` / 该月总时长 ÷ 次数 | 图表的**第二根轴**（小时）；量纲不同，不能硬套左轴 |
| 金额 | **不存在** | 见下 |

**充电页是一张「充入电量」卡**（左电量 + 右金额 → 逐次图 → 直流/交流拆分一行），
不是两张卡也不是四宫格：

- **图是"所选月份内的每一次充电"**，不是全年月度趋势。这张卡讲的就是"这一个月"，
  在下面摆一条全年趋势只会让人怀疑看的是哪个月。
  横轴标签 `10-09`，同一天充两次时追加 `#2` —— 重复标签在类目轴上会被当成同一个刻度
  （iOS 的 Swift Charts 会直接把两根柱子合并）。
- 图是**柱（本次电量，左轴）+ 折线（本次时长，右轴）**：同样 40 度，
  快充二十分钟、慢充一整夜，光看柱子完全一样。
- **金额就在大数区右边**：当月金额（跟着月份筛选）+ 累计金额（Σ 所有可查月份）。
  `months` 接口每个月都带 `amount` / `amountCount`，前端只做加法；
  估算（`amount_source='estimate'`）不计入，与单月汇总同一口径。
  没补录时显示「--」，**绝不显示 0 或估算值**。
- **快充 / 慢充不单独给"次数"** —— 直流次数 + 交流次数 = 上面那个「共 N 次」，
  换个说法重复一遍而已。只保留各自的**电量**，压成图下面一行。
- 最下面那张卡是**纯操作卡**（「金额补录」）：数字已经在上面了，这块只留三个入口
  加一句状态 —— 一块放数、一块放操作，各自只有一件事。

iOS 侧（`ChargesView.trendChart`）要额外记住一件事：**Swift Charts 没有"每系列一套刻度"**。
所以时长按 `scale = (axisMax * 0.74) / maxHours` 折算进电量的坐标空间，
右轴的刻度值再反向折算回小时显示（`raw / scale`）。改 `axisMax` 的取值时，
两个地方必须一起改，否则右轴数字和线的位置就对不上了。

**金额一定不要编。** 车端报文里没有任何 `fee/cost/amount/price` 字段，站点也不在
充电记录里；官方 App 的「补能订单」金额页在浩汉网关后面（要浩汉账号态），
**不可自动化**。所以金额只有三条路：截图识别（主线，已接入）/ 手写录入 / 估算
（必须标 `estimated`，且**不与真值混算**）。没有金额时大数区写「未补录」，
**不显示任何估算数字** —— 把猜测画成"实际支出"比留空更糟。

**表设计：`charge_sessions` 与 `charge_records` 不要合并。**
前者是"车充了多少度"（自动、权威），后者是"支付账单解析出的金额"（历史遗留、实测 0 行）。
合成一行就会逼着二选一 —— `charge_records.energy_kwh` 恒为 NULL 就是这么来的。
`amount` 与 `station_name` 只由 OCR/手工写入，同步时用 `COALESCE(旧值, 新值)` 保留，
**例行同步绝不能把用户补录的钱抹掉**。

**不要把 VIN 落进这张表**：本机单车主场景，落一份车架号只是凭空多一处敏感数据，
查询也只按月份过滤。

**同步节奏**：`POST /api/charges/sync` 是幂等的（按 `eventId` upsert），服务端有 10 秒冷却。
请求体是 `{startTimeStart: null}` ⇒ **一次拉约两年全量**，没有增量参数，
所以"多久同步一次"本质是"多久愿意打一次官方网关"（风控问题，不是数据量问题）。

页面**没有手动同步按钮**，只有三种触发：

| 触发 | 条件 | 说明 |
|---|---|---|
| 空库 | 本地一条流水都没有 | 第一进来必须填上 |
| **跨天** | 上次同步不是今天（`zk.chargeSyncAt` 存本地，跨刷新保留） | 一天最多打一次；同一天反复切 tab 不再打 |
| **充电结束** | 车况 `isCharging` true→false | **唯一真正产生新数据**的时刻；等 60 秒（官方落库有延迟）再拉 |

切月份只读本地库，**不打网关**。自动同步一律静默（不弹 toast），失败下次机会再说。
只有真的打到网关才写「同步时间」—— 429/401/网络失败都不写，否则一次失败会被记成
"今天已同步"，当天不再重试。手动兜底在调试台（`?debug=1` → 接口 → `POST /api/charges/sync`）。

iOS 侧规则完全相同，落点：`ChargeSyncStamp`（UserDefaults key `zk.chargeSyncAt`）、
`ChargesViewModel.sync(silent:)` / `syncAfterChargeEnd()`、
`ChargesView.onChange(of: store.isCharging)`。iOS 没有调试台，**下拉刷新**就是手动入口
（原生手势，界面上不占位置）。

---

## 💴 金额补录（截图识别 / 手写 / 待确认配对）：改这块之前先读

金额唯一能拿到的地方是**人手里的那张截图**（极氪 App「补能订单」页、第三方账单、
支付凭证）。链路：

```
选图 → POST /api/charges/receipts/ocr   （识别，**不入库**，返回候选 + needsReview）
     → 前端弹核对框（金额/电量/时间/站点可改，可指定归属哪次充电）
     → POST /api/charges/receipts/commit（幂等，配不上的落 pending / unmatched）
     → GET  /api/charges/payments       （待确认队列，点一下即可绑定）
```

调试口：`POST /api/charges/receipts/ocr-debug` + 页面 `/preview/ocr-test.html`。
正式链路的白名单过滤把"模型到底读了什么"也裁掉了，评测识别质量要看被裁掉的那部分，
所以调试口额外带 `raw`（模型原文）与 `parsedRows`（未清洗字段）——
**只许本机调试**：这两样可能含 prompt 没拦住的 VIN / 手机号 / 完整订单号，
不入库、不进日志、不进正式链路。

⚠️ **网页侧 POST 必须带 `Content-Type: application/json`**（`withAuth()` 里统一补）。
`fetch` 对字符串 body 的默认头是 `text/plain;charset=UTF-8`，而 FastAPI 的 `Body(...)`
只解析 JSON —— 少了这个头，请求在**进入函数之前**就被判 422，
报错形如 `{"type":"dict_type","msg":"Input should be a valid dictionary"}`，
看着像报文格式写错，实际只是少了一个头（2026-10-22 的「确认补录报 422」就是它）。
`FormData`（截图上传）不是字符串，不会被加这个头。

三条红线：

| 红线 | 为什么 |
|---|---|
| **识别结果不直接入库** | 模型会把服务费原价当金额、会把一笔看成两笔；"金额读错"比"没有金额"更糟 |
| **配不上的不丢** | 零命中 → `unmatched`，多候选 → `pending`。钱已经花了，删掉等于把支出抹了 |
| **图片不落盘** | 只在内存 → base64 → 上游；日志只记 `sha8` / 字节数 / 耗时 |

**配对口径**（`bills/matching.py`，别自己改）：
强匹配 = 电量差 ≤5% **且** 起点差 ≤10 分钟；弱匹配 = 落在 session 起止 ±30 分钟。
唯一强匹配才自动绑定，其余一律进「待确认」。之所以不用订单号：官方订单号在支付侧，
充电流水里没有，能对齐的只有电量 + 时间。

**隐私**：`vision_ocr.py` 的 prompt 明确禁止输出 VIN / 车牌 / 手机号 / 完整订单号，
回传后还要按白名单 + 正则再刮一遍（模型不听话是常态，不能只靠 prompt）。
订单号只留后四位，站点名去掉门牌楼层。

**开关**：`DEEPSEEK_API_KEY`（根 `.env`）。没配时 `/receipts/status` 返回
`configured=false`，前端把识别按钮降级并给出指引，但**手写录入永远可用**。

---

## 📍 车辆位置：改这块之前先读

- **坐标已由服务端转成 GCJ-02**（依据网关的 `marsCoordinates` 标志）。
  客户端**不要再转第二次**，否则会反向偏回去 500 米。
- **位置不是实时的**：车静止时网关不更新坐标（实测 15 条快照只有 3 个位置点），
  `reportedAt` 可能滞后几十分钟。界面**必须**显示上报时间。
- **key 只在服务端**：客户端请求 `/api/vehicle/location/map.png` 拿图，
  不要在客户端拼腾讯 URL。iOS 用 `APIClient.imageData`（要带 Authorization 头），
  **不能用 `AsyncImage`** —— 它不能自定义请求头。
- **缓存是隐私手段**：地址落 `geocode_cache`、图落 `data/mapcache/`，
  坐标不变就完全不请求第三方。改缓存逻辑前想清楚"会不会让外发变多"。
- **降级要分清两种**：`mapAvailable=false` 是没配 key（去填 `.env`）；
  `mapAvailable=true` 但 `address=null` 是第三方取不到（额度/网络），改配置没用。
- **「当地气温」不是「车外温度」**：车端 `climateStatus.exteriorTemp` 实测非空率 0/15，
  这版固件根本不上报。所以那一格是 `GET /api/vehicle/weather` 按坐标查来的天气，
  界面标签**必须**写「当地气温」—— 暴晒、地下车库时两者能差十几度，标成"车外温度"就是谎报。
  取不到显示 `--`，**绝不用 0℃ 顶替**（0℃ 是具体气温，会被当真）。
  该接口与 `/location` 共用同一份 60 秒位置缓存，多一个接口不多外发一次坐标；
  天气结果另按坐标缓存 5 分钟（官方约 10 分钟更新一次）。
  若哪天固件开始上报 `exteriorTemp`，在 `weatherTemp()` 里加一条"有真值优先用真值"即可。
  iOS 侧同口径：`AppStore.weather`（`loadWeather()` 挂在 `refresh()` 末尾，失败只清这一格）
  + `DashboardView` 的「当地气温」卡 + `MockData.weather`（演示固定 22℃）。
- **设置页（网页/iOS 同一套规则）**：
  · 「服务端/服务连接」卡**只在未登录时显示**（登录后地址与连接状态是噪音；
    退出登录后可回来改，或用 `?api=`）；
  · 「服务端车控」（`.env` 的 ALLOW_COMMANDS）放在**车辆控制卡**里、客户端总开关上方 ——
    两把锁并排看才讲得清"发不发"和"收不收"；诊断卡里不再重复；
  · 车辆权限只显示前 6 项，多的折叠。**网页用「…」小按钮，iOS 用「展开全部 N 项」文字按钮
    （44pt 触控区）** —— 省略号在触摸屏上既不好点也不像按钮，这是两端的**有意差异**；
  · 权限卡不再写"来源：ms-app-bff/…"，那是实现细节。

---

## ❗ 六个容易搞错的认知

1. **车控返回「已提交」≠ 车端已执行。** 网关收下只代表请求被受理。
   要确认真执行，必须查 `queryProcessResult`，或以**车实际动作**为准。
2. **后端不能去掉。** iOS 无法常驻后台轮询（BGTaskScheduler 不可靠、低电量模式直接禁用），
   而"打开就看见最新车况"依赖服务端轮询。密钥也不该落到客户端。
3. **预览页只剩 `preview/index.html` 一个文件**（2026-10-19 合并，原 `debug.html` 已删除）。
   调试台是同一页面里的浮层，由 URL 参数控制：
   · 默认打开 —— 纯设计预览，**调试台不显示、一个网络请求都不发**
   · `?debug=1` —— 显示调试台浮按钮
   · `?debug=0` —— 关掉并记住
   · 调试台里的 **「连接后端」开关** 才决定是否真的发请求（关着时地址输入框是禁用的）

   这样做的原因：以前 `index.html` + `debug.html` 两份文件，改动必须手动同步，
   靠 `diff` 全量差异恒为 554 行来核对 —— 一旦插入新代码这个数字就会变，
   **核对手段本身成了负担**。合并后只有一份源码，同步问题永久消失。
4. **`MockData.swift` 与 `preview/index.html` 的 `MOCK` 常量同源** ——
   改一处要同步另一处（两边文件头都写了这条约定）。模拟数据是"不上网时的演示"，
   但**字段契约不能自成一套**。演示用的站名一律带「演示」字样，别长得像真实场站。
5. **模拟数据绝不能进持久化库。** 假数据长得像真的（日期连续、距离合理、字段齐全），
   读路径分不清来源，排查时还会被当成"接口曾经成功过"的证据 —— 2026-10-19 就
   这样误判过一次，把 `mock_client` 生成的 60 条假行程当成了真车数据。
   两条防线，改动相关代码时别拆：
   - `api/trips.py` / `api/vehicle.py` 在 `is_mock()` 为真时**不落库**；
   - `tests/conftest.py` 把 `config.database` 指向临时库，**并重建 `app.main.store`**
     （store 是导入时创建的，只改 config 不够）。

6. **官方接口的「命名空间」不认识就是 404，别拿 404 当"功能不存在"。**
   `journey-statistics-service` 下统计接口全在 **`h5`** 命名空间（`/api/v2.0/h5/getDailyStatisticsInfo`），
   而 `phone` 下只有一条 `protocolConfirm`。2026-10-19 因为只试了 `phone` + 名词词根，
   枚举 136 条全 `00A01`，据此写下"官方不给行程数据"的错误结论，白费一天。
   ⇒ 找接口的第一手段是**读前端代码**（H5 路由 → 静态站 → webpack chunk），不是猜路径。
   同时还踩到：日统计接口**只回查 60 天**（`A010`）、月报**不能查当月**（`A007`）、
   窗口上限 **31 自然日**（`A008`）—— 历史月份必须换 `getMonthlyStatisticsInfo`。

   同样的教训在电耗口径上重演过一次：一开始只摆「总电耗 + 平均动态电耗」两张卡，
   用户拿 22.7 ÷ 102 得 22.3 去对卡片上的 18.1，怎么看都对不上 ——
   因为少了「动态电耗」这一项（总 = 动态 + 静态）。**三个数必须同时出现。**

---

本仓库仅为个人自用学习，与极氪 / 吉利 / ECARX 无任何关联。
密钥、`.env`、会话文件一律不入库（见 `.gitignore`）。
