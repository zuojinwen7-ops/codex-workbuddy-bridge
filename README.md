# Codex WorkBuddy Bridge

**让 Codex 负责派工与验收，让桌面 WorkBuddy 负责执行。**

[English](README.en.md) · [快速开始](#快速开始) · [完整流程](docs/WORKFLOW.md) · [故障恢复](docs/TROUBLESHOOTING.md) · [验证范围](docs/VALIDATION.md)

作者：[zuojinwen7-ops](https://github.com/zuojinwen7-ops) · MIT · Windows · PowerShell 5.1 / 7

这套项目来自一次实际的双 AI 协作：在 Codex 里说清目标，WorkBuddy 使用自己的工具完成任务，结果落盘后，Codex 被事件唤醒，检查真实成果并给出结论。把这条链路整理出来，是为了让其他人也能在自己的目录里复用。

```mermaid
flowchart LR
    U[用户提出目标] --> C[Codex 派工]
    C --> I[inbox 文件队列]
    I --> W[WorkBuddy 领取并执行]
    W --> R[results 执行回报]
    R --> E[文件事件监听]
    E --> Q[codex queue 唤醒原聊天]
    Q --> V[Codex 检查真实成果]
    V --> A[reviews 验收记录]
```

## 可以做什么

- 把目标、工作目录、允许范围和验收标准写成结构化任务。
- 原子发布和领取任务，保留稳定任务编号，减少重复领取。
- WorkBuddy 在原生桌面会话中执行，回报成果路径与问题。
- 结果变化时触发 Codex 验收；相同内容去重，避免持续重复唤醒。
- 记录任务、结果、实际核验文件的 SHA-256 和验收证据。
- 提供独立测试、可安装 Skill、文档和可复现的源码压缩包。

**定位：本地协作工具，首个实验版本 v0.1.0。** 文件通道在本机，两个产品的模型和联网工具仍按各自账号工作。项目不附带模型、账号或免费额度，不承诺节省百分比。

## 使用前准备

1. Windows，Windows PowerShell 5.1 或 PowerShell 7；本地盘上的项目目录。
2. 已登录、可正常工作的桌面 WorkBuddy，允许它在目标项目运行本仓库的脚本。
3. 已登录的 Codex，以及支持 `codex queue --thread --message` 的原生 `codex.exe`。初始化只检查命令能力，不发送消息。
4. 一个已存在的 Codex 项目聊天，其工作区包含你授权的目录，并取得该聊天的 UUID。可以在该聊天中让 Codex 确认当前聊天编号；不要使用示例 UUID 或其他人的编号。

`codex queue` 的语义见 [OpenAI 官方命令文档](https://learn.chatgpt.com/docs/developer-commands?surface=cli#codex-queue)。命令入队不代表模型已执行，必须看实际聊天和验收记录。

## 快速开始

### 1. 下载并初始化

```powershell
git clone https://github.com/zuojinwen7-ops/codex-workbuddy-bridge.git
cd codex-workbuddy-bridge

# 换成你自己的项目目录和 Codex 聊天 UUID。
.\scripts\initialize.ps1 -WorkspaceRoot 'C:\Projects\demo' -ThreadId 'YOUR-CODEX-CHAT-UUID'
```

如果找不到 `codex.exe`，追加 `-CodexExe 'C:\path\to\codex.exe'`。初始化生成被 Git 忽略的 `bridge.local.json`，以及项目目录下的 `.agent-bridge`。已有配置或运行目录会拒绝覆盖。

```text
C:\Projects\demo\.agent-bridge\
  inbox/        待领取
  processing/   已领取，尚未回报
  done/ failed/ 已归档任务
  results/      执行结果
  reviews/      Codex 验收
  claims/ ids/  领取记录与编号预留
  logs/         监听记录与去重状态
  WORKBUDDY-PROMPT.md / CODEX-PROMPT.md / ACCEPTANCE.md
```

### 2. 接入两个会话

- 把生成的 `WORKBUDDY-PROMPT.md` 交给 WorkBuddy，让它在目标项目会话中读取并开始守候。
- 在对应 Codex 聊天中读取生成的 `CODEX-PROMPT.md`。
- 在本仓库目录启动结果监听：

```powershell
.\scripts\manage-results-watch.ps1 -Action Start
.\scripts\doctor.ps1
```

监听器以隐藏窗口运行。`doctor` 能检查文件配置与监听进程，不能证明 WorkBuddy 已在守候。WorkBuddy 的后台命令结束后是否能唤醒会话，取决于当前版本和会话能力，必须完成一次真实文件任务验证。

### 3. 发出第一条任务

```powershell
.\scripts\submit-task.ps1 `
  -Instruction '在工作目录创建 hello.txt，内容为：你好，双 AI 协作。不要修改其他文件。' `
  -WorkDir 'C:\Projects\demo' `
  -AllowedScope write_file `
  -Checks 'hello.txt 存在，内容与要求一致，未修改其他文件'
```

保存返回的 `task_id`。WorkBuddy 使用 `claim-task.ps1` 领取、实际执行，再用 `report-result.ps1` 回报。Codex 被结果事件唤醒后读取真实文件，检查原要求，并用 `write-review.ps1` 记录证据。完整参数示例见 [操作流程](docs/WORKFLOW.md)。

### 4. 查看或停止

```powershell
.\scripts\manage-results-watch.ps1 -Action Status
.\scripts\manage-results-watch.ps1 -Action Stop
```

Stop 只停止本项目的结果监听，不关闭两个应用。WorkBuddy 的 inbox 守候在它的会话中独立运行。项目不会创建定时任务、登录自启动或修改执行策略；重启后需重新接入两侧。

## 安装为 Codex Skill（可选）

Skill 在 [`skills/codex-workbuddy-bridge`](skills/codex-workbuddy-bridge/SKILL.md)，用于共享文件队列这条路线，不覆盖其他 WorkBuddy MCP 技能。可以让 Codex 的 Skill Installer 从此仓库的该路径安装，或按 [官方 Skill 文档](https://developers.openai.com/codex/skills/) 放入当前版本支持的技能目录。

仅安装 Skill 不会安装脚本、创建目录或启用监听。先完成初始化，再在 Codex 中说：

> 用 codex-workbuddy-bridge 把这个任务交给 WorkBuddy，保存任务编号，收到结果后按原要求验收。

## 测试与打包

```powershell
.\tests\run-tests.ps1
.\scripts\package-release.ps1
```

测试全部使用隔离数据，不调用模型，不冒充 WorkBuddy 的真实执行。源码包按版本控制的文件清单打包，排除本机配置、任务、成果、日志和测试运行目录。GitHub Actions 在 Windows PowerShell 5.1 与 PowerShell 7 下运行相同测试。

## 能力边界

- `success` 是执行回报，`accepted` 才是 Codex 记录的验收结论；记录命令本身不会替你检查业务成果。
- `allowed_scope` 是执行约定，不是操作系统权限隔离。两个应用仍拥有各自原有权限。
- 原子移动减少重复领取；崩溃、外部副作用和投递结果不确定时不保证恰好执行一次。不要自动重发 `processing` 中的任务。
- 结果文件中的 `executor` 是声明；共享目录无法认证执行模型，SHA-256 也不能证明执行来源或内容正确。
- 结果监听去重状态在本机。删除状态文件可能导致重复投递；投递失败或不确定不会静默重发同一内容，需要人工核对。
- 不自动关闭应用、修改 WorkBuddy 数据库、注入调试端口或绕过权限。新电脑、新版本、重新打开后的自动领取均需各自验收。

数据流和公开发布注意事项见 [SECURITY.md](SECURITY.md)。欢迎在 [Issues](https://github.com/zuojinwen7-ops/codex-workbuddy-bridge/issues) 提供去除个人信息的复现步骤。
