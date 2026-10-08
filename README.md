# 影流 · Streamory

原生 iOS MVP：随机回顾照片与视频，浏览时只标记，回顾结束后集中确认清理。采用 SwiftUI、PhotoKit、AVFoundation，最低支持 iOS 17，无第三方依赖。

## 运行

1. 用 Xcode 打开 `Streamory.xcodeproj`，选择 **Streamory** scheme。
2. 在 Signing & Capabilities 中选择自己的 Development Team；如需调整 Bundle Identifier，可在 target 的 Build Settings 修改。
3. 选择安装了 iOS 17 或更高版本的 iPhone / iPad，或已安装运行时的模拟器，运行 App。
4. 首次启动点击「开启我的回忆」，可授权全部照片或部分照片。

模拟器相册为空时，可从系统 Photos 添加本地测试媒体。若只想查看交互，在 Edit Scheme → Run → Arguments 中添加 `-demo`：此模式使用程序绘制的示例图，清理不会访问真实照片。

## MVP 功能

- 权限引导、拒绝权限后的设置入口、有限照片权限管理、空相册和离线媒体提示。
- 全部 / 照片 / 视频过滤，以及指定相册范围。
- 历史同日和长期未查看媒体加权随机排序；一轮不重复，下一轮可重新回顾。
- 图片适配屏幕、模糊背景；Live Photo 延迟 0.3 秒播放；视频静音循环、进度及声音开关。
- 左滑标记并进入下一张；上滑下一张；下滑返回上一张且保留标记。轻点媒体不再标记。
- 长按 0.5 秒，从按压位置展开穿越动画，进入当前相册的时间网格并高亮定位当前照片；可按时间浏览相邻媒体，再返回原随机位置。
- 单独的撤销按钮及最多 100 步撤销；回看和撤销分开处理。
- 四列清理网格、轻点保留、长按预览、预计空间统计、全部保留。
- 最终通过 PhotoKit `performChanges` / `deleteAssets` 请求系统确认；失败或取消后保留标记。
- 后续三张图片/视频缩略帧缓存、旧缓存释放、媒体切换请求取消、后台和结算时暂停视频。
- VoiceOver 操作标签与可访问性动作。

照片、视频和索引仅在本地处理，所有媒体请求均禁用网络。仅在 iCloud 中的原始媒体不会自动下载；可先在系统相册下载。空间估算按已标记媒体的本地资源流式累计，最多并发两项；离线无法读取的资源不计入，并在结算页说明。实际释放空间由系统决定，「最近删除」清空前空间可能尚未释放。

地点只显示媒体已有的经纬度，不发起在线地理编码。浏览历史仅保存最多 5,000 条本地标识与查看时间；本次待清理标记只存在内存，退出 App 后不会自动删除任何内容。

## 开发与验证

```sh
# 环境预检、核心测试、全部原生源码编译及链接
python3 scripts/verify.py

# 安装运行时后执行完整 App 构建
python3 scripts/verify.py --build

# 单独运行核心逻辑测试
swift test --scratch-path build/swift-tests

# 安装 iOS 模拟器运行时后，完整编译及 XCTest
xcodebuild -project Streamory.xcodeproj -scheme Streamory \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath build/DerivedData test
```

已安装 iOS 模拟器运行时，完整 App 构建通过。20 项核心测试通过，App 已在 iPhone 17 模拟器中安装并启动，演示主界面已检查。真实相册权限、删除、触觉反馈及实际设备 60/120 fps 仍需设备验收。

手工验收步骤见 `docs/acceptance.md`；原始产品需求与设计规范见 `docs/app_ui_ux.md`。

## 代码结构

- `Streamory/Core/ReviewEngine.swift`：纯 Foundation 随机排序、Session、过滤、前后导航、手势判定、撤销及库刷新同步。
- `Streamory/Core/ChronologicalAlbum.swift`：时间排序、月份分组与媒体定位索引。
- `Streamory/Services/PhotoLibraryStore.swift`：权限、后台索引、预缓存、空间估算与原生删除。
- `Streamory/Services/MediaLoader.swift`：可取消媒体加载、Live Photo、视频生命周期。
- `Streamory/Views/`：引导页、沉浸回顾、触点穿越动画、时间相册、清理结算与大图预览。
- `StreamoryTests/`：确定性随机、标记/撤销、结算、删除、权重、大相册及库刷新测试。

仓库中已包含 Xcode 工程。添加 Swift 文件后可运行 `python3 scripts/generate-project.py` 重新生成工程；脚本以原子方式更新有变化的文件，跳过未变化文件并保留现有图标。如有手工工程配置请先保留；仅在需要重绘默认图标时传入 `--regenerate-icon`。

PhotoKit 接入依据 [Apple 官方资源读取文档](https://developer.apple.com/documentation/photos/phassetresourcemanager) 与 [媒体变更文档](https://developer.apple.com/documentation/photos/phassetchangerequest)。

Xcode 26.3 崩溃的日志分析、恢复步骤和验证边界见 `docs/xcode-crash-analysis.md`。
