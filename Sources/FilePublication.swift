import Foundation
import CryptoKit
import Darwin

/// A save-panel confirmation is not a filesystem operation. Replacement requires a
/// token for the exact regular file inspected before asking the user, and a backup.
enum FilePublication {
    struct Existing {
        let url: URL
        let byteCount: Int64
        fileprivate let identity: Identity
        fileprivate let digest: String
    }

    struct BackupMetadata: Codable {
        let originalPath: String
        let originalFilename: String
        let createdAt: Date
        let sha256: String
        let backupFilename: String

        enum CodingKeys: String, CodingKey {
            case originalPath, originalFilename, createdAt, backupFilename
            case sha256 = "SHA256"
        }
    }

    static func metadataURL(for backup: URL) -> URL { backup.appendingPathExtension("json") }

    #if FILE_PUBLICATION_TESTS
    // Compile only in the isolated writer test binary, never in the application.
    static var beforeMetadataWriteForTesting: ((URL) throws -> Void)?
    #endif

    fileprivate struct Identity: Equatable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        init(_ info: stat) {
            device = info.st_dev; inode = info.st_ino; size = info.st_size
            modifiedSeconds = info.st_mtimespec.tv_sec; modifiedNanoseconds = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec; changedNanoseconds = info.st_ctimespec.tv_nsec
        }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // Projects already have a 256 MiB limit; reject pathological replacement targets
    // before reading them. Hash/copy in chunks rather than loading the old file twice.
    private static let maximumExistingBytes: Int64 = 512 * 1024 * 1024
    private static let publicationLock = NSRecursiveLock()

    static func inspect(_ destination: URL, protectedSources: [URL] = []) throws -> Existing? {
        let target = try normalizedTarget(destination)
        try protect(target, sources: protectedSources)
        guard let named = try information(target) else { return nil }
        try requireRegular(named, at: target)
        let descriptor = try openRegular(target)
        defer { close(descriptor) }
        let snapshot = try snapshot(descriptor, at: target)
        guard snapshot.identity == Identity(named) else { throw changed(target) }
        try protect(target, sources: protectedSources)
        return snapshot
    }

    /// nil token means create-only, including automatic SRT export. For an explicitly
    /// approved replacement, publish atomically only after a durable byte-exact backup.
    /// A process lock and an advisory inode lock serialize this writer. Inode/hash
    /// checks catch external changes observed before commit. Other applications need
    /// not honor advisory locks; this is not a filesystem compare-and-swap primitive.
    /// No existing path is deleted first, and a verified backup precedes replacement.
    @discardableResult
    static func publish(_ bytes: Data, to destination: URL, replacing: Existing? = nil,
                        backupDirectory: URL? = nil, protectedSources: [URL] = []) throws -> URL? {
        publicationLock.lock()
        defer { publicationLock.unlock() }
        let target = try normalizedTarget(destination)
        if let replacing, replacing.url != target { throw changed(target) }
        return try commit(bytes, to: target, replacing: replacing,
                          backupDirectory: backupDirectory, protectedSources: protectedSources)
    }

    private static func commit(_ bytes: Data, to target: URL, replacing: Existing?,
                               backupDirectory: URL?, protectedSources: [URL]) throws -> URL? {
        let current = try inspect(target, protectedSources: protectedSources)
        if let replacing {
            guard let current, matches(current, replacing) else { throw changed(target) }
            guard backupDirectory != nil else {
                throw Failure(message: "Для замены файла требуется папка резервных копий. Файл не изменён.")
            }
        } else if current != nil {
            throw Failure(message: "Файл уже существует: \(target.path). Подтвердите замену или выберите другое имя.")
        }
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".publication-\(UUID().uuidString).tmp")
        let output = try createExclusive(temporary)
        defer { close(output); try? FileManager.default.removeItem(at: temporary) }
        try write(bytes, to: output)
        guard fsync(output) == 0 else { throw systemError("Не удалось записать новый файл", at: temporary) }

