# CodexBar for macOS

CodexBar 是一个原生 macOS 菜单栏工具，用于查看当前 Codex 账号额度和正在执行的任务。

## 功能

- 使用独立 CodexBar 标识；菜单栏、状态面板与宣传页面保持同一套产品识别。
- 自动读取当前 Codex 账号的真实额度窗口：仅有周额度时显示一行；恢复“5 小时 + 周额度”时自动显示两行。
- 限额解析仅使用 Codex 主额度快照，不会把 `gpt-reserve` / `base_model_inference` 等其他产品的周窗口混入 Codex 周额度。
- 额度区可在 OpenAI 原生模式与 DeepSeek 模式之间切换；DeepSeek 目录包含 `DeepSeek-Flash` / `DeepSeek-V4-Pro`，并通过官方 `/user/balance` 展示真实人民币或美元余额。
- 提供 DeepSeek API Key 配置入口；Key 先在线验证，再保存到 macOS 钥匙串。CodexBar 活跃期间按 DeepSeek 官方协议生成权限为 0600 的临时 Codex 配置租约，退出后原样恢复，不写入仓库或日志。
- 只有 OpenAI / DeepSeek Provider 切换需要校验配置并在用户当次确认后完整重启 Codex；进入 DeepSeek 后，两种外部模型直接在 Codex 原生模型菜单切换，不再重复重启。
- 任务卡直接显示具体模型短名（如 `GPT-6`、`GPT-5.6 Sol`、`DS-Flash`），并保留 Provider 归属用于安全路由；同一 DeepSeek Provider 的不同模型任务可直接打开，跨 Provider 时经明确确认后切回并打开原对话，不新建替代任务。
- DeepSeek 采用临时配置租约：OpenAI 模式也注册当前及旧版 DeepSeek Provider，使历史外部模型对话不再报 `provider not found`；正常退出、异常退出或下次登录发现残留时，都会逐字节恢复切换前的 Codex 配置。
- DeepSeek API Key 保存在 macOS Keychain；启动兼容注册仅尝试非交互读取，若 macOS 要求授权会静默跳过，只有用户明确切换 DeepSeek 时才允许出现一次系统授权；OpenAI 模式不后台刷新 DeepSeek，诊断程序也永不读取该 Keychain 条目。
- 面板会标明已识别的单/双额度模式；任务列表保持在主操作区，重置卡以“数量 + 到期日 + 自动使用开关”紧凑展示，点击后再查看逐卡详情与下一次自动使用时间。明细不完整时自动重试，不显示伪造的“未知日期”。
- 可明确开启“到期前 1 小时自动使用重置卡”；真实兑换、最早到期优先，并用稳定幂等键避免重复消耗。
- 合并统计 Codex 桌面版普通运行任务与 `active` Goal，同一线程只计一次。
- 兼容 Codex 的 `openai` 与 `openai-http` 原生任务标识，任务列表均正确显示为 OpenAI。
- 运行秒数取自当前 turn 的真实启动时间，点击跳转、刷新或打开 Codex 不会重新计时。
- 每个运行任务始终展示当前 turn 的真实 Token 消耗，未运行的 active Goal 展示线程累计 Token；设置任务上限后，同时展示从设置时起的用量、上限和精确百分比。
- 每个任务通过可视化浮层独立设置 25K～5M Token 上限，提供 8 档预设、实时进度环与精确百分比；从设置时的真实累计量开始计算，使用到 90% 时自动发送收尾提示，达到上限后只中断对应任务，不影响其他任务。
- 如果安装时 Codex 已在运行，旧连接任务需要重启 Codex 才能启用停止能力；CodexBar 只会提示，不会自行退出或重启 Codex，必须由用户在面板中当次确认。
- 点击任务直接通过 `codex://threads/{threadId}` 返回对应 Codex 窗口。
- Codex 桌面版启动时自动补启动 CodexBar；两者关闭互不影响，且不会重复启动。
- OpenAI 原生模式不读取或保存 `auth.json`，也不要求 API Key；DeepSeek 是用户主动配置的可选付费 API。
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
| DeepSeek Codex 集成 | DeepSeek-Flash / DeepSeek-V4-Pro，Responses API；原生模型菜单切换；需要有效 API Key 和可用余额 |
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

如果安装时 Codex Desktop 已经打开，正在运行的旧任务不能迁移到共享控制服务。CodexBar 会提示“手动启用”，但不会在后台自行退出或重启 Codex。只有用户当次点击并在系统面板中确认重启后，后续新任务达到上限时才会被精确停止。

## 验证

```bash
swift build
swift run codexbar-selftest
swift run codexbar-diagnostics
```

`codexbar-diagnostics` 只输出额度窗口与任务摘要，不输出账号凭据。DeepSeek Key 也不会被任何诊断命令打印。

也可以单独诊断：

```bash
swift run codexbar-diagnostics --quota-only
swift run codexbar-diagnostics --tasks-only
swift run codexbar-diagnostics --deepseek-catalog-only
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

卸载前会先恢复尚未结束的模型租约，并删除 CodexBar 保存的 DeepSeek Key；随后只移除 CodexBar、监听器和对应 LaunchAgent。

## 隐私与实现边界

- 额度通过当前机器自带的 Codex `app-server` 读取，自动使用 Codex Desktop 当前登录账号。
- DeepSeek 模式使用 DeepSeek 官方 Responses API 配置；支持当前官方目录的 DeepSeek-Flash（含图片输入）与 DeepSeek-V4-Pro。模型目录从官方安装脚本中只读提取并校验，不执行远程脚本；切换前还会用当前 Key 查询 `/models` 确认账号实际可用。
- DeepSeek Key 的持久来源只有 macOS 钥匙串。由于 Codex 当前官方接入字段是 `experimental_bearer_token`，CodexBar 活跃时会把 Key 写入权限为 0600 的临时租约配置供 Codex 使用；CodexBar 退出或看门狗恢复后会删除该临时内容并恢复原配置。
- 模型事务会保存切换前配置的精确本地快照；若租约期间配置被其他程序改动，当前版本会先保存冲突副本，再优先恢复原配置，确保退出后不残留 DeepSeek provider。
- 任务状态通过当前用户的 Codex 本地状态库和桌面主进程当前打开的 rollout 日志只读判断。
- 单任务用量使用该线程 rollout 中的真实 `total_tokens`；全局周额度百分比不能可靠拆分给并行任务，因此不会用全局百分比伪造单任务用量。
- “本轮 Token”使用当前 turn 前后的线程累计 Token 差额计算；限额百分比只表示任务用量占用户设置上限的比例，不代表该任务占用了多少周额度。
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
