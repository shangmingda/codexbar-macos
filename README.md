# CodexBar for macOS

CodexBar 是一个原生 macOS 菜单栏工具，用于查看当前 Codex 账号额度和正在执行的任务，管理 OpenAI / DeepSeek 模型，并在额度重置后继续推进长任务。

[查看产品官网](https://feikong-d2gvwofj40680d268-1304829578.tcloudbaseapp.com/codexbar-macos/index.html) · 当前源码版本：**1.6.2**

- **额度重置后自动续聊**：默认关闭；开启后按真实 5 小时窗口在重置后 3 分钟执行，优先继续因额度不足中断的原对话，保留模型与推理强度；无待续任务时发送“你好”。
- **可配置的钉钉重置提醒**：配置机器人 Webhook 与通知关键字，支持发送测试；仅提醒周额度，同一次重置去重。
- **模型切换与管理**：在 CodexBar 配置来源、Key 与余额；DeepSeek-Flash 和 DeepSeek-V4-Pro 在 Codex 原生模型菜单直接选择，内部换模型无需重启。

官网源码在 [`site/`](site/)。

## 额度重置后自动续聊（1.6.2）

在面板开启“额度重置后自动续聊”后，CodexBar 按当前账号已使用的真实 5 小时窗口，在 `resetsAt + 3 分钟` 执行。上一周期有因订阅额度不足失败的任务时，在各自原对话发送“重拾思考链路，继续任务，不可降低质量。”；没有待续任务时，新建独立对话发送“你好”。续聊保留原模型与推理强度。

Mac 与 CodexBar 需保持运行。休眠、关机或网络不可用时不能保证准点发送；恢复后先核验最新额度。周额度仍不足时保留任务等待；用户已继续、已归档或正在运行的任务不重复恢复。没有真实 300 分钟窗口时不伪造重置时间。窗口启动是否生效以官方最新额度为准。

执行记录保存在 `~/Library/Application Support/CodexBar/quota-recovery.json`，权限为 0600，不含邮箱或凭据。发送结果不明确时先回读消息编号，禁止自动重复发送。该功能首次安装默认关闭，可在本机设置中开启。

1.6.1 起由现有 KeepAlive 监听器按墙钟时间执行，界面刷新不承担调度。服务启用时防止 App Nap，但不阻止机器正常休眠；重启恢复持久计划，到点只做目标任务校验。用户已在新周期续任务时记录为“已由你继续”，不声称自动发送；任务均不再适合续跑且新周期尚未开始时，发送一次“你好”兜底。

后台心跳在 `quota-recovery-status.json`，脱敏事件在 `quota-recovery-events.jsonl`，均为 0600。界面以橙色显示服务未响应或执行故障；`swift run codexbar-diagnostics --quota-recovery-health` 可读取触发时间、延迟和实际结果。发送回执稍晚到达时补读，不重复提交。

1.6.2 起区分提交接受、消息回读和执行状态。已确认完成推理后，即使官方用量仍四舍五入为 0%，也会结合官方重置候选登记下一周期；滚动占位时间不会推迟已登记计划。某个任务被其他会话持有写入权时保留重试，其他任务继续尝试。

后台在 `~/Library/Application Support/CodexBar/quota-recovery-acceptance.json` 记录两个连续自然周期的验收进度（0600）。只有真实窗口提前登记、准点触发、及时提交、消息回读及执行状态证据齐备才通过；短倒计时测试不计入。

底栏的对话图标打开“给我提建议 / 支持作者”，提供邮箱撰信、复制和支付宝扫码支持。支持为自愿行为。

本机源码构建采用临时签名并安装到用户目录，无需管理员密码。凭据通过仅首次安装、后续更新保留原签名的本地助手读写钥匙串，数据仅通过匿名管道传递，读写禁止密码授权弹窗。首次迁移保留旧条目，只使用当前 0600 临时配置中已有的 Key，以及旧条目明确授权的系统读者；不保存系统密码。锁定或权限不足时返回明确错误。

## 功能

- 使用独立 CodexBar 标识；菜单栏、状态面板与宣传页面保持同一套产品识别。
- 自动读取当前 Codex 账号的真实额度窗口：仅有周额度时显示一行；恢复“5 小时 + 周额度”时自动显示两行。
- 菜单栏额度后以并排的透明箭头和紧凑数值显示主网络接口的真实上传、下载速度，每秒更新并使用 3 次采样均值平滑；固定宽度避免菜单栏左右跳动。
- 额度区的铃铛入口可配置钉钉周额度重置提醒：仅周额度通知，5h 额度不通知。Webhook 保存在本机钥匙串，可复用现有求助提醒配置；通知关键字持久保存，支持发送测试。自然轮换和可从额度快照识别的提前重置各提醒一次。
- 限额解析仅使用 Codex 主额度快照，不会把 `gpt-reserve` / `base_model_inference` 等其他产品的周窗口混入 Codex 周额度。
- 额度区可在 OpenAI 原生模式与 DeepSeek 模式之间切换；DeepSeek 目录包含 `DeepSeek-Flash` / `DeepSeek-V4-Pro`，并通过官方 `/user/balance` 展示真实人民币或美元余额。
- 提供 DeepSeek API Key 配置入口；Key 先在线验证，再保存到 macOS 钥匙串。CodexBar 活跃期间按 DeepSeek 官方协议生成权限为 0600 的临时 Codex 配置租约，退出后原样恢复，不写入仓库或日志。
- 只有 OpenAI / DeepSeek Provider 切换需要校验配置并在用户当次确认后完整重启 Codex；进入 DeepSeek 后，两种外部模型直接在 Codex 原生模型菜单切换，不再重复重启。
- 任务卡直接显示具体模型短名（如 `GPT-6`、`GPT-5.6 Sol`、`DS-Flash`），并保留 Provider 归属用于安全路由；同一 DeepSeek Provider 的不同模型任务可直接打开，跨 Provider 时经明确确认后切回并打开原对话，不新建替代任务。
- 自动检测「模型与 Provider 不匹配」的对话（例如只在旧 OpenAI 对话里换了 DeepSeek 模型，导致每一轮都打到 api.openai.com 并返回 401），面板给出修复按钮；修复只改该对话的 Provider 绑定，保留所选模型，并留下可追溯的修复日志。
- DeepSeek 模型目录关闭并行工具调用，并追加「每轮最多一个工具调用」的串行规则：同一轮多个工具调用的输出只要被压缩提示隔开，DeepSeek 就会丢失配对并让整条对话持续报 `No tool output found`；已损坏的对话可以通过剔除夹在输出之间的提示恢复。
- DeepSeek 采用临时配置租约：OpenAI 模式也注册当前及旧版 DeepSeek Provider，使历史外部模型对话不再报 `provider not found`；正常退出、异常退出或下次登录发现残留时，都会逐字节恢复切换前的 Codex 配置。
- DeepSeek API Key 保存在 macOS Keychain，读取采用禁止授权 UI 的策略；锁定或受限时明确返回状态。OpenAI 模式下仅在凭据可非交互访问时刷新余额，不伪造读不到的金额。
- 面板按真实窗口展示单/双额度；任务列表保持在主操作区，重置卡以“数量 + 到期日 + 自动使用开关”紧凑展示，点击后再查看逐卡详情与下一次自动使用时间。明细不完整时自动重试，不显示伪造的“未知日期”。
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
- 额度优先通过已运行的 Codex 共享状态服务读取，通常每 60 秒刷新；失败后最多退避 2 分钟，打开面板可立即重试。最近 30 分钟的成功结果会作为明确标注的缓存显示。任务每 15 秒刷新。
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

`codexbar-diagnostics` 默认只输出额度窗口与任务摘要，不输出账号凭据。DeepSeek Key 不会被诊断命令打印。`--test-dingtalk-reset-notification` 会实际发送一条钉钉测试消息，但不会输出 Webhook。

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
- 周额度重置通知依据相邻的官方额度快照判断；官方接口未提供“重置原因”事件，提前重置须有明确的已用比例下降，自然轮换须跨越完整额度周期，单纯重置时间后移不触发。应用未运行且无历史快照时无法补报。
- 钉钉通知是用户启用的外部发送；Webhook 不写入仓库、日志或诊断输出，只有钉钉返回 `errcode=0` 才标记送达。
- 额度读取、任务统计与执行计划在本机完成；启用自动续聊后通过 Codex 发送消息，启用 DeepSeek 后使用对应模型服务，钉钉通知向用户配置的机器人发送额度信息。
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
