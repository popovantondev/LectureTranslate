import Foundation
import Darwin

private final class QuotaReadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
}

private enum QuotaConnectionFailure: LocalizedError {
    case transport(String), service(String), malformed(String)
    var errorDescription: String? {
        switch self { case .transport(let text), .service(let text), .malformed(let text): return text }
    }
}

/// Dedicated read-only transport. No public method can start a model turn, login,
/// refresh credentials or consume a reset. All pipe access is on one serial queue.
final class CodexQuotaConnection: @unchecked Sendable {
    private let worker = DispatchQueue(label: "LectureTranslator.quota-connection", qos: .utility)
    private let lock = NSLock()
    private var readers: [UUID: QuotaReadCancellation] = [:]
    private var session: QuotaPipeSession? // worker queue only
    private var nextID = 0                 // never reused, including after reconnect
    private let testExecutable: String?
    private let testArguments: [String]?
    private let testEnvironment: [String: String]?
    private let timeoutSeconds: Double

    init(testExecutable: String? = nil, testArguments: [String]? = nil,
         timeoutSeconds: Double = 25, testEnvironment: [String: String]? = nil) {
        self.testExecutable = testExecutable; self.testArguments = testArguments
        self.timeoutSeconds = timeoutSeconds; self.testEnvironment = testEnvironment
    }

    func read() async throws -> QuotaSnapshot {
        let token = QuotaReadCancellation(), key = UUID()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                readers[key] = token; lock.unlock()
                worker.async {
                    let result = Result { try self.readOnWorker(cancellation: token) }
                    self.lock.lock(); self.readers.removeValue(forKey: key); self.lock.unlock()
                    continuation.resume(with: result)
                }
            }
        }, onCancel: { token.cancel() })
    }

    /// Cancel current I/O and close the process; the next read may reconnect.
    /// Cancellation is observed within one 50 ms poll, followed by bounded SIGTERM.
    func shutdown() { enqueueShutdown {} }

    fileprivate func shutdownAndWait() async {
        await withCheckedContinuation { continuation in enqueueShutdown { continuation.resume() } }
    }

    private func enqueueShutdown(_ completion: @escaping () -> Void) {
        lock.lock(); let pending = Array(readers.values)
        pending.forEach { $0.cancel() }
        worker.async { self.session?.close(); self.session = nil; completion() }
        lock.unlock()
    }

    deinit { session?.close() }

    private func id() -> Int { nextID += 1; return nextID }

    private func readOnWorker(cancellation: QuotaReadCancellation) throws -> QuotaSnapshot {
        guard timeoutSeconds.isFinite, timeoutSeconds > 0 else {
            throw TranslatorError.invalid("Некорректное время проверки лимита.")
        }
        try cancellation.check()
        let deadline = ProcessInfo.processInfo.systemUptime + timeoutSeconds
        // A fresh process may repair a broken pipe, never a service/auth/schema
        // error. Both attempts share one deadline: reconnect cannot double it.
        for attempt in 0..<2 {
            do {
                try cancellation.check()
                session?.beginRead()
                if session == nil {
                    guard let path = testExecutable ?? CodexQuotaProbe.executable() else {
                        throw TranslatorError.invalid("Codex CLI не найден. Перевод не запускался.")
                    }
                    let created = try QuotaPipeSession(path: path, arguments: testArguments ?? ["app-server", "--listen", "stdio://"],
                                                      environment: testEnvironment ?? ProcessInfo.processInfo.environment)
                    session = created
                    let initializeID = id()
                    try created.send(["method": "initialize", "id": initializeID, "params": ["clientInfo": [
                        "name": "lecture_translator_quota", "title": "Перевод лекций", "version": "2.7.1"]]],
                        deadline: deadline, cancellation: cancellation)
                    try created.collect(ids: [initializeID], deadline: deadline, cancellation: cancellation) { _, _ in }
                    try created.send(["method": "initialized"], deadline: deadline, cancellation: cancellation)
                }
                let active = session!, accountID = id(), limitsID = id()
                try active.send(["method": "account/read", "id": accountID, "params": ["refreshToken": false]],
                                deadline: deadline, cancellation: cancellation)
                try active.send(["method": "account/rateLimits/read", "id": limitsID], deadline: deadline, cancellation: cancellation)
                var plan: String?, snapshot: QuotaSnapshot?
                try active.collect(ids: [accountID, limitsID], deadline: deadline, cancellation: cancellation) { responseID, result in
                    if responseID == accountID {
                        // Decode and retain only the plan, never email or credentials.
                        struct Account: Decodable { let planType: String? }
                        struct Response: Decodable { let account: Account? }
                        plan = try JSONDecoder().decode(Response.self, from: result).account?.planType
                        if let value = plan, value.count > 64 { throw QuotaConnectionFailure.malformed("Codex вернул некорректный план аккаунта.") }
                    } else { snapshot = try QuotaSnapshot.decodeResult(result) }
                }
                try cancellation.check()
                guard let snapshot else { throw QuotaConnectionFailure.malformed("Codex не предоставил лимит.") }
                var bucket = snapshot.bucket
                if bucket.planType == nil { bucket.planType = plan }
                return QuotaSnapshot(checkedAt: Date(), bucket: bucket)
            } catch {
                session?.close(); session = nil
                if error is CancellationError { throw error }
                if case QuotaConnectionFailure.transport = error, attempt == 0,
                   ProcessInfo.processInfo.systemUptime < deadline { continue }
                throw TranslatorError.invalid(CodexQuotaProbe.diagnostic(error.localizedDescription))
            }
        }
        throw TranslatorError.invalid("Служебное соединение Codex недоступно.")
    }
}

