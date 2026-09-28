import Foundation
import Darwin

struct LimitWindow: Codable, Equatable {
    let usedPercent: Double?
    let windowDurationMins: Int?
    let resetsAt: Double?
    var remaining: Double? {
        guard let usedPercent, usedPercent.isFinite, (0...100).contains(usedPercent) else { return nil }
        return 100 - usedPercent
    }
}

struct LimitBucket: Codable {
    let primary: LimitWindow?
    let secondary: LimitWindow?
    let rateLimitReachedType: String?
    var planType: String? = nil
}

struct QuotaSnapshot: Codable {
    let checkedAt: Date
    let bucket: LimitBucket
    var fiveHours: LimitWindow? { [bucket.primary, bucket.secondary].compactMap { $0 }.first { $0.windowDurationMins == 300 } }
    var weekly: LimitWindow? { [bucket.primary, bucket.secondary].compactMap { $0 }.first { $0.windowDurationMins == 10080 } }
    /// Codex may report ChatGPT Pro as either `pro` or `prolite` in structured
    /// account data. Both are explicit plan identifiers; no missing window is
    /// used to infer this status.
    var isConfirmedPro: Bool { ["pro", "prolite"].contains(bucket.planType?.lowercased() ?? "") }
    // Pro can expose a weekly-only shape. Do not infer it for Plus/unknown plans.
    var weeklyOnly: Bool {
        isConfirmedPro &&
        bucket.primary?.windowDurationMins == 10080 && bucket.secondary == nil
    }

    enum Decision: Equatable {
        case allowed
        case unknown
        case waiting(Date?)
    }

    func decision(reserve: Double, now: Date = Date()) -> Decision {
        guard reserve.isFinite, (0...99).contains(reserve),
              now.timeIntervalSince(checkedAt) >= -10, now.timeIntervalSince(checkedAt) <= 120,
              weekly != nil, fiveHours != nil || weeklyOnly else { return .unknown }
        let windows = [bucket.primary, bucket.secondary].compactMap { $0 }
        guard windows.allSatisfy({ $0.remaining != nil && [300, 10080].contains($0.windowDurationMins ?? 0) }) else { return .unknown }
        let blocked = windows.filter { $0.remaining! <= reserve }
        if blocked.isEmpty { return bucket.rateLimitReachedType == nil ? .allowed : .unknown }
        let resetTimes = blocked.compactMap { $0.resetsAt }.filter { $0.isFinite && $0 > now.timeIntervalSince1970 }
        guard resetTimes.count == blocked.count else { return .waiting(nil) }
        return .waiting(Date(timeIntervalSince1970: resetTimes.max()! + 60))
    }

    static func decodeResult(_ data: Data, now: Date = Date(), accountPlan: String? = nil) throws -> QuotaSnapshot {
        struct Result: Decodable { let rateLimits: LimitBucket?; let rateLimitsByLimitId: [String: LimitBucket]? }
        let response = try JSONDecoder().decode(Result.self, from: data)
        // Do not use a random model-specific bucket as the global Codex quota.
        let bucket: LimitBucket?
        if let map = response.rateLimitsByLimitId, !map.isEmpty { bucket = map["codex"] }
        else { bucket = response.rateLimits }
        guard var bucket else { throw TranslatorError.invalid("Codex не предоставил основной лимит. Запуск перевода запрещён.") }
        // Some app-server versions omit the plan on a bucket. Only supplement an
        // absent value; an explicit, unknown bucket plan must remain fail-closed.
        if bucket.planType == nil { bucket.planType = accountPlan }
        return QuotaSnapshot(checkedAt: now, bucket: bucket)
    }
}

enum QuotaRecovery {
    /// Known resets are read once after the latest blocking window has reset,
    /// with the one-minute safety margin applied by `decision`.
    static func delay(snapshot: QuotaSnapshot?, reserve: Double, now: Date, failureCount: Int) -> TimeInterval {
        if let snapshot, case .waiting(let reset) = snapshot.decision(reserve: reserve, now: now),
           let reset, reset > now {
            return reset.timeIntervalSince(now)
        }
        let minutes = [15, 30, 60][min(max(failureCount - 1, 0), 2)]
        return TimeInterval(minutes * 60)
    }
}

