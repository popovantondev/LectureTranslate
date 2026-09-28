import Foundation
import Darwin

@main
enum InstanceLockTests {
    private static var passed = 0
    private static func check(_ value: Bool, _ label: String) {
        guard value else { fputs("FAIL: \(label)\n", stderr); exit(1) }
        passed += 1
    }
    private static func rejects(_ label: String, busy: Bool = false, _ body: () throws -> Void) {
        do { try body(); check(false, "\(label) must reject") }
        catch TranslationStateLockError.busy { check(busy, "\(label): expected unavailable, got busy") }
        catch TranslationStateLockError.unavailable { check(!busy, "\(label): expected busy, got unavailable") }
        catch { check(false, "\(label): unexpected error type") }
    }

    static func main() throws {
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--legacy-holder" {
            // Simulate released 0.6.2/1.6.3: flock only, no owner PID file or metadata.
            let fd = Darwin.open(CommandLine.arguments[2], O_RDWR | O_CREAT, 0o600)
            guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { exit(4) }
            try FileHandle.standardOutput.write(contentsOf: Data("ready\n".utf8))
            var byte: UInt8 = 0
            _ = Darwin.read(STDIN_FILENO, &byte, 1)
            flock(fd, LOCK_UN); close(fd); return
        }

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("LectureInstanceLockTests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) } // Only this test-owned UUID directory.
        let state = root.appendingPathComponent("Очередь ' $(echo literal)")
        try fm.createDirectory(at: state, withIntermediateDirectories: false)
        let lockURL = state.appendingPathComponent("queue.lock")
        let stale = Data("stale PID 12345; never an ownership authority".utf8)
        try stale.write(to: lockURL)
        var originalInfo = stat(); check(lstat(lockURL.path, &originalInfo) == 0, "stale lock fixture exists")
        var owner: TranslationStateLock? = try TranslationStateLock(root: state)
        try withExtendedLifetime(owner) {
            check(try Data(contentsOf: lockURL) == stale, "acquire does not truncate or overwrite stale lock bytes")
            rejects("second writer", busy: true) { _ = try TranslationStateLock(root: state) }
            var fdFlags: Int32?
            for descriptor: Int32 in 0..<1024 {
                var info = stat()
                if fstat(descriptor, &info) == 0 && info.st_dev == originalInfo.st_dev && info.st_ino == originalInfo.st_ino {
                    fdFlags = fcntl(descriptor, F_GETFD); break
                }
            }
            check(fdFlags.map { $0 & FD_CLOEXEC != 0 } == true, "held lock descriptor has close-on-exec")
            let isolated = try TranslationStateLock(root: root.appendingPathComponent("isolated-preview"))
            withExtendedLifetime(isolated) { check(true, "different state directory can hold its own lock") }
            let alias = root.appendingPathComponent("alias")
            try fm.createSymbolicLink(at: alias, withDestinationURL: state)
            rejects("canonical root alias shares the same lock", busy: true) { _ = try TranslationStateLock(root: alias) }
            let actual = try TranslationStateLock.ownerProcessIDs(root: state, timeoutSeconds: 5)
            check(actual.contains(getpid()), "system lsof finds current holder by exact literal path")
            check(Set(actual).count == actual.count && actual == actual.sorted(), "owner list sorted and unique")
        }
        owner = nil
        check(fm.fileExists(atPath: lockURL.path), "release never deletes lock file")
        var releasedInfo = stat(); _ = lstat(lockURL.path, &releasedInfo)
        check(releasedInfo.st_ino == originalInfo.st_ino && releasedInfo.st_dev == originalInfo.st_dev, "lock inode survives release")
        let reacquired = try TranslationStateLock(root: state)
        withExtendedLifetime(reacquired) { check(true, "stale file without live owner does not block reacquisition") }

        let missing = root.appendingPathComponent("missing-state")
        check(try TranslationStateLock.ownerProcessIDs(root: missing, testExecutable: "/does-not-exist") == [], "missing lock returns no owner without launching helper")
        let badRoot = root.appendingPathComponent("not-directory")
        try Data("file".utf8).write(to: badRoot)
        rejects("file instead of state directory") { _ = try TranslationStateLock(root: badRoot) }
        let symlinkRoot = root.appendingPathComponent("symlink-state")
        try fm.createDirectory(at: symlinkRoot, withIntermediateDirectories: false)
        let protected = root.appendingPathComponent("protected-file")
        try Data("KEEP".utf8).write(to: protected)
        try fm.createSymbolicLink(at: symlinkRoot.appendingPathComponent("queue.lock"), withDestinationURL: protected)
        rejects("lock symlink rejected") { _ = try TranslationStateLock(root: symlinkRoot) }
        rejects("owner discovery rejects lock symlink") { _ = try TranslationStateLock.ownerProcessIDs(root: symlinkRoot) }
        check(try Data(contentsOf: protected) == Data("KEEP".utf8), "symlink target unchanged")
        let directoryRoot = root.appendingPathComponent("directory-lock")
        try fm.createDirectory(at: directoryRoot.appendingPathComponent("queue.lock"), withIntermediateDirectories: true)
        rejects("directory instead of lock") { _ = try TranslationStateLock(root: directoryRoot) }
        let fifoRoot = root.appendingPathComponent("fifo-lock")
        try fm.createDirectory(at: fifoRoot, withIntermediateDirectories: false)
        check(mkfifo(fifoRoot.appendingPathComponent("queue.lock").path, 0o600) == 0, "FIFO fixture created")
        let fifoStart = ProcessInfo.processInfo.systemUptime
        rejects("FIFO lock rejected without blocking") { _ = try TranslationStateLock(root: fifoRoot) }
        check(ProcessInfo.processInfo.systemUptime - fifoStart < 0.5, "FIFO rejection is immediate")
        let readOnlyRoot = root.appendingPathComponent("readonly-lock")
        try fm.createDirectory(at: readOnlyRoot, withIntermediateDirectories: false)
        let readOnlyLock = readOnlyRoot.appendingPathComponent("queue.lock")
        try Data().write(to: readOnlyLock); try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: readOnlyLock.path)
        rejects("permission error is unavailable, not busy") { _ = try TranslationStateLock(root: readOnlyRoot) }

