import AppKit
import Foundation

struct AppUpdateRelease: Equatable, Sendable {
    let version: String
    let displayVersion: String
    let releaseName: String?
    let releaseURL: URL
    let downloadURL: URL
    let releaseNotes: String?
    let publishedAt: Date?
    /// 发布资产提供的 SHA-256（来自 `SHA256SUMS`），安装前用于校验。
    let dmgSHA256: String?

    init(
        version: String,
        releaseName: String?,
        releaseURL: URL,
        downloadURL: URL,
        releaseNotes: String? = nil,
        publishedAt: Date? = nil,
        dmgSHA256: String? = nil
    ) {
        self.version = version
        self.displayVersion = AppReleaseVersion.displayString(from: version)
        self.releaseName = releaseName
        self.releaseURL = releaseURL
        self.downloadURL = downloadURL
        self.releaseNotes = releaseNotes
        self.publishedAt = publishedAt
        self.dmgSHA256 = dmgSHA256
    }
}

struct AppReleaseVersion: Comparable, Equatable {
    private let components: [Int]

    init?(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.first.map { $0 == "v" || $0 == "V" } == true
            ? String(trimmed.dropFirst())
            : trimmed
        guard let digitStart = normalized.firstIndex(where: { $0.isNumber }) else {
            return nil
        }

        var numericPrefix = ""
        for character in normalized[digitStart...] {
            guard character.isNumber || character == "." else { break }
            numericPrefix.append(character)
        }

        let parts = numericPrefix
            .split(separator: ".", omittingEmptySubsequences: false)
            .map(String.init)
        guard !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty }),
              parts.allSatisfy({ Int($0) != nil })
        else {
            return nil
        }

        self.components = Self.normalized(parts.compactMap(Int.init))
    }

    static func < (lhs: AppReleaseVersion, rhs: AppReleaseVersion) -> Bool {
        let width = max(lhs.components.count, rhs.components.count)
        for index in 0..<width {
            let lhsComponent = index < lhs.components.count ? lhs.components[index] : 0
            let rhsComponent = index < rhs.components.count ? rhs.components[index] : 0
            if lhsComponent != rhsComponent {
                return lhsComponent < rhsComponent
            }
        }
        return false
    }

    static func displayString(from rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first.map({ $0 == "v" || $0 == "V" }) == true else {
            return trimmed
        }
        return String(trimmed.dropFirst())
    }

    private static func normalized(_ components: [Int]) -> [Int] {
        var result = components
        while result.count > 1 && result.last == 0 {
            result.removeLast()
        }
        return result
    }
}

struct AppUpdateSchedulePlan: Equatable {
    let shouldCheckNow: Bool
    let nextCheckDate: Date
}

enum AppUpdatePlanner {
    static let dailyCheckHour = 10

    static func updateCandidate(
        latest release: AppUpdateRelease,
        currentVersion: String,
        skippedVersion: String?
    ) -> AppUpdateRelease? {
        guard let latestVersion = AppReleaseVersion(release.version),
              let installedVersion = AppReleaseVersion(currentVersion),
              latestVersion > installedVersion
        else {
            return nil
        }

        if let skippedVersion,
           !skippedVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if skippedVersion == release.version {
                return nil
            }
            if let skippedReleaseVersion = AppReleaseVersion(skippedVersion),
               skippedReleaseVersion == latestVersion {
                return nil
            }
        }

        return release
    }

    static func schedule(
        now: Date,
        lastAttemptDate: Date?,
        calendar: Calendar
    ) -> AppUpdateSchedulePlan {
        let todayCheckDate = checkDate(onSameDayAs: now, calendar: calendar)
        let nextCheckDate = nextDailyCheckDate(after: now, calendar: calendar)
        let alreadyAttemptedToday = lastAttemptDate.map {
            calendar.isDate($0, inSameDayAs: now)
        } ?? false

        guard !alreadyAttemptedToday else {
            return AppUpdateSchedulePlan(shouldCheckNow: false, nextCheckDate: nextCheckDate)
        }

        guard now >= todayCheckDate else {
            return AppUpdateSchedulePlan(shouldCheckNow: false, nextCheckDate: todayCheckDate)
        }

        return AppUpdateSchedulePlan(
            shouldCheckNow: true,
            nextCheckDate: nextCheckDate
        )
    }

    private static func checkDate(onSameDayAs date: Date, calendar: Calendar) -> Date {
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = dailyCheckHour
        components.minute = 0
        components.second = 0
        components.nanosecond = 0
        return calendar.date(from: components) ?? date
    }

    private static func nextDailyCheckDate(after date: Date, calendar: Calendar) -> Date {
        let todayCheckDate = checkDate(onSameDayAs: date, calendar: calendar)
        if date < todayCheckDate {
            return todayCheckDate
        }
        return calendar.date(byAdding: .day, value: 1, to: todayCheckDate)
            ?? date.addingTimeInterval(24 * 60 * 60)
    }
}

