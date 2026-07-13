# CodexBar for macOS

CodexBar 是一个原生 macOS 菜单栏工具，用于查看当前 Codex 账号额度和正在执行的任务。

## 功能

- 自动读取当前 Codex 账号的真实额度窗口：仅有周额度时显示一行；恢复“5 小时 + 周额度”时自动显示两行。
- 展示当前账号所有可用重置卡的真实到期日；明细不完整时自动重试，不显示伪造的“未知日期”。
- 合并统计 Codex 桌面版普通运行任务与 `active` Goal，同一线程只计一次。
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
- 所有读取均发生在本机，不上传任务、额度或账号数据。
- Codex Desktop 协议或本地数据库结构发生大版本变化时，可能需要更新兼容逻辑。

## 分享给其他人

直接把仓库地址发给对方即可：

> https://github.com/shangmingda/codexbar-macos
>
> 请按 README 的“从 GitHub 安装”执行。安装前需要 macOS 14+、Codex Desktop 已登录，以及 Xcode Command Line Tools。

## 开源许可

[MIT License](LICENSE)
