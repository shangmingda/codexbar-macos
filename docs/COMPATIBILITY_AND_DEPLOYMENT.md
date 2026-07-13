# 适配与部署执行事项

## 已验证环境

- 机器架构：Apple Silicon（arm64）
- macOS：26.3
- Codex Desktop：26.707.61608
- Codex CLI / app-server：0.144.0-alpha.4
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

### 任务

任务列表是以下两类的并集：

- Codex Desktop 主 `app-server` 当前加载，且最近生命周期事件为 `task_started` 的普通任务。
- `goals_1.sqlite` 中状态为 `active` 的 Goal。

`task_complete` 或 `turn_aborted` 后普通任务自动移出；同一线程同时属于两类时只显示一次。

任务刷新包含三层稳定性保护：

1. SQLite 读取设置 3 秒忙等待，降低 Codex 正在写库时的瞬时失败。
2. `lsof` 运行态探测失败时自动重试三次，不立即覆盖界面。
3. 新结果是现有任务的子集时进行二次确认，失败时保留上一次成功任务列表。

### 自动启动

- `com.smd.codexbar`：用户登录时打开 CodexBar。
- `com.smd.codexbar.watcher`：监听 `com.openai.codex` 启动事件，在 CodexBar 未运行时补启动。
- CodexBar 与 Codex Desktop 关闭互不影响。

## 部署清单

| 阶段 | 执行命令 | 通过标准 |
| --- | --- | --- |
| 环境 | `swift --version` | Swift 6 可用 |
| 编译 | `swift build` | 无 error / warning |
| 逻辑测试 | `swift run codexbar-selftest` | 20 项测试全部通过 |
| 本机数据 | `swift run codexbar-diagnostics` | 返回额度和任务 JSON |
| 安装 | `./scripts/install.sh` | 输出 `Installed` |
| 签名 | `codesign --verify --deep --strict ~/Applications/CodexBar.app` | 退出码 0 |
| 主进程 | `pgrep -f 'CodexBar.app/Contents/MacOS/CodexBar'` | 仅 1 个实例 |
| 监听器 | `launchctl print gui/$(id -u)/com.smd.codexbar.watcher` | `state = running` |
| 卸载 | `./scripts/uninstall.sh` | 应用与两个 LaunchAgent 均移除 |

## 发布前检查

1. 不提交 `.build/`、`dist/`、日志、数据库或本机用户目录。
2. 搜索并确认没有 Token、Cookie、API Key、密码或授权头。
3. 在至少一台非开发机器上执行 clone → install → diagnostics。
4. Codex Desktop 更新后重点回归：额度读取、普通任务检测、Goal 合并与深链跳转。
5. 将 Codex 原始 `rateLimitResetCredits` 与诊断输出逐项比较卡 ID、状态和到期时间。
6. 连续和并发运行 `--tasks-only`，确认没有 `taskError` 或无效 JSON。

## 已知限制

- Intel Mac 尚未实机验证。
- 本地源码安装使用临时签名，不等同于 Developer ID 公证发行版。
- 如果通过浏览器下载 ZIP 导致 Gatekeeper 提示，优先使用 Git clone 后在终端运行安装脚本；不要绕过来源不明的安全警告。
- Codex CLI 中未被桌面版加载的普通任务目前不计入桌面任务数。