        check(try TranslationStateLock.parseProcessIDs(Data("p13\0\np7\0\np13\0\n".utf8)) == [7, 13], "NUL PID fields parsed and deduplicated")
        check(try TranslationStateLock.parseProcessIDs(Data("p13\0\nf5\0\np7\0\nf8\0\n".utf8)) == [7, 13], "mandatory lsof FD fields ignored safely")
        check(try TranslationStateLock.parseProcessIDs(Data()) == [], "empty output is no owner")
        for (label, bytes) in [
            ("unterminated", Data("p12".utf8)), ("wrong field", Data("x12\0\n".utf8)),
            ("negative PID", Data("p-12\0\n".utf8)), ("zero PID", Data("p0\0\n".utf8)),
            ("overflow PID", Data("p9999999999999999\0\n".utf8)), ("empty PID", Data("p\0\n".utf8)),
            ("embedded newline", Data("p12\np13\0\n".utf8)), ("FD without PID", Data("f5\0\n".utf8)),
            ("invalid UTF8", Data([112, 0xFF, 0]))
        ] { rejects("malformed \(label)") { _ = try TranslationStateLock.parseProcessIDs(bytes) } }

        func fixture(_ script: String, timeout: Double = 1) throws -> [Int32] {
            try TranslationStateLock.ownerProcessIDs(root: state, timeoutSeconds: timeout, testExecutable: "/bin/sh", testArguments: ["-c", script])
        }
        check(try fixture("printf 'p22\\000\\np11\\000\\n'") == [11, 22], "bounded helper reads PID response")
        check(try fixture("exit 0") == [], "early successful exit with no owner")
        check(try fixture("exit 1") == [], "lsof no-match exit is not a timeout")
        let earlyStart = ProcessInfo.processInfo.systemUptime
        rejects("early helper failure") { _ = try fixture("exit 2", timeout: 2) }
        check(ProcessInfo.processInfo.systemUptime - earlyStart < 1, "early exit reported immediately")
        rejects("partial response with failed exit") { _ = try fixture("printf 'p22\\000\\n'; exit 1") }
        rejects("malformed helper output") { _ = try fixture("printf 'p22 bad\\000\\n'") }
        rejects("missing helper executable") { _ = try TranslationStateLock.ownerProcessIDs(root: state, testExecutable: "/does-not-exist") }
        for timeout in [0.0, -1.0, Double.infinity, Double.nan, 61.0] {
            rejects("invalid timeout") { _ = try TranslationStateLock.ownerProcessIDs(root: state, timeoutSeconds: timeout) }
        }
        for script in ["trap '' TERM; while :; do :; done", "exec 1>&-; trap '' TERM; while :; do :; done"] {
            let began = ProcessInfo.processInfo.systemUptime
            rejects("helper timeout even with TERM ignored / stdout closed") { _ = try fixture(script, timeout: 0.15) }
            check(ProcessInfo.processInfo.systemUptime - began < 1, "helper timeout bound includes termination grace")
        }
        let descendantStart = ProcessInfo.processInfo.systemUptime
        check(try fixture("sleep 2 & exit 0", timeout: 1) == [], "descendant-held stdout does not block completed helper")
        check(ProcessInfo.processInfo.systemUptime - descendantStart < 0.8, "no wait for descendant EOF")
        rejects("noisy helper output is bounded") { _ = try fixture("while :; do printf 'p1234567890\\000\\n'; done", timeout: 1) }

