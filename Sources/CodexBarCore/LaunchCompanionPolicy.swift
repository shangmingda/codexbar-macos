public enum LaunchCompanionPolicy {
    public static func shouldLaunchCodexBar(codexIsRunning: Bool, codexBarIsRunning: Bool) -> Bool {
        codexIsRunning && !codexBarIsRunning
    }
}
