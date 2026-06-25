# 设计文档：QA List 驱动的未返信提醒

日期：2026-06-11
对象 skill：`slack-unanswered-reminder2`

## 背景与目标

当前 skill 在指定频道（`monitored_channels`）扫描过去 N 天（`monitoring_period_days`）的全部帖子，找出 team_members 无人回复的帖子并提醒。

改为：**以一个指定的 Slack QA List 为数据源**，取出「完了」列未勾选的项目，对每项顺着其 `メッセージリンク` 回查对应线程，沿用旧的回复判定逻辑，只提醒「List 未完成 且 线程里 team 没人回复」的项。

## 核心决策

| 项 | 决策 |
|---|---|
| 数据源 | 单个 QA List，config 里用 **list 名**指定，运行时用 `slack_search_public` + `type:lists` 解析出 File ID |
| 时间范围 | **取消**（不再有 `monitoring_period_days`，不限时间） |
| 「完了」判定 | 值为 `true` 才算完成；`false` 或**空值**都算未完成 → 进入候选 |
| 无 `メッセージリンク` 的未完成项 | **直接跳过**（无法做回复检查） |
| 回复判定 | **不变**：team_members 或被 mention 者在线程里有回复即视为「已回复」 |
| 提醒条件 | 未完成 **且** 线程里 team 没人回复 |
| 提醒消息格式 | 照旧；仅头部「#频道名 で N 件」一行改为 **List 名** |

## 新执行流程（替换 SKILL.md「実行ワークフロー」）

0. **健康检查**（保留）：`slack_search_users` 验证 team_members 首位；失败 → `last_error.log` + exit，不进 OAuth 流程。
1. **读 config**：`list_name`、`notification_channel`、`team_members`。
2. **解析 List**：`slack_search_public(query="<list_name> type:lists", content_types="files")`。
   - 0 个匹配或多个同名匹配 → 写 `last_error.log` 后 exit（无人模式不询问）。
   - 取唯一匹配的 `File ID`。
3. **读 List**：`slack_read_file(file_id)`，返回 CSV（字段：`タイトル, 問い合わせ内容, 回答希望日, 投稿者, 開始日, 期日, 担当者, 進捗率(％), Status, NextAction, 完了, メッセージリンク`）。按 CSV 规则解析（引号内换行/逗号不算分隔）。
4. **过滤未完成**：保留「完了」≠ `true` 的记录。
5. **逐项回查**：
   - 解析 `メッセージリンク`（`https://<ws>.slack.com/archives/<channel_id>/p<ts_no_dot>`）→ `channel_id` + `ts`（在倒数第 6 位前插入小数点还原 `ts`）。
   - 无链接 → 跳过该项。
   - `slack_read_thread(channel_id, ts)` 取全部回复。
   - 判定：team_members 或（亲帖/线程内被 mention 的 User ID）有任一回复 → 「已回复」，排除。
6. **汇总未回复项** → 若 ≥1 件，发 `notification_channel`；0 件不发。

## 通知消息格式

```
<@member1> <@member2> ... <@memberN>

未返信投稿リマインダー（YYYY-MM-DD）
{list_name} で N 件未返信

1. 【MM-DD HH:MM】{タイトル を 1 行に圧縮}
   {メッセージリンク}
...
```

- 头部 mention 全部 team_members（config 顺序）。
- `【MM-DD HH:MM】` 由 `メッセージリンク` 的 `ts` 还原（与旧实现一致，用消息时间）。
- 每条描述用该 List 项的「タイトル」。
- 跳转链接直接用该项的 `メッセージリンク`（无需再做 ts→link 转换）。

## 受影响文件

| 文件 | 改动 |
|---|---|
| `SKILL.md` | 重写「実行ワークフロー」「クイックリファレンス」「よくあるミス」「エラーハンドリング」「実行例」等；删除时间范围、频道扫描相关描述 |
| `config.yaml` | 删除 `monitored_channels`、`monitoring_period_days`；新增 `list_name`；保留 `notification_channel`、`team_members`、`schedule` |
| `scripts/run-reminder.ps1` | 更新内嵌 prompt 步骤描述；`--allowedTools` 增加 `slack_search_public`、`slack_read_file`（`slack_read_channel` 是否保留视新流程，新流程不再需要可移除） |
| `README.md`、`docs/slack-app-setup.md`、`docs/confluence-template.md` | 同步说明（Slack App scope 需含 `search:read`/文件读取相关；数据源描述更新） |
| `CLAUDE.md` | 同步业务逻辑与 config 字段说明 |

## 不变的约束（务必保留）

- 无人执行：不向用户提问、不进 OAuth 再认证、不做 SKILL.md 自我 review。
- 错误处理：API 失败重试 1 次，持续失败 → `last_error.log` + exit。
- 0 件不发空通知。
- 调度仍由 Task Scheduler + `deploy-task.ps1` 处理（`schedule` 段不动）。

## 待实现时确认的小点

- `slack_search_public` 搜不到 List 的可能原因（List 未被当前用户访问 / 名字含特殊空白字符）——解析失败时把搜到的候选数量写进 `last_error.log` 便于排查。
- `--allowedTools` 的 MCP 命名空间需与实际连接的 Slack MCP 一致（本仓库现存 `mcp__claude_ai_Slack__*` 与 `mcp__plugin_slack_slack__*` 混用问题，一并校正为实际可用的那个）。
