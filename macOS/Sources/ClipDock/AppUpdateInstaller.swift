import AppKit
import CryptoKit
import Foundation

/// 应用内热更安装器。
///
/// 流程：下载 DMG → 校验 SHA-256（发布清单提供时）→ 挂载 → 复制到临时目录
/// → 原子替换当前 .app → 重新启动。
///
/// 设计约束：
/// - 只接受 `.dmg`，且必须是 DMG 内的单个 `.app`；不执行包内任何脚本。
/// - 替换前把旧包移到一个可回滚的备份路径，失败时可恢复。
/// - 目标位置不可写时（应用在只读卷或被系统保护）给出明确错误，而不是静默失败。
@MainActor
protocol AppUpdateInstalling: AnyObject {
    func install(
        release: AppUpdateRelease,
        onProgress: @escaping (AppUpdateInstaller.Progress) -> Void
    ) async throws
}

@MainActor
final class AppUpdateInstaller: AppUpdateInstalling {
    enum InstallError: LocalizedError {
        case downloadFailed(String)
        case invalidArchive
        case appNotFoundInDiskImage
        case mountFailed(String)
        case verificationFailed(String)
        case notWritable(String)
        case replaceFailed(String)

        var errorDescription: String? {
            switch self {
            case .downloadFailed(let message):
                return AppLocalization.format("update.install.downloadFailed", defaultValue: "下载失败：%@", message)
            case .invalidArchive:
                return AppLocalization.text("update.install.invalidArchive", defaultValue: "更新包格式不受支持，仅支持 DMG")
            case .appNotFoundInDiskImage:
                return AppLocalization.text("update.install.missingApp", defaultValue: "更新包中没有找到 ClipDock.app")
            case .mountFailed(let message):
                return AppLocalization.format("update.install.mountFailed", defaultValue: "无法打开更新包：%@", message)
            case .verificationFailed(let message):
                return AppLocalization.format("update.install.verifyFailed", defaultValue: "更新包校验失败：%@", message)
            case .notWritable(let path):
                return AppLocalization.format(
                    "update.install.notWritable",
                    defaultValue: "无法写入 %@，请把 ClipDock.app 放到有写入权限的位置后重试",
                    path
                )
            case .replaceFailed(let message):
                return AppLocalization.format("update.install.replaceFailed", defaultValue: "替换应用失败：%@", message)
            }
        }
    }

    struct Progress: Equatable {
        var fraction: Double?
        var statusText: String
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// 下载并安装，完成后调用 `relaunch`。任一环节失败都会抛出可展示的错误。
    func install(
        release: AppUpdateRelease,
        onProgress: @escaping (Progress) -> Void
    ) async throws {
        let diskImageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipDock-\(release.displayVersion)-\(UUID().uuidString).dmg")
        var mountedVolume: URL?
        var stagedApp: URL?

        defer {
            if let mountedVolume {
                try? FileManager.default.removeItem(at: mountedVolume)
                Self.detach(volume: mountedVolume)
            }
            try? FileManager.default.removeItem(at: diskImageURL)
            if let stagedApp {
                try? FileManager.default.removeItem(at: stagedApp.deletingLastPathComponent())
            }
        }

        onProgress(Progress(fraction: 0, statusText: AppLocalization.text(
            "update.install.downloading",
            defaultValue: "正在下载更新…"
        )))
        try await download(from: release.downloadURL, to: diskImageURL) { fraction in
            onProgress(Progress(fraction: fraction, statusText: AppLocalization.text(
                "update.install.downloading",
                defaultValue: "正在下载更新…"
            )))
        }

        if let expected = release.dmgSHA256 {
            onProgress(Progress(fraction: nil, statusText: AppLocalization.text(
                "update.install.verifying",
                defaultValue: "正在校验更新包…"
            )))
            let actual = try Self.sha256Hex(of: diskImageURL)
            guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
                throw InstallError.verificationFailed("SHA-256 \(actual.prefix(12))…")
            }
        }

        onProgress(Progress(fraction: nil, statusText: AppLocalization.text(
            "update.install.mounting",
            defaultValue: "正在准备安装…"
        )))
        mountedVolume = try Self.attach(diskImage: diskImageURL)
        guard let mountedVolume else { throw InstallError.mountFailed("no mount point") }

