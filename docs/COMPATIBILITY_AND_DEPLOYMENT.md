# 适配与部署执行事项

## 已验证环境

- 机器架构：Apple Silicon（arm64）
- macOS：26.3
- Codex Desktop：26.810.41047
- Codex CLI / app-server：0.148.0-alpha.9
- Swift：6.2.3
- 安装范围：当前 macOS 用户

版本号只是本次验收基线。程序不会把账号、额度数值或线程 ID 写死。

## 自动适配机制

### Codex 安装位置

按以下顺序寻找 Codex 可执行文件：

1. `/Applications/ChatGPT.app/Contents/Resources/codex`
2. `/Applications/Codex.app/Contents/Resources/codex`
3. 当前用户 `~/Applications` 下的相同位置
4. `/opt/homebrew/bin/codex`
5. `/usr/local/bin/codex`

### 账号与额度

CodexBar 启动本机 Codex `app-server --stdio` 并调用 `account/rateLimits/read`。因此读取的是当前机器、当前 macOS 用户在 Codex Desktop 中登录的账号，不需要复制开发者账号或 API Key。

额度窗口根据 `windowDurationMins` 动态分类。当前只返回周窗口时显示周额度；后端恢复 300 分钟窗口时自动增加 5 小时额度。

重置卡读取同一响应中的 `rateLimitResetCredits`。仅展示 `status=available` 的卡，按真实 `expiresAt` 排序；如果后端只返回卡数但未返回明细，界面保留上次成功结果并自动重试，不用“未知”代替真实日期。

DeepSeek 是可选模式，需要能访问 `api.deepseek.com` 与 `cdn.deepseek.com`，并具有有效 API Key 和余额。余额读取官方 `/user/balance`；模型目录从 DeepSeek 官方 Codex 安装脚本的数据段中只读提取、验证后使用，不执行远程脚本。

### 外接模型与回滚

- OpenAI 模式的默认模型、provider、推理强度、插件、MCP 与权限配置不会被改写；CodexBar 活跃期间只追加临时 DeepSeek Provider 兼容段，退出后 `config.toml` 逐字节恢复。
- DeepSeek-Flash 与 DeepSeek-V4-Pro 使用官方 Responses API 配置；Flash 按官方最新目录支持文本和图片输入。进入 DeepSeek Provider 后，两种模型通过 Codex Desktop 原生模型菜单直接切换；部分旧版客户端可能只显示 `Custom`。
- Key 的持久来源仅为 macOS 钥匙串；CodexBar 活跃时按 DeepSeek 官方 `experimental_bearer_token` 协议写入权限为 0600 的临时租约，退出或看门狗恢复时删除临时内容并原样恢复配置。
- 切换前先保存原配置快照，写入后再通过 Codex `config/read` 核验实际 provider 和模型；任何一步失败都回滚 OpenAI。
- 正常退出由应用完成恢复；异常退出和登录残留由独立 watcher 恢复配置，但不会自行退出或重启 Codex Desktop。
- 两类 provider 的历史任务由 Codex 按认证方式分组；切回对应 provider 后重新显示，CodexBar 不删除任务文件。
- DeepSeek 当前官方目录声明仅支持文本输入；带图片的任务应切回 OpenAI。

### 任务

任务列表是以下两类的并集：

- Codex Desktop 主 `app-server` 当前加载，且最近生命周期事件为 `task_started` 的普通任务。
- `goals_1.sqlite` 中状态为 `active` 的 Goal。

`task_complete` 或 `turn_aborted` 后普通任务自动移出；同一线程同时属于两类时只显示一次。

运行时间读取当前 turn 的 `task_started.started_at`，不使用会在点击、打开或访问线程时变化的数据库 `updated_at`。因此任务跳转和手动刷新不会重置秒数，运行列表排序也保持稳定。

任务刷新包含三层稳定性保护：

1. SQLite 读取设置 3 秒忙等待，降低 Codex 正在写库时的瞬时失败。
2. `lsof` 运行态探测失败时自动重试三次，不立即覆盖界面。
3. 新结果是现有任务的子集时进行二次确认，失败时保留上一次成功任务列表。

### 自动启动

- `com.smd.codexbar`：用户登录时打开 CodexBar。
- `com.smd.codexbar.watcher`：监听 `com.openai.codex` 启动事件，在 CodexBar 未运行时补启动。
- `com.smd.codexbar.appserver`：运行 Codex 官方共享 app-server socket，使 CodexBar 能按 `threadId + turnId` 精确中断单个任务。
- 菜单栏应用身份由 `LSUIElement` 固定声明，启动时不重复切换 activation policy，避免 macOS 26 的 AppKit 布局重入。
- 自绘状态栏延后一轮主事件循环挂载；Popover 仅在点击时创建并在关闭后释放，避免后台 Token 刷新触发不可见窗口布局。
- CodexBar 与 Codex Desktop 关闭互不影响。

### 单任务 Token 上限

1. 任务行右侧可选择 25K～5M Token。
2. 配置时记录该线程当前 `total_tokens` 作为基线，历史消耗不会导致任务立即停止。
3. CodexBar 每 3 秒从对应 rollout 更新真实累计值，并用当前 `task_started` 前后的累计值差额展示“本轮 Token”。
4. 使用量达到上限的 90% 时，通过 `turn/steer` 向当前 turn 发送一次收尾与保存状态提示；提示记录持久化，刷新或重启不会重复发送。
5. 达到阈值且任务仍处于 `task_started` 时，通过共享 socket 调用 `turn/interrupt`。即使提示发送失败或当前 turn 不接受 steer，中断仍会独立执行。
6. 中断请求同时携带线程 ID 与当前 turn ID，只停止目标任务；不会终止 Codex Desktop 或其他任务。
7. 配置及已提醒/已中断的 turn 记录保存在 `~/Library/Application Support/CodexBar/task-budgets.json`，重启后仍有效。

