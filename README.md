# ZeekrDash

> 极氪 001 车主自建车控看板 —— 补齐官方 App 缺失的**能耗统计**与**行程历史**，并把分散在各充电服务商的消费记录汇总起来。

**目标车型**：2026 款焕新极氪 001　**目标平台**：**iOS 26.0+**（见 `project.yml` 的 `deploymentTarget`）

> ⚠️ 部署目标写的是 **iOS 26.0**，不是 README 早期版本写的 iOS 17+。
> 界面依赖 iOS 26 原生 Liquid Glass API（`.glassEffect` / `.safeAreaBar`），
> 旧版本 SDK 编不过 —— 这也是构建必须用 `macos-26` + Xcode 26 的原因。

---

## 为什么做这个

极氪官方 App 在数据展示上存在明显缺口：

- ❌ 不显示**能耗**数据
- ❌ 不显示**行程路径历史**
- ❌ 充电消费分散在极氪、特来电、星星充电、国家电网等多个渠道，无法统一查看

本项目通过社区逆向成果对接极氪国区网关，把数据补齐，并以 iOS 原生 App 呈现。

> **免责声明**：本项目基于社区公开的逆向研究成果，与极氪 / 吉利 / ECARX **无任何关联**。
> 仅供个人自用学习。逆向与接口调用可能违反服务条款或当地法律，**请自行评估风险**。
> 密钥、账号、令牌**绝不入库**——请务必遵守。

---

## 架构

```
┌─────────────────────┐         ┌──────────────────────────────┐
│   iOS App           │  HTTP   │   Python 服务（本地）          │
│   SwiftUI           │ ──────> │   FastAPI                    │
│                     │         │                              │
│  · 车况卡片          │         │  · 极氪国区网关对接            │
│  · 行程能耗图        │         │    GW1 短信验证码登录           │
│  · 充电消费报表      │         │    GW3 车数据 / 车控           │
│  · 附近充电站        │         │  · 充电站：极氪 + 第三方两跳    │
│  · 车控面板          │         │  · 账单解析与归集              │
│  · 设置              │         │  · SQLite 存储                │
└─────────────────────┘         └──────────────────────────────┘
```

> **关于 GW2**：早期资料里的「GW2 换 token」这一级**已经停用** ——
> `/app/login/v1/getTokenByCode` 在两个 host 上都返回 404（2026-10-16 真机实测）。
> 现在的链路是 **GW1 → GW3 两级**。`live_client.py` 里仍然保留着「GW3 被拒则回退
> GW2」的分支，那是历史遗留；它没有触发过，不要拿它解释失败原因。

**为什么需要 Python 服务？**

因为你是 iOS 用户，而极氪的密钥提取工具链**依赖安卓 APK**（要从 App 里逆向出 HMAC 密钥、AES 密钥）。
iOS 端拿不到这些，所以把签名与加密逻辑放在 Python 侧，iOS App 只做数据消费。

---

## 快速开始

### 第一步：准备密钥（一次性）

密钥是整个项目的前置门槛。**不需要安卓设备或模拟器** ——
在 PC 上下载官方 APK 整包，用**仓库自带脚本**静态提取即可。

1. 下载官方 APK。国区包名是 **`com.zeekrlife.mobile`**，应用宝等商店都能下到整包。

