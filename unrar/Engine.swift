//
//  Engine.swift
//  ArchiveKitUnrar
//
//  Created by chen on 2025/7.
//
import ArchiveKit
import Foundation
import Unrar

public func ArchiveKitRegisterUnrarEngine() {
    CompressionEngineRegistry.shared.register(engine: Engine())
}

extension Unrar.Entry {
    func toUnarchiverEntry() -> UnarchiverEntry {
        UnarchiverEntry(filePath: fileName,
                        isDirectory: directory,
                        creationDate: creation,
                        modificationDate: modified,
                        crc32: crc32,
                        uncompressedSize: uncompressedSize,
                        compressedSize: compressedSize,
                        encrypted: encrypted,
                        compressionMethod: 0)
    }
}

public final class Engine: CompressionEngine {
    public init() {
    }

    public func listContents(archiveFile: URL, password: String?) async throws -> [UnarchiverEntry] {
        let archive = try Archive(path: archiveFile.path, password: password)
        return try archive.entries().map({ $0.toUnarchiverEntry() })
    }

    public let supportedCompressFormats: Set<CompressionFormat> = Set()
    public let supportedUncompressFormats: Set<CompressionFormat> = Set(arrayLiteral: .rar)

    public func openCompress(options: CompressionOptions) async throws -> any CompressHandle {
        throw ArchiveError.unsupportFeature
    }

    public func openDecompress(options: DecompressionOptions) async throws -> any DecompressHandle {
        try UncompressHandler(options: options)
    }

    public func requiresPassword(archiveFile: URL) async throws -> Bool {
        let archive = try Archive(path: archiveFile.path)
        if archive.isHeaderEncrypted {
            return true
        }
        return try archive.entries().contains { $0.encrypted }
    }

    public func testPassword(archiveFile: URL, password: String) async throws -> Bool {
        let archive = try Archive(path: archiveFile.path, password: password)
        let encryptedEntry = try archive.entries().first { $0.encrypted && !$0.directory }
        guard let encryptedEntry else {
            return true
        }
        var receivedData = false
        do {
            try archive.extract(encryptedEntry) { data, progress in
                if !data.isEmpty {
                    receivedData = true
                    progress.cancel()
                }
            }
            return true
        } catch {
            return receivedData
        }
    }
}

class UncompressHandler: DecompressHandle {
    var progress: Progress = Progress()

    var archive: Archive
    var options: DecompressionOptions
    init(options: DecompressionOptions) throws {
        archive = try Archive(path: options.archiveFile.path, password: options.password)
        self.options = options
    }

    func decompress(ignoreEntrys: [UnarchiverEntry]?) async throws -> [(UnarchiverEntry, URL)] {
        let ignoreSet: Set<String> = Set(ignoreEntrys?.compactMap({ $0.filePath }) ?? [])
        let archive = self.archive
        let options = self.options
        let progress = self.progress
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[(UnarchiverEntry, URL)], Error>) in
            DispatchQueue.global().async {
                do {
                    let result = try Self.extractEntries(
                        from: archive,
                        to: options.destinationDirectory,
                        ignoreSet: ignoreSet,
                        overwriteExisting: options.overwriteExisting,
                        progress: progress
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func extractEntries(
        from archive: Archive,
        to destinationDirectory: URL,
        ignoreSet: Set<String>,
        overwriteExisting: Bool,
        progress: Progress
    ) throws -> [(UnarchiverEntry, URL)] {
        let rootURL = destinationDirectory.standardizedFileURL
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let entries = try archive.entries()
        progress.totalUnitCount = Int64(entries.count)
        progress.completedUnitCount = 0

        var result: [(UnarchiverEntry, URL)] = []
        for entry in entries {
            if progress.isCancelled {
                break
            }
            guard !ignoreSet.contains(entry.fileName) else {
                progress.completedUnitCount += 1
                continue
            }
            let destinationURL = try safeDestinationURL(for: entry, rootURL: rootURL)
            result.append((entry.toUnarchiverEntry(), destinationURL))

            if entry.directory {
                try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
            } else {
                try extractFile(
                    entry,
                    from: archive,
                    to: destinationURL,
                    overwriteExisting: overwriteExisting,
                    progress: progress
                )
            }
            progress.completedUnitCount += 1
        }
        return result
    }

    private static func safeDestinationURL(for entry: Entry, rootURL: URL) throws -> URL {
        let destinationURL = rootURL.appendingPathComponent(entry.fileName).standardizedFileURL
        guard destinationURL.path == rootURL.path || destinationURL.path.hasPrefix(rootURL.path + "/") else {
            throw ArchiveError.invalidPath
        }
        return destinationURL
    }

    private static func extractFile(
        _ entry: Entry,
        from archive: Archive,
        to destinationURL: URL,
        overwriteExisting: Bool,
        progress: Progress
    ) throws {
        let parentURL = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            guard overwriteExisting else {
                throw ArchiveError.fileTypeconflict
            }
            try FileManager.default.removeItem(at: destinationURL)
        }
        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)

        let fileHandle = try FileHandle(forWritingTo: destinationURL)
        defer {
            try? fileHandle.close()
        }

        var writeError: Error?
        progress.fileURL = destinationURL
        progress.totalUnitCount = Int64(entry.uncompressedSize)
        progress.completedUnitCount = 0

        try archive.extract(entry) { data, entryProgress in
            guard writeError == nil else {
                entryProgress.cancel()
                return
            }
            do {
                try fileHandle.write(contentsOf: data)
                progress.completedUnitCount = entryProgress.completedUnitCount
                if progress.isCancelled {
                    entryProgress.cancel()
                }
            } catch {
                writeError = error
                entryProgress.cancel()
            }
        }
        if let writeError {
            throw writeError
        }
    }
}