enum CodexQuotaProbe {
    static func executable(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let paths = ["/usr/local/bin/codex", "/opt/homebrew/bin/codex", "/Applications/Codex.app/Contents/Resources/codex"] +
            (environment["PATH"] ?? "").split(separator: ":").filter { $0.hasPrefix("/") }.map { "\($0)/codex" }
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // Finder/Dock launches do not load the user's shell profile. In an npm install,
    // codex is a #!/usr/bin/env node wrapper, so finding codex alone is insufficient.
    // Add its bin directory and ordinary package-manager locations without executing
    // a login shell or changing the system PATH. Translation uses this same helper.
    static func launchEnvironment(executable: String, inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = inherited
        var paths = [URL(fileURLWithPath: executable).deletingLastPathComponent().path]
        paths += (inherited["PATH"] ?? "").split(separator: ":").map(String.init)
        paths += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        environment["PATH"] = paths.filter { $0.hasPrefix("/") && seen.insert($0).inserted }.joined(separator: ":")
        // The app uses the existing ChatGPT login, never an inherited paid API key.
        environment.removeValue(forKey: "CODEX_API_KEY")
        environment.removeValue(forKey: "OPENAI_API_KEY")
        return environment
    }

    // Keep actionable CLI diagnostics, but do not display credential-shaped values.
    static func diagnostic(_ raw: String) -> String {
        var value = raw.replacingOccurrences(of: #"\x1b\[[0-?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
        for pattern in [#"(?i)\bBearer\s+[^\s\"']+"#, #"\bsk-[A-Za-z0-9_-]+"#,
                        #"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#,
                        #"(?i)(?:access_token|refresh_token|api_key|OPENAI_API_KEY|CODEX_API_KEY)[\"']?\s*[:=]\s*[\"']?[^\s\"',;}]+"#] {
            value = value.replacingOccurrences(of: pattern, with: "[скрыто]", options: .regularExpression)
        }
        value = String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" })
        return String(value.trimmingCharacters(in: .whitespacesAndNewlines).suffix(1800))
    }

    static func read(testExecutable: String? = nil, testArguments: [String]? = nil, timeoutSeconds: Double = 25,
                     isCancelled: () -> Bool = { false }, testEnvironment: [String: String]? = nil) throws -> QuotaSnapshot {
        guard !TranslatorRuntime.isDemoBuild else { throw TranslatorError.invalid("Демо не читает состояние аккаунта.") }
        guard timeoutSeconds.isFinite, timeoutSeconds > 0 else { throw TranslatorError.invalid("Некорректное время проверки лимита.") }
        if isCancelled() { throw CancellationError() }
        guard let path = testExecutable ?? executable() else { throw TranslatorError.invalid("Codex CLI не найден. Перевод не запускался.") }
        let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = testArguments ?? ["app-server", "--listen", "stdio://"]
        process.environment = launchEnvironment(executable: path, inherited: testEnvironment ?? ProcessInfo.processInfo.environment)
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        // A dying child must cause a recoverable write error, not terminate the GUI with SIGPIPE.
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw TranslatorError.invalid("Не удалось настроить безопасное соединение с Codex.")
        }
        let readFD = output.fileHandleForReading.fileDescriptor, writeFD = input.fileHandleForWriting.fileDescriptor
        let errorFD = errors.fileHandleForReading.fileDescriptor
        // A blocking pipe read can survive SIGTERM when a child hangs or a descendant
        // inherits stdout. Bound I/O itself, not only the lifetime of the direct child.
        for fd in [readFD, writeFD, errorFD] {
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                throw TranslatorError.invalid("Не удалось настроить соединение с ограничением времени.")
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeoutSeconds
        do { try process.run() }
        catch { throw TranslatorError.invalid("Не удалось запустить Codex CLI: \(diagnostic(error.localizedDescription)). Перевод не запускался.") }
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
                let grace = ProcessInfo.processInfo.systemUptime + 0.15
                while process.isRunning && ProcessInfo.processInfo.systemUptime < grace { Thread.sleep(forTimeInterval: 0.01) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            try? output.fileHandleForReading.close()
            try? errors.fileHandleForReading.close()
        }
        var errorTail = Data()
        func drainErrors() {
            var bytes = [UInt8](repeating: 0, count: 4096)
            // A noisy descendant must not defeat cancellation or the deadline.
            for _ in 0..<16 {
                let count = bytes.withUnsafeMutableBytes { Darwin.read(errorFD, $0.baseAddress, $0.count) }
                if count <= 0 { return }
                errorTail.append(contentsOf: bytes.prefix(count))
                if errorTail.count > 65_536 { errorTail.removeFirst(errorTail.count - 65_536) }
            }
        }
        func failure(_ message: String) -> TranslatorError {
            drainErrors()
            let detail = diagnostic(String(decoding: errorTail, as: UTF8.self))
            let exit = process.isRunning ? "" : " Код завершения: \(process.terminationStatus)."
            return TranslatorError.invalid(message + exit + (detail.isEmpty ? "" : "\n\nCodex CLI: \(detail)"))
        }
        func ready(_ fd: Int32, for events: Int16) throws {
            while true {
                if isCancelled() { throw CancellationError() }
                drainErrors()
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { throw failure("Истекло время проверки лимита. Перевод не запускался.") }
                var descriptor = pollfd(fd: fd, events: events, revents: 0)
                let result = Darwin.poll(&descriptor, 1, Int32(min(100, ceil(remaining * 1000))))
                if result < 0 {
                    if errno == EINTR { continue }
                    throw failure("Прервано служебное соединение с Codex.")
                }
                if result > 0 { return } // read/write below also handles EOF, HUP and errors.
                if !process.isRunning { throw failure("Codex CLI завершился до получения лимитов. Перевод не запускался.") }
            }
        }
        func send(_ object: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(10)
            var offset = 0
            while offset < data.count {
                try ready(writeFD, for: Int16(POLLOUT))
                let count = data.withUnsafeBytes { Darwin.write(writeFD, $0.baseAddress!.advanced(by: offset), data.count - offset) }
                if count < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    throw failure("Не удалось отправить служебный запрос Codex. Перевод не запускался.")
                }
                guard count > 0 else { throw failure("Codex закрыл служебное соединение.") }
                offset += count
            }
        }
        try send(["method": "initialize", "id": 1, "params": ["clientInfo": ["name": "lecture_translator_preview", "title": "Перевод лекций", "version": "0.1.0"]]])
        var buffer = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            try ready(readFD, for: Int16(POLLIN))
            let count = bytes.withUnsafeMutableBytes { Darwin.read(readFD, $0.baseAddress, $0.count) }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw failure("Прервано служебное соединение с Codex. Перевод не запускался.")
            }
            buffer.append(contentsOf: bytes.prefix(count))
            guard buffer.count < 2_000_000 else { throw TranslatorError.invalid("Неожиданно большой служебный ответ Codex.") }
            while let cut = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<cut]); buffer.removeSubrange(...cut)
                guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let id = message["id"] as? Int else { continue }
                if let error = message["error"] as? [String: Any] {
                    let detail = diagnostic(error["message"] as? String ?? "Неизвестная служебная ошибка.")
                    throw failure("Codex не смог прочитать лимиты: \(detail) Перевод не запускался.")
                }
                if id == 1 {
                    try send(["method": "initialized"])
                    try send(["method": "account/rateLimits/read", "id": 2])
                } else if id == 2, let result = message["result"] {
                    return try QuotaSnapshot.decodeResult(JSONSerialization.data(withJSONObject: result))
                }
            }
        }
        throw failure("Codex CLI закрыл соединение до получения лимитов. Перевод не запускался.")
    }

    #if TRANSLATOR_DEMO
    static func demoSnapshot(now: Date = Date()) -> QuotaSnapshot {
        let future = now.addingTimeInterval(3_600).timeIntervalSince1970
        return QuotaSnapshot(checkedAt: now, bucket: LimitBucket(
            primary: LimitWindow(usedPercent: 35, windowDurationMins: 300, resetsAt: future),
            secondary: LimitWindow(usedPercent: 22, windowDurationMins: 10080, resetsAt: future),
            rateLimitReachedType: nil, planType: "demo"))
    }
    #endif
}