private final class QuotaPipeSession {
    private let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
    private var buffer = Data(), errorTail = Data()
    private var receivedBytes = 0
    private var closed = false
    private var readFD: Int32 { output.fileHandleForReading.fileDescriptor }
    private var writeFD: Int32 { input.fileHandleForWriting.fileDescriptor }
    private var errorFD: Int32 { errors.fileHandleForReading.fileDescriptor }

    init(path: String, arguments: [String], environment: [String: String]) throws {
        process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
        process.environment = CodexQuotaProbe.launchEnvironment(executable: path, inherited: environment)
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        guard fcntl(writeFD, F_SETNOSIGPIPE, 1) != -1 else {
            throw QuotaConnectionFailure.malformed("Не удалось настроить безопасное соединение с Codex.")
        }
        for fd in [readFD, writeFD, errorFD] {
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                throw QuotaConnectionFailure.malformed("Не удалось ограничить время соединения с Codex.")
            }
        }
        do { try process.run() }
        catch { throw QuotaConnectionFailure.service("Не удалось запустить Codex CLI: \(CodexQuotaProbe.diagnostic(error.localizedDescription))") }
    }

    func beginRead() { receivedBytes = 0; errorTail.removeAll(keepingCapacity: true) }

    func close() {
        guard !closed else { return }; closed = true
        try? input.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            let grace = ProcessInfo.processInfo.systemUptime + 0.15
            while process.isRunning && ProcessInfo.processInfo.systemUptime < grace { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        try? output.fileHandleForReading.close(); try? errors.fileHandleForReading.close()
        buffer.removeAll(); errorTail.removeAll()
    }

    deinit { close() }

    private func drainErrors() {
        var bytes = [UInt8](repeating: 0, count: 4096)
        for _ in 0..<16 {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(errorFD, $0.baseAddress, $0.count) }
            if count <= 0 { return }
            errorTail.append(contentsOf: bytes.prefix(count))
            if errorTail.count > 65_536 { errorTail.removeFirst(errorTail.count - 65_536) }
        }
    }

    private func detail(_ message: String) -> String {
        drainErrors()
        let stderr = CodexQuotaProbe.diagnostic(String(decoding: errorTail, as: UTF8.self))
        let exit = process.isRunning ? "" : " Код завершения: \(process.terminationStatus)."
        return message + exit + (stderr.isEmpty ? "" : "\nCodex CLI: \(stderr)")
    }

    private func ready(_ fd: Int32, events: Int16, deadline: Double, cancellation: QuotaReadCancellation) throws {
        while true {
            try cancellation.check(); drainErrors()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw QuotaConnectionFailure.service(detail("Истекло время проверки лимита. Перевод не запускался.")) }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = Darwin.poll(&descriptor, 1, Int32(min(50, ceil(remaining * 1000))))
            if result < 0 {
                if errno == EINTR { continue }
                throw QuotaConnectionFailure.transport(detail("Прервано служебное соединение с Codex."))
            }
            if result > 0 { return }
            if !process.isRunning { throw QuotaConnectionFailure.transport(detail("Codex CLI завершился до получения лимитов.")) }
        }
    }

    func send(_ object: [String: Any], deadline: Double, cancellation: QuotaReadCancellation) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]); data.append(10)
        var offset = 0
        while offset < data.count {
            try ready(writeFD, events: Int16(POLLOUT), deadline: deadline, cancellation: cancellation)
            let count = data.withUnsafeBytes { Darwin.write(writeFD, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw QuotaConnectionFailure.transport(detail("Не удалось отправить служебный запрос Codex."))
            }
            guard count > 0 else { throw QuotaConnectionFailure.transport(detail("Codex закрыл служебное соединение.")) }
            offset += count
        }
    }

    func collect(ids: Set<Int>, deadline: Double, cancellation: QuotaReadCancellation,
                 consume: (Int, Data) throws -> Void) throws {
        var pending = ids, bytes = [UInt8](repeating: 0, count: 4096)
        while !pending.isEmpty {
            try cancellation.check()
            // Do not repeatedly walk a large unterminated frame with the generic
            // Data collection iterator: a noisy server must remain time-bounded.
            while let offset = buffer.withUnsafeBytes({ raw -> Int? in
                guard let base = raw.baseAddress, let newline = memchr(base, 10, raw.count) else { return nil }
                return base.distance(to: UnsafeRawPointer(newline))
            }) {
                try cancellation.check()
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw QuotaConnectionFailure.service(detail("Истекло время проверки лимита. Перевод не запускался."))
                }
                let cut = buffer.index(buffer.startIndex, offsetBy: offset)
                let line = Data(buffer[..<cut]); buffer.removeSubrange(...cut)
                guard !line.isEmpty else { continue }
                guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw QuotaConnectionFailure.malformed("Codex вернул некорректный служебный JSON. Перевод не запускался.")
                }
                // Notifications and server requests are not replies, even when
                // their IDs happen to overlap. Never execute a server request.
                guard message["method"] == nil, let number = message["id"] as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue == Double(number.intValue), pending.contains(number.intValue) else { continue }
                let responseID = number.intValue
                if let rawError = message["error"] {
                    guard let error = rawError as? [String: Any] else {
                        throw QuotaConnectionFailure.malformed("Codex вернул некорректную служебную ошибку.")
                    }
                    throw QuotaConnectionFailure.service(detail("Codex не смог прочитать лимиты: \(CodexQuotaProbe.diagnostic(error["message"] as? String ?? "Служебная ошибка."))"))
                }
                guard let result = message["result"] as? [String: Any] else {
                    throw QuotaConnectionFailure.malformed("Codex вернул ответ без служебного результата.")
                }
                try consume(responseID, JSONSerialization.data(withJSONObject: result))
                pending.remove(responseID)
                if pending.isEmpty { return }
            }
            try ready(readFD, events: Int16(POLLIN), deadline: deadline, cancellation: cancellation)
            let count = bytes.withUnsafeMutableBytes { Darwin.read(readFD, $0.baseAddress, $0.count) }
            if count == 0 { throw QuotaConnectionFailure.transport(detail("Codex CLI закрыл соединение до получения лимитов.")) }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw QuotaConnectionFailure.transport(detail("Прервано служебное соединение с Codex."))
            }
            buffer.append(contentsOf: bytes.prefix(count)); receivedBytes += count
            guard buffer.count < 2_000_000, receivedBytes < 4_000_000 else {
                throw QuotaConnectionFailure.malformed("Неожиданно большой служебный ответ Codex.")
            }
        }
    }
}

