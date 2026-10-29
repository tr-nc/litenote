# Papertray

一张固定的 macOS 横线纸：快捷键唤出，写字、粘贴图片，再把文字和本地图片路径复制给同机 Pi。没有工具盘、待办纸、文档列表或新建文档操作。

## 构建与运行

需要完整 Xcode；部署目标 macOS 14+。当前在 arm64 macOS 26.6.2 上验证，Intel 和 macOS 14 的运行行为尚未实测。

```sh
# Release（arm64 + x86_64）
xcodebuild -project Papertray.xcodeproj -scheme Papertray \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath build build

open build/Build/Products/Release/Papertray.app

# 当前开发机上的测试
xcodebuild -project Papertray.xcodeproj -scheme Papertray \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build test
```

也可打开 `Papertray.xcodeproj`，选择共享的 Papertray scheme。升级时先正常退出旧进程，再启动新构建。

使用本地 ad-hoc 签名，未做 Developer ID 签名或公证，不是公开分发包。不需要关闭 Gatekeeper，也不需要辅助功能、屏幕录制或全局输入监控权限。KeyboardShortcuts 锁定 3.1.0；见 [第三方声明](Papertray/ThirdPartyNotices.txt)。

## 使用

- 首次启动直接显示横线纸。默认 **⌥.（Option + 句号）** 显示／收起同一张纸；设置可重绑定或清除，旧快捷键绑定仍保留。
- 再次唤出恢复当前会话中的光标／选区，直接继续输入；不会新建另一张纸。
- **Esc、左上角关闭按钮都只收起纸张，不删除内容。** 输入法组合期间 Esc 优先交给输入法。图片导入中或保存失败时不关闭窗口。
- 想清空就 **⌘A → Delete**，与普通编辑一样可撤销。自动保存后，重启仍是这张空纸，不会恢复另一份旧文档。
- 顶部无标题文字，仍可拖顶部移动、拖窗口边缘调整大小；长正文在同一个编辑器里连续滚动。显示／隐藏不播放过渡动画。
- Return 与 Shift+Return 都是普通换行。横线跟随文字基线，空行间距保持稳定，插图可以撑开自己的行。
- **⌘V** 接受文字与 PNG/TIFF 剪贴板位图；图片导入本地 PNG。暂不支持文件拖放、任意富文本、动画和多页图片。
- **⌘C／⌘X** 只输出选区文字与图片绝对路径，单选图片输出路径，不发布公开图片或 RTF 剪贴板格式。
- 深色原生毛玻璃、白字，图片保持原色。菜单栏 → **设置…** 可调系统材质、Tint 颜色／浓度、颗粒大小／强度，并恢复默认。亮色 Tint 会以同色相的深色呈现；颗粒强度最左为关闭。
- 材质选项改变系统模糊观感，**不是精确的模糊半径**；不捕获屏幕。系统开启“减少透明度”时使用不透明深色背景并关闭颗粒。
- 菜单栏只提供显示／收起、设置和退出。登录启动默认关闭。

## 保存与旧数据

数据根目录：`~/Library/Application Support/Papertray/`

```text
paper.json                固定横线纸的身份引用
notes/<UUID>.json         正文（继续使用原来的文件，身份不变）
backups/<UUID>.json       前一个有效保存版本
attachments/<UUID>.png    已导入图片
```

第一次升级会沿用**最近修改的旧横线纸**；没有横线纸时只创建一次空白纸。其他旧横线纸和待办纸保留在原目录，不再打开，不自动删除、合并或转换。旧颜色元数据保留，显示统一为白字。

之后始终由 `paper.json` 指向同一个文档，清空、隐藏、重启及重置窗口偏好都不会切换文档。引用或正文缺失／损坏／版本不受支持时会报错，不用空白覆盖，也不自动换成旧文档。首次迁移遇到损坏的旧文件同样停止并保留数据；暂无恢复管理界面。

窗口位置、显隐状态、毛玻璃外观保存在 UserDefaults。旧 `trash/` 如存在会原样保留，新版本不使用它。正文保存先验证图片路径，再原子写入；删除正文、清空或剪切不删除图片文件，避免已复制给 Pi 的路径失效。暂无附件自动清理。

Pi 仍需要调用文件读取工具，模型／工具链也需支持图片；路径本身不会自动把图片放进上下文。

## 验证边界

当前为本地可运行版本。自动化证据及待手工验收见 [docs/VALIDATION.md](docs/VALIDATION.md)；真实输入法候选、全局快捷键、跨 Space、多屏、桌面模糊观感和性能不能仅凭测试通过宣称完成。
