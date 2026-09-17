# ZeekrDash · 极氪车主自建看板

为 **2026 款焕新极氪 001** 车主打造的 iOS 原生应用 + 本地服务端。

弥补官方 App 在**行程记录**、**能耗统计**、**跨服务商充电消费汇总**上的缺失。

---

## 一、项目构成

```
zeekr-dashboard/
├── ZeekrDash/          # iOS 原生应用（SwiftUI）
│   ├── App/            #   入口与根视图
│   ├── Core/
│   │   ├── Models/     #   数据模型（双端契约）
│   │   ├── Network/    #   网络层
│   │   ├── Store/      #   状态管理
│   │   ├── Theme/      #   中国传统色设计系统
│   │   └── Components/ #   复用组件
│   └── Features/       #   功能页（车况/行程/充电/设置）
│
└── server/             # 本地服务端（Python + FastAPI）
    └── app/
        ├── adapters/   #   极氪国区接入层（三网关签名）
        ├── bills/      #   账单解析与服务商识别
        ├── api/        #   REST 接口
        └── core/       #   配置与存储
```

### 为什么需要服务端？

极氪的密钥提取工具链**依赖安卓 APK 逆向**（要用 ADB 从安卓设备拉取 APK，提取 HMAC 密钥与 AES 密钥）。iOS 端无法完成这一步。

因此架构设计为：

> **Python 服务端负责国区登录与数据采集 → iOS App 作为客户端消费数据**

服务端可运行在 Mac 或家中常开设备（NAS / 树莓派等）。

---

## 二、快速开始

### 2.1 启动服务端

```bash
cd server
pip install -r requirements.txt

# 无凭据也能跑：自动进入模拟数据模式
python -m uvicorn app.main:app --host 0.0.0.0 --port 8765
```

访问 <http://localhost:8765/docs> 查看接口文档。

### 2.2 接入真实车辆数据

需要先从**安卓设备**提取 6 个密钥：

```bash
# 1. 拉取极氪 App 的 APK
adb shell pm path com.zeekr.app
adb pull <base.apk 路径> zeekr_base.apk
adb pull <split_config.arm64_v8a.apk 路径> zeekr_arm64.apk

# 2. 用社区工具提取（--region CN）
python zeekr_extract_secrets.py zeekr_base.apk zeekr_arm64.apk --region CN
```

> 提取工具：[wysie/zeekr_key_extractor](https://github.com/wysie/zeekr_key_extractor)

然后把密钥写入环境变量：

```bash
export ZEEKR_PHONE=13800138000
export ZEEKR_HMAC_ACCESS_KEY="..."
export ZEEKR_HMAC_SECRET_KEY="..."
export ZEEKR_PASSWORD_PUBLIC_KEY="..."
export ZEEKR_PROD_SECRET="..."
export ZEEKR_VIN_KEY="..."
export ZEEKR_VIN_IV="..."

# 车控指令总开关（默认关闭，只读模式）
export ALLOW_COMMANDS=true

python -m uvicorn app.main:app --host 0.0.0.0 --port 8765
```

服务启动后，在 iOS App 的「设置」里输入手机号，收短信验证码即可完成登录。

### 2.3 运行 iOS App

```bash
open ZeekrDash.xcodeproj
```

用 Xcode 自签安装到自己的 iPhone：

1. 在 Xcode 中登录 Apple ID（免费账号即可）
2. 修改 Bundle Identifier 为唯一值
3. 选择自己的设备作为运行目标，点运行
4. 首次运行需在 iPhone「设置 → 通用 → VPN与设备管理」中信任开发者证书

> **免费账号签名的有效期是 7 天**，到期后需重新运行一次 Xcode 签名。

---

## 三、功能一览

| 模块 | 能力 |
|---|---|
| **车况** | 电量环形进度、续航、总里程、四轮胎压、门窗状态、充电状态（功率/预计充满）、快捷车控 |
| **行程** | 行程列表（时间/距离/能耗/起终点）、能耗趋势图（7/30/90 天） |
| **充电** | 跨服务商消费汇总、按服务商/月份统计图、消费明细、账单导入 |
| **设置** | 服务端地址、极氪账号登录、轮询间隔、车控总开关、连接诊断 |

### 充电消费汇总怎么用

1. 从**支付宝**导出账单：`我的 → 账单 → 开具交易流水证明 → 个人对账`（CSV 格式）
2. 从**微信**导出账单：`我 → 服务 → 钱包 → 账单 → 常见问题 → 下载账单`（Excel/CSV 格式）
3. 在 App「充电」页点导入，选择导出的文件

系统会自动识别充电消费并按服务商归类，跨平台去重。

> **注意**：微信账单单次最多导出 **90 天**，历史数据需分批导出后依次导入。

---

## 四、数据源与容错

服务端有两种数据源，自动切换：

| 数据源 | 触发条件 | 用途 |
|---|---|---|
| `MockZeekrClient` | 未配置密钥 / 显式指定 | 演示 UI、联调、测试 |
| `LiveZeekrClient` | 密钥配置齐全 | 真实车辆数据 |

可强制指定：`export DATA_SOURCE=mock`（或 `live`）。

### 极氪国区三网关

| 网关 | 地址 | 签名 | 用途 |
|---|---|---|---|
| GW1 | `api-gw-toc.zeekrlife.com` | SHA1 排序签名 | 短信验证码、手机号登录 |
| GW2 | `api.zeekrline.com` | HMAC-SHA1 | 车辆列表、状态（回退通道） |
| GW3 | `snc-tsp-api.zeekrlife.com` | HMAC-SHA256 + AES 加密 VIN | 最新状态、远程控制 |

读取优先走 GW3，被拒（`079001`）自动回退 GW2。

---

## 五、重要提示

### 账号安全

> **请使用独立的极氪子账号并共享车辆，不要用主账号。**

极氪每个账号**只保留一个会话**，任何新登录都会让上一个令牌失效。用主账号会导致手机 App 被挤下线。

### 合规声明

- 本项目基于**社区公开的逆向研究成果**，与极氪 / 吉利**无任何关联**
- 逆向 APK 在部分司法辖区可能受法律限制，**请自行评估**
- 仅供**个人自用学习**，不得用于商业用途或访问他人车辆
- 车辆远程控制存在风险，请确保在安全场景下使用

### 已知限制

- 部分车型的 GW3 接口需要额外提供 `X-VIN` 令牌（从 App 抓包获取）
- 极氪 App 升级可能导致密钥失效，需重新提取
- 行程数据依赖网关支持，部分车型/固件可能返回空

---

## 六、技术栈

| 端 | 技术 |
|---|---|
| iOS | SwiftUI、Swift Charts、async/await、iOS 17+ |
| 服务端 | Python 3.11+、FastAPI、httpx、pycryptodome |
| 存储 | SQLite |

**设计原则**：零第三方前端依赖，代码精简，启动快速。

---

## 七、参考项目

- [RexzeLu/zeekr_ha](https://github.com/RexzeLu/zeekr_ha) — 国区 +86 短信登录方案（本项目主要参考）
- [Fryyyyy/zeekr_ev_api](https://github.com/Fryyyyy/zeekr_ev_api) — Python API 库
- [wysie/zeekr_key_extractor](https://github.com/wysie/zeekr_key_extractor) — 密钥提取工具
- [solderer-de/ioBroker.zeekr](https://github.com/solderer-de/ioBroker.zeekr) — 能源成本模型参考
- [borconi/openzeekr](https://github.com/openzeekr/borconi) — 命令 ID 逆向研究

## 许可

MIT
