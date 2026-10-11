# 关键行为例外

这里保留 8 个需要精确安排并发交错或注入系统 API 失败的既有单元测试。产品流程由[端到端验收](../Main.md)验证；保留原因和实际失败模式见[例外清单](Exceptions.md)。

主应用用例位于 `ECMenuTests/`，Finder Extension 配置副本用例位于 `ECMenuFinderExtensionTests/`。修改相应关键行为时先写能复现失败的测试，再修改实现。

开发机运行 `./scripts/test-checks.sh` 会进入一次性虚拟机；CI 在自己的 runner 中执行。完整验收用于较大修改或发布前，小修改按影响范围做针对性验证。
