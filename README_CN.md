# macOS Locked Use

[English](./README.md) | 简体中文

Computer Use 通过窗口截图、无障碍树（Accessibility）与键鼠事件让 AI Agent 操作桌面应用。在无人值守场景下，核心目标是让 Agent 继续操作宿主桌面，而物理屏幕前的其他人看不到桌面内容、也不能操作电脑。

但在 macOS 上，进入锁屏后系统会停止输出桌面窗口画面，并将键鼠与无障碍输入限制在锁屏界面，导致 Agent 无法继续操作；而现有的替代方案也无法同时满足这一目标：
- **关闭系统锁屏保持常亮**：Agent 可继续操作，但物理屏幕暴露桌面内容，屏幕前的其他人也可操作当前会话。
- **本地保存登录密码代填解锁**：需在本机持久化存储用户登录密码，且解锁后同样会在物理屏幕上暴露桌面并允许他人操作。
- **在独立虚拟机中运行**：不暴露宿主屏幕，但与宿主桌面隔离，Agent 无法操作宿主上已登录的应用与会话。

`macos-locked-use` 为 macOS 上的 Computer Use 提供独立的锁屏会话层，在不存储用户登录密码的前提下，实现**锁屏期间 Agent 可操作宿主窗口，而物理屏幕前的其他人看不到桌面、也无法操作**：
- **定向窗口操作**：临时解锁图形会话，通过 `ScreenCaptureKit` 独立窗口采集与按窗口 ID / PID 定向事件投递操作目标应用。
- **全屏遮罩与本地输入重锁**：所有显示器覆盖全屏模糊壁纸遮罩（显示当前用户头像、`<宿主应用名> is Using Your Mac` 与 `Press any key or click to unlock`）；任务结束时恢复系统锁屏，检测到本地鼠标移动或按键时重锁并要求用户先手动解锁一次后才能再次启用（`awaitingManualUnlock`）。
- **单次授权许可**：通过 `SecurityAgent` 授权插件与 `root` 守护进程配合，在双进程遮罩就绪后签发 5 秒有效期的单次解锁许可，任务结束后恢复锁屏并由用户以密码或 Touch ID 解锁。

```sh
./scripts/build-locked-use.sh --identity "Apple Development: Your Name (TEAMID)"
./dist/release-native/bin/locked-use enable
./dist/release-native/bin/locked-use capture --app Finder --out /tmp/finder.png
```

AI Agent Skill：[`skills/macos-locked-use/SKILL.md`](./skills/macos-locked-use/SKILL.md)

## 接入方式

本仓库提供命令行工具（`locked-use`）与 Swift 库（`LockedUseKit`），共用同一套守护进程与系统授权插件：

| 适用场景 | 接入入口 | 集成方式 |
| --- | --- | --- |
| Node.js / Python / Go / Rust 进程、MCP Server、命令行 Agent | `locked-use` | 构建签名宿主包 `LockedUse.app`，通过内置 `capture / click / type / key` 或 `exec` 操作桌面，任务结束调用 `locked-use end`。 |
| 原生 Swift macOS 客户端（自带签名 `.app` 包与设置界面） | `LockedUseKit` | 在 `Package.swift` 中引入 `LockedUseKit`，将 4 个辅助组件打入应用包 `Contents/Resources/LockedUse/`，在进程内调用 `LockedUseConnection` 与 `LockedUseGUI`（无需对外暴露命令行工具）。 |

环境与签名要求：macOS 14+，Xcode 15.4+，以及含 Team ID 的 Apple 签名证书（`Apple Development` 或 `Developer ID Application`）。macOS 安全插件加载与进程间双向验签拒绝 `-` 匿名签名，从源码接入需在本地使用自有证书签名构建；独立发行的 macOS 客户端可将签名公证后的辅助组件随 `.app` 一并分发。

## 命令行接入

### 1. 构建签名包与初始化

```sh
git clone https://github.com/nia-teams/macos-locked-use.git
cd macos-locked-use

# 查看本机含 Team ID 的签名证书
security find-identity -v -p codesigning

# 构建并签名 ./dist/release-native/LockedUse.app 与软链 ./dist/release-native/bin/locked-use
./scripts/build-locked-use.sh --identity "Apple Development: Your Name (TEAMID)"

# 在解锁状态下安装系统组件并按提示为宿主开启权限
./dist/release-native/bin/locked-use enable
./dist/release-native/bin/locked-use status --json
```

