# PicLight AI 工作流

从[根 AGENTS.md](../AGENTS.md)进入，只按当前任务加载需要的技能和资料。

```text
AGENTS.md                              项目约定与读取路由
.agents/
  skills/
    piclight-development/SKILL.md       开发、修复与恢复任务
    piclight-verification/SKILL.md      选择并记录验证证据
    piclight-review/SKILL.md            行为、异步状态与交付审查
  notes/README.md                      长期决策的生命周期
  notes/implemented/                   已落实的决策
  templates/task.md                    验收条件、当前状态和交接
  templates/decision.md                决策理由与被放弃的方案
docs/development.md                    代码地图与真实构建命令
docs/testing.md                        测试选择、GUI 与应用包检查
scripts/check-agent-docs.py             本地文档导航检查
scripts/tests/test_check_agent_docs.py  检查器的正例与反例
```

## 三个任务入口

| 技能 | 适用场景 |
| --- | --- |
| [piclight-development](skills/piclight-development/SKILL.md) | 实现功能、定位 bug、继续中断工作 |
| [piclight-verification](skills/piclight-verification/SKILL.md) | 为实际改动选择测试、核实完成状态、验证交付物 |
| [piclight-review](skills/piclight-review/SKILL.md) | 评审差异、检查使用行为与处理反馈 |

已有 `docs/specs/`、`docs/superpowers/specs/`、`docs/superpowers/plans/` 和发布记录继续保留原位置；需要时链接到它们。用户点名的本地截图和 bug 资料按当前任务读取，不复制进技能或默认上传。

## 使用方式

新任务先读取根入口；长任务使用[任务模板](templates/task.md)保存验收条件和下一步，避免恢复时重新推测。实现方案涉及长期取舍时使用[决策模板](templates/decision.md)，按[记录规则](notes/README.md)归类。技能缺失自动发现能力的工具也可以通过根入口的链接直接读取。

技能、模板和计划是执行指导，不会自行启动其他 agent、DSH、自动提交或发布。

## 参考与取舍

参考 [DeepSeek Harness 的 AGENTS.md](https://github.com/deepseek-ai/deepseek-harness/blob/d743267388641bc76f17c45ce8b4c231aed1d32c/AGENTS.md)、[Agent Notes](https://github.com/deepseek-ai/deepseek-harness/blob/d743267388641bc76f17c45ce8b4c231aed1d32c/.agents/notes/README.md)、[按改动选择检查](https://github.com/deepseek-ai/deepseek-harness/blob/d743267388641bc76f17c45ce8b4c231aed1d32c/.agents/skills/dsh-pre-push-checks/SKILL.md)和[按需提供上下文](https://github.com/deepseek-ai/deepseek-harness/blob/d743267388641bc76f17c45ce8b4c231aed1d32c/.agents/skills/agent-experience/SKILL.md)。核对版本为 `d743267388641bc76f17c45ce8b4c231aed1d32c`，核对日期为 2026-10-12。

这里采用短入口、任务技能、决策状态和相关检查的组织方式；命令、测试和图像交互约定来自 PicLight 当前实现。三个技能共享项目指南，不复制 Harness 的包结构、平台矩阵或发布策略。具体理由见[已实施记录](notes/implemented/2026-10-12-project-agent-workflow.md)。
