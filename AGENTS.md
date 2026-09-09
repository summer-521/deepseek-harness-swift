# DSH 项目工作约定

通用工程原则使用全局 AGENTS.md，本文件只维护项目约束。

- 当前提交从 Git 读取，不把历史基线、测试计数或临时产物路径当成实时事实。
- 应用通过 Xcode 和现有 scripts 构建；Package.swift 不是完整应用验收入口。新增 Swift 文件须检查 Xcode target。
- 故障测试隔离 DSH_HOME 和 Application Support；不对个人 Profile 注入故障。
- Runtime 选择来自 npm Registry；保留现有事务、失败恢复及 desktop/web 边界。必要的状态解码兼容和事务回滚不属于废弃方案。
- 调研/实施文档目前按用户此前要求保留本地；提交时核对本次范围，不使用 git add .。提交、推送和发布按本次授权执行。
- 历史执行代理的模型和分工只记录当时安排，不作为后续任务的默认配置或分派授权。

常用入口：本地打包用 `bash scripts/release-local.sh arm64`（仅支持 Apple Silicon arm64）。