@MainActor
protocol AppUpdateProviding {
    func latestRelease() async throws -> AppUpdateRelease
}

enum AppUpdateProviderError: Error {
    case invalidResponse
    case invalidStatusCode(Int)
}

struct GitHubAppUpdateProvider: AppUpdateProviding {
    private struct ReleaseResponse: Decodable {
        let tagName: String
        let name: String?
        let htmlURL: URL
        let publishedAt: Date?
        let body: String?
        let assets: [ReleaseAsset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case htmlURL = "html_url"
            case publishedAt = "published_at"
            case body
            case assets
        }
    }

    private struct ReleaseAsset: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    /// 发行版仓库。应用内热更需要从这里取 DMG，必须指向有发布产物的仓库。
    static let repositoryOwner = "zhanghuid"
    static let repositoryName = "ClipDock"

    let endpointURL: URL
    let latestPageURL: URL
    let session: URLSession

    init(
        endpointURL: URL = URL(string: "https://api.github.com/repos/zhanghuid/ClipDock/releases/latest")!,
        latestPageURL: URL = URL(string: "https://github.com/zhanghuid/ClipDock/releases/latest")!,
        session: URLSession = .shared
    ) {
        self.endpointURL = endpointURL
        self.latestPageURL = latestPageURL
        self.session = session
    }

    func latestRelease() async throws -> AppUpdateRelease {
        do {
            return try await latestReleaseFromAPI()
        } catch {
            return try await latestReleaseFromLatestPage()
        }
    }

    private func latestReleaseFromLatestPage() async throws -> AppUpdateRelease {
        var request = URLRequest(url: latestPageURL)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("ClipDock Update Checker", forHTTPHeaderField: "User-Agent")

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppUpdateProviderError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode),
              let releaseURL = httpResponse.url,
              let release = Self.releaseFromLatestPageURL(releaseURL)
        else {
            throw AppUpdateProviderError.invalidStatusCode(httpResponse.statusCode)
        }
        return release
    }

    private func latestReleaseFromAPI() async throws -> AppUpdateRelease {
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ClipDock Update Checker", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppUpdateProviderError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AppUpdateProviderError.invalidStatusCode(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let release = try decoder.decode(ReleaseResponse.self, from: data)
        let dmg = Self.preferredDMGAsset(from: release.assets)
        var checksum: String?
        if let dmg {
            checksum = await Self.checksum(for: dmg.name, from: release.assets)
        }
        return AppUpdateRelease(
            version: release.tagName,
            releaseName: release.name,
            releaseURL: release.htmlURL,
            downloadURL: dmg?.browserDownloadURL
                ?? Self.preferredDownloadURL(from: release.assets, fallback: release.htmlURL),
            releaseNotes: release.body,
            publishedAt: release.publishedAt,
            dmgSHA256: checksum
        )
    }

    /// 优先匹配当前 CPU 架构的 DMG；发行包里同时有 arm64 与 x86_64。
    private static func preferredDMGAsset(from assets: [ReleaseAsset]) -> ReleaseAsset? {
        let dmgAssets = assets.filter { $0.name.lowercased().hasSuffix(".dmg") }
        guard !dmgAssets.isEmpty else { return nil }
        #if arch(arm64)
        let preferredSuffix = "arm64"
        #else
        let preferredSuffix = "x86_64"
        #endif
        return dmgAssets.first { $0.name.lowercased().contains(preferredSuffix) } ?? dmgAssets[0]
    }

    /// 从发布的 `SHA256SUMS` 里取对应 DMG 的摘要；取不到就返回 nil（安装时跳过校验）。
    private static func checksum(for assetName: String, from assets: [ReleaseAsset]) async -> String? {
        guard let manifest = assets.first(where: {
            $0.name.uppercased().hasPrefix("SHA256SUMS")
        }) else {
            return nil
        }

        var request = URLRequest(url: manifest.browserDownloadURL)
        request.timeoutInterval = 15
        request.setValue("ClipDock Updater", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        for line in text.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).filter { !$0.isEmpty }
            guard parts.count >= 2 else { continue }
            let digest = String(parts[0])
            let path = parts.dropFirst().joined(separator: " ")
            // 清单里记录的是 `arm64/ClipDock.app/...` 之类的相对路径，按文件名匹配即可。
            if path.hasSuffix(assetName), digest.count == 64 {
                return digest
            }
        }
        return nil
    }

    nonisolated static func releaseFromLatestPageURL(_ releaseURL: URL) -> AppUpdateRelease? {
        let components = releaseURL.pathComponents
        guard let tagIndex = components.lastIndex(of: "tag") else {
            return nil
        }
        let versionIndex = components.index(after: tagIndex)
        guard components.indices.contains(versionIndex) else {
            return nil
        }

        let version = components[versionIndex]
        guard AppReleaseVersion(version) != nil else {
            return nil
        }
        return AppUpdateRelease(
            version: version,
            releaseName: nil,
            releaseURL: releaseURL,
            downloadURL: releaseURL,
            releaseNotes: nil,
            publishedAt: nil
        )
    }

    private static func preferredDownloadURL(from assets: [ReleaseAsset], fallback: URL) -> URL {
        if let dmg = assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }) {
            return dmg.browserDownloadURL
        }
        if let zip = assets.first(where: { $0.name.lowercased().hasSuffix(".zip") }) {
            return zip.browserDownloadURL
        }
        return assets.first?.browserDownloadURL ?? fallback
    }
}