`build-locked-use.sh` 默认构建当前架构 `release` 包并使用 Bundle ID `com.nia-teams.locked-use.app`，可通过 `--arch universal` 或 `--bundle-id <id>` 覆盖。部署时保留 `LockedUse.app` 目录结构，通过 `LockedUse.app/Contents/MacOS/locked-use` 或 `dist/release-native/bin/locked-use` 软链调用。

### 2. 租约生命周期与调用方式

- **未锁屏状态**：`locked-use` 在当前桌面会话内执行窗口操作或前台子命令。
- **锁屏状态**：首次执行 `capture / click / type / key` 或 `exec` 时唤醒显示器、铺设全屏遮罩、临时解锁图形会话并执行操作。单步命令返回后，用户态会话进程保留租约 **30 秒空闲窗口**，单次租约累计上限 **300 秒**；窗口内的后续命令复用同一遮罩会话。
- **到期与释放**：任务完成后调用 `locked-use end` 释放租约并重锁。空闲满 30 秒或累计满 300 秒时，Broker 收回租约、终止仍在运行的 `exec` 子进程并恢复系统锁屏，命令以退出码 `76` 结束。

**Shell 示例：**

```sh
locked-use capture --app TextEdit --out /tmp/textedit.png
locked-use click --app TextEdit --x 240 --y 180 --pixel
locked-use type --app TextEdit --text "Hello from Locked Use"
locked-use key --app TextEdit --key Return
locked-use end
```

**Node.js / TypeScript 示例：**

```ts
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const LOCKED_USE_BIN = "/path/to/dist/release-native/bin/locked-use";

export async function runLockedUse(args: string[]) {
  return execFileAsync(LOCKED_USE_BIN, args);
}

async function runTask() {
  try {
    const { stdout } = await runLockedUse(["capture", "--app", "TextEdit", "--out", "/tmp/win.png"]);
    const capture = JSON.parse(stdout);
    await runLockedUse(["click", "--window-id", String(capture.windowID), "--x", "240", "--y", "180", "--pixel"]);
    await runLockedUse(["type", "--window-id", String(capture.windowID), "--text", "Hello"]);
  } finally {
    await runLockedUse(["end"]);
  }
}
```

## 遮罩下窗口操作

遮罩激活期间，Guardian 在全局会话层拦截键鼠事件：任何全局 HID 事件（物理键鼠、`cliclick`、`System Events click at {x, y}` 或 `CGEvent.post(tap:)`）都会被判定为本地输入接管并触发重锁。遮罩下的截图与键鼠交互需使用定向到目标窗口或进程的接口：

1. **内置窗口子命令**：`locked-use capture / click / type / key`（基于 `ScreenCaptureKit` 独立窗口采集与按窗口 ID / PID 定向投递事件，兼容原生 Cocoa 窗口与 Chrome / Electron 等自绘窗口）。
2. **无障碍动作**：在 `locked-use exec` 内通过 `AXUIElementPerformAction`（如 `AXPress`）或 `AXUIElementSetAttributeValue` 读写控件属性（不产生全局键鼠事件）。

### 子命令与参数

```sh
locked-use status [--json]
locked-use enable | disable | recover | end | lock
locked-use capture (--app <name-or-bundle-id> | --pid <pid> | --window-id <id>) --out <file.png> [--require-locked]
locked-use click <target> --x <coord> --y <coord> [--pixel] [--double] [--window-local | --screen] [--require-locked]
locked-use type <target> --text <text> [--require-locked]
locked-use key <target> --key <cmd+v|Return|...> [--require-locked]
locked-use exec [--require-locked] -- <command> [args...]
```

- **窗口选择器（`<target>`）**：支持 `--app`、`--pid`、`--window-id` 单独或组合约束；未指定 `--window-id` 时选取最靠前的正常 `layer == 0` 应用窗口。
- **坐标与 Retina 换算**：`capture` 输出 JSON（含 `windowID`、`pid`、逻辑点 `bounds`、物理像素 `pixelWidth` / `pixelHeight` 与 `path`），只采集目标窗口自身像素，不包含遮罩画面。`click` 传入 `--pixel` 时按窗口截图像素坐标点击，默认采用相对窗口左上角的逻辑点（`--window-local`），传入 `--screen` 时采用全局屏幕逻辑点。
- **管理与执行子命令**：
  - `enable` / `disable` / `recover`：安装或更新组件、卸载组件并恢复原认证规则、修复中断的安装。更新宿主应用后若 `status` 提示插件版本不一致，再次运行 `enable` 同步系统组件。
  - `exec [--require-locked] -- <cmd> [args...]`：在遮罩会话内运行前台子进程（如无障碍树查询脚本）。加 `--require-locked` 时，若当前未锁屏且无活跃租约则返回 `77`。

