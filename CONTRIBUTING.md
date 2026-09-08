# 贡献指南

感谢你愿意为 Sona 贡献代码！🎉

这份文档说明如何参与开发。无论是修一个拼写错误还是接入一个新网盘，都欢迎。

## 开始前

- **提 Issue 前先搜索** [已有 Issue](https://github.com/Paul-liu/Sona/issues)，避免重复。
- **大型改动先讨论**：如果要改架构、加新网盘或引入依赖，请先开一个 Issue 或 Discussion 说明方案，达成共识后再动手，避免白做。
- **小改动直接 PR**：修 Bug、改文案、补文档这类，直接提 PR 即可。

## 开发环境

| 项目 | 要求 |
| --- | --- |
| macOS | 13.0+ |
| Swift | 5.9+（Xcode 15 及以上） |
| 依赖 | 无（本项目零第三方依赖，也请保持这一点） |

```bash
git clone https://github.com/Paul-liu/Sona.git
cd Sona
swift build                    # 编译
swift run Sona                 # 运行
```

> 若在受限终端环境下遇到 `sandbox-exec: sandbox_apply: Operation not permitted`，使用 `swift build --disable-sandbox`。

## 开发流程

1. **Fork** 本仓库并 Clone 到本地
2. **新建分支**，命名建议：
   - `fix/简短描述` —— 修 Bug
   - `feat/简短描述` —— 新功能
   - `docs/简短描述` —— 文档
   - `refactor/简短描述` —— 重构
3. **编写代码**，遵循下方代码规范
4. **自测**：确保 `swift build` 通过，并实际运行验证改动
5. **提交 PR**，填写 PR 模板

## 代码规范

**Swift 风格**

- 遵循 [Swift API Design Guidelines](https://swift.org/documentation/api-design-guidelines/)
- 4 空格缩进；类型与协议用 `UpperCamelCase`，变量与函数用 `lowerCamelCase`
- 优先 `let`，只在需要变更时用 `var`
- 异步代码使用 `async/await`，不要用回调地狱
- service 类使用 `@MainActor` 保证 UI 状态在主线程更新

**注释**

- 公开接口、非显而易见的逻辑必须写注释
- 踩过的坑请写清楚**为什么**，而不只是**做了什么**。例如：
  ```swift
  // 关键：Referer 必须指向具体分享页，否则夸克判定 token 与页面不一致返回 14001
  request.setValue(shareReferer(pwdId: pwdId), forHTTPHeaderField: "Referer")
  ```
- 这类注释对后来者价值极高，欢迎多写

**架构约定**

- `Services/` 放业务逻辑与网络请求，`Views/` 只负责渲染与交互
- 新增网盘请参照 `AliyunShareService.swift` 的结构（解析 → 换凭据 → 列举 → 直链）
- 不在 View 里直接发网络请求

**零依赖原则**

本项目刻意在 `Package.swift` 中保持零第三方依赖。如确实需要引入，请在 Issue 中说明理由并讨论 —— 引入依赖的门槛会比较高。

## 提交信息

使用简洁清晰的中文或英文均可，建议遵循常见格式：

```
fix(quark): 修复多次导入时 Referer 不匹配导致的 14001 错误
feat(aliyun): 新增阿里云盘分享支持
docs: 补充排障章节
```

## PR 检查清单

提交前请确认：

- [ ] `swift build` 编译通过，无新增警告
- [ ] 实际运行验证过改动（不只是编译过）
- [ ] 没有提交构建产物（`.build/`、`*.app`、`*.app.zip`、`.DS_Store`）
- [ ] 没有提交任何密钥、Cookie、Token 或个人凭据
- [ ] 涉及 UI 改动的话，附上截图
- [ ] 更新了相关文档（如 README 的功能列表）

## 报告问题

提交 Bug 时请附上：

1. **macOS 版本** 与 **Sona 版本**
2. **复现步骤**
3. **预期行为** 与 **实际行为**
4. **诊断日志**（重要！）：
   ```bash
   tail -50 /tmp/sona_quark_import.log    # 夸克相关问题
   tail -50 /tmp/sona_aliyun_import.log   # 阿里云盘相关问题
   ```
   > 提交日志前请自行检查并删除其中的 Cookie、Token 等敏感信息。

## 行为准则

参与本项目即表示你同意遵守 [行为准则](CODE_OF_CONDUCT.md)。

## 再次感谢

开源项目的生命力来自每一个贡献者。谢谢你花时间在 Sona 上 🙏