/// One cache and one coalesced read for all translation workers. A cancelled
/// waiter cannot cancel other callers. Last-waiter cancellation stops the I/O.
actor SharedQuotaService {
    private let connection: CodexQuotaConnection
    private let ttl: TimeInterval
    private var cache: (snapshot: QuotaSnapshot, uptime: Double)?
    private var generation = 0
    private var waiters: [UUID: CheckedContinuation<QuotaSnapshot, Error>] = [:]
    private var pending: (id: UUID, generation: Int, task: Task<Void, Never>)?

    init(connection: CodexQuotaConnection = CodexQuotaConnection(), ttl: TimeInterval = 10) {
        self.connection = connection
        self.ttl = Self.cacheLifetime(ttl)
    }

    static func cacheLifetime(_ requested: TimeInterval) -> TimeInterval {
        requested.isFinite ? min(10, max(0, requested)) : 0
    }

    func read(force: Bool = false) async throws -> QuotaSnapshot {
        try Task.checkCancellation()
        // The last waiter may have cancelled the transport just before this
        // actor receives a new read. Do not attach the new caller to that task.
        if waiters.isEmpty, pending?.task.isCancelled == true { pending = nil }
        if pending == nil, !force, let cache, ProcessInfo.processInfo.systemUptime - cache.uptime < ttl,
           (0...ttl).contains(Date().timeIntervalSince(cache.snapshot.checkedAt)) { return cache.snapshot }
        let key = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                waiters[key] = continuation
                if pending == nil { startRead() }
            }
        }, onCancel: { Task { await self.cancelWaiter(key) } })
    }

    /// Do not authorize later work from a read begun before the invalidation.
    /// Existing waiters are carried over to a fresh read rather than failed.
    func invalidate() {
        cache = nil; generation += 1
        pending?.task.cancel()
    }

    func shutdown() async {
        cache = nil; generation += 1
        pending?.task.cancel(); pending = nil
        let waiting = Array(waiters.values); waiters.removeAll()
        waiting.forEach { $0.resume(throwing: CancellationError()) }
        // Await the bounded process cleanup, so a normal application exit does
        // not abandon the persistent child before its queued cleanup runs.
        await connection.shutdownAndWait()
    }

    private func startRead() {
        // A failed refresh must not leave an older, superficially fresh allowance.
        cache = nil
        let key = UUID(), version = generation, transport = connection
        let task = Task {
            let result: Result<QuotaSnapshot, Error>
            do { result = .success(try await transport.read()) } catch { result = .failure(error) }
            complete(key, version: version, result: result)
        }
        pending = (key, version, task)
    }

    private func complete(_ key: UUID, version: Int, result: Result<QuotaSnapshot, Error>) {
        guard pending?.id == key else { return }
        pending = nil
        guard version == generation else {
            if !waiters.isEmpty { startRead() }; return
        }
        if case .success(let snapshot) = result { cache = (snapshot, ProcessInfo.processInfo.systemUptime) }
        let waiting = Array(waiters.values); waiters.removeAll()
        waiting.forEach { $0.resume(with: result) }
    }

    private func cancelWaiter(_ key: UUID) {
        guard let continuation = waiters.removeValue(forKey: key) else { return }
        continuation.resume(throwing: CancellationError())
        if waiters.isEmpty { pending?.task.cancel(); pending = nil; cache = nil }
    }
}