protocol AppUpdateStateStoring: AnyObject {
    var lastCheckAttemptDate: Date? { get set }
    var skippedVersion: String? { get set }
    var automaticChecksEnabled: Bool { get set }
}

final class UserDefaultsAppUpdateStateStore: AppUpdateStateStoring {
    private enum Key {
        static let lastCheckAttemptDate = "ClipDock.AppUpdate.lastCheckAttemptDate"
        static let skippedVersion = "ClipDock.AppUpdate.skippedVersion"
        static let automaticChecksEnabled = "ClipDock.AppUpdate.automaticChecksEnabled"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var lastCheckAttemptDate: Date? {
        get { defaults.object(forKey: Key.lastCheckAttemptDate) as? Date }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Key.lastCheckAttemptDate)
            } else {
                defaults.removeObject(forKey: Key.lastCheckAttemptDate)
            }
        }
    }

    var skippedVersion: String? {
        get { defaults.string(forKey: Key.skippedVersion) }
        set {
            if let newValue, !newValue.isEmpty {
                defaults.set(newValue, forKey: Key.skippedVersion)
            } else {
                defaults.removeObject(forKey: Key.skippedVersion)
            }
        }
    }

    var automaticChecksEnabled: Bool {
        get {
            guard defaults.object(forKey: Key.automaticChecksEnabled) != nil else {
                return true
            }
            return defaults.bool(forKey: Key.automaticChecksEnabled)
        }
        set {
            defaults.set(newValue, forKey: Key.automaticChecksEnabled)
        }
    }
}

protocol AppVersionProviding {
    func currentShortVersion() -> String
}

struct BundleAppVersionProvider: AppVersionProviding {
    let bundle: Bundle
    let resourceBundle: Bundle

    init(bundle: Bundle = .main, resourceBundle: Bundle = ClipDockResources.bundle) {
        self.bundle = bundle
        self.resourceBundle = resourceBundle
    }

    func currentShortVersion() -> String {
        if let version = nonEmptyString(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")) {
            return version
        }
        if let version = appInfoPlistValue("CFBundleShortVersionString") {
            return version
        }
        return "0.1.0"
    }

    func currentBuildVersion() -> String {
        if let version = nonEmptyString(bundle.object(forInfoDictionaryKey: "CFBundleVersion")) {
            return version
        }
        if let version = appInfoPlistValue("CFBundleVersion") {
            return version
        }
        return "1"
    }

    private func appInfoPlistValue(_ key: String) -> String? {
        guard let url = resourceBundle.url(forResource: "AppInfo", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = plist as? [String: Any]
        else {
            return nil
        }

        return nonEmptyString(dictionary[key])
    }

    private func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String,
              !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return string
    }
}

enum AppUpdatePromptAction {
    case download
    case skipForNow
    case skipVersion
}

enum AppUpdateSettingsStatus: Equatable {
    case idle
    case checking
    case upToDate
    case available(AppUpdateRelease)
}

/// 应用内安装的界面状态。
enum AppUpdateInstallState: Equatable {
    case idle
    case downloading(AppUpdateInstaller.Progress?)
    case installed
    case failed(String)

    var isBusy: Bool {
        if case .downloading = self { return true }
        return false
    }
}

@MainActor
protocol AppUpdatePromptPresenting: AnyObject {
    func presentUpdatePrompt(
        release: AppUpdateRelease,
        currentVersion: String,
        onAction: @escaping (AppUpdatePromptAction) -> Void
    )
}