2. 提取 6 个密钥并直接写进 `.env`：

   ```bash
   pip install capstone pyelftools
   cp .env.example .env
   python scripts/extract_keys.py <下载的.apk> --write-env
   ```

   几点说明：

   - **整包即可**，不用再传 `split_config.arm64_v8a.apk` —— 整包里已含 `lib/arm64-v8a/libenv.so`。
   - 默认**不回显密钥明文**，只显示掩码（`ab12…cd34`）；要看明文加 `--show`。
   - 提取结果另存 `docs/zeekr_secrets.json`（已被 `.gitignore` 忽略，不会入库）。
   - 该脚本移植自 [wysie/zeekr_key_extractor](https://github.com/wysie/zeekr_key_extractor)（MIT），
     算法未改，只加了脱敏回显与写 `.env`。
   - 官方 App 加了壳也不影响 —— 脚本不依赖类级反编译，只扫 DEX 明文字符串表与反汇编 `libenv.so`。

   > ⚠️ **两条已被实测否证的结论，别再走老路（2026-10-16）：**
   >
   > - `ZEEKR_PROD_SECRET`：网关实际使用的值**不在**提取器输出的 119 个候选里。
   >   「逐个换候选再试」这条路走不通，改用参考实现里已验证的常量。
   > - `ZEEKR_VIN_KEY` / `ZEEKR_VIN_IV`：提取器给的常量恒报
   >   `079025 Decrypt X-VIN failed`。算法（AES-128-CBC + PKCS7 + Base64）没错，
   >   错的只是常量。
   >
   > 判错技巧：网关**验签在 token 校验之前**，补齐必需头之后用**假 JWT** 就能判定
   > 密钥对不对，不需要真车、也不需要重新登录。
   > 另：`079025` 是**复用码**（签名失败 / X-VIN 解密失败都用它），
   > 日志里必须同时打 msg，只看码会把排查方向带偏。

3. **重要**：新建一个**极氪子账号**并把车辆共享给它。
   极氪每个账号只保留一个会话，用主账号会导致手机 App 被踢下线。

### 第二步：启动服务

先装依赖、配密钥：

```bash
cd server
pip install -r requirements.txt

# 配置密钥
cd .. && cp .env.example .env
# 编辑 .env，填入 6 个密钥（手机号不用填，登录时在界面上输入）
```

然后启动。**两套脚本功能与命令完全对应**，按平台选一个：

| 平台 | 启动命令 |
|---|---|
| **Windows** | `scripts\server.cmd start` |
| Linux / macOS / Git Bash | `./scripts/server.sh start` |

两者都支持 `start` / `stop` / `restart` / `status` / `logs`，不带参数时打印用法与当前状态。

`logs` 是**实时跟随**（类似 `tail -f`）：先回放末尾 25 行，之后有新的请求日志会立刻追加显示，
按 `Ctrl+C` 退出。前端一发请求就能看到对应记录，不用反复重跑。

> **Windows 用户**：直接**双击 `scripts\server.cmd`** 也行 —— 会显示状态与用法。
> 它不依赖 Git Bash。服务跑在一个**最小化窗口**里，这是刻意的：
> 只有让进程脱离调用它的那个窗口，关掉窗口时才不会把服务一起带走。
>
> **不要双击 `server.sh`，也不要在 CMD 里执行它。** 它是 bash 脚本，Windows 会用
> `.sh` 的文件关联开一个**一次性**窗口：脚本跑完窗口立刻关闭，看起来像「闪退」，
> 输出也全丢了 —— 成功了看不出来，失败也不知道为什么。
>
> 两个脚本都在 `scripts/` 下、**不在仓库根**：写成 `./server.sh`（在根目录）
> 会直接 `No such file or directory`。

服务起来后：

- <http://localhost:8765/docs> —— FastAPI 自动生成的接口文档
- <http://localhost:8765/preview/index.html> —— **设计预览页**（见下文「预览页」一节）
- <http://localhost:8765/preview/index.html?debug=1> —— **带调试台**：浮层里可配后端地址、逐个打接口、看请求日志。
  调试台里的「连接后端」开关关着时**不发任何请求**（默认就是关的）

`.env` 的位置不敏感：`server/.env` 与**仓库根目录** `.env` 都会被加载（先命中的优先），
所以按上面的 `cd .. && cp .env.example .env`（落在根目录）也能生效。

#### `.env` 的完整键位

| 键 | 必填 | 说明 |
|---|---|---|
| `ZEEKR_HMAC_ACCESS_KEY` | ✅ | 从 APK 提取的 6 个密钥之一 |
| `ZEEKR_HMAC_SECRET_KEY` | ✅ | 同上 |
| `ZEEKR_PASSWORD_PUBLIC_KEY` | ✅ | 同上（RSA 公钥，加密登录密码） |
| `ZEEKR_PROD_SECRET` | ✅ | 同上（GW3 的 X-SIGNATURE 密钥） |
| `ZEEKR_VIN_KEY` | ✅ | 同上（AES-128，加密 VIN） |
| `ZEEKR_VIN_IV` | ✅ | 同上 |
| `ZEEKR_VEHICLE_TOKEN` | ⬜ | **可选的「第 7 项」**。从 App 抓包得到的 `X-VIN` 头值；填了就用它，否则服务端自行 AES 加密 VIN |
| `ZEEKR_CA_SECRET` | ⬜ | GW1（`x_ca_*` 签名）的 App 内置常量，已有默认值；App 改版导致 `4010001` 时可覆盖 |
| `ZEEKR_TSP_PLATFORM` | ⬜ | 权限包接口的平台枚举，**默认 `5`**。非数字报 `000002`，`1/2/3` 报 `037021`，`4` 返回空数组 |
| `ZEEKR_HAOHAN_HOST` | ⬜ | 第三方充电网关地址，默认 `https://gateway-prod.haohanpower.tech` |
| `ZEEKR_HAOHAN_CHANNEL_ID` | ⬜ | 第三方充电网关渠道号，默认 `1`（逆向得到的常量，故配置化） |
| `TENCENT_MAP_KEY` | ⬜ | **车辆位置卡用**。腾讯位置服务 key（需开「逆地理编码」+「静态图」）。留空则只显示经纬度，不显示地址与地图。⚠️ 填了就意味着车坐标会发给腾讯 |
| `ALLOW_COMMANDS` | ⬜ | 车控总开关，**默认 `false`** |
| `API_TOKEN` | ⬜ | 服务端鉴权令牌；留空则不鉴权（见「常见问题」） |
| `DATA_SOURCE` | ⬜ | `auto`（默认）/ `mock` / `live` |
| `APP_HOST` / `APP_PORT` | ⬜ | 默认 `0.0.0.0` / `8765` |
| `APP_DEBUG` | ⬜ | 默认 `false` |
| `POLL_INTERVAL_IDLE` / `POLL_INTERVAL_CHARGING` | ⬜ | 默认 300 / 60 秒 |

`DATA_SOURCE=auto` 时的行为：密钥配置齐全走真实网关，否则**回落到 mock 并在日志里告警**。

> **登录手机号不需要写进 `.env`。** 它在客户端登录时输入
> （预览页 → 设置 → 账号与凭据），服务端既不保存也不依赖它 ——
> 换账号登录只需在界面上填另一个手机号，不必改配置、不必重启服务。
>
> 因此「密钥齐全」就等于「走真实网关」。想回到模拟数据（纯调 UI）时，
> 显式设 `DATA_SOURCE=mock` 即可。

### 第三步：编译 iOS App

**有 Mac：**

```bash
# 安装 XcodeGen（用于生成工程文件）
brew install xcodegen

# 生成 Xcode 工程
xcodegen generate

# 打开
open ZeekrDash.xcodeproj
```

1. 在 Xcode 中：**Signing & Capabilities** → 选择你的 Apple ID Team
2. 连接 iPhone，选择设备，点 **Run**
3. 手机端：**设置 → 通用 → VPN与设备管理** → 信任你的开发者证书

> `ZeekrDash.xcodeproj` 由 XcodeGen 从 `project.yml` 生成，**不入库**（见 `.gitignore`）。
> 没有 XcodeGen 时也可手动新建 iOS App 工程，把 `ZeekrDash/` 下的 `.swift` 拖进去。

**没有 Mac：** 用 GitHub Actions 借 `macos-26` runner 出**未签名 IPA**，再用
AltStore / SideStore / Sideloadly 自签安装。详见「构建与 CI」一节。

### 第四步：连接服务

打开 App → 设置 → 填入服务地址。

> ### ⚠️ 这里有个反直觉的坑，必须先看
>
> **填 `http://localhost:8765` 连不上服务端，只会看到内置模拟数据。**
>
> `ZeekrDash/Core/Network/EndpointMode.swift` 把下列 host 全部判定为
> **loopback → 直接使用 App 内置 MockData，完全不发网络请求**：
>
> ```
> localhost / 127.0.0.1 / 0.0.0.0 / ::1 / [::1]
> ```
>
> 而 `APIClient.defaultBaseURL` 恰好就是 `http://localhost:8765`，
> 所以**开箱状态就是演示模式**（顶栏会显示「模拟数据」徽标）。
>
> **要真正连上服务端，必须填非回环地址** —— 即使在同一台机器上，也要用局域网 IP：
>
> ```
> http://192.168.x.x:8765
> ```
>
> 真机还需要手机与电脑在同一 WiFi 下。

切到真实地址后，App 会自动重新探测并补启轮询；连不上时回落模拟数据并**弹框提示一次**
（顶栏徽标变成「模拟数据 · 后端不可达」）。

---

## 功能

| 模块 | 内容 | 状态 |
|---|---|---|
| **车况** | 电量环形图、续航、总里程、四轮胎压、门锁状态、充电状态 | ✅ |
| **车控** | 见下方「车控指令可信度」——**只有 8 条可下发真车** | ⚠️ 部分 |
| **行程** | 行程列表（时间/距离/能耗/起终点）、能耗趋势图（7/30/90 天） | ✅ |
| **充电** | 充入电量一张卡（按月筛选 + 月度趋势图 + 每次充电时长 + 直/交流电量）、逐笔记录 | ✅ |
| **附近充电站** | 按手机定位查附近站点：距离 / 空枪 / **当前电价** / 分时电价 / 一键导航 | ✅ |
| **设置** | 服务地址、API 令牌、车控总开关、权限包清单、连接诊断 | ✅ |
| **充电金额** | 极氪只给电量不给金额；**截图识别**（核对后入库）+ 手写录入 + 待确认配对 | ✅ |
| **金额配对** | 电量 ±5% 且时间 ±10 分钟自动绑定；配不上的进「待确认」，一条不丢 | ✅ |

> **附近充电站**的数据要**两跳、两套认证体系**才能凑齐：
> 极氪网关给坐标与枪数，**站名与价格却不在那里**（气泡接口 23 个字段里没有任何
> 价格数值）—— 它们来自极氪 App 内嵌的第三方（浩汉能源）SDK，由服务端按
> `stationId` 逐个预取后合并下发。
>
> 三条设计边界：① **取不到价格显示「--」，绝不显示 0**（把"没查到"画成"不要钱"
> 会被当真）；② 第三方挂了列表照常返回，只是没有价格；③ **坐标只发给极氪自己的
> 网关**，转给第三方的只有 `stationId` —— 第三方拿不到"你在哪"。

### ⚠️ 车控指令可信度

`server/app/adapters/zeekr_signing.py` 把指令按**是否有逆向依据**严格分成两类，
`COMMAND_MAP` 里共 18 条，但**「收录」不等于「可信」**：

**已验证 · 可下发真车（8 条）** —— serviceId 有公开逆向成果佐证：

| 指令 | serviceId |
|---|---|
| 锁车 / 解锁 | `RDL` / `RDU` |
| 开 / 关空调 | `ZAF` |
| 闪灯 / 鸣笛 | `RHL` |
| 开始 / 结束充电 | `RCS` |

**未验证 · live 模式一律拒绝（10 条）** —— serviceId 或参数是按缩写推断的，从未在真车验证：

```
前除霜 / 方向盘加热 / 座椅加热 / 座椅通风 / 遮阳帘 / 哨兵模式
关车窗 / 出行规划 / 寻车 / 立即刷新
```

> 注意后 4 条**复用了已验证的 serviceId，但参数值是推断的**
> （如 `closeWindows` 用 `RWS` + value `"close"`），所以同样不可信。
>
> 这些指令**只在 mock 模式放行**（便于联调 UI），live 模式由
> `is_verified_command()` 显式拦截。真车逐条验证通过后，把 serviceId 从
> `ServiceIDUnverified` 迁到 `ServiceID`，并从 `UNVERIFIED_COMMANDS` 移除。
>
> 安全理由：指令静默无效时用户会以为「锁了车其实没锁」，这本身就是安全问题。

---

## 充入电量（充电记录）怎么来的

**不需要你导任何账单。** 极氪账号本身就能拉到每一笔充电的电量、时长与交直流，
充电页打开就会自动同步一次（本地已有时则只在点「同步」时才回源）。

与官方 App「充电记录」页的数字逐月对得上。

### 数据源

```
POST https://snc-tsp-api.zeekrlife.com/ms-charge-manage/api/v2.0/charge/log/queryGroupMouth
body: {"startTimeStart": null, "chargeType": ""}
```

三个必踩的点（都在 `server/app/adapters/live_client.py` 里固化）：

- 除 GW3 签名头外，**必须带** `X-TENANT-ID: ZEEKR` 与 `X-VEHICLE-BRAND: ZEEKR`，缺一个就 `079001`
- `X-VIN` 必须传**加密后的** VIN（明文报 `079025 Decrypt X-VIN failed.`）
- 返回是按「年 → 月 → 记录」三层分组，一次给两年

### 口径

| 展示项 | 来源 | 说明 |
|---|---|---|
| 充入电量 | `sumPower` / 逐笔 `power` | 单位度（kWh），是**充进车里**的量 |
| 充电次数 | `count` | **含电量缺失的记录** —— 充了几次和充了多少度是两件事 |
| 直流 / 交流 | `chargeTypeName` | 映射成 `dc` / `ac`，上游偶尔给空名 |
| 平均充电功率 | 电量 ÷ 时长 | 比"充了多久"更能说明桩的快慢 |
| 金额 | **没有** | 见下 |

### 为什么金额要自己补

**车不知道电价。** 车端报文里没有任何 `fee/cost/amount/price` 叶子字段，
站点也不在充电记录里（这条链路只有电量）。

极氪 App 里的「补能订单」金额页，数据在第三方服务商（浩汉）的网关后面，
要浩汉自己的账号态，极氪 token 不通用 ⇒ **不可自动化**。

所以金额只有三条路，**都已实现**：

| 路子 | 怎么用 | 开关 |
|---|---|---|
| **截图识别**（主线） | 充电流水页 → 「截图识别」→ 选 App「补能订单」截图 → **核对后**入库 | 服务端 `.env` 填 `DEEPSEEK_API_KEY` |
| **手写录入**（零依赖） | 费用卡 → 「手写录入」→ 金额 + 时间即可 | 无需任何配置 |
| 电价估算（兜底） | 不落库、只展示，且单独计数 | `CHARGE_ESTIMATE_PRICE` |

识别结果**先弹核对框再入库**：金额 / 电量 / 时间 / 站点都能改，还能指定它属于哪次充电。
配不上的（零命中 / 多条候选）一条都不丢，停在「待确认」等你点一下。

在补录之前，费用卡会明确写「金额未记录」，**不显示任何估算数字** ——
把猜测画成"实际支出"比留空更糟。

> 隐私：截图只在内存里走一趟（→ base64 → 上游），不落盘、不进日志；
> 识别结果回传前会剔掉 VIN / 车牌 / 手机号 / 完整订单号（只留订单后四位）。

### 旧账单导入还在，但不再增强

`POST /api/charges/import` 与 `charge_records` 表保留原样（能用则用），
文件导入这条通道已确认放弃：微信给的是加密 ZIP、支付宝手机端给 PDF、
而且支付流水只有金额没有电量，本来就要靠配对补，等于两道工序。

---

## 预览页

服务端挂载了一个**单文件设计预览页** `preview/index.html`（约 155 KB），
用 Safari/浏览器打开即可，无需 Mac 也能先看界面与配色：

```
http://<服务地址>/preview
```

它复用**同一套后端接口**，是 iOS 原生版的「所见即所得」参照。

两个必须知道的行为：

1. **从预览页发的车控指令永远不会到服务端。** 预览页里 `DEMO = true`，
   `/api/vehicle/command` 被本地拦截并模拟 620ms 下发耗时后回执成功，
   只翻转本地状态用于预览动效。**端到端验车控只能靠 iOS 真机。**
2. 设了 `API_TOKEN` 时，用 `?token=<令牌>` 打开：
   `http://<服务地址>/preview?token=<令牌>`

> ⚠️ 预览页是**独立的第二份前端实现**（JS 重写了渲染、格式化、配色与 mock 数据），
> 它**不消费** `Theme.swift`。改配色时两边都要改。

---

## 常见问题

### 提示「The account is currently logged in elsewhere」

极氪 SNCTSP 网关**每个账号只保留一个会话**，新登录会顶掉旧令牌。

- 使用**独立子账号**并共享车辆 ← 推荐做法
- 服务端遇到 `079021` 会自动重新登录并重试一次

### 车控指令点了没反应

1. 检查 `.env` 里的 `ALLOW_COMMANDS=true`（默认关闭）
2. 确认 App 设置里的「允许下发控制指令」是开启的（**这是客户端的独立开关，两边都要开**）
3. **重要**：登录时填的手机号，必须和手机上能正常控车的账号**是同一个**
4. 若指令属于上表「未验证」的 10 条，live 模式下服务端会拒绝，这是**预期行为**

### 实时状态拿不到 / 077001 接口未被授权

GW3 登录用的是 `identityType=5` + GW1 的 JWT —— 这是**实测可用**的那一条
（车辆列表、车况、权限包都通）。另外务必检查 `X-VIN` 有没有带上：
`active_vin` 若没落盘，所有需要它的请求都会「裸奔」，表现为 404 / `079001`，
真实原因却是没告诉服务端是哪台车（现已修：车辆列表成功后即写入并持久化）。

服务端遇到 `079001` 时**不会重新登录** —— 误重登会作废自己正在用的令牌。
如果持续失败，多半是**账号与该车没有绑定控制权限**。

返回 `079025 Signature authentication failed` 则是签名串构造问题，服务端会打一条
指向具体排查点的 ERROR 日志。

### 服务端会不会被局域网里别人控制

会 —— 除非你设 `API_TOKEN`。

服务端默认监听 `0.0.0.0` 且不带鉴权，**开启车控后同一局域网内任何人都能直接
POST `/api/vehicle/command` 解锁你的车**。在 `.env` 里设一个令牌即可挡住：

```bash
# 生成一个
openssl rand -hex 24
# 写进 .env
API_TOKEN=<上面生成的值>
```

设完之后，除 `/api/health`（用于连接诊断）外的所有接口都要带令牌：

- **iOS App**：设置 → 服务端 → **API 令牌**，把同一个值填进去
- **浏览器预览页**：用 `http://<服务地址>/preview?token=<令牌>` 打开

不设 `API_TOKEN` 时行为与以前完全一致（不鉴权），方便本地联调。

> ⚠️ **已知问题**：`server/tests/test_hardening.py` 的 `test_disabled_by_default`
> 会断言 `config.api_token == ""`，而该单例会读取真实的 `.env`。
> 因此**在 `.env` 里设了 `API_TOKEN` 之后，这条测试会失败**。
> 也就是说「按本节加固安全」与「测试全绿」目前是互斥的，需要手工绕过或先修测试。

### 密钥会失效吗

会。极氪 App 升级可能改变密钥的存储方式或轮换密钥。

- 关注 [zeekr_key_extractor](https://github.com/wysie/zeekr_key_extractor) 的版本兼容表
- 失效后按第一步重新提取即可

---

## 构建与 CI

仓库只有**一条**流水线 —— GitHub Actions：

| 流水线 | 位置 | 运行环境 | 做什么 |
|---|---|---|---|
| GitHub Actions | `.github/workflows/build-ios.yml` | `macos-26` + Xcode 26 | `xcodegen generate` → `xcodebuild` 不签名编译 → 打包**未签名 IPA** 作为 artifact |

> 曾经还有一条 CNB 流水线（`.cnb.yml` + `ci/` 下的 Linux Swift 类型检查桩），
> 已在 2026-10 移除 —— 它只能做类型检查，而 GitHub 这条能真编出 IPA，
> 两条并存的维护成本不值得。

**借 GitHub 出未签名 IPA（没有 Mac 时的路径）：**

1. push 到 `main`，或到 GitHub 的 **Actions → Build iOS App (unsigned IPA) → Run workflow** 手动触发
2. 构建完成后在页面底部 **Artifacts** 下载 `ZeekrDash-unsigned-ipa`
3. 用 AltStore / SideStore / Sideloadly 自签后安装到 iPhone

> 自动触发带 **paths 过滤**：只有改动 `ZeekrDash/**`、`project.yml` 或工作流自身才会触发。
> **只改 `server/**` 不会触发 iOS 构建**，需要手动 `workflow_dispatch`。

**CI 的已知盲区**（改代码前请了解）：

- **服务端 215 个测试不在 CI 里** —— GitHub 这条只编 iOS，不跑 pytest。
  改了 `server/**` 请本地跑一遍 `python -m pytest tests -q`。
- **CI 只保证"能编译"**，不保证"跑起来对"：仓库内**没有 XCTest target**，
  iOS 端零自动化测试；真机行为只能人工验证。
- iOS 改动若在 Windows / Linux 上写，**本地无法验证编译** ——
  要么 push 后看 Actions，要么在有 Xcode 的机器上过一遍。

---

## 测试

服务端有一批**逐条对应历史缺陷**的回归测试，共 **215 个用例**：

```bash
cd server
pip install -r requirements.txt
pip install pytest          # ← requirements.txt 里没有声明 pytest，需单独装
python -m pytest -q
```

`server/tests/` 六个文件：

| 文件 | 覆盖什么 |
|---|---|
| `test_core.py` | 核心逻辑与签名 |
| `test_hardening.py` | 审计缺陷回归 |
| `test_bills.py` | 账单全链路 |
| `test_adapter_shape.py` | mock 与 live 适配器的**输出字段集合必须一致**（防字段漂移） |
| `test_stations.py` | 附近充电站：字段裁剪、降级语义、缓存网格 |
| `conftest.py` | 统一 `sys.path` 与测试客户端；**强制与本机 `.env` 隔离** |

> 注意：其中 8 个用例使用 `tempfile.mkdtemp()` 建临时 SQLite 库；
> 若运行环境限制新建子目录写入，它们会以
> `sqlite3.OperationalError: unable to open database file` 失败 —— 是环境问题，不是代码缺陷。

---

## 真机验证清单

**已验证的部分（2026-10-16 首次真车实测）**：GW3 签名、GW1 发码 / 登录、
GW3 登录与会话持久化、X-VIN、车辆列表、**车况字段映射**、权限包接口。
也就是说「读到真实车况」这条链路是通的。

**仍未验证的部分**：**车控指令一条都没在真车上试过**（8 条已验证 serviceId 的
也只是"有逆向依据"，不等于"车会动"）；车窗语义、充电功率量纲等少数字段待确认。

所有必须在真车上逐条核对的项目都列在：

```
docs/真机验证清单.md
```

按风险从高到低排序，**建议严格按序执行** —— 前面不通过，后面没有意义。

> 特别提醒：车控指令返回「已提交」只代表网关收下，**不代表车端已执行**。
> 验证时必须以**车实际动作**为准，不能只看接口返回。

---

## 官方接口情报与 APK 工具

> **本项目的接口路径、请求头、字段名，一律以官方原版极氪 App 实际发出的 HTTP 请求为唯一权威。**
> 社区逆向实现只作旁证。所有取证结论**已经固化进仓库，不需要重复逆向**。

### 已固化的产物

| 文件 | 内容 |
|---|---|
| **[`AGENTS.md`](AGENTS.md)** | 给 AI 编码助手的须知（铁律、工具用法、环境坑） |
| `docs/zeekr-apk-reference.md` | 人读的接口与字段目录（网关主机、按服务分组的路径、请求头、能力标志、**字段名 ↔ ZeekrDash 归一化键对照表**） |
| `docs/zeekr-apk-intel.json` | 机器可读的原始情报（不丢数据） |
| `scripts/apk_intel.py` | 一条命令重新提取 / 渲染 / **对比历史版本**（纯标准库） |
| `scripts/extract_keys.py` | 从 APK 提取 6 个网关密钥（见「第一步」） |

**取证方式**：官方 App 已加固（包内含 `libconch.so` 31 MB、`libHHSecurity.so` 等），
JADX 加载后**只能解析出 23 个类 —— 类级反编译不可用**。但 DEX 的**字符串表是明文可读的**，
所以「某条路径/某个字段是否存在」是可判定命题，脚本据此提取，加固不影响结论。
边界说明见参考文档开头的「取证边界」一节。

### 重新提取

```bash
python scripts/apk_intel.py <apk路径>          # 重新生成上面两个文件
python scripts/apk_intel.py <apk路径> --json-only   # 只要 JSON
```

### 官方 App 更新后怎么验证

```bash
python scripts/apk_intel.py <新版.apk> --compare docs/zeekr-apk-intel.json
```

产出 `docs/zeekr-apk-diff.md`，重点看**第一节「契约回归」**：
它逐条检查本项目**正在使用**的路径与字段（脚本里的 `CONTRACT_PATHS` /
`CONTRACT_FIELDS`，与 `server/app/adapters/live_client.py` 一一对应）在新版本里是否还在。

- **契约项消失 = 破坏性变更** → 脚本以**退出码 1** 结束（方便 CI 拦截）。
  正确做法是按参考文档找到官方新名字、改 `live_client.py`，
  **而不是删掉那一行** —— 那等于功能静默失效。
- 无破坏性变更 → 报告末尾会给出替换快照的命令。

新快照另存为 `zeekr-apk-intel-new.json`，**不覆盖**基准文件，人工确认后再手动替换。

> 设计取舍：只有"契约项消失"才算阻断级。每次 App 更新都会带来成百上千条无关字符串，
> 把噪声当风险会让这个检查失去意义。
>
> 顺带一提：刚写好契约清单时，用**同一个 APK 与自己对比**就能发现清单里写错的项
> （正常应全绿）。这是校验契约真实性的最简办法。

---

## 项目结构

```
zeekr-controller/
├── AGENTS.md                   # 给 AI 编码助手的须知（铁律 / 工具用法 / 环境坑）
├── ZeekrDash/                  # iOS App（SwiftUI，零第三方依赖）
│   ├── App/                    # 入口与根视图（RootView 含 Tab 壳与玻璃导航）
│   ├── Core/
│   │   ├── Models/             # 数据模型（双端契约）
│   │   ├── Network/            # APIClient / APIRoutes / EndpointMode
│   │   ├── Store/              # AppStore（车况+轮询+指令）、SettingsStore
│   │   ├── Theme/              # 中国传统色设计系统
│   │   ├── Mock/               # 内置演示数据（localhost 时使用）
│   │   └── Components/         # 复用组件
│   └── Features/               # 功能页
│       ├── Dashboard/          # 车况
│       ├── Trips/              # 行程
│       ├── Charges/            # 充电
│       ├── Controls/           # 车控（15 按钮面板）
│       └── Settings/           # 设置
│
├── server/                     # 服务端（FastAPI）
│   ├── app/
│   │   ├── adapters/           # 极氪网关适配层 + 签名（zeekr_signing.py）
│   │   │                       #   haohan.py = 第三方充电网关（价格来源）
│   │   ├── api/                # 接口路由（stations.py = 附近充电站）
│   │   ├── bills/              # 账单解析与归集
│   │   └── core/               # 配置与 SQLite 存储
│   ├── tests/                  # 215 个回归测试
│   └── requirements.txt
│
├── preview/
│   └── index.html              # 单文件设计预览页 + 调试台（**功能改动的唯一落点**）
├── docs/
│   ├── zeekr-apk-reference.md  # 官方接口情报（人读；**先查这里，别重新逆向**）
│   ├── zeekr-apk-intel.json    # 官方接口情报（机器可读）
│   └── 真机验证清单.md          # 真机逐条核对清单
├── scripts/
│   ├── server.sh               # 服务管理脚本（Linux / macOS / Git Bash）
│   ├── server.cmd              # 同上，Windows 版（**纯 ASCII + CRLF**）
│   ├── logs_tail.py            # 日志实时跟随（Windows 下给 server.cmd 用）
│   ├── apk_intel.py            # APK 接口情报提取 / 渲染 / 版本对比
│   └── extract_keys.py         # 从 APK 提取 6 个网关密钥
│
├── .github/workflows/build-ios.yml
├── project.yml                 # XcodeGen 工程描述
└── .env.example                # 环境变量模板
```

---

## 设计说明

### 配色

采用**中国传统色**体系（参考 [zhongguose.com](https://zhongguose.com/)）。

iOS 端的**唯一真相源是 `ZeekrDash/Core/Theme/Theme.swift`** —— 下表是浅色模式的取值，
深色模式由 `Theme.*(_:)` 按 `ColorScheme` 另行取值（背景 `#14171C`、卡片 `#1E2228`
等）。改配色请改 Theme.swift，不要只改这张表。

> ⚠️ 但 `preview/index.html` 是**独立的第二份实现**，自带一套配色常量、
> **不消费 Theme.swift**。改配色时两边都要改。

| 用途 | 色名 | 色值 |
|---|---|---|
| 主色 | 天青 | `#2E8BC0` |
| 主色（深） | 天青·深 | `#1C6FA8` |
| 强调 | 藤黄 | `#FFB020` |
| 告警 / 失败 | 朱砂 | `#E5483B` |
| 充电 | 靛青 | `#1E7FC2` |
| 正常 / 成功 | 青碧 | `#16B89A` |
| 车控「开启中」 | 珊瑚 | `#FA9894`（浅色模式加深为 `#C9483F`） |
| 背景 | 月白 | `#F3F5F7` |
| 卡片 | 象牙白 | `#FFFFFF` |
| 卡片次级 / 冷灰 | 缟色 | `#EDF1F4` |
| 正文 | 墨 | `#1B1F24` |

> 珊瑚的浅色模式为什么用加深版：本源色 `#FA9894` 在浅玻璃底上对比度只有 1.91，
> 图标线条会发飘；加深到 `#C9483F` 后为 4.25。深色模式下本源色本身是 6.68，直接用。

### 性能取舍

- iOS 端**零第三方依赖**，图表用系统 Swift Charts
- 服务端 SQLite 单文件，无外部数据库
- 轮询自适应：充电中 60 秒，空闲 5 分钟。**两端写死、不做设置项** ——
  网页 `schedulePoll()` 与 iOS `AppStore.currentInterval()` 用同一套数值，
  免得出现"网页 5 分钟、App 20 分钟"这种没法解释的差异
- 状态快照两道防膨胀：距上条不足 60 秒且 SOC/续航/里程都没变则丢弃；
  每辆车只保留最近 2000 条（实测 17280 行/天 → 144 行/天）
- 行程列表有 300 秒 TTL 缓存，网关失败时**降级返回旧缓存**而不是空结果

### 数据来源三态

App 顶栏徽标反映当前数据来源：

| 模式 | 徽标 | 触发条件 |
|---|---|---|
| `mock` | **模拟数据** | 地址为空，或指向 loopback（localhost 等） |
| `live` | 无 | 配置了非回环地址且请求成功 |
| `offline` | **模拟数据 · 后端不可达** | 配置了非回环地址但连不上，已回落模拟数据并弹框提示一次 |

---

## 许可

MIT

本项目与极氪、吉利、ECARX 无任何关联。使用者需自行承担合规与账号风险。
