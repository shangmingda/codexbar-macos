import CodexBarCore
import Foundation

@main
struct SelfTests {
    static func main() throws {
        if let fixtureArgument = CommandLine.arguments.first(where: { $0.hasPrefix("--prepare-provider-recovery-fixture=") }) {
            let root = URL(fileURLWithPath: String(fixtureArgument.dropFirst("--prepare-provider-recovery-fixture=".count)), isDirectory: true)
            let configURL = root.appendingPathComponent("codex/config.toml")
            let supportURL = root.appendingPathComponent("support", isDirectory: true)
            try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("model = \"gpt-5.6-sol\"\nmodel_reasoning_effort = \"xhigh\"\n".utf8).write(to: configURL, options: .atomic)
            let catalog = Data(#"{"models":[{"slug":"deepseek-v4-flash"},{"slug":"deepseek-v4-pro"},{"slug":"deepseek-v4-flash-vision-exp"}]}"#.utf8)
            let manager = ProviderConfigManager(paths: ProviderConfigPaths(configURL: configURL, supportDirectory: supportURL))
            _ = try manager.activateDeepSeek(model: .flash, catalogData: catalog, apiKey: "codexbar-selftest-key")
            print("fixture-ready")
            return
        }
        var passed = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) throws {
            guard condition() else {
                FileHandle.standardError.write(Data("FAIL: \(name)\n".utf8))
                throw TestFailure.failed(name)
            }
            passed += 1
            print("PASS: \(name)")
        }

        let weeklyData = Data(#"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":7,"windowDurationMins":10080,"resetsAt":1784512696},"secondary":null},"rateLimitResetCredits":{"availableCount":3,"credits":[{"id":"card-late","status":"available","expiresAt":1785109509,"title":"Full reset"},{"id":"card-early","status":"available","expiresAt":1784333618,"title":"Full reset"},{"id":"card-last","status":"available","expiresAt":1785524692,"title":"Full reset"},{"id":"card-used","status":"redeemed","expiresAt":1784000000,"title":"Full reset"}]}}}"#.utf8)
        let weekly = try unwrap(RateLimitClient.parseResponse(weeklyData)?.get(), "weekly parse")
        try check(weekly.windows.count == 1, "仅周额度只生成一个窗口")
        try check(weekly.windows[0].shortLabel == "周" && weekly.windows[0].remainingPercent == 93, "周额度剩余百分比")
        try check(weekly.resetCreditAvailableCount == 3 && weekly.resetCredits.count == 3, "真实可用重置卡数量解析")
        try check(weekly.resetCreditDetailsComplete, "重置卡明细完整性识别")
        try check(weekly.resetCredits.map(\.id) == ["card-early", "card-late", "card-last"], "重置卡按真实到期时间排序并过滤已使用卡")

        let consumeReset = try unwrap(RateLimitClient.parseConsumeResponse(Data(#"{"id":2,"result":{"outcome":"reset"}}"#.utf8))?.get(), "consume reset parse")
        let consumeNothing = try unwrap(RateLimitClient.parseConsumeResponse(Data(#"{"id":2,"result":{"outcome":"nothingToReset"}}"#.utf8))?.get(), "consume nothing parse")
        let consumeNoCredit = try unwrap(RateLimitClient.parseConsumeResponse(Data(#"{"id":2,"result":{"outcome":"noCredit"}}"#.utf8))?.get(), "consume no credit parse")
        let consumeRedeemed = try unwrap(RateLimitClient.parseConsumeResponse(Data(#"{"id":2,"result":{"outcome":"alreadyRedeemed"}}"#.utf8))?.get(), "consume redeemed parse")
        try check(consumeReset == .reset, "重置卡真实使用结果解析")
        try check(consumeNothing == .nothingToReset, "当前无需重置结果解析")
        try check(consumeNoCredit == .noCredit, "没有可用重置卡结果解析")
        try check(consumeRedeemed == .alreadyRedeemed, "幂等重复兑换结果解析")

        let availableModelsData = Data(#"{"object":"list","data":[{"id":"deepseek-v4-flash"},{"id":"deepseek-v4-pro"},{"id":"deepseek-v4-flash-vision-exp"}]}"#.utf8)
        let availableModels = try DeepSeekClient.parseAvailableModels(availableModelsData)
        try check(availableModels.contains(DeepSeekModel.visionExperimental.rawValue), "DeepSeek Vision 实验模型 API 列表解析")
        try check(DeepSeekModel.visionExperimental.shortName == "V4 Vision", "DeepSeek Vision 模型界面名称")
        try check(
            !DeepSeekBackgroundRefreshPolicy.shouldRefresh(hasKey: true, activeProvider: .openAI),
            "OpenAI 模式不在后台读取 DeepSeek 凭据"
        )
        try check(
            DeepSeekBackgroundRefreshPolicy.shouldRefresh(hasKey: true, activeProvider: .deepSeek),
            "DeepSeek 模式且已配置 Key 时才后台刷新"
        )
        try check(
            !DeepSeekBackgroundRefreshPolicy.shouldRefresh(hasKey: false, activeProvider: .deepSeek),
            "DeepSeek 未配置 Key 时不发起后台刷新"
        )

        let currentSetupScript = #"""
        write_models_json() {
          cat > "$1" <<'CODEX_MODELS_JSON'
        {"models":[{"slug":"deepseek-v4-flash"},{"slug":"deepseek-v4-pro"},{"slug":"deepseek-v4-flash-vision-exp"}]}
        CODEX_MODELS_JSON
        }
        """#
        let extractedCatalog = try DeepSeekClient.extractOfficialModelCatalog(from: currentSetupScript)
        let extractedObject = try JSONSerialization.jsonObject(with: extractedCatalog) as? [String: Any]
        let extractedModels = (extractedObject?["models"] as? [[String: Any]])?.compactMap { $0["slug"] as? String } ?? []
        try check(extractedModels.contains(DeepSeekModel.visionExperimental.rawValue), "DeepSeek 新版官方脚本目录提取")

        let autoUseNow = Date(timeIntervalSince1970: 1_784_100_000)
        let dueLater = ResetCredit(id: "later", status: "available", expiresAt: autoUseNow.addingTimeInterval(3_601), title: nil)
        let dueSoon = ResetCredit(id: "soon", status: "available", expiresAt: autoUseNow.addingTimeInterval(3_600), title: nil)
        let dueSooner = ResetCredit(id: "sooner", status: "available", expiresAt: autoUseNow.addingTimeInterval(1_800), title: nil)
        try check(dueSoon.autoUseEligibleAt == autoUseNow, "重置卡自动使用时间为到期前一小时")
        try check(dueSooner.isInAutoUseWindow(at: autoUseNow), "重置卡可识别当前是否进入自动使用窗口")
        try check(ResetCreditAutoUsePolicy.nextEligibleCredit(from: [dueLater], records: [:], now: autoUseNow) == nil, "到期前超过一小时不使用重置卡")
        try check(ResetCreditAutoUsePolicy.nextEligibleCredit(from: [dueSoon], records: [:], now: autoUseNow)?.id == "soon", "到期前一小时进入自动使用窗口")
        try check(ResetCreditAutoUsePolicy.nextEligibleCredit(from: [dueSoon, dueSooner], records: [:], now: autoUseNow)?.id == "sooner", "多张卡优先使用最早到期卡")
        let throttledRecord = ResetCreditAutoUseRecord(creditID: "soon", idempotencyKey: "stable-key", lastAttemptAt: autoUseNow.addingTimeInterval(-30))
        try check(ResetCreditAutoUsePolicy.nextEligibleCredit(from: [dueSoon], records: ["soon": throttledRecord], now: autoUseNow) == nil, "一分钟内不重复请求兑换")
        let completedRecord = ResetCreditAutoUseRecord(creditID: "soon", idempotencyKey: "stable-key", completedAt: autoUseNow, outcome: .reset)
        try check(ResetCreditAutoUsePolicy.nextEligibleCredit(from: [dueSoon], records: ["soon": completedRecord], now: autoUseNow) == nil, "已使用卡不会重复兑换")

        let sparseCreditData = Data(#"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":7,"windowDurationMins":10080}},"rateLimitResetCredits":{"availableCount":3,"credits":null}}}"#.utf8)
        let sparseCredits = try unwrap(RateLimitClient.parseResponse(sparseCreditData)?.get(), "sparse credit parse")
        try check(sparseCredits.resetCredits.isEmpty && !sparseCredits.resetCreditDetailsComplete, "卡数存在但明细缺失时不伪造未知日期")

        let dualData = Data(#"{"id":2,"result":{"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":70,"windowDurationMins":300,"resetsAt":1784512696},"secondary":{"usedPercent":30,"windowDurationMins":10080,"resetsAt":1784512696}}}}}"#.utf8)
        let dual = try unwrap(RateLimitClient.parseResponse(dualData)?.get(), "dual parse")
        try check(dual.windows.map(\.shortLabel) == ["5h", "周"], "五小时和周额度自动分类")
        try check(dual.windows.map(\.remainingPercent) == [30, 70], "双窗口剩余百分比")
        try check(StatusTitleFormatter.lines(windows: dual.windows, taskCount: 2).count == 2, "双窗口菜单栏两行")
        try check(StatusTitleFormatter.lines(windows: dual.windows, taskCount: 2)[0].hasPrefix("2项 · 5h 30%"), "任务数合并进菜单栏")

        let mixedProductData = Data(#"{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":77,"windowDurationMins":300,"resetsAt":1788329988},"secondary":{"usedPercent":80,"windowDurationMins":10080,"resetsAt":1788749936}},"rateLimitsByLimitId":{"base_model_inference":{"limitId":"base_model_inference","limitName":"gpt-reserve","primary":{"usedPercent":0,"windowDurationMins":10080,"resetsAt":1788919015},"secondary":null},"codex":{"limitId":"codex","primary":{"usedPercent":77,"windowDurationMins":300,"resetsAt":1788329988},"secondary":{"usedPercent":80,"windowDurationMins":10080,"resetsAt":1788749936}}}}}"#.utf8)
        let mixedProduct = try unwrap(RateLimitClient.parseResponse(mixedProductData)?.get(), "mixed product parse")
        try check(mixedProduct.windows.map(\.remainingPercent) == [23, 20], "Codex 额度不混入 gpt-reserve 的 100% 周窗口")
        try check(mixedProduct.windows.map(\.id).allSatisfy { $0.hasPrefix("codex-") }, "优先使用官方主 rateLimits 快照")

        let byIDOnlyMixedData = Data(#"{"id":2,"result":{"rateLimitsByLimitId":{"base_model_inference":{"limitId":"base_model_inference","primary":{"usedPercent":0,"windowDurationMins":10080}},"codex":{"limitId":"codex","primary":{"usedPercent":61,"windowDurationMins":300},"secondary":{"usedPercent":82,"windowDurationMins":10080}}}}}"#.utf8)
        let byIDOnlyMixed = try unwrap(RateLimitClient.parseResponse(byIDOnlyMixedData)?.get(), "by-id mixed product parse")
        try check(byIDOnlyMixed.windows.map(\.remainingPercent) == [39, 18], "主快照缺失时精确选择 codex limitId")

        let taskData = Data(#"[{"thread_id":"abc","title":"开发状态栏","objective":"目标","cwd":"/tmp/work","tokens_used":12,"time_used_seconds":5,"updated_at_ms":1000,"is_goal":1,"is_running":1,"model_provider":"codexbar_deepseek","model":"deepseek-v4-pro"}]"#.utf8)
        let tasks = try TaskStore.decodeRows(taskData)
        try check(tasks.count == 1 && tasks[0].title == "开发状态栏", "任务行解析")
        try check(tasks[0].deepLink?.absoluteString == "codex://threads/abc", "任务深链")
        try check(tasks[0].isGoal && tasks[0].isRunning, "Goal 与普通运行状态可同时标记")
        try check(tasks[0].providerMode == .deepSeek && tasks[0].providerDisplayName == "DeepSeek", "任务 Provider 归属解析")
        try check(tasks[0].model == DeepSeekModel.pro.rawValue, "任务模型归属解析")
        let openAITask = ActiveTask(id: "openai", title: "原生任务", objective: "", cwd: "/tmp", tokensUsed: 0, timeUsedSeconds: 0, updatedAt: Date(), modelProvider: "openai", model: "gpt-5.6-sol")
        try check(openAITask.providerMode == .openAI, "OpenAI 任务 Provider 识别")
        try check(
            TaskOpenPolicy.route(for: openAITask, activeProvider: .openAI, activeDeepSeekModel: .flash) == .direct,
            "OpenAI 模式直接打开 OpenAI 原任务"
        )
        try check(
            TaskOpenPolicy.route(for: openAITask, activeProvider: .deepSeek, activeDeepSeekModel: .flash) == .switchProvider(mode: .openAI, model: nil),
            "DeepSeek 模式打开 OpenAI 原任务时要求安全切回"
        )
        try check(
            TaskOpenPolicy.route(for: tasks[0], activeProvider: .openAI, activeDeepSeekModel: .flash) == .switchProvider(mode: .deepSeek, model: .pro),
            "OpenAI 模式打开 DeepSeek 原任务时切换到原模型"
        )
        try check(
            TaskOpenPolicy.route(for: tasks[0], activeProvider: .deepSeek, activeDeepSeekModel: .pro) == .direct,
            "DeepSeek Provider 和模型同时匹配时直接打开"
        )
        let visionTask = ActiveTask(id: "vision", title: "Vision 任务", objective: "", cwd: "/tmp", tokensUsed: 0, timeUsedSeconds: 0, updatedAt: Date(), modelProvider: ProviderConfigManager.providerID, model: DeepSeekModel.visionExperimental.rawValue)
        try check(
            TaskOpenPolicy.route(for: visionTask, activeProvider: .deepSeek, activeDeepSeekModel: .flash) == .switchProvider(mode: .deepSeek, model: .visionExperimental),
            "DeepSeek 不同模型的原任务会切回精确模型"
        )
        let unknownProviderTask = ActiveTask(id: "unknown", title: "未知任务", objective: "", cwd: "/tmp", tokensUsed: 0, timeUsedSeconds: 0, updatedAt: Date(), modelProvider: "other-provider", model: "other-model")
        if case .unsupported = TaskOpenPolicy.route(for: unknownProviderTask, activeProvider: .openAI, activeDeepSeekModel: .flash) {
            try check(true, "未知 Provider 不会被错误打开")
        } else {
            try check(false, "未知 Provider 不会被错误打开")
        }

        let startedLine = #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1","started_at":1784106317}}"#
        let tokenLine = #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":42000}}}}"#
        let completedLine = #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1"}}"#
        try check(TaskStore.latestLifecycleEvent(in: Data((startedLine + "\n").utf8)) == .started, "普通任务开始事件识别")
        try check(TaskStore.latestLifecycleEvent(in: Data((startedLine + "\n" + completedLine + "\n").utf8)) == .completed, "普通任务完成事件识别")
        let runtime = TaskStore.runtimeSnapshot(in: Data((startedLine + "\n" + tokenLine + "\n").utf8))
        try check(runtime.lifecycle == .started && runtime.activeTurnID == "turn-1", "运行任务 turn ID 识别")
        try check(runtime.totalTokens == 42_000, "运行任务真实 Token 累计识别")
        try check(runtime.turnTokens == 42_000, "首次 turn 从零计算真实 Token")
        try check(runtime.startedAt == Date(timeIntervalSince1970: 1_784_106_317), "任务真实开始时间识别")
        let priorTokenLine = #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":10000}}}}"#
        let laterTokenLine = #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":50000}}}}"#
        let laterRuntime = TaskStore.runtimeSnapshot(in: Data((priorTokenLine + "\n" + startedLine + "\n" + tokenLine + "\n" + laterTokenLine + "\n").utf8))
        try check(laterRuntime.totalTokens == 50_000 && laterRuntime.turnTokens == 40_000, "本轮 Token 使用线程累计值差额真实计算")
        let completedRuntime = TaskStore.runtimeSnapshot(in: Data((startedLine + "\n" + tokenLine + "\n" + completedLine + "\n").utf8))
        try check(completedRuntime.turnTokens == 0, "已完成 turn 不伪装为运行中消耗")

        let stableStart = Date(timeIntervalSince1970: 1_784_106_317)
        let beforeOpen = ActiveTask(id: "stable", title: "稳定计时", objective: "", cwd: "/tmp", tokensUsed: 1, timeUsedSeconds: 1, updatedAt: Date(timeIntervalSince1970: 1_784_106_400), runStartedAt: stableStart, isRunning: true)
        let afterOpen = ActiveTask(id: "stable", title: "稳定计时", objective: "", cwd: "/tmp", tokensUsed: 1, timeUsedSeconds: 1, updatedAt: Date(timeIntervalSince1970: 1_784_106_900), runStartedAt: stableStart, isRunning: true)
        try check(beforeOpen.elapsedReferenceDate == afterOpen.elapsedReferenceDate, "点击导致 updatedAt 变化时运行秒数不重置")

        let budget = TaskBudget(threadID: "abc", limitTokens: 50_000, baselineTokens: 12_000)
        try check(budget.usage(currentTokens: 42_000).consumedTokens == 30_000, "额度从设置时基线开始计算")
        try check(budget.usage(currentTokens: 42_000).usedPercent == 60, "任务限额百分比精确计算")
        try check(budget.usage(currentTokens: 87_000).usedPercent == 150, "任务超限后保留真实百分比而非截断为 100")
        try check(!budget.usage(currentTokens: 56_999).needsClosingWarning, "任务额度 90% 前不发送收尾提醒")
        try check(budget.usage(currentTokens: 57_000).needsClosingWarning, "任务额度达到 90% 时发送收尾提醒")
        try check(!budget.usage(currentTokens: 61_999).hasReachedLimit, "未达到任务额度时不停止")
        try check(budget.usage(currentTokens: 62_000).hasReachedLimit, "达到任务额度时触发停止")
        try check(!budget.usage(currentTokens: 62_000).needsClosingWarning, "达到上限后直接中断而不重复发送提醒")

        let legacyTask = ActiveTask(id: "legacy", title: "旧控制任务", objective: "", cwd: "/tmp", tokensUsed: 1, timeUsedSeconds: 1, updatedAt: Date(), isRunning: true, isControllable: false)
        let controlledTask = ActiveTask(id: "controlled", title: "共享控制任务", objective: "", cwd: "/tmp", tokensUsed: 1, timeUsedSeconds: 1, updatedAt: Date(), isRunning: true, isControllable: true)
        try check(AutoStopActivationPolicy.shouldSchedule(hasBudgets: true, tasks: [legacyTask]), "旧控制任务设置额度后安排启用自动停止")
        try check(!AutoStopActivationPolicy.shouldSchedule(hasBudgets: true, tasks: [controlledTask]), "共享控制任务不重复安排重启")
        try check(!AutoStopActivationPolicy.mayRestartCodex(userConfirmed: false), "没有当次明确确认时绝不重启 Codex")
        try check(AutoStopActivationPolicy.mayRestartCodex(userConfirmed: true), "仅当次明确确认后允许重启 Codex")

        let budgetURL = FileManager.default.temporaryDirectory.appendingPathComponent("codexbar-budget-test-\(UUID().uuidString).json")
        let budgetStore = TaskBudgetStore(fileURL: budgetURL)
        let warnedBudget = TaskBudget(
            threadID: budget.threadID,
            limitTokens: budget.limitTokens,
            baselineTokens: budget.baselineTokens,
            lastWarnedTurnID: "turn-warning",
            lastWarnedAt: autoUseNow
        )
        try budgetStore.save([warnedBudget.threadID: warnedBudget])
        let restoredBudget = try budgetStore.load()[budget.threadID]
        try check(
            restoredBudget?.threadID == budget.threadID &&
            restoredBudget?.limitTokens == budget.limitTokens &&
            restoredBudget?.baselineTokens == budget.baselineTokens,
            "任务额度配置重启后可恢复"
        )
        try check(
            restoredBudget?.lastWarnedTurnID == "turn-warning" && restoredBudget?.lastWarnedAt == autoUseNow,
            "收尾提醒记录重启后可恢复且不会重复发送"
        )
        let legacyBudgetData = Data(#"{"version":1,"budgets":[{"threadID":"legacy-budget","limitTokens":25000,"baselineTokens":1000,"createdAt":"2026-07-15T00:00:00Z"}]}"#.utf8)
        try legacyBudgetData.write(to: budgetURL, options: .atomic)
        let legacyBudget = try budgetStore.load()["legacy-budget"]
        try check(
            legacyBudget?.limitTokens == 25_000 && legacyBudget?.lastWarnedTurnID == nil,
            "旧版任务额度配置可无损升级"
        )
        try? FileManager.default.removeItem(at: budgetURL)

        let resetRecordURL = FileManager.default.temporaryDirectory.appendingPathComponent("codexbar-reset-credit-test-\(UUID().uuidString).json")
        let resetRecordStore = ResetCreditAutoUseStore(fileURL: resetRecordURL)
        let resetRecord = ResetCreditAutoUseRecord(creditID: "card-1", idempotencyKey: "fixed-key", lastAttemptAt: autoUseNow)
        try resetRecordStore.save([resetRecord.creditID: resetRecord])
        let restoredResetRecord = try resetRecordStore.load()[resetRecord.creditID]
        try check(restoredResetRecord?.idempotencyKey == "fixed-key" && restoredResetRecord?.lastAttemptAt == autoUseNow, "重置卡幂等键和尝试时间可恢复")
        try? FileManager.default.removeItem(at: resetRecordURL)
        try check(LaunchCompanionPolicy.shouldLaunchCodexBar(codexIsRunning: true, codexBarIsRunning: false), "Codex 启动且工具未运行时联动启动")
        try check(!LaunchCompanionPolicy.shouldLaunchCodexBar(codexIsRunning: true, codexBarIsRunning: true), "工具已运行时不重复启动")
        try check(!LaunchCompanionPolicy.shouldLaunchCodexBar(codexIsRunning: false, codexBarIsRunning: false), "Codex 未运行时不误启动")
        try check(QuotaWindow(id: "a", usedPercent: 150, durationMinutes: 300, resetsAt: nil).remainingPercent == 0, "百分比上限保护")
        try check(QuotaWindow(id: "b", usedPercent: -1, durationMinutes: 300, resetsAt: nil).remainingPercent == 100, "百分比下限保护")

        let balanceData = Data(#"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"110.25","granted_balance":"10.25","topped_up_balance":"100.00"}]}"#.utf8)
        let deepSeekBalance = try DeepSeekClient.parseBalance(balanceData)
        try check(deepSeekBalance.isAvailable && deepSeekBalance.balances.first?.total == Decimal(string: "110.25"), "DeepSeek 官方余额结构解析")

        let providerTestRoot = FileManager.default.temporaryDirectory.appendingPathComponent("codexbar-provider-test-\(UUID().uuidString)", isDirectory: true)
        let providerConfigURL = providerTestRoot.appendingPathComponent("codex/config.toml")
        let providerSupportURL = providerTestRoot.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: providerConfigURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let originalProviderConfig = #"""
        # 用户原始配置
        model = "gpt-5.6-sol"
        model_reasoning_effort = "xhigh"
        base_instructions = """
        keep this multiline value
        """

        [plugins.demo]
        enabled = true
        """#
        let originalProviderData = Data(originalProviderConfig.utf8)
        try originalProviderData.write(to: providerConfigURL, options: .atomic)
        let minimalCatalog = Data(#"{"models":[{"slug":"deepseek-v4-flash"},{"slug":"deepseek-v4-pro"},{"slug":"deepseek-v4-flash-vision-exp"}]}"#.utf8)
        let providerManager = ProviderConfigManager(paths: ProviderConfigPaths(configURL: providerConfigURL, supportDirectory: providerSupportURL))
        let switched = try providerManager.activateDeepSeek(model: .flash, catalogData: minimalCatalog, apiKey: "codexbar-selftest-key")
        let switchedConfig = try String(contentsOf: providerConfigURL, encoding: .utf8)
        try check(switched.mode == .deepSeek && switched.deepSeekModel == .flash, "DeepSeek 切换事务进入 Flash 模式")
        try check(switchedConfig.contains("model = \"deepseek-v4-flash\"") && switchedConfig.contains("wire_api = \"responses\""), "DeepSeek 官方 Responses 配置真实写入")
        try check(!switchedConfig.contains("gpt-5.6-sol") && !switchedConfig.contains("keep this multiline value"), "DeepSeek 不兼容的原模型参数在租约内隔离")
        try check(switchedConfig.contains("[plugins.demo]") && switchedConfig.contains("enabled = true"), "非模型 Codex 配置保持不变")
        _ = try providerManager.activateDeepSeek(model: .pro, catalogData: minimalCatalog, apiKey: "codexbar-selftest-key")
        let proConfig = try String(contentsOf: providerConfigURL, encoding: .utf8)
        try check(proConfig.contains("model = \"deepseek-v4-pro\"") && !proConfig.contains("deepseek-v4-flash\"\nmodel_provider"), "DeepSeek Flash 与 Pro 可逆切换且不叠加配置")
        _ = try providerManager.activateDeepSeek(model: .visionExperimental, catalogData: minimalCatalog, apiKey: "codexbar-selftest-key")
        let visionConfig = try String(contentsOf: providerConfigURL, encoding: .utf8)
        try check(visionConfig.contains("model = \"deepseek-v4-flash-vision-exp\""), "DeepSeek Vision 实验模型真实写入 Codex 配置")
        let independentRecoveryManager = ProviderConfigManager(paths: ProviderConfigPaths(configURL: providerConfigURL, supportDirectory: providerSupportURL))
        _ = try independentRecoveryManager.restore()
        let restoredProviderData = try Data(contentsOf: providerConfigURL)
        try check(restoredProviderData == originalProviderData, "退出 DeepSeek 后 Codex 原配置逐字节恢复")
        try check(!providerManager.hasActiveTransaction(), "独立看门狗恢复后不残留模型租约")

        let absentConfigURL = providerTestRoot.appendingPathComponent("absent/config.toml")
        let absentManager = ProviderConfigManager(paths: ProviderConfigPaths(configURL: absentConfigURL, supportDirectory: providerTestRoot.appendingPathComponent("absent-support")))
        _ = try absentManager.activateDeepSeek(model: .flash, catalogData: minimalCatalog, apiKey: "codexbar-selftest-key")
        _ = try absentManager.restore()
        try check(!FileManager.default.fileExists(atPath: absentConfigURL.path), "原本无配置文件时回滚后不留下配置")
        try? FileManager.default.removeItem(at: providerTestRoot)

        let keychainTestStore = DeepSeekCredentialStore(service: "com.smd.codexbar.selftest.\(UUID().uuidString)", account: "temporary")
        try keychainTestStore.save("codexbar-selftest-key")
        try check(keychainTestStore.hasKey(), "DeepSeek Key 只读元数据即可判断存在")
        let loadedTestKey = try keychainTestStore.load()
        try check(loadedTestKey == "codexbar-selftest-key", "DeepSeek Key 可写入并读取 macOS 钥匙串")
        try keychainTestStore.delete()
        let deletedTestKey = try keychainTestStore.load()
        try check(deletedTestKey == nil, "DeepSeek Key 可从 macOS 钥匙串完整删除")

        print("\n\(passed) 项测试全部通过")
    }

    private static func unwrap<T>(_ value: T?, _ name: String) throws -> T {
        guard let value else { throw TestFailure.failed(name) }
        return value
    }
}

enum TestFailure: Error { case failed(String) }