        let legacyRoot = root.appendingPathComponent("legacy-without-metadata")
        try fm.createDirectory(at: legacyRoot, withIntermediateDirectories: false)
        let legacyFile = legacyRoot.appendingPathComponent("queue.lock")
        let legacy = Process(), ready = Pipe(), input = Pipe()
        legacy.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        legacy.arguments = ["--legacy-holder", legacyFile.path]
        legacy.standardInput = input; legacy.standardOutput = ready; legacy.standardError = FileHandle.nullDevice
        try legacy.run()
        defer { try? input.fileHandleForWriting.close(); if legacy.isRunning { legacy.terminate() }; try? ready.fileHandleForReading.close() }
        var wait = pollfd(fd: ready.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        check(Darwin.poll(&wait, 1, 2000) > 0, "legacy holder ready within deadline")
        let hello = try ready.fileHandleForReading.read(upToCount: 6)
        check(hello == Data("ready\n".utf8), "legacy holder acquired flock without metadata")
        rejects("new version respects legacy owner", busy: true) { _ = try TranslationStateLock(root: legacyRoot) }
        let legacyOwners = try TranslationStateLock.ownerProcessIDs(root: legacyRoot, timeoutSeconds: 5)
        check(legacyOwners == [legacy.processIdentifier], "owner discovery finds exact legacy holder, not another isolated state")
        check(try Data(contentsOf: legacyFile).isEmpty, "legacy lock stays empty; no PID assumptions")
        try input.fileHandleForWriting.close()
        let releaseDeadline = ProcessInfo.processInfo.systemUptime + 1
        while legacy.isRunning && ProcessInfo.processInfo.systemUptime < releaseDeadline { Thread.sleep(forTimeInterval: 0.01) }
        check(!legacy.isRunning, "test legacy owner releases normally")
        check(try TranslationStateLock.ownerProcessIDs(root: legacyRoot, timeoutSeconds: 5).isEmpty, "released legacy file has no open owner")
        let afterLegacy = try TranslationStateLock(root: legacyRoot)
        withExtendedLifetime(afterLegacy) { check(true, "new version acquires after legacy release") }
        print("PASS: \(passed) instance lock checks. Isolated state and owned test helpers; no GUI, model or account calls.")
    }
}
