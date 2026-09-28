import Foundation
import Darwin
import CryptoKit

@main
enum FilePublicationTests {
    private static var passed = 0
    private static func check(_ condition: Bool, _ label: String) {
        guard condition else { fputs("FAIL: \(label)\n", stderr); exit(1) }
        passed += 1
    }
    private static func rejects(_ label: String, _ body: () throws -> Void) {
        do { try body(); fputs("FAIL: \(label) did not reject\n", stderr); exit(1) }
        catch { passed += 1 }
    }

    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FilePublicationTests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) } // Only this test-owned UUID directory.
        let destination = root.appendingPathComponent("День 5.ru.srt")
        let backups = root.appendingPathComponent("state/file-backups")
        let first = Data("Первая сохранённая версия.\n".utf8)
        let second = Data("Новая проверенная версия.\n".utf8)

        check(try FilePublication.inspect(destination) == nil, "missing destination has no replacement token")
        check(try FilePublication.publish(first, to: destination) == nil, "new publication has no backup")
        check(try Data(contentsOf: destination) == first, "new output has exact bytes")
        rejects("default never authorizes overwrite") { try FilePublication.publish(second, to: destination) }
        check(try Data(contentsOf: destination) == first, "default collision preserves old bytes")
        let token = try FilePublication.inspect(destination)!
        let retainedOldHandle = try FileHandle(forWritingTo: destination)
        defer { try? retainedOldHandle.close() }
        check(token.byteCount == first.count, "token exposes inspected byte count")
        rejects("replacement requires service backup destination") {
            try FilePublication.publish(second, to: destination, replacing: token)
        }
        check(try Data(contentsOf: destination) == first, "missing backup setting preserves original")
        let backup = try FilePublication.publish(second, to: destination, replacing: token, backupDirectory: backups)!
        check(try Data(contentsOf: destination) == second, "explicit replacement publishes new bytes")
        check(try Data(contentsOf: backup) == first, "backup preserves exact previous bytes")
        try retainedOldHandle.write(contentsOf: Data("External holder changed its old inode".utf8))
        check(try Data(contentsOf: backup) == first, "backup is a byte copy independent of the displaced inode")
        check(backup.deletingLastPathComponent().path == backups.path, "backup is kept in service folder")
        let attributes = try fm.attributesOfItem(atPath: backup.path)
        check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "backup is private to user")
        let metadataURL = FilePublication.metadataURL(for: backup)
        let metadataDecoder = JSONDecoder(); metadataDecoder.dateDecodingStrategy = .iso8601
        let metadataBytes = try Data(contentsOf: metadataURL)
        let metadata = try metadataDecoder.decode(FilePublication.BackupMetadata.self, from: metadataBytes)
        check(metadata.originalPath == token.url.path && metadata.originalFilename == destination.lastPathComponent,
              "backup metadata records exact original path and filename")
        check(metadata.backupFilename == backup.lastPathComponent && abs(metadata.createdAt.timeIntervalSinceNow) < 10,
              "backup metadata identifies the backup and creation time")
        let firstHash = SHA256.hash(data: first).map { String(format: "%02x", $0) }.joined()
        check(metadata.sha256 == firstHash && String(decoding: metadataBytes, as: UTF8.self).contains("\"SHA256\""),
              "metadata checksum verifies the backed-up bytes")
        let metadataAttributes = try fm.attributesOfItem(atPath: metadataURL.path)
        check((metadataAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "metadata paths remain private to the user")
        rejects("consumed token cannot overwrite a newer version") {
            try FilePublication.publish(first, to: destination, replacing: token, backupDirectory: backups)
        }
        check(try Data(contentsOf: destination) == second, "stale token preserves latest content")

        let beforeEdit = try FilePublication.inspect(destination)!
        let external = Data("Изменено вне программы.".utf8)
        try external.write(to: destination)
        rejects("in-place external edit invalidates consent") {
            try FilePublication.publish(first, to: destination, replacing: beforeEdit, backupDirectory: backups)
        }
        check(try Data(contentsOf: destination) == external, "external edit remains intact")
        let beforeRename = try FilePublication.inspect(destination)!
        try external.write(to: destination, options: .atomic)
        rejects("same bytes in a replacement inode invalidate consent") {
            try FilePublication.publish(first, to: destination, replacing: beforeRename, backupDirectory: backups)
        }
        let another = root.appendingPathComponent("Другой.ru.srt")
        try external.write(to: another)
        let otherToken = try FilePublication.inspect(another)!
        rejects("consent for one path cannot replace another") {
            try FilePublication.publish(first, to: destination, replacing: otherToken, backupDirectory: backups)
        }

        let directory = root.appendingPathComponent("Day_05.lectureproject")
        try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        let sentinel = directory.appendingPathComponent("source.srt")
        try first.write(to: sentinel)
        rejects("directory inspection rejected") { _ = try FilePublication.inspect(directory) }
        rejects("directory publication rejected") { try FilePublication.publish(second, to: directory) }
        check(try Data(contentsOf: sentinel) == first, "directory contents preserved")
        let symlink = root.appendingPathComponent("Ссылка.ru.srt")
        try fm.createSymbolicLink(at: symlink, withDestinationURL: destination)
        rejects("symlink rejected rather than followed") { _ = try FilePublication.inspect(symlink) }
        rejects("symlink publication rejected") { try FilePublication.publish(first, to: symlink) }
        let dangling = root.appendingPathComponent("Битая ссылка.ru.srt")
        try fm.createSymbolicLink(at: dangling, withDestinationURL: root.appendingPathComponent("Absent"))
        rejects("dangling symlink is not treated as missing") { try FilePublication.publish(first, to: dangling) }
        let fifo = root.appendingPathComponent("Pipe.ru.srt")
        guard mkfifo(fifo.path, 0o600) == 0 else { fatalError("fixture FIFO failed") }
        rejects("special file rejected without waiting for data") { _ = try FilePublication.inspect(fifo) }

        let source = root.appendingPathComponent("Original.srt")
        try first.write(to: source)
        rejects("protected source path cannot be chosen") { _ = try FilePublication.inspect(source, protectedSources: [source]) }
        let hardLink = root.appendingPathComponent("Alias.ru.srt")
        try fm.linkItem(at: source, to: hardLink)
        rejects("hard-linked source alias cannot be chosen") { _ = try FilePublication.inspect(hardLink, protectedSources: [source]) }
        let unprotectedToken = try FilePublication.inspect(hardLink)!
        rejects("source protection is repeated at publication") {
            try FilePublication.publish(second, to: hardLink, replacing: unprotectedToken,
                backupDirectory: backups, protectedSources: [source])
        }
        let sourceAlias = root.appendingPathComponent("source-link.srt")
        try fm.createSymbolicLink(at: sourceAlias, withDestinationURL: source)
        rejects("protected source symlink resolves to real source") { _ = try FilePublication.inspect(source, protectedSources: [sourceAlias]) }
        let absentSource = root.appendingPathComponent("Absent-source.srt")
        rejects("even missing protected source pathname is not an output") {
            try FilePublication.publish(second, to: absentSource, protectedSources: [absentSource])
        }
        check(try Data(contentsOf: source) == first, "all source protection checks preserve input")

        let substituted = root.appendingPathComponent("Changed-type.ru.srt")
        try first.write(to: substituted)
        let beforeTypeChange = try FilePublication.inspect(substituted)!
        try fm.removeItem(at: substituted)
        try fm.createDirectory(at: substituted, withIntermediateDirectories: false)
        rejects("directory substituted after confirmation cannot be replaced") {
            try FilePublication.publish(second, to: substituted, replacing: beforeTypeChange, backupDirectory: backups)
        }
        try fm.removeItem(at: substituted)
        try fm.createSymbolicLink(at: substituted, withDestinationURL: source)
        rejects("symlink substituted after confirmation cannot be replaced") {
            try FilePublication.publish(second, to: substituted, replacing: beforeTypeChange, backupDirectory: backups)
        }
        check(try Data(contentsOf: source) == first, "changed-type races do not alter the source")

        let blockedBackup = root.appendingPathComponent("Not a directory")
        try first.write(to: blockedBackup)
        let fresh = try FilePublication.inspect(destination)!
        rejects("backup path occupied by a file aborts replacement") {
            try FilePublication.publish(second, to: destination, replacing: fresh, backupDirectory: blockedBackup)
        }
        check(try Data(contentsOf: destination) == external, "backup failure leaves original intact")
        let backupLink = root.appendingPathComponent("Backup link")
        try fm.createSymbolicLink(at: backupLink, withDestinationURL: backups)
        rejects("service backup symlink rejected") {
            try FilePublication.publish(second, to: destination, replacing: fresh, backupDirectory: backupLink)
        }
        check(try fm.contentsOfDirectory(atPath: backups.path).count == 2, "failed attempts add neither backup nor metadata")

        #if FILE_PUBLICATION_TESTS
        let metadataFailureDirectory = root.appendingPathComponent("Failed metadata")
        var occupiedMetadata: URL?
        FilePublication.beforeMetadataWriteForTesting = { url in
            occupiedMetadata = url
            try fm.createDirectory(at: url, withIntermediateDirectories: false)
        }
        rejects("metadata creation failure aborts replacement after successful byte backup") {
            try FilePublication.publish(second, to: destination, replacing: fresh, backupDirectory: metadataFailureDirectory)
        }
        FilePublication.beforeMetadataWriteForTesting = nil
        check(try Data(contentsOf: destination) == external, "metadata failure leaves original file unchanged")
        let retainedBackups = try fm.contentsOfDirectory(at: metadataFailureDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "backup" }
        let retainedBytes = try retainedBackups.map { try Data(contentsOf: $0) }
        check(retainedBackups.count == 1 && retainedBytes == [external],
              "verified byte backup survives metadata failure")
        check(occupiedMetadata != nil && fm.fileExists(atPath: occupiedMetadata!.path), "failed metadata creation does not delete the obstructing path")
        #endif

        let large = root.appendingPathComponent("Multi-chunk.lectureproject")
        let largeBytes = Data(repeating: 123, count: 2 * 1024 * 1024 + 37)
        try FilePublication.publish(largeBytes, to: large)
        let largeToken = try FilePublication.inspect(large)!
        let largeBackup = try FilePublication.publish(Data(), to: large, replacing: largeToken, backupDirectory: backups)!
        check(try Data(contentsOf: largeBackup) == largeBytes, "streamed backup covers every chunk and final tail")
        check(try Data(contentsOf: large).isEmpty, "empty replacement is a valid atomic byte publication")
        let emptyToken = try FilePublication.inspect(large)!
        let emptyBackup = try FilePublication.publish(second, to: large, replacing: emptyToken, backupDirectory: backups)!
        check(try Data(contentsOf: emptyBackup).isEmpty, "empty original is backed up and replaced correctly")
        let longName = String(repeating: "Л", count: 80) + ".lectureproject"
        let longDestination = root.appendingPathComponent(longName)
        try FilePublication.publish(first, to: longDestination)
        let longToken = try FilePublication.inspect(longDestination)!
        let longBackup = try FilePublication.publish(second, to: longDestination, replacing: longToken, backupDirectory: backups)!
        let longMetadata = try metadataDecoder.decode(FilePublication.BackupMetadata.self,
            from: Data(contentsOf: FilePublication.metadataURL(for: longBackup)))
        check(longMetadata.originalFilename == longName && longMetadata.originalPath == longToken.url.path,
              "metadata preserves long Unicode filenames without the backup basename truncation")
        // A backup is a copy, not a hard link to an inode which other holders may edit.
        try first.write(to: destination)
        check(try Data(contentsOf: backup) == first, "backup is independent of later target writes")
        let remainingTemps = try fm.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".publication-") }
        check(remainingTemps.isEmpty, "temporary outputs removed after success and failure")
        rejects("remote URLs rejected") { _ = try FilePublication.inspect(URL(string: "https://example.invalid/file")!) }
        print("PASS: \(passed) safe file publication checks. Isolated files; no user state or model requests.")
    }
}
