# AIQuota Touch Bar

Mac 菜单栏与 Touch Bar 工具：查看 Claude / Codex 的用量、AI 会话状态和工作阶段，在触控栏里处理任务，并提供歌词、小猫、专注计时、呼吸和钢琴。

本仓库包含 AIQuota 的 Mac 部分，以及 Touch Bar 歌词所需的 Chrome 扩展。

## 功能

- Control Strip 小图标显示用量与会话状态；点按展开 Touch Bar。
- AI 首页固定一屏：额度、最要紧的两张对话、对话页、可选双机入口、小猫和工具。
- 会话灯区分运行、等待用户、出错、完成和空闲，支持 Claude Code、Codex 与 ZCode。
- 工作阶段、路线图、任务操作、交接提示、材料架、常用指令与翻译。
- 小猫、专注计时、呼吸练习、触控栏钢琴，以及 Bilibili / YouTube 歌词。
- `tb` 命令可将终端任务的状态显示在触控栏上。

## 环境

- Apple 芯片 Mac，macOS 13 或更新；当前构建目标为 arm64。
- 完整 Touch Bar 功能需要带 Touch Bar 的 MacBook Pro。其他 Mac 可使用菜单栏功能。
- 编译需要带 macOS 26 SDK 的 Xcode 或 Command Line Tools。划词翻译运行时需要 macOS 26。
- 使用额度功能时，需在本机登录相应的 Claude / Codex 应用。
- Tailscale 与 `two-machine` 是可选集成；未安装时不显示双机入口。

## 构建与运行

```bash
git clone git@github.com:shuai9928/aiquota-touchbar.git
cd aiquota-touchbar
./mac/build.sh --build-only
open mac/build/AIQuota.app
```

`--build-only` 仅编译至 `mac/build/`，适合预览；接入会话灯等功能需要安装后的应用。要安装至 `~/Applications` 并启动：

```bash
./mac/build.sh
```

打开应用后，用菜单栏里的「接入…」配置会话灯、`tb` 命令、开机启动和歌词扩展。修改其他应用配置前会备份，并只处理 AIQuota 自己的条目。

Touch Bar 需要在「系统设置 → 键盘 → 触控栏设置」中开启「显示 Control Strip」。新增 Codex hooks 后，在 Codex 设置中审阅并信任相应条目；新开会话后生效。

## 歌词扩展

在 Chrome 的 `chrome://extensions` 中开启开发者模式，选择「加载已解压的扩展程序」，加载本仓库的 `chrome/` 目录。通过应用的「接入…」也可以准备扩展文件。

## 测试与打包

```bash
./mac/test.sh
./mac/package.sh
```

测试使用临时配置目录。打包脚本先测试、再构建，将安装盘输出到 `dist/`，包括应用、使用说明、卸载脚本和第三方授权。

## 数据与兼容性

Claude 用量读取本机桌面应用的用量记录；Codex 用量使用本机登录调用用量接口，只读登录文件，不修改它。会话状态主要来自本机 hooks；本仓库不包含登录文件、用户配置、会话数据或聊天记录。

Touch Bar Control Strip 使用 macOS 私有接口；系统更新可能影响兼容性。用量接口及 AI 应用的本地记录格式也可能随版本变化。

## 目录

| 目录 | 内容 |
|---|---|
| `mac/` | Swift 源码、应用信息、构建/测试/打包脚本 |
| `mac/tests/` | Swift 与 Chrome 扩展测试 |
| `chrome/` | 歌词扩展与配套脚本 |

触控栏钢琴改编自 `p-x9/pock-piano-widget`，其 MIT 授权保留在 `mac/LICENSE.piano-upstream`。
