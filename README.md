# Papertray

轻量 macOS 菜单栏便笺：唤出工具盘，拖出横线纸或待办纸，输入、粘贴图片，再把文字和本地图片路径复制给同机 Pi。

**当前状态：阶段 A 可运行验证版，不是完整首版。** 已有原生应用、XCTest 和 Release 构建；跨屏真实拖动、中文输入法、全屏/Space 和实际 Pi 输入框粘贴仍待手工验收。产品合同见 [HANDOFF.md](HANDOFF.md)，实现与测试边界见 [docs/VALIDATION.md](docs/VALIDATION.md)。

## 构建与运行

需要完整 Xcode；部署目标 macOS 14+，目前只在 arm64 macOS 26.6.2 上运行验证。

```sh
# Release（arm64 + x86_64；Intel 运行行为尚未测试）
xcodebuild -project Papertray.xcodeproj -scheme Papertray \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath build build

open build/Build/Products/Release/Papertray.app

# 当前 arm64 开发机上的测试
xcodebuild -project Papertray.xcodeproj -scheme Papertray \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build test
```

也可直接打开 `Papertray.xcodeproj`，选择共享的 Papertray scheme。

本地构建使用 **ad-hoc 签名**，未做 Developer ID 签名或公证，不是公开分发包。不需要禁用 Gatekeeper 或授予完全磁盘访问、输入监控、辅助功能、屏幕录制权限。依赖 KeyboardShortcuts 精确锁定 3.1.0，许可证随应用打包于 `ThirdPartyNotices.txt`，源码见 [第三方声明](Papertray/ThirdPartyNotices.txt)。

## 使用

- 首次启动显示工具盘；菜单栏托盘图标也可打开。
- 默认 **⌥.（Option + 句号）** 切换工具盘，设置里可重绑定或清除。
- **拖出**横线纸/待办纸创建新便笺，单击只选择；Esc、拖回工具盘取消。
- 拖标题栏移动，拖窗口边缘调整大小。长正文在一个编辑器中垂直滚动；横线跟随实际文字基线，换行、缩放窗口和插图后仍对齐。
- Todo：每项是独立的横线区域，左侧 checkbox 固定在区域起始处，右侧容纳文字与图片。内容增加时区域向下扩展，后续区域顺延，整页统一滚动。
- **Return** 拆分/新建下一项，**Shift+Return** 在当前区域内换行；多段粘贴仍属于同一项。
- 点击 checkbox 勾选，支持撤销/重做。控件不属于可拖选的正文；在相邻项边界删除会合并项目，全选删除后保留一个空项。
- 工具盘笔色只影响之后输入，不给旧选区染色。
- **⌘V** 接受文字、PNG/TIFF 剪贴板位图；图片独立导入 PNG。暂不支持往正文拖文件、任意富文本、动画和多页图片。
- **⌘C / ⌘X** 输出实际选区的纯文本、待办标记和图片绝对路径。单选图片输出路径。不会同时发布公开图片/RTF 类型。
- 便笺标题栏不显示红黄绿按钮，只保留删除按钮；点击后确认永久删除正文和备份，不进废纸篓、不能撤销。删除失败保留编辑内容并允许重试；已导出的图片附件仍保留。
- 登录启动默认关闭，只有在设置中主动开启才调用系统登录项接口。

## 数据

固定根目录：

```text
~/Library/Application Support/Papertray/
  notes/<UUID>.json
  attachments/<UUID>.png
  backups/<UUID>.json
  trash/
```

复制时输出实际绝对路径，不含 `~`。文档只记录附件 UUID；先原子保存、验证图片，再保存文档、允许复制。移除图片、剪切、撤销不删除实体文件；当前没有自动附件清理。

窗口位置、可见性和当前笔色保存在应用 UserDefaults。删除笔记使用标题栏按钮，不提供废纸篓；`trash/` 是旧版本预留的空目录。损坏或较新版本文档不会被空白覆盖，备份恢复界面尚未实现。

Pi 仍需调用文件读取工具，模型/工具链也需支持图片；路径本身并不自动把图片放进模型上下文。

## 接下来

先完成 [验证记录中的手工门槛](docs/VALIDATION.md#待手工验收)，再进入阶段 B：故障恢复、快捷键注册失败反馈、持久化性能与更完整的编辑边界。视觉特效不在本轮范围。