### 退出码

| 退出码 | 含义 | 调用方处理方式 |
| --- | --- | --- |
| `0`（或子命令退出码） | 操作完成；`exec` 在未发生保护中断时透传子进程退出码 | 继续后续步骤 |
| `75` | 检测到本地键鼠输入或处于 `awaitingManualUnlock`，屏幕已重锁 | 停止任务并交回本地控制，不提示用户重新锁屏 |
| `76` | 租约达到 30 秒空闲超时或 300 秒时长上限，或运行期间另一终端调用 `locked-use end` 释放了租约 | 按需决定是否发起新租约 |
| `77` | 未安装、缺少权限、或未满足 `--require-locked` | 检查 `locked-use status --json` 中的 `blockers` |
| `64` | 命令行参数格式错误 | 修正调用参数 |

当 `locked-use` 自身因保护中断或前置检查返回 `75` / `76` / `77` / `64` 时，会向 `stderr` 输出以 `locked-use: ` 开头的一行诊断信息；可据此与 `exec` 子进程自身返回的同名退出码区分。

## 客户端库接入

原生 macOS 应用（`YourApp.app`）可在进程内集成 `LockedUseKit`，锁屏遮罩展示宿主应用的名称与图标。

### 1. 添加 SwiftPM 依赖

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/nia-teams/macos-locked-use.git", from: "0.1.0")
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "LockedUseKit", package: "macos-locked-use")
        ]
    )
]
```

### 2. 打包辅助组件

使用与 `YourApp.app` 相同的签名证书和 Team ID 构建 4 个辅助组件，放入 `YourApp.app/Contents/Resources/LockedUse/`：

```sh
./scripts/build-locked-use-components.sh \
  --identity "Developer ID Application: Your Team (TEAMID)" \
  --configuration release \
  --arch universal

mkdir -p "YourApp.app/Contents/Resources/LockedUse"
for item in LockedUseInstaller LockedUseService LockedUseGuardian LockedUseAuth.bundle; do
  ditto ".build/locked-use/components-release-universal/$item" \
    "YourApp.app/Contents/Resources/LockedUse/$item"
done
```

在 `YourApp.app/Contents/Info.plist` 中声明输入监控权限用途：

```xml
<key>NSInputMonitoringUsageDescription</key>
<string>在锁屏操作期间检测本地键鼠输入并恢复锁屏。</string>
```

### 3. 调用接口

```swift
import LockedUseKit

// 查询诊断状态
let diagnostics = LockedUseDiagnostics.collect()

// 启用或停用（在解锁状态下由主线程调用）
@MainActor
func setLockedUseEnabled(_ enabled: Bool) throws {
    _ = try LockedUseSettings.handle(
        arguments: ["locked-use", enabled ? "enable" : "disable"]
    )
}

