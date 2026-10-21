---
name: piclight-verification
description: Use when choosing checks for a PicLight change, investigating test results, or preparing a completion claim or application deliverable.
---

# PicLight 验证选择

让每个完成结论对应当前版本的实际证据。读取[验证指南](../../../docs/testing.md)中与改动有关的部分；打包时再读取[开发指南](../../../docs/development.md)。

## 选择检查

1. 核对实际改动面，包括未跟踪文件和用户点名的被忽略资料。`git diff` 不是这些文件的完整内容检查。
2. 从验证指南选择相关测试起点；阅读它们是否真的覆盖改变的行为。共享窗口、视口和解码生命周期变更必要时扩大范围。
3. 串行运行检查并确认退出码、选中数量、失败和跳过。检查未运行或选中零项时不报告通过。
4. UI、物理设备和交付包按各自实际入口验证。旧测试报告、旧应用包和已安装旧进程不能证明新版本。

| 变更 | 首选证据 |
| --- | --- |
| AI 入口、技能与指南 | `python3 scripts/check-agent-docs.py`，再核对事实与触发范围 |
| 用户提供的截图文档 | 原图与引用逐一核对、Markdown 预览；不要为附图重跑 Swift 或重建旧包 |
| Swift 行为 | 对应 XCTest；需要时增加相邻或全量回归 |
| 图像和原生窗口交互 | 自动行为测试加当前应用的相关操作检查 |
| 发布产物 | 当前包的路径、版本和包检查；DMG 单独核对 |

例如只修设置页布局：选择 `SettingsWindowTests` 和 `FileAssociationTests`，查看真实页内控件是否可操作；无需为此点击应用并修改系统默认打开方式。

## 记录与报告

按[任务模板](../../templates/task.md)记录实际命令、工作版本或产物、结果、证据和未覆盖项。只检查文档时不引用历史 Swift 测试数量作新证据。包检查、自动事件测试和真实捏合/悬停的结论分别写；无法验证的操作保留待验证状态。

相同代码及前提下已有通过证据，不因提交动作重复运行。只有新改动、失败、范围扩大或前提改变时再运行相关检查。
