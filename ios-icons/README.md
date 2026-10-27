# ios-icons/

**图标资产的正式位置已经搬到 `ZeekrDash/Resources/Icons.xcassets`。**

搬走的原因（踩过的坑）：`project.yml` 里 target 的 `sources` 只有 `ZeekrDash/`，
CI 是 `xcodegen generate` 现场生成工程（`ZeekrDash.xcodeproj` 不入库），
所以放在仓库根的 `ios-icons/` **根本不会被编进 App** —— actool 不报错，装到手机上
才发现 `Image("ctrl-lock")` 全是空白。

这个目录现在只留「来源与校验记录」，不参与构建：

| 文件 | 作用 |
|---|---|
| `convert-report.json` | 28 个 imageset 的逐条转换记录（尺寸、渲染意图、做了哪些修正） |
| `preview.png` | 三档底色（`#1B2233` / `#6742E8` / `#FFFFFF`）渲染对照图，用于和 HTML 版比对 |
| `_unused/switch-track.svg` | v2 里未被引用的废弃件（设置开关是 CSS `.v2-set-sw` 画的，iOS 用原生 `Toggle`） |

源 SVG 仍在 `preview/icons/`（网页侧唯一来源）；改图标请改那边，然后重新走一遍
「currentColor → 具体色 + template、transform flatten、circle/ellipse/rect → path」，
再同步到 `ZeekrDash/Resources/Icons.xcassets`。
