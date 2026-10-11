# 应用图标交付

图标的唯一设计源和可重建输出见[应用图标设计源](../../../design/AppIcon/Main.md)，生成、同步及缓存刷新入口见[开发脚本](../../../scripts/Main.md#视觉证据与交付)。本文件只记录 macOS 与 Xcode 的交付边界。

## 平台契约

Apple 当前的 macOS 应用图标规范要求提供未预先遮罩的方形图层，最终圆角由系统应用。预制圆角会妨碍系统材质并可能使边缘劣化。Icon Composer 使用分层文档描述背景和前景，Xcode 根据目标平台、外观与尺寸生成最终图标；同名 `.icon` 文档取代旧的 AppIcon Asset Catalog。

参考：

- [App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons)
- [Creating your app icon using Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)

## 项目观察

项目于 2026-08-21 在 macOS 26.6.1（25G76）、Xcode 26.6（17F113）中验证：有效 Icon Composer 文档能够生成正确的 ICNS 和 Asset Catalog，但 Launch Services 可能继续按 Bundle ID 与图标资源名返回旧缓存。相同产物改用新的测试 Bundle ID 时会立即显示新图标；`LSUIElement` 的静态值不影响该结果，因此资源编译问题与本机登记缓存需要分开判断。

在相同身份和路径上反复调试时，强制登记、递增 bundle version、重启 Dock 或用户级 IconServices 仍可能留下旧位图。当前环境需要重建用户级 IconServices store 和 Dock icon cache 后再登记应用。该行为不是公开契约，只能通过显式的脚本刷新模式处理；平台升级后需要重新验证。

## 交付约束

Xcode 只使用 `ApplicationIcon.icon` 作为正式图标入口，不与旧式 `.appiconset` 并存。正式 Bundle/Dock 图标与状态页应用图标都由设计源生成，但后者不是系统图标来源。设计参数、生成物定义和同步命令分别由上方链接的设计与脚本文档负责，本文件不维护其副本。
