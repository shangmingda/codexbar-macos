import CodexBarCore
import Foundation

@main
struct SelfTests {
    static func main() async throws {
        if let fixtureArgument = CommandLine.arguments.first(where: { $0.hasPrefix("--prepare-openai-compat-fixture=") }) {
            let root = URL(fileURLWithPath: String(fixtureArgument.dropFirst("--prepare-openai-compat-fixture=".count)), isDirectory: true)
            let configURL = root.appendingPathComponent("codex/config.toml")
            let supportURL = root.appendingPathComponent("support", isDirectory: true)
            try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("model = \"gpt-5.6-sol\"\nmodel_provider = \"openai\"\nmodel_reasoning_effort = \"high\"\n".utf8).write(to: configURL, options: .atomic)
            let manager = ProviderConfigManager(paths: ProviderConfigPaths(configURL: configURL, supportDirectory: supportURL))
            _ = try manager.activateOpenAICompatibility(apiKey: nil)
            print("openai-compat-fixture-ready")
            return
        }
        if let fixtureArgument = CommandLine.arguments.first(where: { $0.hasPrefix("--prepare-native-picker-fixture=") }) {
            let root = URL(fileURLWithPath: String(fixtureArgument.dropFirst("--prepare-native-picker-fixture=".count)), isDirectory: true)
            let configURL = root.appendingPathComponent("codex/config.toml")
            let supportURL = root.appendingPathComponent("support", isDirectory: true)
            try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("model = \"gpt-5.6-sol\"\nmodel_reasoning_effort = \"xhigh\"\n".utf8).write(to: configURL, options: .atomic)
            let script = try String(contentsOf: DeepSeekClient.setupScriptURL, encoding: .utf8)
            let catalog = try DeepSeekClient.extractOfficialModelCatalog(from: script)
            let manager = ProviderConfigManager(paths: ProviderConfigPaths(configURL: configURL, supportDirectory: supportURL))
            _ = try manager.activateDeepSeek(model: .flash, catalogData: catalog, apiKey: "codexbar-selftest-key")
            print("native-picker-fixture-ready")
            return
        }
        if let fixtureArgument = CommandLine.arguments.first(where: { $0.hasPrefix("--prepare-provider-recovery-fixture=") }) {
            let root = URL(fileURLWithPath: String(fixtureArgument.dropFirst("--prepare-provider-recovery-fixture=".count)), isDirectory: true)
            let configURL = root.appendingPathComponent("codex/config.toml")
            let supportURL = root.appendingPathComponent("support", isDirectory: true)
            try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("model = \"gpt-5.6-sol\"\nmodel_reasoning_effort = \"xhigh\"\n".utf8).write(to: configURL, options: .atomic)
            let catalog = Data(#"{"models":[{"slug":"deepseek-flash","display_name":"DeepSeek-Flash","description":"Native picker fixture","default_reasoning_level":"high","supported_reasoning_levels":[{"effort":"high","description":"Fixture"}],"input_modalities":["text","image"],"shell_type":"shell_command","visibility":"list","minimal_client_version":"0.144.0","supported_in_api":true,"priority":1},{"slug":"deepseek-v4-pro","display_name":"DeepSeek-V4-Pro","description":"Native picker fixture","default_reasoning_level":"high","supported_reasoning_levels":[{"effort":"high","description":"Fixture"}],"input_modalities":["text"],"shell_type":"shell_command","visibility":"list","minimal_client_version":"0.144.0","supported_in_api":true,"priority":2}]}"#.utf8)
            let manager = ProviderConfigManager(paths: ProviderConfigPaths(configURL: configURL, supportDirectory: supportURL))
            _ = try manager.activateDeepSeek(model: .flash, catalogData: catalog, apiKey: "codexbar-selftest-key")
            print("fixture-ready")
            return
        }
        if let scanArgument = CommandLine.arguments.first(where: { $0.hasPrefix("--scan-tool-pairing=") }) {
            let url = URL(fileURLWithPath: String(scanArgument.dropFirst("--scan-tool-pairing=".count)))
            let scan = try ThreadToolPairingRepair.scan(sessionAt: url)
            print("deepseek=\(scan.containsDeepSeekProvider) interleaved=\(scan.interleavedLines.count) notices=\(scan.noticeLines.count)")
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

        let availableModelsData = Data(#"{"object":"list","data":[{"id":"deepseek-flash"},{"id":"deepseek-v4-pro"}]}"#.utf8)
        let availableModels = try DeepSeekClient.parseAvailableModels(availableModelsData)
        try check(availableModels.contains(DeepSeekModel.flash.rawValue), "DeepSeek Flash 模型 API 列表解析")
        try check(DeepSeekModel.flash.shortName == "Flash", "DeepSeek Flash 模型界面名称")
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
        {"models":[{"slug":"deepseek-flash"},{"slug":"deepseek-v4-pro"}]}
        CODEX_MODELS_JSON
        }
        """#
        let extractedCatalog = try DeepSeekClient.extractOfficialModelCatalog(from: currentSetupScript)
        let extractedObject = try JSONSerialization.jsonObject(with: extractedCatalog) as? [String: Any]
        let extractedModels = (extractedObject?["models"] as? [[String: Any]])?.compactMap { $0["slug"] as? String } ?? []
        try check(extractedModels.contains(DeepSeekModel.flash.rawValue), "DeepSeek 新版官方脚本目录提取")

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
        try check(tasks[0].modelDisplayName == "DS-V4 Pro", "DeepSeek 任务展示具体模型短名")
        let openAITask = ActiveTask(id: "openai", title: "原生任务", objective: "", cwd: "/tmp", tokensUsed: 0, timeUsedSeconds: 0, updatedAt: Date(), modelProvider: "openai", model: "gpt-5.6-sol")
        try check(openAITask.providerMode == .openAI, "OpenAI 任务 Provider 识别")
        try check(openAITask.modelDisplayName == "GPT-5.6 Sol", "OpenAI 任务展示具体模型短名")
        let gpt6Task = ActiveTask(id: "gpt6", title: "GPT-6 任务", objective: "", cwd: "/tmp", tokensUsed: 0, timeUsedSeconds: 0, updatedAt: Date(), modelProvider: "openai", model: "gpt-6-astra")
        try check(gpt6Task.modelDisplayName == "GPT-6", "GPT-6 Astra 任务使用精简名")
        let legacyFlashTask = ActiveTask(id: "legacy-ds", title: "旧 DeepSeek 任务", objective: "", cwd: "/tmp", tokensUsed: 0, timeUsedSeconds: 0, updatedAt: Date(), modelProvider: "codexbar-deepseek", model: "deepseek-v4-flash")
        try check(legacyFlashTask.modelDisplayName == "DS-V4 Flash", "旧 DeepSeek 任务保留可识别短名")
        let futureTask = ActiveTask(id: "future", title: "未来模型", objective: "", cwd: "/tmp", tokensUsed: 0, timeUsedSeconds: 0, updatedAt: Date(), modelProvider: "future-provider", model: "future-model-preview-version")
        try check(futureTask.modelDisplayName == "future-model-prev…", "未知新模型显示真实 id 而非其他模型")
        let openAIHTTPTask = ActiveTask(id: "openai-http", title: "HTTP 原生任务", objective: "", cwd: "/tmp", tokensUsed: 0, timeUsedSeconds: 0, updatedAt: Date(), modelProvider: "openai-http", model: "gpt-5.6-sol")
        try check(openAIHTTPTask.providerMode == .openAI, "openai-http Provider 显示为 OpenAI")
        try check(openAIHTTPTask.providerDisplayName == "OpenAI", "openai-http Provider 不显示为未知模型")
        try check(
            TaskOpenPolicy.route(for: openAIHTTPTask, activeProvider: .openAI, activeDeepSeekModel: .flash) == .direct,
            "openai-http 任务在 OpenAI 模式直接打开"
        )
        try check(
            TaskOpenPolicy.route(for: openAIHTTPTask, activeProvider: .deepSeek, activeDeepSeekModel: .flash) == .switchProvider(mode: .openAI, model: nil),
            "openai-http 任务从 DeepSeek 安全切回 OpenAI"
        )
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
        let proTask = ActiveTask(id: "pro", title: "Pro 任务", objective: "", cwd: "/tmp", tokensUsed: 0, timeUsedSeconds: 0, updatedAt: Date(), modelProvider: ProviderConfigManager.providerID, model: DeepSeekModel.pro.rawValue)
        try check(
            TaskOpenPolicy.route(for: proTask, activeProvider: .deepSeek, activeDeepSeekModel: .flash) == .direct,
            "DeepSeek Provider 内不同模型由 Codex 原生菜单处理，不再重启"
        )
        let legacyDeepSeekTask = ActiveTask(id: "legacy-ds", title: "旧 DeepSeek 任务", objective: "", cwd: "/tmp", tokensUsed: 0, timeUsedSeconds: 0, updatedAt: Date(), modelProvider: ProviderConfigManager.legacyProviderID, model: "deepseek-v4-flash-vision-exp")
        try check(legacyDeepSeekTask.providerMode == .deepSeek, "旧版连字符 DeepSeek Provider 兼容识别")
        try check(DeepSeekModel.compatible(rawValue: legacyDeepSeekTask.model) == .flash, "旧版 Flash/Vision 模型映射到当前 Flash")
        let decodedLegacyModel = try JSONDecoder().decode(DeepSeekModel.self, from: Data(#""deepseek-v4-flash-vision-exp""#.utf8))
        try check(decodedLegacyModel == .flash, "旧版模型租约可升级解码，不阻断配置恢复")
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
        try check(NetworkSpeed.compact(0) == "0B/s" && NetworkSpeed.compact(1_500_000) == "1.5M/s", "状态栏网速单位紧凑显示")
        try check(DingTalkWebhookStore.isValid("https://oapi.dingtalk.com/robot/send?access_token=test-value"), "钉钉官方机器人地址校验")
        try check(!DingTalkWebhookStore.isValid("https://example.com/robot/send?access_token=test-value"), "拒绝非钉钉 Webhook 域名")
        let resetNow = Date(timeIntervalSince1970: 1_790_000_000)
        let oldDue = resetNow.addingTimeInterval(-10)
        let laterDue = resetNow.addingTimeInterval(604_800)
        let naturalOld = QuotaWindow(id: "codex-secondary-10080", usedPercent: 42, durationMinutes: 10_080, resetsAt: oldDue)
        let naturalNew = QuotaWindow(id: naturalOld.id, usedPercent: 0, durationMinutes: 10_080, resetsAt: laterDue)
        let natural = QuotaResetDetector.detect(previous: [naturalOld], current: [naturalNew], now: resetNow)
        try check(natural.count == 1 && natural[0].kind == .scheduled, "周额度自然窗口轮换触发提醒")
        let earlyOld = QuotaWindow(id: "codex-secondary-10080", usedPercent: 37, durationMinutes: 10_080, resetsAt: resetNow.addingTimeInterval(80_000))
        let earlyNew = QuotaWindow(id: earlyOld.id, usedPercent: 0, durationMinutes: 10_080, resetsAt: earlyOld.resetsAt)
        let early = QuotaResetDetector.detect(previous: [earlyOld], current: [earlyNew], now: resetNow)
        try check(early.count == 1 && early[0].kind == .early, "官方提前清零可由额度快照识别")
        let correction = QuotaWindow(id: earlyOld.id, usedPercent: 36, durationMinutes: 10_080, resetsAt: earlyOld.resetsAt)
        try check(QuotaResetDetector.detect(previous: [earlyOld], current: [correction], now: resetNow).isEmpty, "小幅额度校正不误报重置")
        let shortOld = QuotaWindow(id: "codex-primary-300", usedPercent: 42, durationMinutes: 300, resetsAt: oldDue)
        let shortNew = QuotaWindow(id: shortOld.id, usedPercent: 0, durationMinutes: 300, resetsAt: resetNow.addingTimeInterval(18_000))
        try check(QuotaResetDetector.detect(previous: [shortOld], current: [shortNew], now: resetNow).isEmpty, "5h 自然重置不通知")
        let shortEarlyOld = QuotaWindow(id: shortOld.id, usedPercent: 42, durationMinutes: 300, resetsAt: shortNew.resetsAt)
        try check(QuotaResetDetector.detect(previous: [shortEarlyOld], current: [shortNew], now: resetNow).isEmpty, "5h 提前清零不通知")
        let idleOld = QuotaWindow(id: earlyOld.id, usedPercent: 0, durationMinutes: 10_080, resetsAt: laterDue)
        let idleNew = QuotaWindow(id: earlyOld.id, usedPercent: 0, durationMinutes: 10_080, resetsAt: laterDue.addingTimeInterval(300))
        try check(QuotaResetDetector.detect(previous: [idleOld], current: [idleNew], now: resetNow).isEmpty, "周额度 100% 时间随查询滚动不误报")
        let driftingNew = QuotaWindow(id: earlyOld.id, usedPercent: 37, durationMinutes: 10_080, resetsAt: laterDue)
        try check(QuotaResetDetector.detect(previous: [earlyOld], current: [driftingNew], now: resetNow).isEmpty, "周额度非零且只有重置时间后移不误报")
        let tinyOld = QuotaWindow(id: earlyOld.id, usedPercent: 1, durationMinutes: 10_080, resetsAt: laterDue)
        try check(QuotaResetDetector.detect(previous: [tinyOld], current: [idleOld], now: resetNow).isEmpty, "周额度 1% 到 0% 微小校正不误报")
        let movedEarlyNew = QuotaWindow(id: earlyOld.id, usedPercent: 0, durationMinutes: 10_080, resetsAt: laterDue)
        try check(QuotaResetDetector.detect(previous: [earlyOld], current: [movedEarlyNew], now: resetNow).first?.kind == .early, "周额度下降且重置时间变化仍识别提前重置")
        try check(!QuotaResetDetector.shouldNotify(QuotaWindow(id: "unknown", usedPercent: 0, durationMinutes: nil, resetsAt: nil)), "未知额度周期不发送通知")
        try await DingTalkResetNotifier(credentialStore: DingTalkWebhookStore(service: "codexbar-test-\(UUID().uuidString)", legacyService: nil)).send(event: QuotaResetEvent(window: shortNew, kind: .early, detectedAt: resetNow), keyword: "请注意")
        try check(true, "发送边界拒绝 5h 事件且不读取钥匙串或请求网络")
        let noticeURL = FileManager.default.temporaryDirectory.appendingPathComponent("codexbar-reset-notice-test-\(UUID().uuidString).json")
        let noticeStore = try QuotaResetNoticeStore(fileURL: noticeURL)
        let initialPending = try noticeStore.observe([naturalOld], now: resetNow)
        try check(initialPending.isEmpty, "首次额度快照只建立基线")
        try check(noticeStore.lastSnapshot?.windows == [naturalOld] && noticeStore.lastSnapshot?.observedAt == resetNow, "最近额度快照可用于短暂故障时展示缓存")
        let pending = try noticeStore.observe([naturalNew], now: resetNow)
        try check(pending.count == 1, "额度重置事件持久入队")
        let restoredNoticeStore = try QuotaResetNoticeStore(fileURL: noticeURL)
        try check(restoredNoticeStore.pending.count == 1, "应用重启后待发通知可恢复")
        let repeatPending = try restoredNoticeStore.observe([naturalNew], now: resetNow.addingTimeInterval(300))
        try check(repeatPending.count == 1, "周额度通知等待期间重复快照不重复入队")
        try restoredNoticeStore.markDelivered(pending[0].id)
        let finalPending = try restoredNoticeStore.observe([naturalNew], now: resetNow)
        try check(finalPending.isEmpty, "通知成功后重复快照不重发")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var legacyJournal = try JSONSerialization.jsonObject(with: Data(contentsOf: noticeURL)) as! [String: Any]
        legacyJournal["pending"] = try JSONSerialization.jsonObject(with: encoder.encode([
            QuotaResetEvent(window: shortNew, kind: .early, detectedAt: resetNow),
            QuotaResetEvent(window: naturalNew, kind: .scheduled, detectedAt: resetNow)
        ]))
        try JSONSerialization.data(withJSONObject: legacyJournal).write(to: noticeURL)
        let migratedStore = try QuotaResetNoticeStore(fileURL: noticeURL)
        try check(migratedStore.pending.count == 1 && migratedStore.pending[0].window.durationMinutes == 10_080, "升级清理旧版 5h 待发事件并保留周提醒")
        let remigratedStore = try QuotaResetNoticeStore(fileURL: noticeURL)
        try check(remigratedStore.pending.count == 1, "升级清理结果持久化且重启不恢复 5h 事件")
        try? FileManager.default.removeItem(at: noticeURL)

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
        let minimalCatalog = Data(#"{"models":[{"slug":"deepseek-flash"},{"slug":"deepseek-v4-pro"}]}"#.utf8)
        let providerManager = ProviderConfigManager(paths: ProviderConfigPaths(configURL: providerConfigURL, supportDirectory: providerSupportURL))
        let compatible = try providerManager.activateOpenAICompatibility(apiKey: "codexbar-selftest-key")
        let compatibleConfig = try String(contentsOf: providerConfigURL, encoding: .utf8)
        try check(compatible.mode == .openAI, "OpenAI 默认模式保留")
        try check(compatibleConfig.contains("model = \"gpt-5.6-sol\"") && compatibleConfig.contains("[model_providers.codexbar_deepseek]"), "OpenAI 模式注册 DeepSeek 历史对话 Provider")
        try check(compatibleConfig.contains("[model_providers.codexbar-deepseek]"), "旧版 DeepSeek Provider 别名已注册")
        try check(compatibleConfig.contains("[model_providers.deepseek]"), "DeepSeek 官方 Provider 别名已注册")
        try check(!compatibleConfig.contains("model_catalog_json"), "OpenAI 原生模型目录不被外部目录覆盖")
        let switched = try providerManager.activateDeepSeek(model: .flash, catalogData: minimalCatalog, apiKey: "codexbar-selftest-key")
        let switchedConfig = try String(contentsOf: providerConfigURL, encoding: .utf8)
        try check(switched.mode == .deepSeek && switched.deepSeekModel == .flash, "DeepSeek 切换事务进入 Flash 模式")
        try check(switchedConfig.contains("model = \"deepseek-flash\"") && switchedConfig.contains("wire_api = \"responses\""), "DeepSeek 官方 Responses 配置真实写入")
        try check(switchedConfig.contains("[model_providers.codexbar-deepseek]"), "DeepSeek 模式保留旧 Provider 对话兼容")
        try check(!switchedConfig.contains("gpt-5.6-sol") && !switchedConfig.contains("keep this multiline value"), "DeepSeek 不兼容的原模型参数在租约内隔离")
        try check(switchedConfig.contains("[plugins.demo]") && switchedConfig.contains("enabled = true"), "非模型 Codex 配置保持不变")
        _ = try providerManager.activateDeepSeek(model: .pro, catalogData: minimalCatalog, apiKey: "codexbar-selftest-key")
        let proConfig = try String(contentsOf: providerConfigURL, encoding: .utf8)
        try check(proConfig.contains("model = \"deepseek-v4-pro\"") && !proConfig.contains("deepseek-flash\"\nmodel_provider"), "DeepSeek Flash 与 Pro 可逆切换且不叠加配置")
        _ = try providerManager.activateDeepSeek(model: .flash, catalogData: minimalCatalog, apiKey: "codexbar-selftest-key")
        let flashAgainConfig = try String(contentsOf: providerConfigURL, encoding: .utf8)
        try check(flashAgainConfig.contains("model = \"deepseek-flash\""), "DeepSeek Flash 模型真实写入 Codex 配置")
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
        let silentTestKey = try keychainTestStore.loadNonInteractively()
        try check(silentTestKey == nil || silentTestKey == "codexbar-selftest-key", "DeepSeek 后台钥匙串读取无需授权弹窗")
        let loadedTestKey = try keychainTestStore.load()
        try check(loadedTestKey == "codexbar-selftest-key", "DeepSeek Key 可写入并读取 macOS 钥匙串")
        try keychainTestStore.delete()
        let deletedTestKey = try keychainTestStore.load()
        try check(deletedTestKey == nil, "DeepSeek Key 可从 macOS 钥匙串完整删除")

        // Codex keeps a thread's provider when only the model is swapped in the
        // native picker, so a DeepSeek model can stay routed to api.openai.com.
        func bindingTask(_ id: String, model: String?, provider: String?) -> ActiveTask {
            ActiveTask(
                id: id,
                title: "binding-\(id)",
                objective: "",
                cwd: "/tmp",
                tokensUsed: 0,
                timeUsedSeconds: 0,
                updatedAt: Date(),
                modelProvider: provider,
                model: model
            )
        }
        try check(
            bindingTask("a", model: "deepseek-flash", provider: "openai").providerBindingIssue
                == .deepSeekModelOnOpenAIProvider(model: "deepseek-flash"),
            "识别 DeepSeek 模型挂在 OpenAI Provider 的错配"
        )
        try check(
            bindingTask("b", model: "deepseek-v4-flash-vision-exp", provider: "openai-http").providerBindingIssue?.isDeepSeekModelOnOpenAIProvider == true,
            "旧版 DeepSeek slug 同样被识别为错配"
        )
        try check(
            bindingTask("c", model: "gpt-5.6-sol", provider: "codexbar_deepseek").providerBindingIssue
                == .openAIModelOnDeepSeekProvider(model: "gpt-5.6-sol"),
            "识别 OpenAI 模型挂在 DeepSeek Provider 的错配"
        )
        try check(bindingTask("d", model: "deepseek-flash", provider: "codexbar_deepseek").providerBindingIssue == nil, "正常 DeepSeek 任务不报错配")
        try check(bindingTask("e", model: "gpt-5.6-sol", provider: "openai-http").providerBindingIssue == nil, "正常 OpenAI 任务不报错配")
        try check(bindingTask("f", model: "deepseek-v4-pro", provider: "deepseek").providerBindingIssue == nil, "DeepSeek 官方 Provider 任务不报错配")
        try check(bindingTask("g", model: nil, provider: nil).providerBindingIssue == nil, "缺少模型信息时不误报")
        try check(bindingTask("h", model: "gpt-5.6-sol", provider: "openai").providerBindingIssue == nil, "OpenAI 自家人工组合不误报")

        // Parallel tool calls must be serialised for DeepSeek: the endpoint
        // loses the second output and then replays the broken pair forever.
        let parallelCatalog = Data(#"{"models":[{"slug":"deepseek-flash","supports_parallel_tool_calls":true,"input_modalities":["text","image"]},{"slug":"deepseek-v4-pro","supports_parallel_tool_calls":true}]}"#.utf8)
        let normalizedCatalog = try ProviderConfigManager.normalizingCatalog(parallelCatalog)
        let normalizedObject = try unwrap(try JSONSerialization.jsonObject(with: normalizedCatalog) as? [String: Any], "规范化目录可解析")
        let normalizedModels = try unwrap(normalizedObject["models"] as? [[String: Any]], "规范化目录仍包含 models")
        try check(normalizedModels.count == 2, "目录规范化保留全部 DeepSeek 模型")
        try check(
            normalizedModels.allSatisfy { ($0["supports_parallel_tool_calls"] as? Bool) == false },
            "DeepSeek 目录关闭并行工具调用"
        )
        try check(
            (normalizedModels.first?["input_modalities"] as? [String])?.contains("image") == true,
            "目录规范化不改动模型的其余能力字段"
        )
        let slugOnlyCatalog = try ProviderConfigManager.normalizingCatalog(minimalCatalog)
        try check(slugOnlyCatalog.count > 0, "仅含 slug 的历史目录同样可以规范化")
        try check(
            normalizedModels.allSatisfy { $0["base_instructions"] == nil },
            "缺少 base_instructions 的目录不注入空提示"
        )

        // 仅关闭并行标记还不够：DeepSeek 仍会在一条消息里请求多张图片，而客户端把
        // <image_resize_notice> 插在工具输出之间就会破坏配对。因此目录同时写入串行规则。
        let instructionCatalog = Data(#"{"models":[{"slug":"deepseek-flash","base_instructions":"BASE-PROMPT","supports_parallel_tool_calls":true}]}"#.utf8)
        let instructedCatalog = try ProviderConfigManager.normalizingCatalog(instructionCatalog)
        let instructedObject = try unwrap(try JSONSerialization.jsonObject(with: instructedCatalog) as? [String: Any], "注入串行规则的目录可解析")
        let instructedModels = try unwrap(instructedObject["models"] as? [[String: Any]], "注入串行规则后仍包含 models")
        let instructedPrompt = try unwrap(instructedModels.first?["base_instructions"] as? String, "模型保留 base_instructions")
        try check(instructedPrompt.hasPrefix("BASE-PROMPT"), "注入串行规则时保留原 base_instructions")
        try check(instructedPrompt.contains("## CodexBar tool-call rule"), "DeepSeek 目录写入串行工具调用规则")
        try check(instructedPrompt.contains("at most one tool call per assistant turn"), "串行规则明确限制每轮一次工具调用")
        let twiceCatalog = try ProviderConfigManager.normalizingCatalog(instructedCatalog)
        let twiceObject = try unwrap(try JSONSerialization.jsonObject(with: twiceCatalog) as? [String: Any], "重复规范化的目录可解析")
        let twiceModels = try unwrap(twiceObject["models"] as? [[String: Any]], "重复规范化后仍包含 models")
        let twicePrompt = try unwrap(twiceModels.first?["base_instructions"] as? String, "重复规范化保留提示")
        let markerCount = twicePrompt.components(separatedBy: "## CodexBar tool-call rule").count - 1
        try check(markerCount == 1, "重复规范化不会叠加串行工具调用规则")

        // 真正被客户端发送的是 model_messages.instructions_template：只写 base_instructions
        // 时模型看不到规则（实测 3/3 仍然并行请求两张图），写进模板后降为 0~1 次。
        let templateCatalog = Data(#"{"models":[{"slug":"deepseek-flash","base_instructions":"BASE","model_messages":{"instructions_template":"TEMPLATE-PROMPT","instructions_variables":[]}}]}"#.utf8)
        let templateNormalized = try ProviderConfigManager.normalizingCatalog(templateCatalog)
        let templateObject = try unwrap(try JSONSerialization.jsonObject(with: templateNormalized) as? [String: Any], "含 model_messages 的目录可解析")
        let templateModels = try unwrap(templateObject["models"] as? [[String: Any]], "含 model_messages 的目录保留 models")
        let messages = try unwrap(templateModels.first?["model_messages"] as? [String: Any], "model_messages 被保留")
        let template = try unwrap(messages["instructions_template"] as? String, "instructions_template 被保留")
        try check(template.hasPrefix("TEMPLATE-PROMPT"), "注入规则时保留原 instructions_template")
        try check(template.contains("## CodexBar tool-call rule"), "串行规则写入 instructions_template")
        try check((messages["instructions_variables"] as? [Any]) != nil, "model_messages 其余字段不被改动")
        let templateTwice = try ProviderConfigManager.normalizingCatalog(templateNormalized)
        let templateTwiceModels = try unwrap(try (JSONSerialization.jsonObject(with: templateTwice) as? [String: Any])?["models"] as? [[String: Any]], "重复规范化模板目录可解析")
        let templateTwiceMessages = try unwrap(templateTwiceModels.first?["model_messages"] as? [String: Any], "重复规范化保留 model_messages")
        let templateTwiceText = try unwrap(templateTwiceMessages["instructions_template"] as? String, "重复规范化保留模板")
        try check(
            templateTwiceText.components(separatedBy: "## CodexBar tool-call rule").count - 1 == 1,
            "重复规范化不会叠加 instructions_template 规则"
        )
        let noTemplateCatalog = Data(#"{"models":[{"slug":"deepseek-flash","model_messages":{"instructions_variables":[]}}]}"#.utf8)
        let noTemplateNormalized = try ProviderConfigManager.normalizingCatalog(noTemplateCatalog)
        let noTemplateModels = try unwrap(try (JSONSerialization.jsonObject(with: noTemplateNormalized) as? [String: Any])?["models"] as? [[String: Any]], "无模板目录可解析")
        let noTemplateMessages = try unwrap(noTemplateModels.first?["model_messages"] as? [String: Any], "无模板目录保留 model_messages")
        try check(noTemplateMessages["instructions_template"] == nil, "缺少 instructions_template 时不注入字符串")

        // 截图压缩提示是损坏配对的唯一直接触发点：规则里必须包含"看图前先缩小"的操作步骤。
        try check(instructedPrompt.contains("sips --resampleHeightWidthMax 2048"), "串行规则包含截图预缩小步骤")
        try check(instructedPrompt.contains("2048 pixels"), "串行规则说明 2048 像素阈值")

        // 坏配对检测与修复：构造与真实 rollout 同构的会话文件。
        let pairingRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codexbar-pairing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: pairingRoot, withIntermediateDirectories: true)
        let sessionURL = pairingRoot.appendingPathComponent("rollout-2026-09-12T15-33-15-019f0000-0000-7000-8000-00000000abcd.jsonl")
        func sessionLine(_ payload: [String: Any]) -> String {
            let object: [String: Any] = [
                "timestamp": "2026-09-12T13:06:47.000Z",
                "type": "response_item",
                "payload": payload
            ]
            let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return String(data: data, encoding: .utf8)!
        }
        let calls = "deepseek-flash codexbar_deepseek view_image"
        let lines = [
            sessionLine(["type": "function_call", "call_id": "call_a", "name": "view_image"]),
            sessionLine(["type": "function_call", "call_id": "call_b", "name": "view_image"]),
            sessionLine(["type": "function_call_output", "call_id": "call_a", "output": calls]),
            sessionLine(["type": "message", "role": "developer", "content": [["type": "input_text", "text": "<image_resize_notice> resized </image_resize_notice>"]]]),
            sessionLine(["type": "function_call_output", "call_id": "call_b", "output": calls]),
            sessionLine(["type": "message", "role": "developer", "content": [["type": "input_text", "text": "<image_resize_notice> trailing </image_resize_notice>"]]])
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: sessionURL, atomically: true, encoding: .utf8)
        let scan = try ThreadToolPairingRepair.scan(sessionAt: sessionURL)
        try check(scan.containsDeepSeekProvider, "会话扫描识别 DeepSeek Provider")
        try check(scan.interleavedLines.count == 1, "只把夹在两条工具输出之间的项判为坏配对")
        try check(scan.noticeLines.count == 1, "坏配对里只有压缩提示可安全删除")
        try check(ThreadToolPairingRepair.threadID(fromSessionFile: sessionURL) == "019f0000-0000-7000-8000-00000000abcd", "从会话文件名解析线程标识")

        let candidates = ThreadToolPairingRepair.scanSessions(root: pairingRoot, codexHome: pairingRoot)
        try check(candidates.count == 1, "会话目录扫描能找到坏配对")
        try check(candidates.first?.removableNotices == 1, "候选记录携带可删除提示数量")
        guard let candidate = candidates.first else { throw TestFailure.failed("缺少坏配对候选") }
        let backupRoot = pairingRoot.appendingPathComponent("backups", isDirectory: true)
        let record = try ThreadToolPairingRepair.repair(candidate: candidate, backupRoot: backupRoot, supportDirectory: pairingRoot)
        try check(record.removedItems == 1, "修复删除 1 条夹在中间的输出提示")
        try check(FileManager.default.fileExists(atPath: record.backupPath), "修复前保留会话文件备份")
        let repaired = try ThreadToolPairingRepair.scan(sessionAt: sessionURL)
        try check(repaired.noticeLines.isEmpty && repaired.interleavedLines.isEmpty, "修复后不再存在坏配对")
        let journalURL = pairingRoot.appendingPathComponent(ThreadToolPairingRepair.journalFileName)
        let pairingJournalPermissions = (try? FileManager.default.attributesOfItem(atPath: journalURL.path)[.posixPermissions] as? NSNumber)?.intValue
        try check(pairingJournalPermissions == 0o600, "坏配对修复日志权限为 0600")
        let secondRecord = try ThreadToolPairingRepair.repair(candidate: candidate, backupRoot: backupRoot, supportDirectory: pairingRoot)
        try check(secondRecord.removedItems == 0, "重复修复不再改动会话文件")
        try? FileManager.default.removeItem(at: pairingRoot)

        // Repair writes exactly one thread row, keeps a journal and verifies the
        // result by read-back.
        let repairRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codexbar-repair-\(UUID().uuidString)", isDirectory: true)
        let repairCodexHome = repairRoot.appendingPathComponent("codex", isDirectory: true)
        let repairSupport = repairRoot.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: repairCodexHome, withIntermediateDirectories: true)
        let repairDatabase = repairCodexHome.appendingPathComponent("state_5.sqlite")
        let mismatchedID = "019f595e-797b-7893-bc40-35e1afe0fd1b"
        let untouchedID = "019f6509-52dd-7e50-844e-fb8d37cd37a2"
        try runSQLite(
            database: repairDatabase,
            sql: """
            CREATE TABLE threads (id TEXT PRIMARY KEY, model TEXT, model_provider TEXT NOT NULL, title TEXT NOT NULL DEFAULT '', preview TEXT NOT NULL DEFAULT '', archived INTEGER NOT NULL DEFAULT 0, updated_at INTEGER NOT NULL DEFAULT 0, updated_at_ms INTEGER);
            INSERT INTO threads (id, model, model_provider, title, updated_at_ms) VALUES ('\(mismatchedID)','deepseek-flash','openai','错配的旧对话',1789141473000);
            INSERT INTO threads (id, model, model_provider, title, updated_at_ms) VALUES ('\(untouchedID)','gpt-5.6-sol','openai-http','正常对话',1789000000000);
            INSERT INTO threads (id, model, model_provider, title, archived, updated_at_ms) VALUES ('019f0000-0000-0000-0000-00000000000a','deepseek-flash','openai','已归档对话',1789141473000, 1);
            """
        )
        let repairStore = ThreadProviderRepairStore(codexHome: repairCodexHome, supportDirectory: repairSupport)
        let scanned = try repairStore.findMismatchedThreads()
        try check(scanned.count == 1 && scanned.first?.id == mismatchedID, "线程库扫描只命中错配且未归档的对话")
        try check(scanned.first?.issue == .deepSeekModelOnOpenAIProvider(model: "deepseek-flash"), "线程库扫描给出正确的错配类型")
        try check(scanned.first?.title == "错配的旧对话", "线程库扫描带回可读标题")
        let repairRecord = try repairStore.repair(threadID: mismatchedID, provider: ProviderConfigManager.providerID)
        try check(
            repairRecord.previousProvider == "openai" && repairRecord.appliedProvider == ProviderConfigManager.providerID,
            "线程修复记录原始与目标 Provider"
        )
        let repairedRows = try querySQLite(database: repairDatabase, sql: "SELECT id, model, model_provider FROM threads ORDER BY id;")
        try check(repairedRows.count == 3, "线程修复不新增或删除线程行")
        let repairedTarget = try unwrap(repairedRows.first { ($0["id"] as? String) == mismatchedID }, "修复后的目标线程仍存在")
        try check(
            (repairedTarget["model_provider"] as? String) == ProviderConfigManager.providerID
                && (repairedTarget["model"] as? String) == "deepseek-flash",
            "线程修复只改 Provider 并保留用户选择的模型"
        )
        let untouchedRow = try unwrap(repairedRows.first { ($0["id"] as? String) == untouchedID }, "未涉及的线程仍存在")
        try check(
            (untouchedRow["model_provider"] as? String) == "openai-http" && (untouchedRow["model"] as? String) == "gpt-5.6-sol",
            "线程修复不触碰其他线程"
        )
        let journalData = try Data(contentsOf: repairStore.journalURL)
        let journalText = String(data: journalData, encoding: .utf8) ?? ""
        try check(journalText.contains(mismatchedID) && journalText.contains("openai"), "线程修复留下可追溯的备份日志")
        let journalPermissions = (try FileManager.default.attributesOfItem(atPath: repairStore.journalURL.path)[.posixPermissions]) as? Int
        try check(journalPermissions == 0o600, "修复日志权限为 0600")
        let rescan = try repairStore.findMismatchedThreads()
        try check(rescan.isEmpty, "修复后线程库扫描不再报错配")
        let repairedModel = try repairStore.repair(
            threadID: untouchedID,
            model: "deepseek-flash",
            provider: ProviderConfigManager.providerID
        )
        try check(repairedModel.appliedModel == "deepseek-flash", "线程修复可以同时指定目标模型")
        do {
            _ = try repairStore.repair(threadID: "not-a-thread-id", provider: ProviderConfigManager.providerID)
            try check(false, "非法线程标识必须被拒绝")
        } catch {
            try check(true, "非法线程标识必须被拒绝")
        }
        do {
            _ = try repairStore.repair(threadID: "019f0000-0000-0000-0000-000000000009", provider: ProviderConfigManager.providerID)
            try check(false, "不存在的线程必须被拒绝")
        } catch {
            try check(true, "不存在的线程必须被拒绝")
        }
        try? FileManager.default.removeItem(at: repairRoot)

        for (condition, name) in try await QuotaRecoveryTests.run() { try check(condition, name) }
        for (condition, name) in try CredentialAccessTests.run() { try check(condition, name) }
        print("\n\(passed) 项测试全部通过")
    }

    private static func runSQLite(database: URL, sql: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database.path, sql]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw TestFailure.failed("sqlite3 执行失败") }
    }

    private static func querySQLite(database: URL, sql: String) throws -> [[String: Any]] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", "-json", database.path, sql]
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
    }

    private static func unwrap<T>(_ value: T?, _ name: String) throws -> T {
        guard let value else { throw TestFailure.failed(name) }
        return value
    }
}

enum TestFailure: Error { case failed(String) }
