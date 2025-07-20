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
                        isDirectory: false,
                        creationDate: creation,
                        modificationDate: modified,
                        crc32: crc32,
                        uncompressedSize: uncompressedSize,
                        compressedSize: compressedSize,
                        encrypted: encrypted,
                        compressionMethod: 0)
    }
}

public class Engine: CompressionEngine {
    public init() {
    }

    public func listContents(archiveFile: URL, password: String?) async throws -> [UnarchiverEntry] {
        let archive = try Archive(path: archiveFile.path, password: password)
        return try archive.entries().map({ $0.toUnarchiverEntry() })
    }

    public var supportedCompressFormats: Set<CompressionFormat> = Set()
    public var supportedUncompressFormats: Set<CompressionFormat> = Set(arrayLiteral: .rar)

    public func openCompress(options: CompressionOptions) async throws -> any CompressHandle {
        throw ArchiveError.unsupportFeature
    }

    public func openDecompress(options: DecompressionOptions) async throws -> any DecompressHandle {
        try UncompressHandler(options: options)
    }

    public func requiresPassword(archiveFile: URL) async throws -> Bool {
        try Archive(path: archiveFile.path).isPasswordProtected()
    }

    public func testPassword(archiveFile: URL, password: String) async throws -> Bool {
        let archive = try Archive(path: archiveFile.path, password: password)
        /// 有文件是加密的
        return archive.validatePassword()
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
        var result: [(UnarchiverEntry, URL)] = [(UnarchiverEntry, URL)]()
        let ignoreSet: Set<String> = Set(ignoreEntrys?.compactMap({ $0.filePath }) ?? [])
        let archive = self.archive
        let options = self.options
        let progress = self.progress
        _ = try await withUnsafeThrowingContinuation { cc in
            DispatchQueue.global().async {
                do {
                    for entry in try archive.entries() {
                        if ignoreSet.contains(entry.fileName) {
                            continue
                        }
                        let dest = options.destinationDirectory.appendingPathComponent(entry.fileName)
                        result.append((entry.toUnarchiverEntry(),dest))
                        try UncompressHandler.extra(options: options, archive: archive, entry: entry, progress: progress)
                    }
                    cc.resume(returning: true)
                } catch {
                    cc.resume(throwing: error)
                }
            }
        }
        return result
    }

    static func extra(options: DecompressionOptions, archive: Archive, entry: Entry, progress: Progress) throws {
        if entry.fileName.contains("../") {
            return
        }
        /// 文件夹
        if entry.directory {
            if options.createSubfolder {
                try FileManager.default.createDirectory(at: options.destinationDirectory.appendingPathComponent(entry.fileName), withIntermediateDirectories: true)
            }
            return
        }
        /// 文件
        let fileName = entry.fileName
        progress.fileURL = URL(fileURLWithPath: fileName)
        progress.totalUnitCount = Int64(entry.uncompressedSize)
        let fileHandle: FileHandle
        if options.createSubfolder {
            fileHandle = try FileHandle(forWritingTo: options.destinationDirectory.appendingPathComponent(entry.fileName))
        } else {
            fileHandle = try FileHandle(forWritingTo: options.destinationDirectory.appendingPathComponent(URL(fileURLWithPath: entry.fileName).lastPathComponent))
        }
        defer {
            try? fileHandle.close()
        }
        var extraError: (any Error)?
        if let extraError = extraError {
            throw extraError
        }
        progress.completedUnitCount = Int64(entry.uncompressedSize)
    }
}
