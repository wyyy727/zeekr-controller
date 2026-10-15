# AGENTS.md — 给 AI 编码助手的项目须知

> 本文件面向在此仓库工作的所有 AI agent（Claude Code / Codex / Cursor / Copilot / WorkBuddy 等）。
> 人类读者请直接看 [`README.md`](README.md)。

## 项目一句话

极氪 001 车主自建的车控看板：**iOS App（SwiftUI） + Python 后端（FastAPI）**，
绕开臃肿的官方 App，直连极氪国区网关，补齐能耗统计 / 行程历史 / 充电账单归集。

---

## ⚠️ 两条铁律

### 铁律一：接口与字段，一律以官方 APK 为唯一权威

- 官方原版极氪 App **实际发出的 HTTP 请求**（host / path / 请求头 / 字段名）是**唯一**权威来源。
- 社区逆向实现（`zeekr_ev_api`、`openzeekr`、`zeekr_ha` 等）**只作旁证，不作结论**。
- 不采信"按服务名猜"的路径。
- 取证结论已固化在 `docs/zeekr-apk-reference.md` —— **先查它，不要重新逆向**。

### 铁律二：改动纪律

| 改动类型 | 怎么改 |
|---|---|
| **功能 / UI 类** | **先只改 `preview/index.html`**（用户在 Windows 上没 Mac，靠预览页看效果）。**iOS 与后端代码必须等用户明确确认后再动。** |
| **接口路径 / 字段名纠错** | 属于修复而非新功能，**可直接改后端**（`server/app/adapters/live_client.py`） |
| iOS 小组件（Widget） | **一律不做** —— 用户明确表示不需要臃肿功能 |

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
| 起后端 | `./scripts/server.sh start` / `logs` / `status` / `stop` |
| 跑测试 | `cd server && .venv/Scripts/python.exe -m pytest tests -q` |
| APK 分析（有 capstone） | `C:\Users\Administrator\.workbuddy\binaries\python\envs\zeekr\Scripts\python.exe` |
| 可用 JDK（21） | `D:\develop\jdk21\jdk-21.0.9`（**全局 `JAVA_HOME` 指向 Java 11，不够用，别改全局**） |

**已知环境坑**：

- `git clone` GitHub 会因证书吊销检查失败 → 用 `git -c http.schannelCheckRevoke=false clone ...`，或走镜像。
- 下载大文件优先用 `gh-proxy.com`；`ghproxy.net` 会**静默截断**（HTTP 200 但文件不完整）。
- 服务端默认**模拟数据模式**（`.env` 里 `ZEEKR_PHONE` 为空时）→ 前端调试不依赖真实网关。

---

## 📁 关键文件

| 路径 | 作用 |
|---|---|
| `server/app/adapters/live_client.py` | 极氪网关对接**全部实现**（路径、字段解析、车控、能力集） |
| `server/app/adapters/zeekr_signing.py` | 三网关签名（SHA1 / HMAC-SHA1 / HMAC-SHA256+AES-128-CBC） |
| `server/app/adapters/mock_client.py` | 模拟数据（字段形状必须与 live 保持一致 —— 有测试守着） |
| `server/tests/test_adapter_shape.py` | 防漂移：两个适配器输出形状必须一致 |
| `preview/index.html` | **单文件设计预览页**（功能改动的唯一落点） |
| `preview/debug.html` | 预览页的调试副本，可连本机/远程后端看接口响应 |
| `docs/zeekr-apk-reference.md` | 官方接口情报（**先查这里**） |
| `docs/真机验证清单.md` | 真车逐条核对清单 |

---

## ❗ 三个容易搞错的认知

1. **车控返回「已提交」≠ 车端已执行。** 网关收下只代表请求被受理。
   要确认真执行，必须查 `queryProcessResult`，或以**车实际动作**为准。
2. **后端不能去掉。** iOS 无法常驻后台轮询（BGTaskScheduler 不可靠、低电量模式直接禁用），
   而"打开就看见最新车况"依赖服务端轮询。密钥也不该落到客户端。
3. **`preview/index.html` 与 `preview/debug.html` 是两份文件**，
   后者是前者的副本 + 调试层，**改前者不会自动同步后者**。

---

本仓库仅为个人自用学习，与极氪 / 吉利 / ECARX 无任何关联。
密钥、`.env`、会话文件一律不入库（见 `.gitignore`）。