任务限额百分比按“从设置限额时起的 Token ÷ 用户设置的 Token 上限”计算，可超过 100%。Codex 返回的周额度 `usedPercent` 是账号级快照，没有 thread 归属；并行任务、其他设备或 ChatGPT 共用额度时无法真实拆分，因此界面不会把它伪装成单任务周额度占比。

安装脚本会执行 `launchctl setenv CODEX_APP_SERVER_USE_LOCAL_DAEMON 1`。如果安装时 Codex Desktop 已运行，旧 `stdio` 进程中的任务不能被共享服务跨进程接管。CodexBar 只显示“手动启用”提示，不持久化重启待办，也不会在空闲、刷新或后台恢复时自行退出 Codex。只有用户当次点击并明确确认后才会完整重启；重启后的新任务由共享服务承载，达到阈值时会自动停止。

### 重置卡到期前自动使用

1. 功能默认关闭，用户需在重置卡行明确开启；设置保存在当前 macOS 用户的应用偏好中。
2. 每分钟读取完整的可用卡明细，只选择剩余时间大于 0 且不超过 1 小时的卡。
3. 多张卡同时进入窗口时优先最早到期卡，通过 `account/rateLimitResetCredit/consume` 传入具体 `creditId`。
4. 每张卡生成并持久化一个 `idempotencyKey`，同一卡重试始终复用，防止网络超时导致重复消耗。
5. `reset` 或 `alreadyRedeemed` 标记完成；`nothingToReset` 和 `noCredit` 不伪造成功，保留重试并重新读取账号状态。
6. 记录保存在 `~/Library/Application Support/CodexBar/reset-credit-auto-use.json`，不包含账号凭据。

## 部署清单

| 阶段 | 执行命令 | 通过标准 |
| --- | --- | --- |
| 环境 | `swift --version` | Swift 6 可用 |
| 编译 | `swift build` | 无 error / warning |
| 逻辑测试 | `swift run codexbar-selftest` | 全部测试通过 |
| 模型事务 | `swift run codexbar-selftest` | Flash/Pro、旧模型兼容、原生目录解析、逐字节恢复、无原配置恢复全部通过 |
| 本机数据 | `swift run codexbar-diagnostics` | 返回额度和任务 JSON |
| 安装 | `./scripts/install.sh` | 输出 `Installed` |
| 签名 | `codesign --verify --deep --strict ~/Applications/CodexBar.app` | 退出码 0 |
| 主进程 | `pgrep -f 'CodexBar.app/Contents/MacOS/CodexBar'` | 仅 1 个实例 |
| 监听器 | `launchctl print gui/$(id -u)/com.smd.codexbar.watcher` | `state = running` |
| 控制服务 | `launchctl print gui/$(id -u)/com.smd.codexbar.appserver` | `state = running` 且 socket 存在 |
| 控制探针 | `swift run codexbar-diagnostics --tasks-only --control-probe="$HOME/.codex/app-server-control/app-server-control.sock"` | `controlProbe = ok` |
| 卸载 | 先退出 Codex，再执行 `./scripts/uninstall.sh` | 应用与三个 LaunchAgent 均移除 |

## 发布前检查

1. 不提交 `.build/`、`dist/`、日志、数据库或本机用户目录。
2. 搜索并确认没有 Token、Cookie、API Key、密码或授权头。
3. 在至少一台非开发机器上执行 clone → install → diagnostics。
4. Codex Desktop 更新后重点回归：额度读取、普通任务检测、Goal 合并与深链跳转。
5. 将 Codex 原始 `rateLimitResetCredits` 与诊断输出逐项比较卡 ID、状态和到期时间。
6. 连续和并发运行 `--tasks-only`，确认没有 `taskError` 或无效 JSON。
7. 在隔离 `CODEX_HOME` 启动共享 daemon：客户端 A 创建长任务，客户端 B 调用 `turn/interrupt`，确认最终 turn 状态为 `interrupted`。
8. 在临时配置目录依次执行 OpenAI → Flash → Pro → OpenAI，并对恢复前后配置做 SHA-256 比较。
9. DeepSeek 模式下分别验证正常退出与强制终止 CodexBar，确认 watcher 清除租约、恢复原配置并重启 Codex。

## 已知限制

- Intel Mac 尚未实机验证。
- 本地源码安装使用临时签名，不等同于 Developer ID 公证发行版。
- 如果通过浏览器下载 ZIP 导致 Gatekeeper 提示，优先使用 Git clone 后在终端运行安装脚本；不要绕过来源不明的安全警告。
- Codex CLI 中未被桌面版加载的普通任务目前不计入桌面任务数。
- 自动停止以 Codex 已结算并写入 rollout 的 Token 事件为准，可能比阈值多一个模型步骤；不能把全局周额度百分比可靠归因给单个并行任务。
- 重置卡只能在 Codex 后端认为当前额度窗口可重置时消耗；返回 `nothingToReset` 时卡片仍保留。Mac 在整段提前窗口内关机或休眠时无法补用已经过期的卡。
- DeepSeek 余额和模型可用性取决于其官方 API；断网、Key 无效或余额不足时切换会失败并停留/回滚到 OpenAI。