        let sourceApp = try Self.findApp(in: mountedVolume)
        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipDock-staged-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let staged = stagingRoot.appendingPathComponent(sourceApp.lastPathComponent)
        stagedApp = staged
        try FileManager.default.copyItem(at: sourceApp, to: staged)

        onProgress(Progress(fraction: nil, statusText: AppLocalization.text(
            "update.install.installing",
            defaultValue: "正在安装更新…"
        )))
        try Self.replaceCurrentApp(with: staged)
    }

    // MARK: - 下载

    private func download(
        from url: URL,
        to destination: URL,
        onProgress: @escaping (Double?) -> Void
    ) async throws {
        var request = URLRequest(url: url)
        request.setValue("ClipDock Updater", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 120

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw InstallError.downloadFailed("invalid response")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw InstallError.downloadFailed("HTTP \(http.statusCode)")
            }

            let total = http.expectedContentLength
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }

            var buffer = Data()
            buffer.reserveCapacity(1 << 20)
            var received: Int64 = 0
            var lastReported = 0.0

            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= (1 << 20) {
                    try handle.write(contentsOf: buffer)
                    received += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    if total > 0 {
                        let fraction = Double(received) / Double(total)
                        if fraction - lastReported >= 0.01 {
                            lastReported = fraction
                            onProgress(min(fraction, 0.99))
                        }
                    }
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
            }
            onProgress(1)
        } catch let error as InstallError {
            throw error
        } catch {
            throw InstallError.downloadFailed(error.localizedDescription)
        }
    }

    // MARK: - 挂载与替换

    private static func attach(diskImage: URL) throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = [
            "attach", diskImage.path,
            "-nobrowse", "-readonly", "-noautoopen", "-plist"
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = plist as? [String: Any],
              let entities = dictionary["system-entities"] as? [[String: Any]]
        else {
            throw InstallError.mountFailed("hdiutil attach failed")
        }
        guard let mountPoint = entities.compactMap({ $0["mount-point"] as? String }).first else {
            throw InstallError.mountFailed("no mount point")
        }
        return URL(fileURLWithPath: mountPoint)
    }

    private static func detach(volume: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", volume.path, "-force", "-quiet"]
        try? process.run()
        process.waitUntilExit()
    }

    /// DMG 里可能还有 `.DS_Store`、`Applications` 链接等，只取真正的 `.app`。
    private static func findApp(in volume: URL) throws -> URL {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: volume,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let apps = contents.filter { $0.pathExtension.lowercased() == "app" }
        if let exact = apps.first(where: { $0.lastPathComponent == "ClipDock.app" }) {
            return exact
        }
        guard let first = apps.first else {
            throw InstallError.appNotFoundInDiskImage
        }
        return first
    }

    /// 把 staging 里的新包换到当前运行位置。
    ///
    /// 用同卷内的临时目录做中转，保证 `replaceItemAt` 走的是原子重命名而不是跨卷复制。
    private static func replaceCurrentApp(with stagedApp: URL) throws {
        let currentApp = Bundle.main.bundleURL
        guard currentApp.pathExtension.lowercased() == "app" else {
            throw InstallError.notWritable(currentApp.path)
        }

        let parent = currentApp.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw InstallError.notWritable(parent.path)
        }

        let incoming = parent.appendingPathComponent(".ClipDock-incoming-\(UUID().uuidString).app")
        let backup = parent.appendingPathComponent(".ClipDock-backup-\(UUID().uuidString).app")
        defer {
            try? FileManager.default.removeItem(at: incoming)
        }

        do {
            try FileManager.default.copyItem(at: stagedApp, to: incoming)
            // 先移走旧包，再改名新包：任一步失败都可以回滚。
            try FileManager.default.moveItem(at: currentApp, to: backup)
            do {
                try FileManager.default.moveItem(at: incoming, to: currentApp)
            } catch {
                try? FileManager.default.moveItem(at: backup, to: currentApp)
                throw error
            }
            try? FileManager.default.removeItem(at: backup)
        } catch let error as InstallError {
            throw error
        } catch {
            throw InstallError.replaceFailed(error.localizedDescription)
        }
    }

    // MARK: - 校验

    private static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 1 << 20)
            guard !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// 重新启动当前应用。
@MainActor
enum AppRelauncher {
    static func relaunch() {
        let appURL = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, _ in
            NSApp.terminate(nil)
        }
    }
}
