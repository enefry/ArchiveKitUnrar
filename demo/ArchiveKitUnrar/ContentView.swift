//
//  ContentView.swift
//  ArchiveKitUnrar
//
//  Created by 陈任伟 on 2025/7/13.
//

import ArchiveKitUnrar
import Combine
import SwiftUI
import UniformTypeIdentifiers
import Unrar

extension URL: Identifiable {
    public var id: URL { self }
}

class FileModel: ObservableObject {
    @Published var files: [URL] = []
    @Published var logs: String = ""
    @Published var progress: Double = 0

    @Published var volumes: [URL] = []

    func setVolumes(_ urls: [URL]) {
        volumes = urls
    }

    var progressObj = Progress()
    var cancellables: [AnyCancellable] = []
    init() {
        progressObj.publisher(for: \.fractionCompleted).sink { [weak self] in
            self?.progress = $0
        }.store(in: &cancellables)
    }

    func onPick(_ files: [URL]) {
        let files = files.filter({ $0.isFileURL })
        if !files.isEmpty {
            self.files = files
            append(log: "选择:[\(files.map({ $0.path }).joined(separator: ","))]\n")
        }
        DispatchQueue.global().async {
            self.onTest(files)
        }
    }

    func onTest(_ urls: [URL]) {
        for url in urls {
            onTest(url)
        }
    }

    func onTest(_ url: URL) {
        let start = url.startAccessingSecurityScopedResource()
        defer {
            if start {
                url.stopAccessingSecurityScopedResource()
            }
        }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
            if isDir.boolValue {
                onTest(folder: url)
            } else {
                onTest(file: url)
            }
        }
    }

    func onTest(folder url: URL) {
        append(log: "遍历文件夹：\(url.path)\n--------------------------\n")
        if let files = (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.compactMap({ url.appendingPathComponent($0) }) {
            for file in files {
                onTest(file)
            }
        }
        append(log: "--------------------------")
    }

    func format(enties: [Entry]) -> String {
        let debugDescription: (Entry) -> String = { entry in
            let sizeStr = String(format: "%10ld", entry.uncompressedSize)
            let compStr = String(format: "%10ld", entry.compressedSize)
            let encStr = entry.encrypted ? "*" : " "
            let dirStr = entry.directory ? "<DIR>" : "     "
            let ratioStr = String(format: "%6.2f%%", entry.compressionRatio * 100)
            let methodStr = "\(entry.compressionMethod)"
            let dateStr = DateFormatter.localizedString(from: entry.modified, dateStyle: .short, timeStyle: .short)
            // Adjust the width for fileName to 40 chars, truncate if too long
            let fileNameStr: String
            if entry.fileName.count > 40 {
                let prefix = entry.fileName.prefix(37)
                fileNameStr = "\(prefix)..."
            } else {
                fileNameStr = entry.fileName.padding(toLength: 40, withPad: " ", startingAt: 0)
            }
            return String(format: "%@ %@ %@ %@ %@ %@ %@ %@", sizeStr, compStr, ratioStr, encStr, dirStr, methodStr.padding(toLength: 8, withPad: " ", startingAt: 0), dateStr, fileNameStr)
        }
        var lines = [String]()
        lines.append("")
        return lines.joined(separator: "\n")
    }

    func onTest(file url: URL) {
        let path = url.path
        if !Unrar.Archive.isRARArchive(at: path) {
            append(log: "\(path) 不是 rar 文件")
            return
        }
        do {
            volumes.forEach { url in
                url.startAccessingSecurityScopedResource()
            }
            defer{
                volumes.forEach { url in
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let archive = try Unrar.Archive(fileURL: url, volumes: volumes)
            append(log: "\(path) \n\(archive.debugDescription)")
            let files = try archive.entries()
            append(log: Entry.format(enties: files))
        } catch {
            append(log: "处理文件 \(path) 异常：\(error)")
        }
        append(log: "\n\n")
    }

    func append(log: String) {
        DispatchQueue.main.async {
            self.logs.append(log)
            self.logs.append("\n")
        }
    }

    func extra(_ url: URL) {
        do {
            url.startAccessingSecurityScopedResource()
            volumes.forEach { $0.startAccessingSecurityScopedResource() }
            defer {
                url.stopAccessingSecurityScopedResource()
                volumes.forEach { $0.stopAccessingSecurityScopedResource() }
            }

            let temp = NSTemporaryDirectory().appending("\(UUID().uuidString)/")
            append(log: "解压到：\(temp)")

            let archive = try Archive(fileURL: url, volumes: volumes)
            try archive.extract(destPath: temp, progress: progressObj)
            append(log: "解压完成: \(url)")
        } catch {
            append(log: "解压异常:\(error)")
        }
    }
}

// 方法2：使用 GeometryReader + PreferenceKey（兼容性好）
struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct AdaptiveScrollView<Content: View>: View {
    let maxHeight: CGFloat
    let content: Content
    @State private var contentHeight: CGFloat = 0

    init(maxHeight: CGFloat, @ViewBuilder content: () -> Content) {
        self.maxHeight = maxHeight
        self.content = content()
    }

    var body: some View {
        ScrollViewReader { _ in
            ScrollView {
                content
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: ContentHeightKey.self,
                                value: geo.size.height
                            )
                        }
                    )
            }
            .onScrollGeometryChange(for: CGFloat.self, of: { geo in
                geo.contentSize.height
            }, action: { _, newValue in
                contentHeight = newValue
            })
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(contentHeight, maxHeight))
        }
    }
}

