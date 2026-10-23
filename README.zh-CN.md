<p align="center">
  <img src="assets/logo/poster.png" alt="POCOX poster" width="100%" />
</p>

<h1 align="center">POCOX</h1>

<p align="center">
  <strong>PO</strong>cket&nbsp;<strong>CO</strong>de<strong>X</strong> · <em>把你的每一台设备，都装进口袋。</em>
</p>

<p align="center">
  <a href="CHANGELOG.md"><img alt="status: work in progress" src="https://img.shields.io/badge/status-WIP-626C7E"></a>
  <a href="https://github.com/acking-you/POCOX/releases"><img alt="latest release" src="https://img.shields.io/github/v/release/acking-you/POCOX?color=355ACF&label=release"></a>
  <a href="https://www.rust-lang.org"><img alt="rust" src="https://img.shields.io/badge/built%20with-Rust-355ACF.svg"></a>
  <a href="https://flutter.dev"><img alt="flutter" src="https://img.shields.io/badge/UI-Flutter-355ACF.svg"></a>
  <a href="LICENSE"><img alt="license" src="https://img.shields.io/badge/license-Apache--2.0-355ACF.svg"></a>
</p>

<p align="center">
  <a href="README.md">English</a> · <strong>中文</strong>
</p>

> [!WARNING]
> POCOX 正在积极开发中：API、磁盘布局和协议都可能不经通知而变化。欢迎反馈缺陷和设计意见。

POCOX 把你的每一台设备都装进口袋。智能体照原厂的方式继续用；POCOX 在每台电脑上跟进它们的会话，让手机、平板或另一台电脑随时接手。

## 支持的智能体

<table>
  <tr>
    <td align="center" width="25%"><a href="docs/app-server-protocol-sync.md"><img src="assets/readme/codex.svg" width="36" alt=""><br><b>Codex</b></a><br><sub>原生 app-server</sub></td>
    <td align="center" width="25%"><a href="docs/acp-agents.md"><img src="assets/readme/claude.svg" width="36" alt=""><br><b>Claude Code</b></a><br><sub>ACP 适配器</sub></td>
    <td align="center" width="25%"><a href="docs/opencode-native.md"><img src="assets/readme/opencode.svg" width="36" alt=""><br><b>OpenCode</b></a><br><sub>原生服务</sub></td>
    <td align="center" width="25%"><a href="docs/grok-build.md"><img src="assets/readme/grok.svg" width="36" alt=""><br><b>Grok Build</b></a><br><sub>ACP 与 Grok 扩展</sub></td>
  </tr>
</table>

其它 ACP 智能体只需填写程序和参数即可托管（[ACP 智能体](docs/acp-agents.md)）。

## 能做什么

- **图片附件**：随消息发送图片，并在主机会话项目中保留副本，供智能体的看图工具读取（[附件](docs/composer-turns.md#attachments)）。

- **这台机器上的每一个会话**：列出并实时跟进 Codex、Claude Code、Grok Build 与 OpenCode 运行的会话，包括在它们自己的 App 或 CLI 里开启的（[原生历史](docs/native-agent-history.md)，含平台限制）。
- **任意服务，所有设备**：在其它设备上访问每台电脑的智能体，并共享开发服务器或 API；智能体也能借助 `pocox` 工具自己共享端口、连接端口或 API（[智能体工具](docs/agent-tools.md)）。
- **任意桌面都能托管**：macOS、Windows 和 Linux 可同时托管多个智能体，各自配置模型服务（[托管](docs/hosting-configuration.md)）。
- **随处触及**：iOS、Android、桌面 App 和 CLI 可以引导对话、处理审批、浏览历史、查看改动（[App](docs/app-ui.md)）。
- **共享订阅**：把一台电脑的 Codex 登录发布成 OpenAI 兼容的 Responses API，没装 Codex 的设备也能用（[CLI](docs/cli.md)）。
- **管理其它电脑**：在手机上为另一台桌面添加、配置和停止服务（[远程管理](docs/remote-device-management.md)）。

规划中：让智能体直接操作你其它设备的 shell 和文件。

## 工作原理

每台电脑在智能体旁运行 POCOX App 或 CLI，设备之间经 [pb-mapper](https://github.com/acking-you/pb-mapper) 中转访问彼此的服务，可用共享密钥（自建）或 GitHub 登录（托管账号）。详见[架构](docs/architecture.md)。

## 快速开始

从 [Releases](https://github.com/acking-you/POCOX/releases) 下载 App，或安装 CLI：

```bash
curl -fsSL https://raw.githubusercontent.com/acking-you/POCOX/main/scripts/install.sh | sh
```

```bash
pocox login     # 每台设备都用同一个 GitHub 账号登录
pocox serve     # 在装有 Codex 的电脑上
pocox connect   # 在另一台设备上，然后运行打印出的 codex --remote 命令
```

Windows 安装、自建中转与全部命令见 [CLI](docs/cli.md)；分步指南见[使用指南](docs/usage.zh-CN.md)；自建后端见 [deploy](deploy/README.md)。0.6.0 之后的版本全新起步，不迁移旧版本的设置（[更新日志](CHANGELOG.md)）。

## 文档

| | |
| --- | --- |
| **使用** | [使用指南](docs/usage.zh-CN.md) · [CLI](docs/cli.md) · [部署](deploy/README.md) · [架构](docs/architecture.md) |
| **智能体** | [Codex 协议](docs/app-server-protocol-sync.md) · [ACP 智能体](docs/acp-agents.md) · [OpenCode](docs/opencode-native.md) · [Grok Build](docs/grok-build.md) · [托管配置](docs/hosting-configuration.md) |
| **会话** | [原生历史](docs/native-agent-history.md) · [历史缓存](docs/session-cache-sync.md) · [Guardian](docs/guardian-sessions.md) · [文件链接](docs/session-file-links.md) · [图像](docs/native-image-generation.md) · [语音](docs/live-voice.md) |
| **App** | [界面](docs/app-ui.md) · [输入框](docs/composer-turns.md) · [智能体工具](docs/agent-tools.md) · [星系](docs/galaxy-geometry.md) · [更新](docs/app-updates.md) |
| **设备** | [远程管理](docs/remote-device-management.md) · [中转恢复](docs/relay-worker-recovery.md) · [连接生命周期](docs/harness-connection-lifecycle.md) |
| **发布** | [macOS](docs/macos-release.md) · [Linux AppImage](docs/linux-appimage.md) · [更新日志](CHANGELOG.md) |

全部文档：[文档索引](docs/README.md)（多为英文）。

## 参与贡献

构建、测试和提交 PR 的步骤见 [CONTRIBUTING.md](CONTRIBUTING.md)；面向开发者与智能体的编码和设计规则见 [AGENTS.md](AGENTS.md)。

## 许可证

[Apache License 2.0](LICENSE)。`deps/` 下的子模块各自保留其许可证。
