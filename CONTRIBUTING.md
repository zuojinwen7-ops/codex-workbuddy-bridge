# 参与项目

欢迎用可复现的例子改进安装、队列可靠性和会话接入体验。先说明 Windows、PowerShell、Codex 和 WorkBuddy 版本，以及预期和实际结果。

修改前阅读 README 与 SECURITY。保留稳定任务 ID、同内容去重、不自动重发执行状态不确定任务，以及“执行回报需独立验收”的约定。兼容 Windows PowerShell 5.1；不要引入系统执行策略绕过、硬编码本机目录、强制退出应用或隐式云端上传。

```powershell
.\tests\run-tests.ps1
```

提交前逐文件检查，运行数据和真实业务成果不能进入版本控制。新增或修复行为应有适当的独立测试，合成数据明确标注为测试，不把它当作 WorkBuddy 真实执行证据。
