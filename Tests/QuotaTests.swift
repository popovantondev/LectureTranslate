import Foundation

enum TranslatorRuntime { static var isDemoBuild: Bool { false } }

@main
enum QuotaTests {
    static func main() throws {
        if CommandLine.arguments.contains("--live") {
            // Read-only account metadata, never a translation or model request.
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
            let started = ProcessInfo.processInfo.systemUptime
            let snapshot = try CodexQuotaProbe.read(testEnvironment: environment)
            print("PASS: actual Codex quota from GUI-style PATH in \(String(format: "%.2f", ProcessInfo.processInfo.systemUptime - started)) s")
            let fiveHours = snapshot.fiveHours?.remaining.map { String($0) } ?? "not provided"
            let weekly = snapshot.weekly?.remaining.map { String($0) } ?? "not provided"
            print("5-hour remaining: \(fiveHours); weekly remaining: \(weekly)")
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LectureQuotaTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        var passed = 0
        func check(_ condition: Bool, _ name: String) {
            guard condition else { fputs("FAIL: \(name)\n", stderr); exit(1) }
            passed += 1
        }
        let guiEnvironment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let launch = CodexQuotaProbe.launchEnvironment(executable: root.appendingPathComponent("codex").path,
            inherited: ["PATH": ":.:relative:/bin:/bin:/usr/bin", "OPENAI_API_KEY": "fake-key", "CODEX_API_KEY": "fake-key", "LANG": "ru_RU.UTF-8"])
        let paths = launch["PATH"]!.split(separator: ":").map(String.init)
        check(paths.first == root.path, "CLI bin directory supplies its interpreter")
        check(paths.contains("/usr/local/bin") && paths.contains("/opt/homebrew/bin"), "Finder launch gains normal package-manager directories")
        check(Set(paths).count == paths.count && paths.allSatisfy { $0.hasPrefix("/") }, "PATH has no duplicate or implicit working-directory entries")
        check(launch["OPENAI_API_KEY"] == nil && launch["CODEX_API_KEY"] == nil, "paid API keys are not inherited")
        check(launch["LANG"] == "ru_RU.UTF-8", "unrelated environment preserved")

        let recoveryNow = Date(timeIntervalSince1970: 2_000_000_000)
        let blocked = QuotaSnapshot(checkedAt: recoveryNow, bucket: LimitBucket(
            primary: LimitWindow(usedPercent: 90, windowDurationMins: 300, resetsAt: recoveryNow.addingTimeInterval(900).timeIntervalSince1970),
            secondary: LimitWindow(usedPercent: 90, windowDurationMins: 10080, resetsAt: recoveryNow.addingTimeInterval(1800).timeIntervalSince1970),
            rateLimitReachedType: nil, planType: "plus"))
        check(QuotaRecovery.delay(snapshot: blocked, reserve: 15, now: recoveryNow, failureCount: 1) == 1860,
            "recovery waits once until the latest blocking reset plus safety margin")
        check(QuotaRecovery.delay(snapshot: nil, reserve: 15, now: recoveryNow, failureCount: 1) == 900,
            "first transient recovery backoff is fifteen minutes")
        check(QuotaRecovery.delay(snapshot: nil, reserve: 15, now: recoveryNow, failureCount: 2) == 1800,
            "second transient recovery backoff is thirty minutes")
        check(QuotaRecovery.delay(snapshot: nil, reserve: 15, now: recoveryNow, failureCount: 99) == 3600,
            "transient recovery backoff is capped at sixty minutes")

        let rpc = #"""
        #!/bin/sh
        while IFS= read -r request; do
          case "$request" in
            *'"method":"initialize"'*) printf '%s\n' '{"id":1,"result":{}}' ;;
            *'rateLimits'*) printf '%s\n' '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":4,"windowDurationMins":300,"resetsAt":2100000000},"secondary":{"usedPercent":12,"windowDurationMins":10080,"resetsAt":2100001000}}}}'; exit 0 ;;
          esac
        done
        """#
        let runtime = root.appendingPathComponent("quota-fixture-node")
        let wrapper = root.appendingPathComponent("codex")
        try Data((rpc + "\n").utf8).write(to: runtime)
        try Data("#!/usr/bin/env quota-fixture-node\n".utf8).write(to: wrapper)
        for url in [runtime, wrapper] { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) }
        let result = try CodexQuotaProbe.read(testExecutable: wrapper.path, testArguments: [], timeoutSeconds: 2, testEnvironment: guiEnvironment)
        check(result.fiveHours?.remaining == 96 && result.weekly?.remaining == 88, "npm-style env interpreter works with GUI-style PATH")

        func rejection(_ server: String, timeout: Double = 2) -> (String, Double) {
            let started = ProcessInfo.processInfo.systemUptime
            do {
                _ = try CodexQuotaProbe.read(testExecutable: "/bin/sh", testArguments: ["-c", server], timeoutSeconds: timeout, testEnvironment: guiEnvironment)
                check(false, "invalid server must not authorize translation")
                return ("", 0)
            } catch { return (error.localizedDescription, ProcessInfo.processInfo.systemUptime - started) }
        }
        let early = rejection("printf '%s\\n' 'env: node: No such file or directory' >&2; exit 37")
        check(early.1 < 1, "early CLI exit is reported promptly")
        check(early.0.contains("env: node: No such file or directory"), "stderr is not discarded")
        check(!early.0.contains("время") && !early.0.contains("времени"), "early CLI exit is not mislabeled timeout")
        let successWithoutReply = rejection("exit 0")
        check(!successWithoutReply.0.contains("время") && !successWithoutReply.0.contains("времени"), "clean exit without RPC result is not a successful quota or timeout")

        let serviceError = rejection(#"IFS= read -r request; printf '%s\n' '{"id":1,"error":{"code":-32000,"message":"Not logged in; run codex login"}}'; exit 1"#)
        check(serviceError.0.contains("Not logged in; run codex login"), "RPC error preserves useful service message")
        let noisy = rejection("i=0; while [ $i -lt 12000 ]; do printf '%s\\n' 'diagnostic-padding-line' >&2; i=$((i+1)); done; printf '%s\\n' 'FINAL-DIAGNOSTIC' >&2; exit 1", timeout: 4)
        check(noisy.0.contains("FINAL-DIAGNOSTIC") && noisy.0.count < 2200, "large stderr is drained and shown as a bounded tail")

        let redacted = CodexQuotaProbe.diagnostic("\u{1B}[31mproblem\u{1B}[0m Bearer synthetic-value sk-fake-key access_token=private-value eyJabc.def.signature")
        check(redacted.contains("problem") && !redacted.contains("\u{1B}"), "terminal formatting removed from GUI diagnostic")
        check(!redacted.contains("synthetic-value") && !redacted.contains("fake-key") && !redacted.contains("private-value") && !redacted.contains("eyJabc"), "credential-shaped diagnostics are redacted")

        let hanging = rejection("trap '' TERM; while :; do :; done", timeout: 0.15)
        check(hanging.1 < 1.25 && hanging.0.contains("Истекло время"), "nonresponsive server retains a bounded timeout")
        let cancelAt = ProcessInfo.processInfo.systemUptime + 0.1
        do {
            _ = try CodexQuotaProbe.read(testExecutable: "/bin/sh", testArguments: ["-c", "trap '' TERM; while :; do :; done"], timeoutSeconds: 4,
                isCancelled: { ProcessInfo.processInfo.systemUptime >= cancelAt }, testEnvironment: guiEnvironment)
            check(false, "cancelled probe must stop")
        } catch is CancellationError { check(true, "cancellation is preserved") }
        check(ProcessInfo.processInfo.systemUptime - cancelAt < 1, "cancel does not wait for network timeout")
        print("PASS: \(passed) quota launch/diagnostic checks. No service or model requests.")
    }
}
