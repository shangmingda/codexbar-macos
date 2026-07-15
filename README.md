# CodexBar for macOS

CodexBar 是一个原生 macOS 菜单栏工具，用于查看当前 Codex 账号额度和正在执行的任务。

## 功能

- 自动读取当前 Codex 账号的真实额度窗口：仅有周额度时显示一行；恢复“5 小时 + 周额度”时自动显示两行。
- 展示当前账号所有可用重置卡的真实到期日；明细不完整时自动重试，不显示伪造的“未知日期”。
- 可明确开启“到期前 1 小时自动使用重置卡”；真实兑换、最早到期优先，并用稳定幂等键避免重复消耗。
- 合并统计 Codex 桌面版普通运行任务与 `active` Goal，同一线程只计一次。
- 运行秒数取自当前 turn 的真实启动时间，点击跳转、刷新或打开 Codex 不会重新计时。
- 每个任务可独立设置 25K～5M Token 上限，从设置时的真实累计量开始计算；使用到 90% 时自动发送收尾提示，达到上限后只中断对应任务，不影响其他任务。
- 如果安装时 Codex 已在运行，CodexBar 会等所有任务结束后自动完整重启一次 Codex 并启用停止能力；也可在面板确认后立即启用。
- 点击任务直接通过 `codex://threads/{threadId}` 返回对应 Codex 窗口。
- Codex 桌面版启动时自动补启动 CodexBar；两者关闭互不影响，且不会重复启动。
- 不读取或保存 `auth.json`，不要求 API Key，不依赖付费服务。
- 额度每 60 秒刷新，任务每 15 秒刷新；打开面板时立即刷新任务。
- 任务和额度获取包含自动重试、SQLite 忙等待与上次成功结果保护，瞬时失败不需要手动刷新恢复。

## 兼容性

| 项目 | 状态 |
| --- | --- |
| macOS 14 及以上 | 支持 |
| Apple Silicon | 已实机验证 |
| Intel Mac | 源码可构建，尚未实机验证 |
| Codex Desktop | 需要已安装并登录当前用户账号 |
| Codex 额度模式 | 自动识别单窗口或双窗口 |
| 多 macOS 用户 | 只读取当前登录用户的 `CODEX_HOME` / `~/.codex` |
| 纯 Codex CLI 任务 | 不纳入桌面版普通运行任务统计 |

当前实机验证环境和升级注意事项见 [适配与部署说明](docs/COMPATIBILITY_AND_DEPLOYMENT.md)。

## 从 GitHub 安装

前置要求：安装 Xcode Command Line Tools，并确认 Codex Desktop 已登录。

```bash
xcode-select -p >/dev/null 2>&1 || xcode-select --install
git clone https://github.com/shangmingda/codexbar-macos.git
cd codexbar-macos
./scripts/install.sh
```

如果刚执行了 `xcode-select --install`，请等待系统完成安装后，再重新运行 `./scripts/install.sh`。

安装脚本会：

1. 在本机以 Release 模式编译并临时签名。
2. 安装到 `~/Applications/CodexBar.app`。
3. 创建用户级 LaunchAgent，使登录后自动运行。
4. 安装轻量监听器，在 Codex Desktop 启动时补启动 CodexBar。
5. 启用 Codex 官方共享 app-server 控制通道，用于精确中断达到上限的单个 turn。

如果安装时 Codex Desktop 已经打开，正在运行的旧任务不能迁移到共享控制服务。CodexBar 会等待所有任务结束后自动完整重启一次 Codex；之后新任务达到上限时会被精确停止。也可以点击面板中的“立即启用”，确认中断当前所有任务后立刻完成重启。

## 验证

```bash
swift build
swift run codexbar-selftest
swift run codexbar-diagnostics
```

`codexbar-diagnostics` 只输出额度窗口与任务摘要，不输出账号凭据。

也可以单独诊断：

```bash
swift run codexbar-diagnostics --quota-only
swift run codexbar-diagnostics --tasks-only
```

控制通道只读探针：

```bash
swift run codexbar-diagnostics --tasks-only \
  --control-probe="$HOME/.codex/app-server-control/app-server-control.sock"
```

## 升级

```bash
cd codexbar-macos
git pull --ff-only
./scripts/install.sh
```

安装脚本会安全替换旧版本并重载 LaunchAgent。

## 卸载

```bash
cd codexbar-macos
./scripts/uninstall.sh
```

卸载只移除 CodexBar、监听器和对应 LaunchAgent，不修改 Codex Desktop 或 `~/.codex` 数据。

## 隐私与实现边界

- 额度通过当前机器自带的 Codex `app-server` 读取，自动使用 Codex Desktop 当前登录账号。
- 任务状态通过当前用户的 Codex 本地状态库和桌面主进程当前打开的 rollout 日志只读判断。
- 单任务用量使用该线程 rollout 中的真实 `total_tokens`；全局周额度百分比不能可靠拆分给并行任务，因此不会用全局百分比伪造单任务用量。
- 收尾提示通过当前 Codex app-server 的 `turn/steer` 发送，同一任务 turn 只发送一次；自动停止继续通过 `turn/interrupt(threadId, turnId)` 完成，不会使用 `kill` 终止整个 Codex。
- 重置卡自动使用默认关闭；开启后通过当前 Codex app-server 的 `account/rateLimitResetCredit/consume` 指定真实卡 ID。返回“当前无需重置”时不会消耗该卡，并会继续检查。
- 所有读取均发生在本机，不上传任务、额度或账号数据。
- Codex Desktop 协议或本地数据库结构发生大版本变化时，可能需要更新兼容逻辑。
- Token 统计在 Codex 写入用量事件后更新，因此可能比配置值多消耗一次尚未结算的模型步骤；CodexBar 每 3 秒检查一次已设置上限的任务。
- 如果 Mac 在整段“到期前 1 小时”内关机或休眠，应用无法在后台兑换已经过期的卡。

## 分享给其他人

直接把仓库地址发给对方即可：

> https://github.com/shangmingda/codexbar-macos
>
> 请按 README 的“从 GitHub 安装”执行。安装前需要 macOS 14+、Codex Desktop 已登录，以及 Xcode Command Line Tools。

## 开源许可

[MIT License](LICENSE)
