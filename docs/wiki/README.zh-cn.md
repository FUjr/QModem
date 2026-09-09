# QModem Wiki 内容索引

这里保存可同步到 GitHub Wiki 的版本化内容，源码仓库中的页面与 Wiki 发布页保持同一
套规则：

- [分支与发布策略](../release/branch-policy.zh-cn.md)：说明 `main`、`stable`、feature、
  hotfix 和冲突决策规则；
- [版本迁移与反馈](../release/version-migration.zh-cn.md)：按 release tag 记录测试中
  的功能、迁移风险、已知问题和版本 Issue 入口。

每个 release tag 都应创建一个对应的置顶 Issue，正文包含完整 tag、提交 SHA、变更摘要、
已知问题、升级/回滚步骤和反馈格式；新版本发布后取消上一个版本的置顶状态。Issue
链接按标签筛选，避免用户在不同版本之间误报。

## 发布维护清单

1. 确认 tag 来源分支和完整提交 SHA。
2. 更新版本迁移表、已知问题和反馈链接。
3. 创建并置顶新版本 Issue，取消旧版本置顶。
4. 在对应分支的 release 页面标注预发布或稳定状态。
5. 发布后补充社区验证结果，不把 CI 构建成功当作硬件验证结论。