@MainActor
protocol AppUpdateURLOpening: AnyObject {
    func open(_ url: URL)
}

@MainActor
final class WorkspaceAppUpdateURLOpener: AppUpdateURLOpening {
    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

@MainActor
final class AppUpdateCoordinator {
    private let provider: any AppUpdateProviding
    private let promptPresenter: any AppUpdatePromptPresenting
    private let urlOpener: any AppUpdateURLOpening
    private let stateStore: any AppUpdateStateStoring
    private let versionProvider: any AppVersionProviding
    private let calendar: Calendar
    private let now: () -> Date
    private let installer: any AppUpdateInstalling
    private var installTask: Task<Void, Never>?
    private var installState: AppUpdateInstallState = .idle
    private var isInstalling = false
    private var timer: Timer?
    private var checkTask: Task<Void, Never>?
    private var settingsCheckTask: Task<Void, Never>?
    private var isStarted = false
    private var isChecking = false
    private var isUpdatePromptPending = false

    var onSettingsUpdateStatusChanged: ((AppUpdateSettingsStatus) -> Void)?
    var onInstallStateChanged: ((AppUpdateInstallState) -> Void)?
    /// 测试可替换重启行为；生产环境走 `AppRelauncher`。
    var relaunchAfterInstall: (() -> Void)?

    var automaticChecksEnabled: Bool {
        stateStore.automaticChecksEnabled
    }

    init(
        provider: any AppUpdateProviding = GitHubAppUpdateProvider(),
        promptPresenter: any AppUpdatePromptPresenting = AppUpdatePromptWindowPresenter(),
        urlOpener: any AppUpdateURLOpening = WorkspaceAppUpdateURLOpener(),
        stateStore: any AppUpdateStateStoring = UserDefaultsAppUpdateStateStore(),
        versionProvider: any AppVersionProviding = BundleAppVersionProvider(),
        calendar: Calendar = .autoupdatingCurrent,
        now: @escaping () -> Date = Date.init,
        installer: any AppUpdateInstalling = AppUpdateInstaller()
    ) {
        self.provider = provider
        self.promptPresenter = promptPresenter
        self.urlOpener = urlOpener
        self.stateStore = stateStore
        self.versionProvider = versionProvider
        self.calendar = calendar
        self.now = now
        self.installer = installer
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        scheduleNextCheck(from: now())
    }

    func stop() {
        isStarted = false
        timer?.invalidate()
        timer = nil
        checkTask?.cancel()
        checkTask = nil
        settingsCheckTask?.cancel()
        settingsCheckTask = nil
        installTask?.cancel()
        installTask = nil
        isInstalling = false
        isUpdatePromptPending = false
    }

    func checkForSettingsUpdate() {
        guard stateStore.automaticChecksEnabled else {
            onSettingsUpdateStatusChanged?(.idle)
            return
        }
        settingsCheckTask?.cancel()
        onSettingsUpdateStatusChanged?(.checking)
        settingsCheckTask = Task { @MainActor [weak self] in
            await self?.checkForSettingsUpdateNow()
        }
    }

    func setAutomaticChecksEnabled(_ isEnabled: Bool) {
        guard stateStore.automaticChecksEnabled != isEnabled else { return }
        stateStore.automaticChecksEnabled = isEnabled
        if isEnabled {
            if isStarted {
                scheduleNextCheck(from: now())
            }
        } else {
            timer?.invalidate()
            timer = nil
            checkTask?.cancel()
            checkTask = nil
            settingsCheckTask?.cancel()
            settingsCheckTask = nil
            onSettingsUpdateStatusChanged?(.idle)
        }
    }

    /// 手动检查：忽略「自动检查」开关，也不写 lastCheckAttemptDate。
    func checkManually() async {
        settingsCheckTask?.cancel()
        onSettingsUpdateStatusChanged?(.checking)
        await checkForSettingsUpdateNow()
    }

    func checkForSettingsUpdateNow() async {
        do {
            let currentVersion = versionProvider.currentShortVersion()
            let latestRelease = try await provider.latestRelease()
            guard !Task.isCancelled else { return }

            if let candidate = AppUpdatePlanner.updateCandidate(
                latest: latestRelease,
                currentVersion: currentVersion,
                skippedVersion: nil
            ) {
                onSettingsUpdateStatusChanged?(.available(candidate))
            } else {
                onSettingsUpdateStatusChanged?(.upToDate)
            }
        } catch {
            guard !Task.isCancelled else { return }
            onSettingsUpdateStatusChanged?(.idle)
        }
    }

