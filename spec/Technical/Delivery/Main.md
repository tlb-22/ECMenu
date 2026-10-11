# 交付边界

本目录记录构建产物需要保持稳定、且无法仅从单个源码文件恢复的交付约束。

- [构建身份](BuildIdentity.md)：产品与测试目标的名称、Bundle ID、App Group、签名和环境隔离。
- [应用图标](AppIcon.md)：macOS 图标合成契约、Xcode 交付入口和本机缓存边界。

- [开发、验证与交付流程](DevelopmentWorkflow.md)：构建、进程登记、测试、预览与交付的控制流和工具 API 边界。

- [虚拟机端到端测试](VirtualMachineTests.md)：独立桌面环境、项目预热与日常验收。
