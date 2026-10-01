import Foundation

enum TranslatorRuntime { static var isDemoBuild: Bool { false } }

@main
enum QuotaConnectionTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LectureQuotaConnectionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        var passed = 0
        func check(_ condition: Bool, _ name: String) {
            guard condition else { fputs("FAIL: \(name)\n", stderr); exit(1) }
            passed += 1
        }
        let fixture = root.appendingPathComponent("server.rb")
        // A local JSON-lines fixture. It is not Codex and never uses a network.
        let source = #"""
        require 'json'
        Encoding.default_external = Encoding::UTF_8
        STDOUT.sync = true
        STDERR.sync = true
        mode, log = ARGV
        sleep 30 if mode == 'slow-start'
        File.open(log, 'a') { |f| f.puts "start #{Process.pid}" }
        starts = File.readlines(log).grep(/^start /).length
        if mode == 'noisy'
          STDERR.write("padding diagnostic\n" * 25_000)
          STDERR.puts 'FINAL-SERVICE-DIAGNOSTIC sk-fixture-secret'
          exit 37
        end
        if mode == 'exit' || (mode == 'reconnect' && starts == 1)
          STDERR.puts "env: fixture-node: No such file or directory sk-fixture-secret Bearer hidden-fixture-token"
          exit 37
        end
        send_json = lambda { |value| STDOUT.puts JSON.generate(value) }
        account_id = nil
        reads = 0
        STDIN.each_line do |line|
          request = JSON.parse(line)
          method = request['method']
          File.open(log, 'a') { |f| f.puts JSON.generate(request) }
          case method
          when 'initialize'
            if mode == 'hang'
              Signal.trap('TERM', 'IGNORE')
              File.open(log, 'a') { |f| f.puts 'ready hang' }
              sleep 30
            elsif mode == 'rpc-error'
              send_json.call({'id'=>request['id'], 'error'=>{'code'=>-32000, 'message'=>'Not logged in; run codex login'}})
            elsif mode == 'oversized'
              STDOUT.write('x' * 2_100_000)
              sleep 30
            elsif mode == 'malformed'
              STDOUT.puts 'not-json'
            elsif mode == 'malformed-error'
              send_json.call({'id'=>request['id'], 'error'=>'invalid-error', 'result'=>{}})
            elsif mode == 'malformed-result'
              send_json.call({'id'=>request['id'], 'result'=>[]})
            else
              send_json.call({'id'=>request['id'], 'result'=>{}})
            end
          when 'initialized'
          when 'account/read'
            raise 'refresh is forbidden' unless request.fetch('params').fetch('refreshToken') == false
            account_id = request['id']
          when 'account/rateLimits/read'
            reads += 1
            sleep 0.15 if mode == 'slow'
            if mode == 'fail-refresh' && reads > 1
              send_json.call({'id'=>request['id'], 'error'=>{'code'=>-32000, 'message'=>'temporary service failure'}})
              next
            end
            week = {'usedPercent'=>11 + reads, 'windowDurationMins'=>10080, 'resetsAt'=>2_100_000_000}
            primary = mode == 'plus' ? {'usedPercent'=>4, 'windowDurationMins'=>300, 'resetsAt'=>2_100_000_000} : week
            secondary = mode == 'plus' ? week : nil
            bucket = {'primary'=>primary, 'secondary'=>secondary}
            bucket['planType'] = 'plus' if mode == 'bucket-wins'
            result = {'rateLimitsByLimitId'=>{'codex'=>bucket}}
            result = {'rateLimitsByLimitId'=>{'other'=>bucket}} if mode == 'wrong-bucket'
            result = {'rateLimits'=>{'primary'=>{'usedPercent'=>'bad'}}} if mode == 'bad-value'
            # IDs from notifications/server requests/unknown errors cannot steal a response.
            send_json.call({'method'=>'account/updated', 'id'=>account_id, 'params'=>{'planType'=>'unknown'}})
            send_json.call({'id'=>999999, 'error'=>{'message'=>'unrelated response'}})
            send_json.call({'id'=>request['id'], 'result'=>result})
            plan = mode == 'plus' ? 'plus' : 'pro'
            plan = nil if mode == 'missing-plan'
            send_json.call({'id'=>account_id, 'result'=>{'account'=>{'type'=>'chatgpt', 'planType'=>plan, 'email'=>'demo@example.invalid', 'access_token'=>'do-not-retain'}}})
            exit 0 if mode == 'close-after-read'
          else
            raise "Forbidden method: #{method}"
          end
        end
        """#
        try Data(source.utf8).write(to: fixture)
        func make(_ mode: String = "normal", timeout: Double = 2) -> (CodexQuotaConnection, URL) {
            let log = root.appendingPathComponent("\(mode)-\(UUID().uuidString).log")
            return (CodexQuotaConnection(testExecutable: "/usr/bin/ruby", testArguments: [fixture.path, mode, log.path],
                    timeoutSeconds: timeout, testEnvironment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]), log)
        }
        func logLines(_ url: URL) -> [String] { ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
        func count(_ method: String, _ url: URL) -> Int { logLines(url).filter { $0.contains("\"method\":\"\(method)\"") }.count }
        func starts(_ url: URL) -> Int { logLines(url).filter { $0.hasPrefix("start ") }.count }
        func waitForRequest(_ log: URL, method: String = "account/rateLimits/read") async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while count(method, log) == 0 && ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            check(count(method, log) > 0, "fixture reached the requested protocol phase before cancellation/invalidation")
        }
        func waitForHang(_ log: URL) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while !logLines(log).contains("ready hang") && ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            check(logLines(log).contains("ready hang"), "fixture ignores SIGTERM before cancellation/shutdown")
        }
        func rejects(_ mode: String, timeout: Double = 2) async -> (String, Double, URL) {
            let (connection, log) = make(mode, timeout: timeout)
            defer { connection.shutdown() }
            let began = ProcessInfo.processInfo.systemUptime
            do { _ = try await connection.read(); check(false, "\(mode) must fail"); return ("", 0, log) }
            catch { return (error.localizedDescription, ProcessInfo.processInfo.systemUptime - began, log) }
        }

        let (connection, log) = make()
        let first = try await connection.read(), second = try await connection.read()
        check(starts(log) == 1 && count("initialize", log) == 1, "two reads reuse exactly one initialized process")
        check(count("account/read", log) == 2 && count("account/rateLimits/read", log) == 2, "account plan and quota read on each uncached snapshot")
        check(first.weekly?.remaining == 88 && second.weekly?.remaining == 87, "out-of-order responses are routed by request ID")
        check(first.weeklyOnly && first.fiveHours == nil && first.decision(reserve: 15) == .allowed, "Pro plan fallback permits documented weekly-only shape")
        let encoded = String(decoding: try JSONEncoder().encode(first), as: UTF8.self)
        check(!encoded.contains("private-fixture") && !encoded.contains("do-not-retain") && !encoded.contains("email"), "snapshot retains no account email or credentials")
        let methods = logLines(log).compactMap { ($0.data(using: .utf8)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }.compactMap { $0["method"] as? String }
        check(Set(methods) == ["initialize", "initialized", "account/read", "account/rateLimits/read"], "transport emits only its four allowed protocol methods")
        connection.shutdown()

        let (plus, _) = make("plus"); let plusQuota = try await plus.read(); plus.shutdown()
        check(plusQuota.fiveHours?.remaining == 96 && plusQuota.weekly?.remaining == 88 && plusQuota.decision(reserve: 15) == .allowed,
              "Plus keeps both independent windows")
        let (explicit, _) = make("bucket-wins"); let explicitQuota = try await explicit.read(); explicit.shutdown()
        check(explicitQuota.bucket.planType == "plus" && explicitQuota.decision(reserve: 15) == .unknown, "explicit bucket plan wins and incomplete Plus fails closed")
        let (missing, _) = make("missing-plan"); let missingQuota = try await missing.read(); missing.shutdown()
        check(missingQuota.decision(reserve: 15) == .unknown, "unknown weekly-only plan never invents a five-hour allowance")
        let wrong = await rejects("wrong-bucket")
        check(starts(wrong.2) == 1 && wrong.0.contains("основной лимит"), "unknown global bucket fails without reconnect")
        let malformedValue = await rejects("bad-value")
        check(starts(malformedValue.2) == 1, "malformed limit values are not retried or authorized")
        let malformed = await rejects("malformed")
        check(starts(malformed.2) == 1 && malformed.0.contains("JSON"), "malformed protocol is not retried")
        let malformedError = await rejects("malformed-error")
        check(starts(malformedError.2) == 1 && malformedError.0.contains("ошибку"), "malformed RPC error cannot be hidden by a simultaneous result")
        let malformedResult = await rejects("malformed-result")
        check(starts(malformedResult.2) == 1, "array-shaped initialization result fails closed")
        let service = await rejects("rpc-error")
        check(starts(service.2) == 1 && service.0.contains("Not logged in"), "authentication error is actionable and never auto-retried")
        let (reconnected, reconnectLog) = make("reconnect")
        let recovered = try await reconnected.read(); reconnected.shutdown()
        check(starts(reconnectLog) == 2 && recovered.weeklyOnly, "one transport reconnect repairs EOF before initialization")
        let (idleClosed, idleLog) = make("close-after-read")
        _ = try await idleClosed.read()
        try await Task.sleep(nanoseconds: 50_000_000)
        _ = try await idleClosed.read(); idleClosed.shutdown()
        check(starts(idleLog) == 2, "EOF between uncached reads reconnects without retaining an old plan/result")
        let early = await rejects("exit")
        check(starts(early.2) == 2 && early.1 < 1.5, "repeated early exit is bounded to two launches")
        check(early.0.contains("fixture-node") && !early.0.contains("Истекло время"), "early exit preserves stderr instead of false timeout")
        check(!early.0.contains("sk-fixture-secret") && !early.0.contains("hidden-fixture-token"), "stderr is credential-redacted")
        let noisy = await rejects("noisy", timeout: 4)
        check(noisy.0.contains("FINAL-SERVICE-DIAGNOSTIC") && noisy.0.count < 2000 && !noisy.0.contains("sk-fixture-secret"),
              "large stderr is drained into a bounded, redacted diagnostic tail")
        let oversized = await rejects("oversized")
        check(starts(oversized.2) == 1 && oversized.0.contains("большой"), "oversized frame is rejected with a bounded buffer: \(oversized.0)")
        // A short deadline may expire before the interpreter records startup.
        // Verify that valid outcome separately from a ready, SIGTERM-ignoring child.
        let coldTimeout = await rejects("slow-start", timeout: 0.15)
        check(coldTimeout.1 < 1.25 && coldTimeout.0.contains("Истекло время") && starts(coldTimeout.2) == 0,
              "short deadline is bounded before fixture startup: elapsed=\(coldTimeout.1), starts=\(starts(coldTimeout.2))")
        let timeout = await rejects("hang", timeout: 1)
        check(logLines(timeout.2).contains("ready hang"), "timeout case reaches the SIGTERM-ignoring fixture")
        check(timeout.1 < 2.1 && timeout.0.contains("Истекло время") && starts(timeout.2) == 1,
              "deadline plus cleanup remains bounded for a SIGTERM-ignoring process: elapsed=\(timeout.1), starts=\(starts(timeout.2))")
        let zeroTimeout = await rejects("normal", timeout: 0)
        let infiniteTimeout = await rejects("normal", timeout: .infinity)
        check(starts(zeroTimeout.2) == 0 && starts(infiniteTimeout.2) == 0, "invalid timeout does not launch a child")
        let (cancelConnection, cancelLog) = make("hang", timeout: 4)
        let cancelledTask = Task { try await cancelConnection.read() }
        try await waitForHang(cancelLog)
        let cancelStart = ProcessInfo.processInfo.systemUptime
        cancelledTask.cancel()
        do { _ = try await cancelledTask.value; check(false, "cancel must throw") }
        catch is CancellationError { check(true, "transport propagates task cancellation") }
        check(ProcessInfo.processInfo.systemUptime - cancelStart < 1 && starts(cancelLog) == 1, "cancelled service read never reconnects")
        cancelConnection.shutdown()

        let (cacheConnection, cacheLog) = make("slow")
        check(SharedQuotaService.cacheLifetime(60) == 10 && SharedQuotaService.cacheLifetime(10) == 10, "cache lifetime cannot exceed ten seconds")
        check(SharedQuotaService.cacheLifetime(-1) == 0 && SharedQuotaService.cacheLifetime(.infinity) == 0 && SharedQuotaService.cacheLifetime(.nan) == 0,
              "invalid cache lifetimes disable caching")
        let serviceCache = SharedQuotaService(connection: cacheConnection, ttl: 0.2)
        let simultaneous = try await withThrowingTaskGroup(of: QuotaSnapshot.self) { group in
            for _ in 0..<10 { group.addTask { try await serviceCache.read() } }
            var values: [QuotaSnapshot] = []; for try await value in group { values.append(value) }; return values
        }
        check(simultaneous.count == 10 && Set(simultaneous.map { $0.weekly!.remaining! }).count == 1, "ten simultaneous callers receive one coalesced result")
        check(count("account/rateLimits/read", cacheLog) == 1, "coalescing sends only one service request pair")
        _ = try await serviceCache.read()
        check(count("account/rateLimits/read", cacheLog) == 1, "fresh quota is cached")
        _ = try await serviceCache.read(force: true)
        check(count("account/rateLimits/read", cacheLog) == 2 && starts(cacheLog) == 1, "forced read skips cache while reusing connection")
        try await Task.sleep(nanoseconds: 250_000_000)
        _ = try await serviceCache.read()
        check(count("account/rateLimits/read", cacheLog) == 3, "TTL expiry obtains new limits")
        await serviceCache.invalidate()
        _ = try await serviceCache.read()
        check(count("account/rateLimits/read", cacheLog) == 4, "invalidation never serves the previous cached snapshot")
        await serviceCache.shutdown()
        _ = try await serviceCache.read()
        check(starts(cacheLog) == 2 && count("account/rateLimits/read", cacheLog) == 5, "Resume after shutdown creates a fresh connection and no stale cache")
        await serviceCache.shutdown()

        let (sharedCancelConnection, sharedCancelLog) = make("slow")
        let sharedCancel = SharedQuotaService(connection: sharedCancelConnection)
        let leave = Task { try await sharedCancel.read() }
        let stay = Task { try await sharedCancel.read(force: true) }
        try await Task.sleep(nanoseconds: 100_000_000); leave.cancel()
        do { _ = try await leave.value; check(false, "cancelled waiter must not get result") }
        catch is CancellationError { check(true, "individual coalesced waiter cancels promptly") }
        _ = try await stay.value
        check(count("account/rateLimits/read", sharedCancelLog) == 1, "cancelling one waiter does not cancel another or create duplicate I/O")
        await sharedCancel.shutdown()

        let (lastConnection, lastLog) = make("slow")
        let lastService = SharedQuotaService(connection: lastConnection)
        let onlyWaiter = Task { try await lastService.read() }
        try await waitForRequest(lastLog); onlyWaiter.cancel()
        do { _ = try await onlyWaiter.value; check(false, "last waiter must cancel") }
        catch is CancellationError { check(true, "last waiter cancellation propagates") }
        _ = try await lastService.read()
        check(starts(lastLog) == 2 && count("account/rateLimits/read", lastLog) == 2, "last waiter cancellation closes transport and a later read restarts it")
        await lastService.shutdown()

        let (invalidatedConnection, invalidatedLog) = make("slow")
        let invalidatedService = SharedQuotaService(connection: invalidatedConnection)
        let beforeInvalidation = Task { try await invalidatedService.read() }
        try await waitForRequest(invalidatedLog)
        await invalidatedService.invalidate()
        let afterInvalidation = Task { try await invalidatedService.read(force: true) }
        let prior = try await beforeInvalidation.value, fresh = try await afterInvalidation.value
        check(prior.checkedAt == fresh.checkedAt && count("account/rateLimits/read", invalidatedLog) == 2,
              "invalidation during I/O carries all waiters to one fresh read instead of authorizing with the old result")
        await invalidatedService.shutdown()

        let (failedRefreshConnection, failedRefreshLog) = make("fail-refresh")
        let failedRefreshService = SharedQuotaService(connection: failedRefreshConnection)
        _ = try await failedRefreshService.read()
        do { _ = try await failedRefreshService.read(force: true); check(false, "refresh must fail") }
        catch { check(error.localizedDescription.contains("temporary service failure"), "forced refresh propagates the service failure") }
        _ = try await failedRefreshService.read()
        check(starts(failedRefreshLog) == 2 && count("account/rateLimits/read", failedRefreshLog) == 3, "failed forced refresh cannot authorize from the previous cached value")
        await failedRefreshService.shutdown()

        let (shutdownConnection, shutdownLog) = make("hang", timeout: 4)
        let shutdownService = SharedQuotaService(connection: shutdownConnection)
        let waiter = Task { try await shutdownService.read() }
        try await waitForHang(shutdownLog)
        let shutdownStart = ProcessInfo.processInfo.systemUptime
        await shutdownService.shutdown()
        do { _ = try await waiter.value; check(false, "shutdown waiter must cancel") }
        catch is CancellationError { check(true, "shutdown cancels coalesced waiters") }
        check(ProcessInfo.processInfo.systemUptime - shutdownStart < 1 && starts(shutdownLog) == 1, "shutdown is prompt and does not reconnect")

        let now = Date()
        func snapshot(plan: String?, primary: LimitWindow?, secondary: LimitWindow?) -> QuotaSnapshot {
            QuotaSnapshot(checkedAt: now, bucket: LimitBucket(primary: primary, secondary: secondary, rateLimitReachedType: nil, planType: plan))
        }
        let week = LimitWindow(usedPercent: 10, windowDurationMins: 10080, resetsAt: now.timeIntervalSince1970 + 600)
        let five = LimitWindow(usedPercent: 20, windowDurationMins: 300, resetsAt: now.timeIntervalSince1970 + 300)
        check(snapshot(plan: "pro", primary: week, secondary: nil).decision(reserve: 15, now: now) == .allowed, "Pro weekly-only shape is also supported")
        check(snapshot(plan: "prolite", primary: week, secondary: nil).decision(reserve: 15, now: now) == .allowed, "explicit Pro-lite account ID weekly-only shape is supported")
        check(snapshot(plan: "plus", primary: week, secondary: nil).decision(reserve: 15, now: now) == .unknown, "missing Plus window is unknown, not zero usage")
        check(snapshot(plan: "other", primary: week, secondary: nil).decision(reserve: 15, now: now) == .unknown, "unknown plan with incomplete windows is fail-closed")
        check(snapshot(plan: "plus", primary: five, secondary: week).decision(reserve: 15, now: now) == .allowed, "known two-window shape is allowed")
        check(snapshot(plan: "pro", primary: LimitWindow(usedPercent: nil, windowDurationMins: 10080, resetsAt: nil), secondary: nil).decision(reserve: 15, now: now) == .unknown,
              "missing usage is never treated as zero")
        check(snapshot(plan: "pro", primary: LimitWindow(usedPercent: 85, windowDurationMins: 10080, resetsAt: now.timeIntervalSince1970 + 600), secondary: nil).decision(reserve: 15, now: now) != .allowed,
              "15 percent reserve applies to weekly-only Pro")
        check(snapshot(plan: "pro", primary: LimitWindow(usedPercent: 101, windowDurationMins: 10080, resetsAt: nil), secondary: nil).decision(reserve: 15, now: now) == .unknown,
              "out-of-range usage fails closed")
        check(snapshot(plan: "pro", primary: LimitWindow(usedPercent: 1, windowDurationMins: 60, resetsAt: nil), secondary: nil).decision(reserve: 15, now: now) == .unknown,
              "unknown window duration fails closed")
        let merged = try QuotaSnapshot.decodeResult(Data(#"{"rateLimits":{"primary":{"usedPercent":10,"windowDurationMins":10080},"secondary":null}}"#.utf8), now: now, accountPlan: "pro")
        check(merged.weeklyOnly, "compatible decoder accepts optional plan fallback")
        // Let any bounded, asynchronously cancelled fixture close before cleanup.
        try await Task.sleep(nanoseconds: 250_000_000)
        print("PASS: \(passed) reusable quota connection/cache checks. Local fixtures only; no service or model requests.")
    }
}
