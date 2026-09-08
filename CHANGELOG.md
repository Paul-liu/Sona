# 更新日志

本项目的所有重要变更都会记录在此文件。

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [1.1.3] - 2026-09-08

### 修复
- **阿里云盘导入 HTTP 429 限流失败**：平台对单 IP 短时请求数有限流，旧代码失败即报错，用户每次重试都立刻再触发限流。现在 `file/list` 遇 429 自动退避重试（5s / 10s / 15s，最多 3 次）
- 导入弹窗新增限流状态横幅，用 `TimelineView` 显示倒计时「限流中，约 X 秒后自动重试…」

## [1.1.2] - 2026-09-08

### 变更
- 云端侧边栏改为**纵向可折叠分组**（原为横向 segmented），便于未来扩展更多网盘
- `CloudKind` 改为 `CaseIterable + Identifiable` 公开枚举，侧边栏数据驱动渲染
- 新增网盘只需：加枚举 case + 在 `playlists(for:)` 加分支

## [1.1.1] - 2026-09-08

### 变更
- 阿里云盘从独立 section 合并进「云端」分组（应社区反馈）
- 云端分组顶部改为 segmented 切换，状态行与歌单跟随切换
- 移除 `SidebarSelection` 的 `.quark` / `.aliyun` 顶层导航项

## [1.1.0] - 2026-09-08

### 新增
- **阿里云盘分享支持**：匿名访问，无需登录
  - 支持 `alipan.com` / `aliyundrive.com`、`/s/xxx/folder/yyy` 子目录、有/无提取码
  - `AliyunShareService` + `AliyunModels`
  - share_token 内存缓存（2 小时有效），播放时按需刷新
- 导入弹窗重构为 `CloudImportSheet`，粘贴后**自动识别网盘来源**
- `TrackSource` 新增 `.aliyun`，曲目角标与配色区分

### 修复
- 错误码映射漏判：实测为 `ShareLink.Cancelled`（带点号），原硬编码 `ShareLinkCancelled` 匹配不上，改为去点后包含匹配
- `LocalStreamProxy` Referer 写死为夸克域名，导致阿里云盘直链被拒。改为按来源传参，Cookie 仅在夸克请求时携带

## [1.0.10] - 2026-09-07

### 修复
- **夸克导入 14001「非法 token」**（第二次导入必现）：三个接口的 `Referer` 写死为 `https://pan.quark.cn/`，而夸克校验 Referer 必须指向具体分享页 `https://pan.quark.cn/s/{pwdId}`。stoken 接口照常返回 token 但后续 detail 严格校验失败
- 14001 自动重新拉取 stoken 并重试
- 导入入口加并发锁

## [1.0.9] - 2026-09-07

### 修复
- **侧边栏点击无反应**：`List(selection:)` + `.tag()` 在行内嵌 Button 或 tag 挂错层级时完全失效。改为手动模式：`onTapGesture` 显式赋值 + 自绘选中/悬停背景
- detail 视图加 `.id(selectionKey)` 强制重建
- 切换歌单时清空搜索词

## [1.0.8] - 2026-09-07

### 修复
- 分享文件列举分页参数写死第 1 页，单目录超 50 首只能取前 50
- 夸克 412 风控时 body 非 JSON，旧代码直接解码报乱码错误。加状态码检查 + 1.5s 重试
- 新增导入诊断日志 `/tmp/sona_quark_import.log`

## [1.0.7] - 2026-09-07

### 修复
- 资料库改为按歌单分栏展示（原合并成两栏）
- 分享链接解析支持夸克 App 复制的整段文本，自动提取链接与提取码

## [1.0.6] - 2026-09-07

### 新增
- 本地 / 云端均支持**多次导入**，每次按文件夹名或分享标题生成独立歌单
- 全局 Toast 提示栏，导入结果显示在顶部（原在侧边栏）
- 侧边栏歌单支持右键移除

## [1.0.5] - 2026-09-07

### 修复
- 扫码后服务端验证误报：改为 member/info → config → account/info 多接口兜底
- 验证失败时提供「强制使用当前 Cookie」按钮

## [1.0.4] - 2026-09-07

### 修复
- 登录弹窗秒关：游客 cookie 被误判为登录成功。改为严格判定 `__pus` + `__puus` 并存，并服务端验证

## [1.0.0] - 2026-09-06

### 新增
- 首个版本发布
- 本地音乐扫描与播放、夸克网盘扫码登录与分享导入、本地流媒体代理、系统控制中心联动

---

[1.1.3]: https://github.com/Paul-liu/Sona/compare/v1.1.2...v1.1.3
[1.1.2]: https://github.com/Paul-liu/Sona/compare/v1.1.1...v1.1.2
[1.1.1]: https://github.com/Paul-liu/Sona/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/Paul-liu/Sona/compare/v1.0.10...v1.1.0
[1.0.10]: https://github.com/Paul-liu/Sona/compare/v1.0.9...v1.0.10
[1.0.9]: https://github.com/Paul-liu/Sona/compare/v1.0.8...v1.0.9
[1.0.8]: https://github.com/Paul-liu/Sona/compare/v1.0.7...v1.0.8
[1.0.7]: https://github.com/Paul-liu/Sona/compare/v1.0.6...v1.0.7
[1.0.6]: https://github.com/Paul-liu/Sona/compare/v1.0.5...v1.0.6
[1.0.5]: https://github.com/Paul-liu/Sona/compare/v1.0.4...v1.0.5
[1.0.4]: https://github.com/Paul-liu/Sona/compare/v1.0.0...v1.0.4
[1.0.0]: https://github.com/Paul-liu/Sona/releases/tag/v1.0.0
