# 安全政策

## 支持的版本

我们仅为**最新版本**提供安全修复。请始终使用 [Releases](https://github.com/Paul-liu/Sona/releases) 中的最新版。

| 版本 | 是否支持 |
| --- | --- |
| 最新版 | ✅ |
| 更早版本 | ❌ |

## 报告漏洞

**请不要通过公开 Issue 报告安全漏洞。**

请通过 GitHub 的 [Security Advisories](https://github.com/Paul-liu/Sona/security/advisories/new) 私下报告，并包含：

- 漏洞类型与影响范围
- 复现步骤或概念验证代码
- 潜在危害评估
- （可选）修复建议

我们会在 **72 小时内**确认收到，并在修复后与你协调公开时间。感谢你负责任地披露。

## 使用者的安全注意事项

本项目涉及网络凭据，请注意：

- 夸克登录态以 Cookie 形式存于本机 `UserDefaults`，**不会上传**到任何第三方服务器
- 阿里云盘为匿名访问，不存储任何账号信息
- 诊断日志（`/tmp/sona_quark_import.log`、`/tmp/sona_aliyun_import.log`）**可能包含敏感信息**，提交给他人前请自行检查并删除 Cookie、Token 等内容
- 请仅从本仓库的 Releases 下载预编译版本，不要使用来源不明的分发包

## 免责

本项目为学习研究用途，使用各平台公开接口，不包含破解或绕过授权的代码。详见 [README 免责声明](README.md#免责声明)。