struct ContentView: View {
    @StateObject var model: FileModel = FileModel()
    @State private var isFileImporterPresented = false
    @State private var isVolumeImporterPresented = false

    var body: some View {
        VStack {
            HStack {
                Button("选择文件") {
                    isFileImporterPresented = true
                }
                .fileImporter(
                    isPresented: $isFileImporterPresented,
                    allowedContentTypes: [UTType(mimeType: "application/x-rar-compressed")!, .exe, .folder],
                    allowsMultipleSelection: true
                ) { result in
                    switch result {
                    case let .success(urls):
                        model.onPick(urls)
                    case let .failure(error):
                        model.append(log: "选择文件失败: \(error.localizedDescription)")
                    }
                }
                Button("选择Volumes") {
                    isVolumeImporterPresented = true
                }
                .fileImporter(isPresented: $isVolumeImporterPresented,
                              allowedContentTypes: [UTType(mimeType: "application/x-rar-compressed")!],
                              allowsMultipleSelection: true) { result in
                    switch result {
                    case let .success(urls):
                        model.setVolumes(urls)
                    case let .failure(failure):
                        model.append(log: "选择文件失败：\(failure.localizedDescription)")
                    }
                }
            }
            if model.progress > 0.001 {
                ProgressView("解压进度", value: model.progress)
            }

            AdaptiveScrollView(maxHeight: 400) {
                if !model.files.isEmpty {
                    LazyVStack(spacing: 0) { // 使用LazyVStack提高性能
                        ForEach(model.files) { url in
                            HStack {
                                Text("\(url)")
                                Spacer()
                                Button("解压") {
                                    model.extra(url)
                                }
                            }
                            .padding(4)
                            .frame(maxWidth: .infinity)
                            .background(in: Rectangle())
                            Divider()
                        }
                    }
                }
            }
//            .fixedSize(horizontal: false, vertical: true) // 关键：让ScrollView垂直方向自适应
//            .frame(maxHeight: 400) // 设置最大高度
            Divider()
            ScrollView {
                if !model.logs.isEmpty {
                    Text(model.logs)
                        .font(Font.body.monospaced())
                        .textSelection(.enabled)
                }
            }.defaultScrollAnchor(.bottom)
        }
        .padding()
    }
}
