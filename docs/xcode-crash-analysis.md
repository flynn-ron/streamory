# Xcode 崩溃分析与开发流程优化

## 已确认的证据

用户提供的报告记录：2026-10-06 17:15:25（北京时间），Xcode 26.3 / 17C529，macOS 26.6.2。崩溃进程为 `com.apple.dt.Xcode`，主线程 `EXC_CRASH / SIGABRT`，断言签名为 `[self isValid]`。

系统统一日志在 17:15:24.952 记录了更完整的断言：

```text
ASSERTION FAILURE in
DVTFrameworks/DVTFoundation/Multicore/DVTTimeSlicedMainThreadWorkQueue.m:433
Message sent to invalidated object:
<_DVTTimeSlicedMainThreadUnorderedUniquingWorkQueue …>
```

失效堆栈包含 `IDEContainer primitiveInvalidate`、`IDEXMLPackageContainer primitiveInvalidate`、`IDEWorkspace primitiveInvalidate` 和 `IDEContainer _closeContainerIfNeeded:`；随后主线程定时器通过 `_processWorkQueuesOnDeadline`、`_processWithDeadline:`、`_evaluateProcessingStatus` 访问已经失效的队列，引发断言并终止 Xcode。

用户确认发生于编译或运行 App 期间。这里的工作区关闭/失效是日志中的内部流程，不能推断为用户手动关闭工程。报告和日志没有给出 App 代码异常，也没有足够信息确定究竟是哪项操作触发了容器失效。因此可确定直接故障在 Xcode 的队列生命周期检查，尚不能认定具体产品缺陷、工程文件写入或某个插件是触发原因。

## 与崩溃分开处理的构建障碍

- `xcodebuild -list -project Streamory.xcodeproj` 能正常解析两个 target 和 Streamory scheme。
- plist、隐私清单、工程结构检查通过。
- `xcodebuild -showdestinations` 明确报告 iOS 26.2 未安装，`simctl list runtimes` 列表为空。
- SDK 编译器可用，不代表存在能打包、启动和调试 App 的完整平台环境。

缺少运行时会阻止正常运行；目前没有证据证明它直接导致上述 Xcode 队列断言。

## 已落地的优化

1. 工程、scheme 和图标生成改为同目录临时文件写入后原子替换，避免文件被读取时只有部分内容。
2. 内容相同时完全跳过写入，保留文件修改时间，减少无意义的文件监视、工程刷新与索引工作。
3. 默认保留现有 App 图标；只有缺失或显式指定 `--regenerate-icon` 时才绘制，避免覆盖手工图标。
4. 增加 `scripts/verify.py`，独立验证工程、核心测试、原生 SDK 编译/链接和运行时环境，并把日志保存到 `build/verification`。`--build` 在运行时缺失时返回失败，不把源码验证宣称为 App 完整构建成功。

这些改动提高开发流程的可诊断性和文件更新安全性，不能视为已修复 Xcode 自身崩溃。

## 建议恢复步骤

1. 在 Xcode Settings → Components 安装 iOS 组件及运行时，再选择可用设备运行。
2. 运行 `python3 scripts/verify.py --build`，取得脱离 Xcode GUI 的构建结果；日志位于 `build/verification/app-build.log`。
3. 如果命令行构建成功、Xcode GUI 仍以同一断言退出，可检查较新兼容 Xcode 的修复说明，并向 Apple Feedback Assistant 提交崩溃报告、上述断言日志与复现步骤。
4. 如果只有本工程重复出现，可关闭工程后暂存它自己的 `xcuserdata` 或 DerivedData，再重新打开对照测试。保留原文件以便恢复，不需要清空全局 Xcode 缓存或重置所有设置。

本次没有升级 Xcode、安装大型运行时、关闭正在运行的 IDE，或删除全局缓存。

## 本次验证

- 11 项核心 XCTest 全部通过。
- 全部原生源码通过 iOS Simulator SDK 编译及链接。
- 重复执行工程生成两次，工程、scheme 和图标内容及修改时间均保持不变。
- 注入原子替换失败后，原工程文件保持完整，临时文件被清理。
- `verify.py --build` 在本机明确返回退出码 1，指出缺少 iOS 运行时。
- 尚未完成 App 打包、设备运行或 Xcode GUI 崩溃复现/消失验证。