    func openReleasePage(_ release: AppUpdateRelease) {
        urlOpener.open(release.releaseURL)
    }

    /// 应用内热更：下载 → 校验 → 替换 → 重启。
    /// 失败时通过 `onInstallStateChanged` 报错，不会让应用停在半安装状态。
    func installUpdate(_ release: AppUpdateRelease) {
        guard !isInstalling else { return }
        isInstalling = true
        publishInstallState(.downloading(nil))
        // 从「关于」页触发时没有提示窗口，这里补一个，让进度可见。
        let hasPrompt = (promptPresenter as? AppUpdatePromptWindowPresenter)?.hasActivePrompt ?? false
        if !hasPrompt {
            presentUpdatePromptIfNeeded(for: release)
        }

        installTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isInstalling = false
                self.installTask = nil
            }
            do {
                try await self.installer.install(release: release) { progress in
                    self.publishInstallState(.downloading(progress))
                }
                guard !Task.isCancelled else { return }
                self.publishInstallState(.installed)
                // 给界面一帧时间展示「安装完成」，再重启。
                try? await Task.sleep(nanoseconds: 400_000_000)
                if let relaunchAfterInstall = self.relaunchAfterInstall {
                    relaunchAfterInstall()
                } else {
                    AppRelauncher.relaunch()
                }
            } catch is CancellationError {
                self.publishInstallState(.idle)
            } catch {
                self.publishInstallState(.failed(error.localizedDescription))
            }
        }
    }

    private func publishInstallState(_ state: AppUpdateInstallState) {
        installState = state
        onInstallStateChanged?(state)
        (promptPresenter as? AppUpdatePromptWindowPresenter)?.updateInstallState(state)
    }

    var currentInstallState: AppUpdateInstallState {
        installState
    }

    func cancelInstall() {
        installTask?.cancel()
        installTask = nil
        isInstalling = false
        publishInstallState(.idle)
    }

    func presentUpdatePrompt(for release: AppUpdateRelease) {
        presentUpdatePromptIfNeeded(for: release)
    }

    private func scheduleNextCheck(from date: Date) {
        guard isStarted, stateStore.automaticChecksEnabled else { return }
        timer?.invalidate()
        timer = nil

        let plan = AppUpdatePlanner.schedule(
            now: date,
            lastAttemptDate: stateStore.lastCheckAttemptDate,
            calendar: calendar
        )
        if plan.shouldCheckNow {
            checkTask = Task { @MainActor [weak self] in
                await self?.runScheduledCheck()
            }
        } else {
            scheduleTimer(fireDate: plan.nextCheckDate)
        }
    }

    private func scheduleTimer(fireDate: Date) {
        let timer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.runScheduledCheck()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func runScheduledCheck() async {
        guard isStarted else { return }
        timer?.invalidate()
        timer = nil
        await checkForUpdates()
        scheduleNextCheck(from: now())
    }

    private func checkForUpdates() async {
        guard !isChecking else { return }
        guard !isUpdatePromptPending else { return }
        isChecking = true
        stateStore.lastCheckAttemptDate = now()
        defer { isChecking = false }

        do {
            let latestRelease = try await provider.latestRelease()
            guard !Task.isCancelled,
                  let candidate = AppUpdatePlanner.updateCandidate(
                    latest: latestRelease,
                    currentVersion: versionProvider.currentShortVersion(),
                    skippedVersion: stateStore.skippedVersion
                  )
            else {
                return
            }

            let currentVersion = versionProvider.currentShortVersion()
            presentUpdatePromptIfNeeded(for: candidate, currentVersion: currentVersion)
        } catch {
            return
        }
    }

    private func presentUpdatePromptIfNeeded(
        for release: AppUpdateRelease,
        currentVersion: String? = nil
    ) {
        guard !isUpdatePromptPending else { return }
        isUpdatePromptPending = true
        promptPresenter.presentUpdatePrompt(
            release: release,
            currentVersion: currentVersion ?? versionProvider.currentShortVersion()
        ) { [weak self] action in
            self?.isUpdatePromptPending = false
            self?.handlePromptAction(action, for: release)
        }
    }

    private func handlePromptAction(_ action: AppUpdatePromptAction, for release: AppUpdateRelease) {
        switch action {
        case .download:
            // 可热更时直接应用内安装；下载地址不是 DMG 时退回浏览器下载。
            if release.downloadURL.pathExtension.lowercased() == "dmg" {
                installUpdate(release)
            } else {
                urlOpener.open(release.downloadURL)
            }
        case .skipForNow:
            break
        case .skipVersion:
            stateStore.skippedVersion = release.version
        }
    }
}
