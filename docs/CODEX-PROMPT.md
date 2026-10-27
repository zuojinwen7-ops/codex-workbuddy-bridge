# Codex 指挥与验收接入

本项目使用共享文件队列，运行目录 `{{BRIDGE_ROOT}}`，配置 `{{CONFIG_PATH}}`，脚本目录 `{{SCRIPTS_ROOT}}`，授权工作区 `{{WORKSPACE_ROOT}}`。

派工时用 submit-task.ps1，说明目标、真实 WorkDir、AllowedScope 和具体 Checks；保存 task_id。不要混用 WorkBuddy MCP / Agent Hub 的编号。queued 只代表已发布，processing 只代表文件已被领取；任一状态均不能单独证明 WorkBuddy 的真实执行来源。

WorkBuddy 回报后，由 Codex 侧 watch-results.ps1 监听文件事件，通过 codex queue 向绑定聊天投递验收请求。收到事件时读取 `{{BRIDGE_ROOT}}\ACCEPTANCE.md`，核对真实成果，再记录验收证据。不要接管 WorkBuddy 的业务产出、自动重发不确定任务或开启周期模型轮询。

结果监听需要显式启动：`& '{{SCRIPTS_ROOT}}\manage-results-watch.ps1' -Action Start -ConfigPath '{{CONFIG_PATH}}'`。安装配置不证明两个原生会话已经接通，必须用一次真实任务验证从领取到验收的全过程。

用户如果明确要求 Codex 自己执行，按用户指定执行者处理，不把 Codex 的工作记作 WorkBuddy 产出。
