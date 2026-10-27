# WorkBuddy 执行会话接入

请在你自己的原生会话中执行共享文件队列任务。工作区为 `{{WORKSPACE_ROOT}}`，运行目录为 `{{BRIDGE_ROOT}}`，脚本目录为 `{{SCRIPTS_ROOT}}`，配置文件为 `{{CONFIG_PATH}}`。

先阅读本文件，确认这些路径在当前会话的授权范围内；保留已有登录、模型、技能和权限。不要修改桥接脚本、配置或原生数据库，不自行安装其他网关。不要调用 Codex、codex-dispatch 或再次委派回 Codex。

守候必须在用户指定的 WorkBuddy 项目/原生会话中运行；任务 work_dir 不会自动切换项目。选择不符时先说明并让用户选择正确会话，不默默接到另一个项目。ALREADY_RUNNING 表示该队列已有守候，核对原会话，不反复启动第二个。

1. 运行 `claim-task.ps1 -ConfigPath '{{CONFIG_PATH}}'`。返回 claimed 后读取完整任务、工作目录、允许范围和验收标准。
2. 使用你自身的工具真正完成任务并自检。范围字段只是约定，不能扩大用户授权；遇到需要额外授权的动作，报告具体阻塞。
3. 完成后运行 `report-result.ps1 -ConfigPath '{{CONFIG_PATH}}' -TaskId '实际编号' -Status success -Summary '简短结果' -ArtifactPaths '真实文件绝对路径'`。读取任务允许没有 ArtifactPaths。
4. 失败时以 failed 回报并传 ErrorMessage，说明已发生的修改和未解决问题；不要反复执行不确定的任务，不要自己写 Codex 验收记录。
5. 继续领取直到 empty。随后以当前会话支持的后台命令方式运行 `watch-inbox.ps1 -ConfigPath '{{CONFIG_PATH}}' -TimeoutSeconds 3600`，等待文件事件。确保后台命令结束通知能唤醒本会话。
6. 守候返回 EVENT 或 PENDING 后回到领取步骤，处理当前队列后重新守候。TIMEOUT 可重新等待；ERROR 先说明原因并核对队列。没有后台唤醒能力时如实说明，改为用户手动触发领取，不声称自动化已完成。

所有命令都使用完整脚本路径，例如 `& '{{SCRIPTS_ROOT}}\claim-task.ps1' -ConfigPath '{{CONFIG_PATH}}'`。不要把示例编号当作真实任务。

最终回报保持简短：当前状态、真实成果路径、必要测试证据、未解决问题和额外修改。自动验收由 Codex 侧结果监听触发，你不需要调用 Codex。
