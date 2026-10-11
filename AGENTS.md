# AGENTS.md

指引给 AI agent(及开发者):如何理解、构建、改动 Threadly。

## 这是什么

Threadly 是 Racket 社区论坛(racket.discourse.group,Discourse 架构)的
原生客户端:浏览最新主题、读长帖、全文搜索。论坛是 Racket 语言设计讨论
与生态动态的主场,Threadly 给它一个配得上内容质量的阅读器。**全平台
产品,与 Taskly 同标:桌面三平台(macOS/Windows/Linux)先行,移动端
iOS/iPadOS/Android 后期必须落地。**技术形态遵循
[Rivet](https://github.com/turinglambdaai/rivet) 线:**Racket 引擎 +
各平台第一方原生 UI**。产品灵魂是**阅读体验**——壳的每一像素都要按这个
标准做(对标线见 fulcrum 的 Raycast 对标)。

| 层 | 技术 | 目录 | 状态 |
|---|---|---|---|
| 引擎(Discourse API/缓存) | Racket 9.3 | `app/` | ✅ fixture 测试全绿 |
| CLI | Racket | `app/cli.rkt` | ✅ latest/topic/search/categories/doctor |
| macOS 壳 | SwiftUI | `macos-host/` | ✅ 首片 |
| Windows/Linux 壳 | WinUI 3 / GTK4 | (待建) | M1 |
| Android 壳 | Kotlin(Rivet `platform/android`,Kotlin codegen 已就绪) | (待建) | M4 |
| iOS/iPadOS 壳 | SwiftUI(Rivet portable Swift 层已跨编译,等其移动交付链 Phase 8) | (待建) | M4 |

## 硬边界(本仓库存在的合法性根基,任何改动不得越过)

1. **只读优先,凭据零入库**:当前只用匿名公开 JSON API;登录写操作
   (Discourse user API key 流)是独立里程碑,任何 token/cookie/密码不得
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
pin、开发跟最新。

**颜值第一生产力(用户 2026-10-11 定调)**:界面必须优雅美观,按苹果的
设计做。壳相关改动的完成定义=亮暗双模式实机截图验收;不达标的 UI 等于
没做。图标改版走 `scripts/make-icons.py`,禁止手改生成物。

## 版本与发布

- VERSION == rivet.rktd version == app/version.rkt,由
  `scripts/check-release-version.sh` 三方校验,CI 跑。
- CHANGELOG 是 Keep-a-Changelog 风格;发版前 `## x.y.z` 段必须先写。
- 新产品走 0.x 纪元,首发 0.1.0。
- 发布管线:macOS DMG(arm64/x64)+ 签名 update feed
  (`scripts/make-update-manifest.sh`,密钥经 `scripts/update-keys.sh`
  生成后进 Sync/Keys + GitHub Secret `UPDATE_ED25519_PRIVATE_KEY`)。
- Windows/Linux 壳落地后再扩 release 管线(家族标杆:deb+rpm+AppImage+
  Flatpak+tar.gz,参照 podlens release.yml)。

## 坑(已踩过)

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
