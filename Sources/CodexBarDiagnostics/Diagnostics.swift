import CodexBarCore
import Foundation

@main
struct Diagnostics {
    static func main() async {
        if CommandLine.arguments.contains("--migrate-stable-credentials") {
            do { try CredentialMigration.run(); exit(0) }
            catch { print("stableCredentialMigrationFailed=true"); exit(1) }
        }
        if CommandLine.arguments.contains("--recovery-submission-readiness") {
            do {
                let client = AppServerControlClient()
                let path = CommandLine.arguments.first { $0.hasPrefix("--journal-path=") }.map { String($0.dropFirst("--journal-path=".count)) }
                let store = try QuotaRecoveryStore(fileURL: path.map { URL(fileURLWithPath: $0) } ?? QuotaRecoveryStore.defaultURL)
                for cycle in store.cycles where cycle.completedAt == nil {
                    for job in cycle.jobs where !job.resolved && job.sendingAt == nil {
                        do { _ = try await client.sendRecovery(job: job, validateOnly: true); print("thread=\(job.threadID ?? "unknown") submissionReady=true") }
                        catch { print("thread=\(job.threadID ?? "unknown") submissionReady=false reason=\(error.localizedDescription)") }
                    }
                }
                exit(0)
            } catch { print("readinessUnavailable=true"); exit(1) }
        }
        if CommandLine.arguments.contains("--recovery-pending-decisions") {
            do {
                let client = AppServerControlClient()
                for cycle in try QuotaRecoveryStore().cycles where cycle.completedAt == nil {
                    for job in cycle.jobs where !job.resolved {
                        guard let failure = job.failure else { continue }
                        let decision = try await client.recoveryDecision(failure)
                        print("thread=\(failure.threadID) resume=\(decision.shouldResume) reason=\(decision.reason) model=\(decision.updatedFailure?.model ?? failure.model ?? "unknown") effort=\(decision.updatedFailure?.effort ?? failure.effort ?? "unknown") latestTurn=\(decision.updatedFailure?.turnID ?? failure.turnID)")
                    }
                }
                exit(0)
            } catch { print("pendingDecisionUnavailable=true"); exit(1) }
        }
        if CommandLine.arguments.contains("--deepseek-keychain-api-models") {
            do {
                guard let key = try DeepSeekCredentialStore().loadNonInteractively() else { exit(2) }
                let models = try await DeepSeekClient().fetchAvailableModels(apiKey: key)
                print("deepseekKeychainAPIValid=\(Set(models).isSuperset(of: Set(DeepSeekModel.allCases.map(\.rawValue))))")
                exit(0)
            } catch { print("deepseekKeychainAPIValid=false"); exit(1) }
        }
        if CommandLine.arguments.contains("--credential-access-status") {
            let store = DeepSeekCredentialStore()
            let exists = store.hasKey()
            do { print("deepseekExists=\(exists) deepseekReadable=\(try store.loadNonInteractively() != nil)") }
            catch { print("deepseekExists=\(exists) deepseekReadable=false") }
            do { _ = try DingTalkWebhookStore().load(); print("dingtalkReadable=true") }
            catch { print("dingtalkReadable=false") }
            exit(0)
        }
        if CommandLine.arguments.contains("--quota-recovery-health") {
            do {
                let status = try QuotaRecoveryServiceStatus.read()
                let store = try QuotaRecoveryStore()
                let data = try JSONSerialization.data(withJSONObject: [
                    "phase": status.phase, "notice": status.notice,
                    "heartbeatAgeSeconds": max(0, Date().timeIntervalSince(status.heartbeatAt)),
                    "nextExecution": status.executeAt.map { ISO8601DateFormatter().string(from: $0) } ?? "none",
                    "lastTrigger": status.lastTriggeredAt.map { ISO8601DateFormatter().string(from: $0) } ?? "none",
                    "lastDelaySeconds": status.lastDelaySeconds ?? -1,
                    "cycleOutcomes": store.cycles.compactMap(\.outcome)
                ], options: [.prettyPrinted, .sortedKeys])
                print(String(data: data, encoding: .utf8)!)
                exit(Date().timeIntervalSince(status.heartbeatAt) > 90 ? 1 : 0)
            } catch { print("recoveryHealthUnavailable=true"); exit(1) }
        }
        if let threadArgument = CommandLine.arguments.first(where: { $0.hasPrefix("--recovery-receipt-thread=") }),
           let messageArgument = CommandLine.arguments.first(where: { $0.hasPrefix("--message-id=") }) {
            do {
                let receipt = try await AppServerControlClient().recoveryReceipt(
                    threadID: String(threadArgument.dropFirst("--recovery-receipt-thread=".count)),
                    messageID: String(messageArgument.dropFirst("--message-id=".count)))
                print("greetingReceipt=\(receipt != nil)")
                exit(receipt == nil ? 1 : 0)
            } catch { print("receiptError=\(error.localizedDescription)"); exit(1) }
        }
        if CommandLine.arguments.contains("--quota-recovery-preview") {
            do {
                let client = AppServerControlClient(timeout: 8)
                let key = try await client.recoveryAccountKey()
                let quota = try await client.readRateLimits()
                let failures = try await client.recoveryFailures(since: Date().addingTimeInterval(-18_000), quotaExhausted: quota.windows.contains { $0.usedPercent == 100 })
                let store = try QuotaRecoveryStore()
                print("planAccount=true windows=\(quota.windows.count) shortWindow=\(quota.windows.contains { $0.durationMinutes == 300 }) quotaFailures=\(failures.count) next=\(store.next(accountKey: key)?.executeAt.description ?? "none")")
                exit(0)
            } catch { print("recoveryPreviewError=\(error.localizedDescription)"); exit(1) }
        }
        if CommandLine.arguments.contains("--test-recovery-greeting") {
            do {
                let client = AppServerControlClient(timeout: 12)
                _ = try await client.recoveryAccountKey()
                let cwd = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CodexBar/QuotaRecovery")
                try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
                let id = try await client.createRecoveryThread(cwd: cwd.path)
                let job = QuotaRecoveryJob(threadID: id)
                let turnID = try await client.sendRecovery(job: job)
                let confirmed = try await client.recoveryReceipt(threadID: id, messageID: job.id) != nil
                print("threadID=\(id) turnID=\(turnID) greetingReceipt=\(confirmed)")
                exit(confirmed ? 0 : 1)
            } catch { print("greetingError=\(error.localizedDescription)"); exit(1) }
        }
        if CommandLine.arguments.contains("--sample-network-speed") {
            let monitor = NetworkSpeedMonitor()
            _ = monitor.sample()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let speed = monitor.sample()
            print("upload=\(NetworkSpeed.compact(speed.uploadBytesPerSecond)) download=\(NetworkSpeed.compact(speed.downloadBytesPerSecond))")
            exit(0)
        }
        if CommandLine.arguments.contains("--quota-shared-only") {
            do {
                let value = try await AppServerControlClient(timeout: 8).readRateLimits()
                print("shared_quota_windows=\(value.windows.count)")
                exit(value.windows.isEmpty ? 1 : 0)
            } catch {
                print("shared_quota_error=\(error.localizedDescription)")
                exit(1)
            }
        }
        if CommandLine.arguments.contains("--quota-cache-state") {
            do {
                let snapshot = try QuotaResetNoticeStore().lastSnapshot
                print("cached_windows=\(snapshot?.windows.count ?? 0) cached_at=\(snapshot?.observedAt.description ?? "none")")
                exit(0)
            } catch {
                print("quota_cache_error=\(error.localizedDescription)")
                exit(1)
            }
        }
        if CommandLine.arguments.contains("--test-dingtalk-reset-notification") {
            do {
                try await DingTalkResetNotifier().send(event: nil, keyword: "请注意")
                print("DingTalk reset test delivered (errcode=0)")
                exit(0)
            } catch {
                print("DingTalk reset test failed: \(error.localizedDescription)")
                exit(1)
            }
        }
        if let modelArgument = CommandLine.arguments.first(where: { $0.hasPrefix("--thread-launch-model=") }),
           let providerArgument = CommandLine.arguments.first(where: { $0.hasPrefix("--thread-launch-provider=") }) {
            let model = String(modelArgument.dropFirst("--thread-launch-model=".count))
            let provider = String(providerArgument.dropFirst("--thread-launch-provider=".count))
            do {
                let thread = try await CodexThreadLauncher().createThread(
                    model: model,
                    cwd: FileManager.default.currentDirectoryPath,
                    expectedProvider: provider
                )
                let data = try JSONSerialization.data(
                    withJSONObject: ["threadId": thread.id, "modelProvider": thread.modelProvider],
                    options: [.prettyPrinted, .sortedKeys]
                )
                print(String(data: data, encoding: .utf8)!)
                exit(0)
            } catch {
                print(#"{"threadLaunchError":"\#(error.localizedDescription)"}"#)
                exit(1)
            }
        }
        if CommandLine.arguments.contains("--deepseek-catalog-only") {
            do {
                let data = try await DeepSeekClient().fetchOfficialModelCatalog()
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let models = (object?["models"] as? [[String: Any]])?.compactMap { $0["slug"] as? String } ?? []
                print(String(data: try JSONSerialization.data(withJSONObject: ["deepSeekModels": models], options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
                exit(Set(models).isSuperset(of: Set(DeepSeekModel.allCases.map(\.rawValue))) ? 0 : 1)
            } catch {
                print(#"{"catalogError":"\#(error.localizedDescription)"}"#)
                exit(1)
            }
        }
        if CommandLine.arguments.contains("--deepseek-api-models-only") {
            guard let apiKey = ProcessInfo.processInfo.environment["CODEXBAR_DEEPSEEK_API_KEY"],
                  !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                print(#"{"apiModelsError":"诊断程序不读取 macOS 钥匙串；如需调用 DeepSeek API，请在当次进程环境中提供 CODEXBAR_DEEPSEEK_API_KEY"}"#)
                exit(2)
            }
            do {
                let models = try await DeepSeekClient().fetchAvailableModels(apiKey: apiKey).sorted()
                print(String(data: try JSONSerialization.data(withJSONObject: ["deepSeekAPImodels": models], options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
                exit(Set(models).isSuperset(of: Set(DeepSeekModel.allCases.map(\.rawValue))) ? 0 : 1)
            } catch {
                print(#"{"apiModelsError":"\#(error.localizedDescription)"}"#)
                exit(1)
            }
        }
        let tasksOnly = CommandLine.arguments.contains("--tasks-only")
        let quotaOnly = CommandLine.arguments.contains("--quota-only")
        let controlProbe = CommandLine.arguments.first { $0.hasPrefix("--control-probe=") }
        var output: [String: Any] = ["timestamp": ISO8601DateFormatter().string(from: Date())]
        do {
            let config = try await ProviderConfigVerifier().readEffectiveConfig()
            output["effectiveProvider"] = config["model_provider"] as? String ?? "openai"
            output["effectiveModel"] = config["model"] as? String ?? "unknown"
            output["codexBarProviderLease"] = ProviderConfigManager().status().mode.rawValue
        } catch {
            output["providerError"] = error.localizedDescription
        }
        if !tasksOnly { do {
            let rateLimitData = try await RateLimitClient().fetch()
            output["quota"] = rateLimitData.windows.map { [
                "label": $0.shortLabel,
                "usedPercent": $0.usedPercent,
                "remainingPercent": $0.remainingPercent,
                "durationMinutes": $0.durationMinutes as Any,
                "resetsAt": $0.resetsAt.map { ISO8601DateFormatter().string(from: $0) } as Any
            ] }
            output["resetCreditAvailableCount"] = rateLimitData.resetCreditAvailableCount
            output["resetCreditDetailsComplete"] = rateLimitData.resetCreditDetailsComplete
            output["resetCredits"] = rateLimitData.resetCredits.map { [
                "id": $0.id,
                "status": $0.status,
                "expiresAt": $0.expiresAt.map { ISO8601DateFormatter().string(from: $0) } as Any,
                "expiryLabel": $0.expiryLabel,
                "title": $0.title as Any
            ] }
        } catch { output["quotaError"] = error.localizedDescription } }
        if !quotaOnly { do {
            let tasks = try await TaskStore().fetchActiveTasks()
            output["activeTasks"] = tasks.map { [
                "id": $0.id,
                "title": $0.title,
                "cwd": $0.cwd,
                "isGoal": $0.isGoal,
                "isRunning": $0.isRunning,
                "tokensUsed": $0.tokensUsed,
                "turnTokensUsed": $0.turnTokensUsed,
                "activeTurnID": $0.activeTurnID as Any,
                "runStartedAt": $0.runStartedAt.map { ISO8601DateFormatter().string(from: $0) } as Any,
                "isControllable": $0.isControllable,
                "modelProvider": $0.modelProvider as Any,
                "model": $0.model as Any
            ] }
        } catch { output["taskError"] = error.localizedDescription } }
        if let controlProbe {
            let path = String(controlProbe.dropFirst("--control-probe=".count))
            do {
                try await AppServerControlClient(socketURL: URL(fileURLWithPath: path)).probe()
                output["controlProbe"] = "ok"
            } catch {
                output["controlError"] = error.localizedDescription
            }
        }
        let data = try! JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8)!)
        exit((output["quotaError"] == nil && output["taskError"] == nil && output["controlError"] == nil && output["providerError"] == nil) ? 0 : 1)
    }
}
