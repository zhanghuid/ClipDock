import ClipboardPanelApp
import Foundation

/// S3 同步状态（供界面展示）。
enum S3SyncState: Equatable {
    case idle
    case uploading
    case downloading
    case succeeded(S3SyncOutcome)
    case failed(String)
}

/// 一次同步的结果摘要。
struct S3SyncOutcome: Equatable {
    var direction: S3SyncDirection
    var uploadedCount: Int
    var importedCount: Int
    var skippedCount: Int

    var summary: String {
        switch direction {
        case .upload:
            return AppLocalization.format(
                "s3.status.uploaded",
                defaultValue: "已上传 %lld 条记录",
                uploadedCount
            )
        case .download:
            return AppLocalization.format(
                "s3.status.downloaded",
                defaultValue: "已导入 %lld 条，跳过 %lld 条重复记录",
                importedCount,
                skippedCount
            )
        }
    }
}

enum S3SyncDirection: Equatable {
    case upload
    case download
}

/// 编排 S3 整库快照同步。
///
/// 复用现有备份能力：上传时导出整库为临时 `.clipdock` 文件后 PUT 到 S3；
/// 下载时 GET 后交给 Rust 侧合并导入（按 ID 去重）。
/// 不做远端历史备份，远端始终只有一份当前快照。
@MainActor
final class S3SyncCoordinator {
    private let settings: S3SettingsStore
    private let databaseWorker: ClipboardCoreDatabaseWorker
    private let rustCoreClient: RustCoreClient
    private let appSupportDirectory: () -> URL?

    private var timer: Timer?
    private var syncTask: Task<Void, Never>?
    private var isAutomaticRunning = false

    var onStateChange: ((S3SyncState) -> Void)?
    var onDataImported: (() -> Void)?

    init(
        settings: S3SettingsStore,
        databaseWorker: ClipboardCoreDatabaseWorker,
        rustCoreClient: RustCoreClient,
        appSupportDirectory: @escaping () -> URL?
    ) {
        self.settings = settings
        self.databaseWorker = databaseWorker
        self.rustCoreClient = rustCoreClient
        self.appSupportDirectory = appSupportDirectory
    }

    var isBusy: Bool {
        syncTask != nil
    }

    // MARK: - 手动操作

    func upload() {
        run(direction: .upload)
    }

    func download() {
        run(direction: .download)
    }

    /// 双向同步：先拉取合并远端，再上传合并后的整库。
    /// 这样多设备不会互相覆盖掉对方新增的条目。
    func synchronize() {
        runTwoWay()
    }

    func cancel() {
        syncTask?.cancel()
        syncTask = nil
        onStateChange?(.idle)
    }

    // MARK: - 定时同步

    /// 根据设置启动或重启定时器。没有完整配置时不会启动。
    func refreshAutomaticSync() {
        stopAutomaticSync()
        guard settings.isAutomaticSyncEnabled,
              settings.configuration.isComplete,
              settings.hasSecretAccessKey else {
            return
        }
        let interval = TimeInterval(settings.automaticSyncIntervalMinutes * 60)
        guard interval > 0 else { return }

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.runAutomaticSyncIfNeeded()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stopAutomaticSync() {
        timer?.invalidate()
        timer = nil
    }

    private func runAutomaticSyncIfNeeded() {
        guard !isAutomaticRunning, syncTask == nil else { return }
        guard settings.configuration.isComplete, settings.hasSecretAccessKey else { return }
        isAutomaticRunning = true
        runTwoWay { [weak self] in
            self?.isAutomaticRunning = false
        }
    }

    // MARK: - 执行

    private func run(direction: S3SyncDirection) {
        guard syncTask == nil else { return }
        onStateChange?(direction == .upload ? .uploading : .downloading)

        syncTask = Task { [weak self] in
            guard let self else { return }
            defer { self.syncTask = nil }
            do {
                let outcome = try await self.perform(direction: direction)
                guard !Task.isCancelled else { return }
                self.settings.lastSyncDate = Date()
                self.onStateChange?(.succeeded(outcome))
            } catch is CancellationError {
                self.onStateChange?(.idle)
            } catch {
                self.onStateChange?(.failed(Self.describe(error)))
            }
        }
    }

    private func runTwoWay(completion: (() -> Void)? = nil) {
        guard syncTask == nil else { return }
        onStateChange?(.downloading)

        syncTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.syncTask = nil
                completion?()
            }
            do {
                // 先合并远端，避免上传覆盖其他设备新增的条目。
                let downloaded = try await self.perform(direction: .download)
                guard !Task.isCancelled else { return }
                let uploaded = try await self.perform(direction: .upload)
                guard !Task.isCancelled else { return }

                self.settings.lastSyncDate = Date()
                self.onStateChange?(.succeeded(S3SyncOutcome(
                    direction: .upload,
                    uploadedCount: uploaded.uploadedCount,
                    importedCount: downloaded.importedCount,
                    skippedCount: downloaded.skippedCount
                )))
            } catch is CancellationError {
                self.onStateChange?(.idle)
            } catch {
                self.onStateChange?(.failed(Self.describe(error)))
            }
        }
    }

    private func perform(direction: S3SyncDirection) async throws -> S3SyncOutcome {
        guard let appSupportURL = appSupportDirectory() else {
            throw S3SyncError.incompleteConfiguration
        }
        let configuration = settings.configuration
        guard configuration.isComplete else {
            throw S3SyncError.incompleteConfiguration
        }
        let secret = settings.secretAccessKey
        guard !secret.isEmpty else {
            throw S3SyncError.missingSecretKey
        }
        let client = S3Client(configuration: configuration, secretAccessKey: secret)

        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipdock-s3-\(UUID().uuidString).clipdock")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        switch direction {
        case .upload:
            // 先导出到临时文件（Rust 侧保证一致性快照），再上传。
            let exportResult = await databaseWorker.transferBackup(
                client: rustCoreClient,
                appSupportURL: appSupportURL,
                fileURL: temporaryURL,
                importing: false
            )
            let exported = try exportResult.get()
            try await client.upload(fileURL: temporaryURL)
            return S3SyncOutcome(
                direction: .upload,
                uploadedCount: Int(exported.exportedCount),
                importedCount: 0,
                skippedCount: 0
            )

        case .download:
            guard try await client.head() != nil else {
                // 远端还没有快照，视为空库，不算失败。
                return S3SyncOutcome(direction: .download, uploadedCount: 0, importedCount: 0, skippedCount: 0)
            }
            try await client.download(to: temporaryURL)
            let importResult = await databaseWorker.transferBackup(
                client: rustCoreClient,
                appSupportURL: appSupportURL,
                fileURL: temporaryURL,
                importing: true
            )
            let imported = try importResult.get()
            onDataImported?()
            return S3SyncOutcome(
                direction: .download,
                uploadedCount: 0,
                importedCount: Int(imported.importedCount),
                skippedCount: Int(imported.skippedCount)
            )
        }
    }

    private static func describe(_ error: Error) -> String {
        if let s3Error = error as? S3SyncError {
            return s3Error.errorDescription ?? "\(s3Error)"
        }
        if let rustError = error as? RustCoreError {
            return rustError.message
        }
        return error.localizedDescription
    }
}
