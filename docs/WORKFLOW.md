# 完整操作流程

以下命令从仓库目录运行；默认读取 `bridge.local.json`，多项目时每次显式传对应的 `-ConfigPath 'C:\path\project.local.json'`。每个项目使用独立的工作目录、队列目录和 Codex 聊天。

## 初始化与接入

```powershell
.\scripts\initialize.ps1 -WorkspaceRoot 'C:\Projects\demo' -ThreadId 'YOUR-CODEX-CHAT-UUID'
.\scripts\manage-results-watch.ps1 -Action Start
.\scripts\doctor.ps1
```

初始化不替用户登录，不建立 WorkBuddy 会话，不自动启用任何后台进程。将运行目录里生成的提示词交给各自会话，确认 WorkBuddy 可以执行本项目脚本。结果监听进程和 WorkBuddy 守候是两个独立环节。

## 项目与回报聊天的选择

先在 WorkBuddy 里选择承接任务的项目/会话，再在该会话运行守候。`work_dir` 是执行目录元数据，不是原生项目选择器；本版本不通过文件任务自动切换 WorkBuddy 项目。

一套运行目录只绑定一个 Codex 回报聊天。这个聊天由初始化的 ThreadId 决定，不一定是后来提交每条任务的聊天。要将结果回到发起项目，请为该项目单独初始化队列，并绑定对应 Codex 聊天，不共用另一项目的配置。

若发起项目也在等待/验收，而另一个旧监听或跟进任务仍处理同一批结果，两边可能都回答。先核对各监听的真实目录、聊天绑定和原任务状态，再正常停止重复通道；不能把“双聊天回复”直接当成 WorkBuddy 重复执行。本仓库不自动修改其他聊天的监听或定时任务。

原型与发布仓库是独立目录。其他聊天对原型的更新需要经过源码比对与测试才能同步，不能把尚未核对的修复当成此版本已经具备的能力。

## Codex 派工

把工作压成一个可以验收的目标，说明允许修改的目录、具体成果与验收标准。工具任务参数没有“任意 Shell 命令”字段；自然语言仍可能包含危险要求，执行者必须遵守用户授权。

```powershell
.\scripts\submit-task.ps1 -Instruction '创建 hello.txt，内容为 Hello。只改这个文件。' -WorkDir 'C:\Projects\demo' -AllowedScope write_file -Checks '检查文件内容及修改范围' -TaskId 'demo-hello-001'
```

稳定 ID 重复提交会拒绝，即使前一任务失败也不会覆盖。ID 预留之后、入队之前崩溃时可能只剩 `ids` 记录：先核对，不自动删除记录后重发。

## WorkBuddy 领取和回报

```powershell
.\scripts\claim-task.ps1
```

返回 `claimed` 时，读取返回任务，使用 WorkBuddy 自身工具实际完成；`empty` 时才等待新任务。脚本校验 JSON、ID、目录与范围枚举，用同盘文件移动决出领取者。它不代替 WorkBuddy 执行指令。

```powershell
# WorkBuddy 实际完成并自检后回报。
.\scripts\report-result.ps1 -TaskId 'demo-hello-001' -Status success -Summary '已创建并核对内容。' -ArtifactPaths 'C:\Projects\demo\hello.txt'

# 如果执行失败，用失败回报结束本轮，并描述已发生的副作用。
.\scripts\report-result.ps1 -TaskId 'demo-other-001' -Status failed -Summary '执行受阻，未创建目标文件。' -ErrorMessage '说明具体阻塞及是否有其他改动。'
```

上面两个回报是不同任务的示例，不能对同一任务连续回报。成果路径必须是任务工作目录下真实的普通文件；读取任务可以没有 `ArtifactPaths`，Codex 验收时需要读取实际源文件。

先归档任务，再原子发布结果。两步间进程中断时，可能出现“已归档、无结果”的状态，不能据此认为执行失败并重做。

## WorkBuddy 守候

```powershell
.\scripts\watch-inbox.ps1 -TimeoutSeconds 3600
```

通过 WorkBuddy 支持的后台命令方式运行。它先挂文件事件，再查积压，不周期性调用模型。返回 `PENDING` 或 `EVENT` 后领取至 `empty`，随后重新守候；返回 `TIMEOUT` 时可重新等待。多个任务的优先级与顺序由 `claim-task.ps1` 决定，事件中的文件名只表示有任务。

同一运行目录只保留一个 inbox 守候，重复启动会返回 `ALREADY_RUNNING`；此时核对原会话，不循环重启第二个守候。不同项目的队列锁相互独立。

守候进程必须由 WorkBuddy 原生会话管理，且命令完成应实际唤醒该会话。脚本从普通终端单独启动不会让 WorkBuddy 自己执行任务。会话关闭、后台工具被取消、系统休眠或版本不支持时，自动领取可能中断。

## Codex 验收

读取运行目录 `ACCEPTANCE.md`，核对原任务、结果、授权范围和真实成果。下面命令只记录检查结果；先实际检查再调用：

```powershell
.\scripts\write-review.ps1 -TaskId 'demo-hello-001' -Verdict accepted -Summary '文件符合要求。' -Evidence '读取 hello.txt，逐字核对 Hello；检查修改范围。'
```

读取类任务或其他附加核查材料，用 `-SourcePaths` 加入实际检查文件，记录其内容哈希。结论可以是 `accepted`、`rework_required`、`blocked`。失败执行不能记录为 accepted。

不合格时保存具体反馈。需要返工时，保留原记录，用新 ID 并在 `Context` 引用旧 ID；只有已经确认原执行结束，且用户授权仍然适用时才提交新一轮。不能因为暂时没回报、监听超时或 `processing` 未消失而自动重发。

## 正常停止和恢复

```powershell
.\scripts\manage-results-watch.ps1 -Action Stop
.\scripts\manage-results-watch.ps1 -Action Status
```

停止使用标记文件让匹配的监听进程退出，不终止应用。重新 Start 会核对 PID、实际脚本路径、队列目录和聊天绑定；同目录只允许一个结果监听器。电脑重新启动后，分别恢复结果监听和 WorkBuddy 会话，再完成一次真实任务验收。
