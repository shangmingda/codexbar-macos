# Changelog

## 1.5.0

- 对齐 DeepSeek 官方最新 Codex 目录：`deepseek-flash` 与 `deepseek-v4-pro`。
- 进入 DeepSeek Provider 后，两种外部模型由 Codex 原生模型菜单直接选择；模型间切换不再修改全局配置或重启 Codex。
- OpenAI 模式下保留临时 DeepSeek Provider 兼容注册，历史 DeepSeek 对话不再报 `model provider not found`；同时兼容早期 `codexbar-deepseek` 标识。
- Key 仍由 CodexBar 录入、在线验证并保存到 macOS Keychain；仅在 CodexBar 活跃期间创建权限为 0600 的临时 Codex 租约，正常或异常退出均恢复原配置。
- 启动兼容注册只尝试非交互读取 Keychain，不会因为本地签名更新循环弹出授权框。
- `openai-http` 可通过 OpenAI 配置校验；恢复残留租约不再重启共享 app-server，避免干扰正在运行的 Codex 任务。
- 任务卡标签改为具体模型短名（如 `GPT-6`、`GPT-5.6 Sol`、`DS-Flash`），新增未知模型也会显示经截断的真实 id，不再笼统显示 Provider。

## 1.4.8

- 兼容 Codex 新写入的 `openai-http` 任务 Provider 标识，任务列表统一显示为 OpenAI，不再误报未知模型。
- `openai-http` 任务沿用 OpenAI 原任务的安全打开策略：OpenAI 模式直接跳转，DeepSeek 模式下明确确认后切回 OpenAI。
- 本次兼容只规范任务元数据，不结束、重启或修改正在运行的 Codex 任务。

## 1.4.7

- 修复周额度偶发或持续错误显示 100% 的问题。
- 兼容 Codex 同时返回 `codex` 与 `base_model_inference` / `gpt-reserve` 多产品限额的新结构，不再按无序字典结果混合周窗口。
- 优先读取官方主 `rateLimits` 快照，其次精确选择 `codex` limitId；仅在两者都缺失时使用确定性降级选择。
- 增加当前真实多产品响应回归用例，确保 `gpt-reserve` 的 100% 周窗口不会覆盖 Codex 周额度。

## 1.4.6

- 修复本地临时签名升级后反复弹出 DeepSeek Keychain 授权框的问题。
- 启动时只非交互读取 Keychain 条目元数据，不读取 API Key 密文。
- OpenAI 模式不再后台刷新 DeepSeek 余额；只有 DeepSeek 模式且已配置 Key 时才允许。
- 用户明确切换 DeepSeek 时最多读取一次 Keychain，本次 CodexBar 进程内缓存 Key，余额与模型校验不再重复触发系统授权。
- `codexbar-diagnostics` 完全禁止读取 macOS Keychain；需要 DeepSeek API 诊断时只接受当次进程环境参数。

## 1.4.5

- 修复 DeepSeek 模式无法打开 OpenAI 原对话、OpenAI 模式无法打开 DeepSeek 原对话的交互断路。
- 点击其他 Provider 的任务时，先明确说明重启影响并征得当次确认，然后切回该任务原 Provider/模型并打开原对话。
- 切换后不再为已有对话新建替代任务；未知 Provider 或未知 DeepSeek 模型继续安全阻止。
- 增加 OpenAI/DeepSeek 双向切换、DeepSeek 精确模型恢复和未知来源保护回归测试。

## 1.4.4

- 增加 `deepseek-v4-flash-vision-exp`，界面显示为 V4 Vision，并支持官方目录声明的图片输入能力。
- 兼容 DeepSeek 最新安装脚本的 `write_models_json "$1"` 目录格式，同时保留旧格式解析。
- 切换模型前使用当前 Key 查询 DeepSeek `/models`，账号未返回目标模型时不修改 Codex 配置。
- 增加 Vision 模型目录解析、API 列表、配置写入和可逆切换测试。

## 1.4.3

- 修复旧版持久化重启待办在任务列表短暂为空时弹出 ChatGPT 退出确认的问题。
- 移除空闲、启动恢复和后台租约恢复中的自动退出；所有 Codex 重启均须用户当次明确确认。
- 升级时清除旧版 `CodexBarAutoStopActivationPending`，且不再持久化重启请求。
- 仅检查设置了上限的具体任务，历史上限不再影响无关运行任务。

## 1.4.0

- 引入 CodexBar 独立品牌 Logo，并统一用于菜单栏状态项和面板标题。
- 额度区新增当前账号单窗口/双窗口模式提示，保持与真实额度窗口一致。
- 任务列表提升到额度下方的主操作区；重置卡改为数量、到期日和自动使用开关的紧凑摘要，逐卡状态与下一次自动使用时间收进二级浮层。
- 单任务限额升级为可视化编辑浮层：8 档上限、实时进度环、真实 Token 百分比、90% 收尾和 100% 停止状态同屏呈现。
- 对齐产品与宣传站的交互和时间口径，移除产品中不会实际出现的演示反馈。

## 1.3.0

- 增加重置卡到期前 1 小时自动使用开关；新安装默认关闭，需用户明确开启。
- 通过当前 Codex 的 `account/rateLimitResetCredit/consume` 使用指定卡 ID，不伪造兑换结果。
- 每张卡持久化唯一幂等键；网络重试不会重复消耗，优先处理最早到期卡。
- 当前额度窗口无需重置时保留卡片并持续检查，直到成功、卡片失效或到期。

## 1.2.2

- 自动停止控制通道未接管时，不再只提示用户手动重启：默认等待所有任务结束后完整重启 Codex 并自动启用。
- 增加“立即启用”操作及中断任务确认；用户明确选择后可立即完整重启 Codex。
- 保持单任务隔离：不会为了停止一个旧控制任务而直接结束整个 Codex 进程。

## 1.2.1

- 修复点击任务跳转后相对秒数从头计算的问题：运行时间改用 rollout 的真实 `task_started.started_at`。
- 运行任务排序同步改用本轮启动时间，点击或刷新线程访问时间时不再跳动。

## 1.2.0

- 任务行右侧增加独立 Token 上限配置，支持 25K、50K、100K、250K、500K、1M、2M 和 5M。
- 上限从设置时的线程累计 Token 开始计算，配置持久化到本机应用支持目录。
- 有上限的任务每 3 秒读取 rollout 真实 Token；达到上限后通过 `turn/interrupt` 精确停止当前 turn。
- 增加共享 app-server LaunchAgent 和 Codex 启动环境配置，不使用 `kill` 误伤其他任务。
- 增加控制通道只读探针、Token/turn 解析与额度持久化测试。

## 1.1.0

- 增加可用重置卡真实到期日展示。
- 卡片明细缺失时自动重试，并保留上一次真实结果。
- 任务读取增加 SQLite 忙等待、三次自动重试和任务减少二次确认。
- 任务/额度刷新改为防重入，避免并发刷新互相覆盖。
- 诊断命令增加 `--quota-only` 和 `--tasks-only`。

## 1.0.0

- 首次发布：额度、普通任务、active Goal、深链跳转和 Codex 启动联动。
