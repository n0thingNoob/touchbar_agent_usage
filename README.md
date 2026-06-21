# touchbar_agent_usage

Codex Touch Bar 额度小工具，用 Swift/AppKit 做成 macOS 菜单栏 + Touch Bar 常驻显示。

这个项目用于在带 Touch Bar 的 MacBook 上显示 Codex 当前额度使用情况。实现思路参考小红书链接：

http://xhslink.com/o/8P2949BYKEM

## 功能

- 通过本机 Codex app-server 读取账户额度，不抓网页。
- 调用：

```sh
/Applications/Codex.app/Contents/Resources/codex app-server --listen stdio://
```

- 使用 JSON-RPC 请求：

```text
account/rateLimits/read
```

- 显示两行分段电量条：
  - `5小时`
  - `周限额`
- 右侧显示剩余百分比和重置时间。
- 剩余额度使用 `100 - usedPercent` 计算。
- 刷新时保留旧数据，新数据回来后再替换，避免 Touch Bar 空白。
- 左侧显示 Codex logo。
- 每 5 分钟自动刷新一次 usage 数据。
- Touch Bar 上点击 Codex logo，会显示 `刷新`、`打开浮窗`、`返回` 操作按钮。
- 支持随 Codex 启动自动启动，随 Codex 退出自动退出。

## Touch Bar 常驻方案

项目使用私有 `NSTouchBar` system modal selector：

```objc
presentSystemModalTouchBar:systemTrayItemIdentifier:
```

这和一些 CountdownTimer 类 Touch Bar 小工具的做法类似。它可以做到本机自用的 Touch Bar 常驻显示，但不是 Apple 公开 API：

- 不适合上架 Mac App Store。
- macOS 更新后可能失效。
- 不会出现在系统设置里的 Touch Bar Extensions / Customize Control Strip 列表中。

## 运行

```sh
swift run CodexQuotaBar
```

如果本机 `xcrun` 指向缺失的 Command Line Tools，而你安装了完整 Xcode，可以临时指定：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run CodexQuotaBar
```

## 打包为 .app

```sh
./Scripts/build-app.sh
open .build/CodexQuotaBar.app
```

打包脚本会优先使用 `/Applications/Xcode.app/Contents/Developer`，避免本机 Command Line Tools 路径损坏时构建失败。

## 随 Codex 启停

安装用户级 LaunchAgent：

```sh
./Scripts/install-codex-autostart.sh
```

它会：

- 将当前构建复制到 `~/Applications/CodexQuotaBar.app`
- 每 10 秒检查 Codex 桌面端主进程 `/Applications/Codex.app/Contents/MacOS/Codex`
- Codex 启动而小工具未启动时，自动打开小工具
- Codex 退出时，自动关闭小工具

卸载：

```sh
./Scripts/uninstall-codex-autostart.sh
```

## 右键菜单

菜单栏 `Codex xx%` 右键菜单包含：

- `刷新`
- `显示额度`
- `打开浮窗`
- `退出`

## 项目结构

```text
Sources/CodexQuotaBar/main.swift
Sources/TouchBarPrivateSupport/TouchBarPrivateSupport.h
Sources/TouchBarPrivateSupport/TouchBarPrivateSupport.m
Scripts/build-app.sh
Scripts/install-codex-autostart.sh
Scripts/uninstall-codex-autostart.sh
```