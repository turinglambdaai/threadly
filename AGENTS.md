# AGENTS.md

指引给 AI agent(及开发者):如何理解、构建、改动 Threadly。

## 这是什么

Threadly 是 Racket 社区论坛(racket.discourse.group,Discourse 架构)的
原生客户端:浏览最新主题、读长帖、全文搜索。论坛是 Racket 语言设计讨论
与生态动态的主场,Threadly 给它一个配得上内容质量的阅读器。**全平台
产品,与 Taskly 同标:桌面三平台(macOS/Windows/Linux)为当前维护范围；移动端
iOS/iPadOS/Android 只保留按需求评估的方向，不是当前交付承诺。**技术形态遵循
[Rivet](https://github.com/turinglambdaai/rivet) 线:**Racket 引擎 +
各平台第一方原生 UI**。产品灵魂是**阅读体验**——壳的每一像素都要按这个
标准做(对标线见 fulcrum 的 Raycast 对标)。

| 层 | 技术 | 目录 | 状态 |
|---|---|---|---|
| 引擎(Discourse API/缓存) | Racket 9.3 | `app/` | ✅ fixture 测试全绿 |
| CLI | Racket | `app/cli.rkt` | ✅ latest/topic/search/categories/doctor |
| macOS 壳 | SwiftUI | `macos-host/` | ✅ 首片 |
| Windows/Linux 壳 | WinUI 3 / GTK4+WebKitGTK | `windows/` `linux/` | ✅ M1(CI 编译门+launch smoke) |
| Android 壳 | Kotlin(Rivet `platform/android`,Kotlin codegen 已就绪) | (待建) | M4 |
| iOS/iPadOS 壳 | SwiftUI(Rivet portable Swift 层已跨编译,等其移动交付链 Phase 8) | (待建) | M4 |
| watchOS 伴机 | SwiftUI + rivet WatchConnectivity typed companion(表端不嵌引擎) | (待建) | M4 尾段:依赖 iOS 宿主与 M2 登录态,通知伴机形态 |

## 硬边界(本仓库存在的合法性根基,任何改动不得越过)

1. **只读优先,凭据零入库**:匿名浏览使用公开 JSON API；登录写操作
   使用已实现的 Discourse user API key 流,任何 token/cookie/密码不得
   写进仓库或进序列化日志。
2. **做好公民**:只打公开端点;所有响应走磁盘缓存(默认 TTL 300s);
   请求带身份标识 UA;429 必须如实上抛退避,禁止批量爬取(翻页有上限)。
3. **论坛是唯一事实源**:本地只缓存不 fork;编辑/删除/挪版以论坛为准;
   保留作者与原链,不做误导内容归属的转换。
4. **内容礼貌**:引擎不得绕过 Discourse 的 rate limit,不得解析登录墙
   后的内容。

## 架构速览

| 模块 | 文件 | 说明 |
|---|---|---|
| HTTP | `app/core/http.rkt` | net/http-client 之上;手动跟重定向(≤5 跳,每跳保留 UA) |
| Discourse API | `app/core/discourse.rkt` | fetch×4 + parse×4;parse 是纯函数,fixture 驱动测试,CI 无网络 |
| 缓存 | `app/core/cache.rkt` | JSON 文件缓存 + TTL,键=URL sha1;断网时过期缓存仍可用(标注 cached) |
| 路径 | `app/core/paths.rkt` | `$THREADLY_DATA_DIR` 覆盖 > 平台缓存目录;测试用 `current-data-dir` 参数注入 |
| RVT1 面 | `app/backend.rkt` | 壳的唯一接口;行=定位字符串(Fulcrum 风格),布局见文件头注释 |
| CLI | `app/cli.rkt` | version/latest/topic/search/categories/doctor;doctor 离线 |

## 快速命令

```bash
raco test tests/                 # 必须全绿
racket app/cli.rkt latest        # 冒烟(需网络;CI 冒烟只用 version/doctor)
racket app/cli.rkt doctor
raco rivet build                 # 生成 GeneratedBackend.swift + 构建壳
```

Rivet 工作约定:开发前 pull `~/Codes/rivet`,pull 后清 `compiled/` 再
`raco setup`;生成 GeneratedBackend.swift 前核对 rivet pin;发布构建切
pin、开发跟最新。图标改版走 `scripts/make-icons.py`,禁止手改生成物。

## 版本与发布

- **发版以 taskly v0.1.2 实际资产为家族标杆**,已有平台范围逐项对齐:
  macOS arm64/x64 各 dmg+zip(更新载荷)且每件带 `.sha256` sidecar,汇总
  `SHA256SUMS`,加单一签名 feed `update-manifest.json`;Windows/Linux
  宿主落地后按标杆补 msi+zip 与 deb+rpm+AppImage+tar.gz+zip 全矩阵。
- 发版前必实测产物(下载 dmg/安装、启动、读帖)。
- VERSION == rivet.rktd version == app/version.rkt,由
  `scripts/check-release-version.sh` 三方校验,CI 跑。
- CHANGELOG 是 Keep-a-Changelog 风格;发版前 `## x.y.z` 段必须先写,
  release 由此产 validate 门拦截。
- 新产品走 0.x 纪元,首发 0.1.0。
- 更新签名:Ed25519,`RIVET_UPDATE_KEY_ID=threadly-2026-10`;私钥三处
  就位(Sync/Keys `secrets.ini` [threadly] 节 + GitHub Secret
  `UPDATE_ED25519_PRIVATE_KEY` PEM 形态;散件即到即收立删)。轮换规则见
  Sync/Keys/AGENTS.md。
- 产品主页 `site/` → threadly.jrtx.site(Pages workflow 部署,Pages 已
  启用 workflow 构建型;DNS CNAME 记录由用户添加)。产品站采用家族静态
  站点约定:双语 i18n 默认中文、共享暖色变量+完整暗色主题、零依赖、系统
  字体栈(家族规范:禁 Google Fonts)。

## 坑(已踩过)

- **Racket read-json 把 JSON null 解析成 'null 符号**,而 `hash-ref` 的
  默认值只在键缺失时生效——可选字段(如 last_posted_at)必须过
  `json-clean`('null→#f),否则 'null 混进 RPC 行直接炸
  `(List (List String))` 契约;本地 fixture 不含 null 行时不暴露,
  真机分类页才炸。
- **壳的观察断链**:`@EnvironmentObject model` + `model.store.*` 时,store
  的 `@Published` 变化不触发视图重渲染(PodLens 同款隐患)。必须
  `.environmentObject(model.store)` 单独注入,视图直接声明
  `@EnvironmentObject store`。
- **`raco rivet build` 缓存(上游 #129 同款)**:改 Swift 后
  `raco rivet package` 可能不重编壳、打包出旧二进制。验收/发版前先
  `raco rivet clean` 再 package;拿 `strings` 核对新符号真在二进制里。
- **WKWebView 亮暗跟随**:prefers-color-scheme 读的是
  `NSApp.effectiveAppearance`,`preferredColorScheme` 在 macOS 不可靠;
  亮暗双验证用 `THREADLY_APPEARANCE=dark|light` 环境变量(勿改用户全局
  系统外观)。
- **GUI 自动化**:cliclick 点击前必须先 AXRaise + frontmost,否则点到
  前台窗口;截被遮挡窗口用 `screencapture -l <CGWindowID>`
  (CGWindowListCopyWindowInfo 查 id)。
- **WinUI 3 的 WebView2 控件在 Windows App SDK 里**
  (`Microsoft.UI.Xaml.Controls.WebView2`,XAML 默认命名空间直接写
  `<WebView2>`);`Microsoft.Web.WebView2` NuGet 只提供 CoreWebView2 与
  loader,没有 XAML 控件也没有 winrt 投影头——pch 不要 include 它。
  控件用代码创建并 try/catch:缺 loader/运行时只降级阅读器,不能炸壳。
- **GTK4 的 WebKitGTK 是 `webkitgtk-6.0`**(pkg-config 名、apt 包
  `libwebkitgtk-6.0-dev`);`webkit2gtk-4.1` 是 GTK3+libsoup3,别碰。
  伞头文件是小写 `#include <webkit/webkit.h>`。
- **Linux CI 的 embed Racket**(setup-embed-racket 产出的 minimal)不带
  `raco make`(compiler-lib)和 `raco ctool`(cext-lib),`raco rivet
  build` 前要 `raco pkg install --auto --no-docs compiler-lib cext-lib`;
  Linux CMake 经 `add_subdirectory` + `rivet::platform` 消费 Rivet 平台
  库(rivet#238),仓里不再手抄 Rivet 源清单;WebKitGTK 由宿主自己链
  (`webkitgtk-6.0` PkgConfig::WEBKIT)。
- **本机 git 突然报 Xcode license**(Xcode/CLT 后台升级后 `/usr/bin/git`
  被挡,exit 69):临时用
  `/Applications/Xcode.app/Contents/Developer/usr/bin/git`,根治需要用户
  跑 `sudo xcodebuild -license accept`(agent 无 sudo)。

## 组合定位（Portfolio placement）

- 当前决策（2026-10-v2）：免费社区工具；保活。具体价格、免费/付费边界和开卖门禁以本仓 [PRICING.md](PRICING.md) 为唯一权威；旧版收费候选与早鸟方案已被替代。
- 组合归属：[PORTFOLIO](https://github.com/turinglambdaai/turinglambdaai.github.io/blob/master/PORTFOLIO.md)。当前全部产品开发中、没有实际用户；目标定价不表示已经开卖，不因此立即给开发版加收费墙。
- 免费产品不接商业激活；付费层先实现可验证价值，再接 Commerce/Permit。优先完成本仓既有产品审查 issue；不修改现行源码 LICENSE。

## 产品交付与下一步（2026-10-23）

- 家族[交付标准](https://github.com/turinglambdaai/turinglambdaai.github.io/blob/master/docs/PRODUCT-STANDARD.md)与[组合策略](https://github.com/turinglambdaai/turinglambdaai.github.io/blob/master/PORTFOLIO.md)是共用政策；本仓具体行为以 `README.md` 为准，不复制五库依赖图。
- 当前执行入口：[产品审查 issue](https://github.com/turinglambdaai/threadly/issues/1)。维护模式：先对齐登录/回帖/AI 与密钥存储的真实状态，补最小 packaged 阅读/搜索/反馈证据。移动端仅在实际需求与维护能力具备后评估。
- 开工先检查干净工作树与远端，以 fast-forward-only 更新并记录 SHA；共享文件一次一个写入者，保留其他 checkout 的未提交工作。
- 每次只完成一个可验收切片，记录 owned files、依赖 pin、命令/平台/产物证据和回滚。已实现、已发布、实机验收分别陈述；不修改 requirements 或复用旧证据来制造通过。