// 在租约内串行执行窗口点击与输入
@MainActor
func clickAndType(connection: LockedUseConnection) throws {
    try connection.perform(requireLocked: false) {
        let target = try LockedUseGUI.findWindow(app: "TextEdit")
        try LockedUseGUI.click(target: target, x: 120, y: 90)
        try LockedUseGUI.typeText("Hello", windowID: target.windowID, pid: target.pid)
        try LockedUseActionScope.validate()
    }
}
```

异步单窗口截图 `LockedUseGUI.captureWindow(windowID:outputPath:)` 可配合 `LockedUseConnection.beginAction` / `finishAction` 与 `LockedUseActionScope.withAsyncValidator` 调用；同一连接上的 GUI 操作保持串行。

## 系统权限

在「系统设置 → 隐私与安全性」中只需为**宿主应用**开启三项权限：

| 授权对象 | 权限 | 用途 |
| --- | --- | --- |
| 宿主应用（`LockedUse` 或接入方 `YourApp`） | 辅助功能、屏幕录制、输入监控 | 操作目标窗口与锁屏控件、独立窗口截图、检测物理键鼠接管 |

`LockedUseGuardian` 编译为独立签名的纯 Mach-O 可执行文件（非 `.app` 应用包），由宿主进程通过 `Process` 拉起，macOS TCC 将其辅助功能与输入监控归属到宿主应用名下，系统设置中不会出现第二个授权条目。Broker 与授权插件不申请 TCC 权限。

安装与卸载需管理员密码或 Touch ID 授权。首次运行 `enable` 时若宿主尚未勾选上述权限，命令仍会完成组件安装；在系统设置中打开宿主开关并按系统提示重开宿主后，运行 `locked-use status --json` 确认 `"available": true`。

## 安装组件与路径

下表中的 `ROOT` 指 `/Library/Application Support/LockedUse`：

| 组件 / 文件 | 安装路径 | 用途 |
| --- | --- | --- |
| `LockedUseGuardian` | `ROOT/LockedUseGuardian` | 渲染全屏遮罩，唤醒屏幕、驱动锁屏认证并监听物理键鼠接管 |
| `LockedUseService` | `ROOT/LockedUseService` | Broker 守护进程（`root`），管理单次解锁许可、租约与双进程释放屏障 |
| `LockedUseInstaller` | `ROOT/LockedUseInstaller` | 安装、卸载与恢复系统组件及认证规则 |
| `LockedUseAuth.bundle` | `/Library/Security/SecurityAgentPlugins/LockedUseAuth.bundle` | `SecurityAgent` 授权插件，在锁屏认证时向 Broker 请求单次许可 |
| `com.nia-teams.locked-use.broker.plist` | `/Library/LaunchDaemons/com.nia-teams.locked-use.broker.plist` | 注册并拉起 `LockedUseService` 守护进程 |
| 运行时状态与通信目录 | `ROOT/*.json`、`ROOT/run/` | 保存客户端签名白名单、认证规则备份、恢复记录与本地 UNIX socket |

`enable` 会在系统 Authorization Database 的 `system.login.screensaver` 规则中加入 `LockedUseAuth` 分支并保留原生密码与 Touch ID 认证分支；`disable` 恢复原有规则并移除上述文件。

## 组件协作流程

宿主应用（或 `locked-use`）在锁屏状态下向 Broker 申请租约后，拉起 `LockedUseGuardian` 主进程与独立的 `Watchdog` 进程覆盖所有显示器。Broker 确认两个守护进程均已就绪后签发 5 秒有效期的单次许可，由 Guardian 唤醒屏幕并触发锁屏认证；`SecurityAgent` 加载 `LockedUseAuth.bundle` 向 Broker 核销该单次许可完成解锁。租约主动结束或到期（30 秒空闲 / 300 秒上限）时，恢复系统锁屏并回到 `idle`；若任务期间任一守护进程失联或检测到物理键鼠输入，屏幕重锁并转入 `awaitingManualUnlock`，待用户使用密码或 Touch ID 解锁一次后，Broker 轮询检测到同 UID、同 `auditSessionID` 的已解锁控制台会话再复位回 `idle`。

## 安全与风险

- **本机进程的调用边界**：Broker 通过内核 `LOCAL_PEERTOKEN` 校验连接进程的签名标识、Team ID、Hardened Runtime，并拒绝带 `get-task-allow` 或注入环境变量的进程。若客户端在进程内集成 `LockedUseKit` 且不安装 `locked-use` CLI，本机其他程序无法借用其签名解锁屏幕；若在机器上部署 `locked-use` CLI，当前登录用户下的其他本地进程可调用 `locked-use` 借用其签名在锁屏期间截图或操作窗口。
- **锁屏异常与远程恢复**：修改 `system.login.screensaver` 涉及系统锁屏认证链路，安装前建议在「系统设置 → 通用 → 共享」中开启「远程登录（SSH）」。若插件异常或锁屏界面长时间无法进入桌面，可从另一台设备通过 SSH 登录执行以下命令恢复系统原生锁屏认证：
  ```sh
  sudo "/Library/Application Support/LockedUse/LockedUseInstaller" recover
  ```
- **登录钥匙串保持锁定**：无密码解锁未提供用户的登录密码，macOS 登录钥匙串（Login Keychain）在遮罩解锁期间仍处于锁定状态；依赖登录钥匙串读取凭据的应用在此期间无法读取受保护条目。
- **已验证的系统版本**：已在 Apple Silicon Mac（macOS 15.6）上完成实测验证；构建与运行最低要求为 macOS 14.0。

## 验证

```sh
python3 scripts/check-source.py
./scripts/test-locked-use.sh
```

## 许可证

[MIT](./LICENSE)。基于 [open-computer-use](https://github.com/iFurySt/open-computer-use) 的 Locked Use 模块重构。