        guard let replacing else {
            try protect(target, sources: protectedSources)
            // Hard-link publication is exclusive and atomic: a concurrent creator wins
            // safely, and the caller never overwrites its newly appeared file.
            guard Darwin.link(temporary.path, target.path) == 0 else {
                throw systemError("Не удалось сохранить новый файл", at: target)
            }
            return nil
        }
        let original = try openRegular(target)
        defer { close(original) }
        while flock(original, LOCK_EX | LOCK_NB) != 0 {
            if errno == EINTR { continue }
            throw Failure(message: "Файл занят другим сохранением: \(target.path). Повторите позже.")
        }
        defer { flock(original, LOCK_UN) }
        guard matches(try snapshot(original, at: target), replacing) else { throw changed(target) }
        let backup = try makeBackup(original, original: replacing, directory: backupDirectory!)
        // Keep a successful backup even if a later check or atomic rename fails.
        guard let latest = try inspect(target, protectedSources: protectedSources), matches(latest, replacing),
              matches(try snapshot(original, at: target), replacing) else { throw changed(target) }
        guard Darwin.rename(temporary.path, target.path) == 0 else {
            throw systemError("Замена не выполнена; резерв сохранён в \(backup.path)", at: target)
        }
        return backup
    }

    private static func makeBackup(_ descriptor: Int32, original: Existing, directory: URL) throws -> URL {
        guard directory.isFileURL else { throw Failure(message: "Резервная копия требует локальной папки.") }
        if let info = try information(directory) {
            guard (info.st_mode & S_IFMT) == S_IFDIR else {
                throw Failure(message: "Папка резервных копий занята файлом или ссылкой. Оригинал не изменён: \(directory.path)")
            }
        } else {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        guard let info = try information(directory), (info.st_mode & S_IFMT) == S_IFDIR else {
            throw Failure(message: "Не удалось проверить папку резервных копий. Оригинал не изменён.")
        }
        let backup = directory.appendingPathComponent("\(UUID().uuidString)-\(original.url.lastPathComponent.prefix(40)).backup")
        let output = try createExclusive(backup)
        var finished = false
        defer {
            close(output)
            if !finished { try? FileManager.default.removeItem(at: backup) }
        }
        let copiedDigest = try digest(descriptor, copyingTo: output)
        guard copiedDigest == original.digest, fsync(output) == 0 else {
            throw Failure(message: "Не удалось получить точную резервную копию. Оригинал не изменён: \(original.url.path)")
        }
        // Verify the materialized backup, not just the bytes offered to write().
        let saved = try openRegular(backup)
        defer { close(saved) }
        guard try digest(saved) == original.digest else {
            throw Failure(message: "Проверка резервной копии не пройдена. Оригинал не изменён.")
        }
        // A verified byte copy remains available if publishing its metadata fails.
        // The destination still remains untouched until both files are persisted.
        finished = true
        try saveBackupMetadata(backup: backup, original: original)
        let folder = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { throw systemError("Не удалось закрепить резервную копию на диске", at: directory) }
        defer { close(folder) }
        guard fsync(folder) == 0 else { throw systemError("Не удалось закрепить резервную копию на диске", at: directory) }
        return backup
    }

    private static func saveBackupMetadata(backup: URL, original: Existing) throws {
        let metadata = BackupMetadata(originalPath: original.url.path,
            originalFilename: original.url.lastPathComponent, createdAt: Date(),
            sha256: original.digest, backupFilename: backup.lastPathComponent)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let bytes = try encoder.encode(metadata)
        let destination = metadataURL(for: backup)
        #if FILE_PUBLICATION_TESTS
        try beforeMetadataWriteForTesting?(destination)
        #endif
        let descriptor = try createExclusive(destination)
        var finished = false
        defer {
            close(descriptor)
            if !finished { try? FileManager.default.removeItem(at: destination) }
        }
        try write(bytes, to: descriptor)
        guard fsync(descriptor) == 0 else {
            throw systemError("Не удалось сохранить сведения о резервной копии. Оригинал не изменён", at: destination)
        }
        let saved = try openRegular(destination)
        defer { close(saved) }
        let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard try digest(saved) == expected else {
            throw Failure(message: "Проверка сведений о резервной копии не пройдена. Оригинал не изменён.")
        }
        finished = true
    }

    private static func normalizedTarget(_ destination: URL) throws -> URL {
        guard destination.isFileURL, destination.path.hasPrefix("/"), !destination.path.contains("\0"),
              destination.path.utf8.count <= 16_384, !destination.lastPathComponent.isEmpty,
              !["/", ".", ".."].contains(destination.lastPathComponent) else {
            throw Failure(message: "Выберите обычный локальный файл.")
        }
        // Resolve parents, not the leaf: a leaf symlink must be rejected, not followed.
        return destination.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
            .appendingPathComponent(destination.lastPathComponent)
    }

    private static func protect(_ target: URL, sources: [URL]) throws {
        let targetInfo = try information(target)
        for source in sources {
            guard source.isFileURL else { throw Failure(message: "Некорректный путь защищённого исходника.") }
            let original = source.standardizedFileURL.resolvingSymlinksInPath()
            let normalizedSource = try normalizedTarget(source)
            let samePath = original == target || normalizedSource == target
            let sourceInfo = try information(original)
            let sameInode = targetInfo != nil && sourceInfo != nil && targetInfo!.st_dev == sourceInfo!.st_dev && targetInfo!.st_ino == sourceInfo!.st_ino
            guard !samePath && !sameInode else {
                throw Failure(message: "Нельзя заменять исходный файл: \(source.path). Выберите отдельное имя результата.")
            }
        }
    }

    private static func information(_ url: URL) throws -> stat? {
        var value = stat()
        if lstat(url.path, &value) == 0 { return value }
        if errno == ENOENT { return nil }
        throw systemError("Не удалось проверить файл", at: url)
    }
    private static func requireRegular(_ info: stat, at url: URL) throws {
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0, info.st_size <= maximumExistingBytes else {
            throw Failure(message: "Нельзя заменить папку, ссылку, специальный или слишком большой файл: \(url.path)")
        }
    }
    private static func openRegular(_ url: URL) throws -> Int32 {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw systemError("Не удалось открыть обычный файл", at: url) }
        do {
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw systemError("Не удалось проверить открытый файл", at: url) }
            try requireRegular(info, at: url)
            return descriptor
        } catch { close(descriptor); throw error }
    }
    private static func snapshot(_ descriptor: Int32, at url: URL) throws -> Existing {
        var before = stat(), after = stat()
        guard fstat(descriptor, &before) == 0 else { throw systemError("Не удалось проверить файл", at: url) }
        try requireRegular(before, at: url)
        let hash = try digest(descriptor)
        guard fstat(descriptor, &after) == 0, Identity(before) == Identity(after),
              let named = try information(url), Identity(named) == Identity(after) else { throw changed(url) }
        return Existing(url: url, byteCount: after.st_size, identity: Identity(after), digest: hash)
    }
    private static func matches(_ lhs: Existing, _ rhs: Existing) -> Bool {
        lhs.url == rhs.url && lhs.identity == rhs.identity && lhs.digest == rhs.digest
    }
    private static func digest(_ descriptor: Int32, copyingTo output: Int32? = nil) throws -> String {
        guard lseek(descriptor, 0, SEEK_SET) >= 0 else { throw Failure(message: "Не удалось прочитать файл для проверки.") }
        var hasher = SHA256(), count: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            let readCount = Darwin.read(descriptor, &buffer, buffer.count)
            if readCount < 0 && errno == EINTR { continue }
            guard readCount >= 0 else { throw Failure(message: "Ошибка чтения файла для проверки или резервирования.") }
            if readCount == 0 { break }
            count += Int64(readCount)
            guard count <= maximumExistingBytes else { throw Failure(message: "Файл изменился или слишком велик для безопасной замены.") }
            let chunk = Data(buffer.prefix(readCount))
            hasher.update(data: chunk)
            if let output { try write(chunk, to: output) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func createExclusive(_ url: URL) throws -> Int32 {
        let result = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard result >= 0 else { throw systemError("Не удалось создать служебный файл", at: url) }
        return result
    }
    private static func write(_ bytes: Data, to descriptor: Int32) throws {
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw Failure(message: "Не удалось полностью записать файл. Оригинал не изменён.") }
                offset += written
            }
        }
    }
    private static func changed(_ url: URL) -> Failure {
        Failure(message: "Файл изменился после выбора: \(url.path). Замена отменена; выберите его и подтвердите ещё раз.")
    }
    private static func systemError(_ message: String, at url: URL) -> Failure {
        let detail = String(cString: strerror(errno))
        return Failure(message: "\(message): \(url.path). \(detail)")
    }
}
