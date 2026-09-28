import Foundation
import Darwin

enum TranslationStateLockError: LocalizedError {
    case busy
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .busy: return "Эта очередь уже открыта в другом экземпляре переводчика."
        case .unavailable(let detail): return "Не удалось открыть блокировку очереди. \(detail)"
        }
    }
}

/// The kernel lock is the authority, not an owner PID or the presence of a stale file.
/// Keep the same inode for legacy versions. Never delete, truncate or replace queue.lock.
final class TranslationStateLock {
    private let descriptor: Int32

    init(root: URL) throws {
        guard root.isFileURL else { throw TranslationStateLockError.unavailable("Требуется локальная папка состояния.") }
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        catch { throw TranslationStateLockError.unavailable(error.localizedDescription) }
        let path = Self.lockURL(root: root).path
        let opened = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard opened >= 0 else { throw Self.systemError(errno) }
        var retained = false
        defer { if !retained { close(opened) } }
        var info = stat()
        guard fstat(opened, &info) == 0 else { throw Self.systemError(errno) }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw TranslationStateLockError.unavailable("queue.lock должен быть обычным файлом, не ссылкой или специальным устройством.")
        }
        // O_CLOEXEC is atomic with open; also verify the flag rather than relying on
        // how an individual child-process launcher happens to handle inherited FDs.
        let flags = fcntl(opened, F_GETFD)
        guard flags >= 0, flags & FD_CLOEXEC != 0 else {
            throw TranslationStateLockError.unavailable("Не удалось запретить наследование блокировки дочерними процессами.")
        }
        while flock(opened, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            if code == EINTR { continue }
            if code == EWOULDBLOCK { throw TranslationStateLockError.busy }
            throw Self.systemError(code)
        }
        var named = stat()
        guard lstat(path, &named) == 0, (named.st_mode & S_IFMT) == S_IFREG,
              named.st_dev == info.st_dev, named.st_ino == info.st_ino else {
            throw TranslationStateLockError.unavailable("Файл блокировки изменился во время открытия. Попробуйте снова; очередь не изменена.")
        }
        descriptor = opened; retained = true
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    /// Returns processes with the exact queue.lock file open, including legacy apps
    /// that never wrote owner metadata. A PID is only a candidate: the UI must match
    /// NSRunningApplication identity, ignore itself, and never guess between owners.
    /// This function never focuses or terminates another application.
    static func ownerProcessIDs(root: URL, timeoutSeconds: Double = 2.0,
                                testExecutable: String? = nil, testArguments: [String]? = nil) throws -> [Int32] {
        guard root.isFileURL, timeoutSeconds.isFinite, timeoutSeconds > 0, timeoutSeconds <= 60 else {
            throw TranslationStateLockError.unavailable("Некорректные параметры поиска открытой очереди.")
        }
        let path = lockURL(root: root).path
        var info = stat()
        if lstat(path, &info) != 0 {
            if errno == ENOENT { return [] }
            throw systemError(errno)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw TranslationStateLockError.unavailable("queue.lock не является обычным файлом.")
        }
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: testExecutable ?? "/usr/sbin/lsof")
        // Arguments, not a shell command: spaces, Unicode and punctuation are literal.
        process.arguments = testArguments ?? ["-nP", "-F0p", "--", path]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let fd = output.fileHandleForReading.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw TranslationStateLockError.unavailable("Не удалось настроить ограниченный по времени поиск приложения.")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeoutSeconds
        do { try process.run() }
        catch { throw TranslationStateLockError.unavailable("Не удалось запустить служебный поиск: \(error.localizedDescription)") }
        defer {
            // Stop only the helper launched above, never any PID returned by lsof.
            if process.isRunning {
                process.terminate()
                let grace = ProcessInfo.processInfo.systemUptime + 0.10
                while process.isRunning && ProcessInfo.processInfo.systemUptime < grace { Thread.sleep(forTimeInterval: 0.005) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            try? output.fileHandleForReading.close()
        }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192), eof = false
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else {
                throw TranslationStateLockError.unavailable("Не удалось найти открытое окно за отведённое время. Блокировка и очередь не изменены.")
            }
            if !eof {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    data.append(contentsOf: buffer.prefix(count))
                    guard data.count <= 65_536 else { throw TranslationStateLockError.unavailable("Слишком большой служебный ответ при поиске окна.") }
                    continue
                }
                if count == 0 { eof = true }
                else if errno != EAGAIN && errno != EINTR {
                    throw TranslationStateLockError.unavailable("Не удалось прочитать служебный ответ при поиске окна.")
                }
            }
            if !process.isRunning {
                // A descendant retaining stdout must not hold up the UI after the
                // helper exits. Drain immediately available bytes only, never wait for EOF.
                if !eof {
                    let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                    if count > 0 {
                        data.append(contentsOf: buffer.prefix(count))
                        guard data.count <= 65_536 else { throw TranslationStateLockError.unavailable("Слишком большой служебный ответ при поиске окна.") }
                        continue
                    }
                }
                guard process.terminationReason == .exit else {
                    throw TranslationStateLockError.unavailable("Служебный поиск окна был прерван.")
                }
                if process.terminationStatus == 1 && data.isEmpty { return [] } // lsof: no matching open file.
                guard process.terminationStatus == 0 else {
                    throw TranslationStateLockError.unavailable("Служебный поиск окна завершился с кодом \(process.terminationStatus).")
                }
                return try parseProcessIDs(data)
            }
            if eof { Thread.sleep(forTimeInterval: min(0.02, remaining)); continue }
            var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let polled = Darwin.poll(&item, 1, Int32(min(20, ceil(remaining * 1000))))
            if polled < 0 && errno != EINTR { throw systemError(errno) }
        }
    }

    static func parseProcessIDs(_ data: Data) throws -> [Int32] {
        if data.isEmpty { return [] }
        guard let text = String(data: data, encoding: .utf8), text.contains("\0"),
              text.last == "\0" || text.hasSuffix("\0\n") else {
            throw TranslationStateLockError.unavailable("Некорректный формат списка открытых процессов.")
        }
        var result = Set<Int32>(), hasProcess = false
        for field in text.split(separator: "\0", omittingEmptySubsequences: true) {
            let value = field.trimmingCharacters(in: .newlines)
            if value.isEmpty { continue }
            if value.first == "f", hasProcess, value.count > 1, value.count < 128,
               !value.contains("\n"), !value.contains("\r") { continue } // lsof may include mandatory FD fields.
            guard value.first == "p", value.dropFirst().allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  let pid = Int32(value.dropFirst()), pid > 0 else {
                throw TranslationStateLockError.unavailable("Некорректный идентификатор в списке открытых процессов.")
            }
            result.insert(pid); hasProcess = true
        }
        guard hasProcess else { throw TranslationStateLockError.unavailable("Список процессов не содержит идентификаторов.") }
        return result.sorted()
    }

    private static func lockURL(root: URL) -> URL {
        root.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent("queue.lock")
    }
    private static func systemError(_ code: Int32) -> TranslationStateLockError {
        .unavailable(String(cString: strerror(code)))
    }
}
