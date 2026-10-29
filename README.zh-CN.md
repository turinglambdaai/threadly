# Threadly

Racket 社区论坛的原生客户端——不开浏览器标签页就能浏览、阅读、全文搜索
[racket.discourse.group](https://racket.discourse.group)。Racket 的设计讨论、
提案与生态动态都发生在这个论坛上,Threadly 给这些长技术帖一套配得上内容
的阅读体验:目前面向桌面；移动端暂缓。

[![CI](https://github.com/turlamai/threadly/actions/workflows/ci.yml/badge.svg)](https://github.com/turlamai/threadly/actions/workflows/ci.yml) [![Release](https://img.shields.io/github/v/release/turlamai/threadly)](https://github.com/turlamai/threadly/releases/latest) [![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Windows%20%7C%20Linux-blue)](https://github.com/turlamai/threadly/releases/latest) [![License](https://img.shields.io/badge/license-AGPL--3.0-blue)](LICENSE) ![Racket](https://img.shields.io/badge/Racket-9.3-9D00FF?logo=racket&logoColor=white)

[English](README.md) · **中文**

## 开始使用

AGPL-3.0 许可的免费社区阅读器，处于维护模式；不要求商业账号，也不销售移动端。 桌面维护范围为 macOS、Windows、Linux；移动与手表客户端尚未交付。

[安装、首次使用、隐私与备份恢复](docs/USER-GUIDE.zh-CN.md) · [English](docs/USER-GUIDE.md)

## 为什么

论坛的每一页都在加载一个 Web 应用——侧栏、脚本、层层外壳——包裹着本该
被好好阅读的文字。关于类型系统和宏展开器的长帖在浏览器标签页里一晃而过,
切个窗口就找不到了。而桌面端根本没有客户端:Discourse 只有官方 iOS/Android
应用,桌面用户拿到的只是一个网址。

Threadly 就来做这个桌面客户端,而且按 Racket 社区做事的方式:一个小而
清晰的 Racket 引擎、第一方原生 UI、没有魔法。

## 它怎么工作

- **浏览**——全部分类的最新主题,带回复/浏览/点赞计数;所有响应落磁盘
  缓存,重复打开同一视图不会重复请求论坛。
- **阅读**——为长讨论设计的帖子视图:按阅读顺序呈现,渲染论坛自己的
  HTML,作者与原帖一键跳回网页。
- **搜索**——全站归档搜索,键盘优先。

引擎走匿名公开的 Discourse JSON API(任意论坛 URL 加 `.json`):不要账号、
不爬页面、不碰私有端点。

## 设计原则

1. **论坛是唯一事实源。** Threadly 只缓存、不分叉:编辑、删除、挪版
   永远以论坛为准,每个帖子都能跳回原链。
2. **做好公民。** 只打公开端点;响应全部落盘缓存并带 TTL;请求带身份
   标识的 User-Agent;收到 429 老实退避,不往死里重试。
3. **今天只读。** 应用内外不存放任何凭据。登录(Discourse 的 user API
   key 流)是后续里程碑,不是藏起来的功能。
4. **长文优先。** 阅读体验就是产品本身;要移除的恰恰是层层 chrome。

## 状态与路线图

今天已可用:Discourse 引擎(最新主题/读帖/搜索/分类)、带离线兜底的 TTL
磁盘缓存、终端 CLI 和 macOS / Windows / Linux 原生宿主。登录写操作和 BYOK AI
已有实现；打包工作流证据仍是独立交付门禁。

- [x] M0 —— Discourse 引擎、磁盘缓存、CLI、macOS SwiftUI 壳
- [x] M1 —— Windows 与 Linux 原生壳
- [x] M2 —— 登录态:user API key 流、回帖、点赞、通知
- [x] M3 —— 阅读增值:帖子摘要、翻译
- [ ] 移动端暂缓，仅在用户需求、维护能力与 Rivet 真机交付证据具备后评估，不作当前承诺。

## 从源码构建

```bash
raco test tests/                     # 必须全绿(不需要网络)

racket app/cli.rkt latest            # 终端里浏览
racket app/cli.rkt topic <id>        # 读一个主题
racket app/cli.rkt search "raco"     # 搜索归档
racket app/cli.rkt doctor            # 本地环境自检(离线)
```

Threadly 遵循 [Rivet](https://github.com/turlamai/rivet) 架构:
Racket 引擎 + 各平台第一方原生 UI。macOS 壳在 `macos-host/`,通过
`raco rivet build` 构建。

## 许可证

[AGPL-3.0](LICENSE)
