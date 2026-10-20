import Foundation
import Testing
@testable import ClipDock

struct AppUpdateCheckerTests {
    @Test
    func releaseVersionComparisonHandlesPrefixAndPatchWidth() throws {
        let older = try #require(AppReleaseVersion("0.1.3"))
        let newer = try #require(AppReleaseVersion("v0.1.10"))
        let equalWithPatch = try #require(AppReleaseVersion("0.1.0"))
        let equalWithoutPatch = try #require(AppReleaseVersion("0.1"))

        #expect(newer > older)
        #expect(equalWithPatch == equalWithoutPatch)
        #expect(AppReleaseVersion("not-a-version") == nil)
    }

    @Test
    func updatePlannerRequiresNewerUnskippedRelease() throws {
        let release = AppUpdateRelease(
            version: "v0.1.4",
            releaseName: "ClipDock 0.1.4",
            releaseURL: try #require(URL(string: "https://github.com/appdev/ClipDock/releases/tag/v0.1.4")),
            downloadURL: try #require(URL(string: "https://github.com/appdev/ClipDock/releases/download/v0.1.4/ClipDock.dmg"))
        )

        #expect(AppUpdatePlanner.updateCandidate(
            latest: release,
            currentVersion: "0.1.3",
            skippedVersion: nil
        ) == release)
        #expect(AppUpdatePlanner.updateCandidate(
            latest: release,
            currentVersion: "0.1.4",
            skippedVersion: nil
        ) == nil)
        #expect(AppUpdatePlanner.updateCandidate(
            latest: release,
            currentVersion: "0.1.3",
            skippedVersion: "v0.1.4"
        ) == nil)
        #expect(AppUpdatePlanner.updateCandidate(
            latest: release,
            currentVersion: "0.1.3",
            skippedVersion: "0.1.4"
        ) == nil)
    }

    @Test
    func githubLatestPageURLProvidesReleaseTagWithoutAPIResponseBody() throws {
        let releaseURL = try #require(URL(string: "https://github.com/appdev/ClipDock/releases/tag/v0.2.0"))
        let release = try #require(GitHubAppUpdateProvider.releaseFromLatestPageURL(releaseURL))

        #expect(release.version == "v0.2.0")
        #expect(release.displayVersion == "0.2.0")
        #expect(release.releaseURL == releaseURL)
        #expect(release.downloadURL == releaseURL)
    }

    @Test
    func scheduleWaitsUntilTenWhenCurrentDayCheckIsStillAhead() throws {
        let calendar = fixedCalendar()
        let now = try date("2026-05-20T09:30:00Z")
        let expectedNext = try date("2026-05-20T10:00:00Z")

        let plan = AppUpdatePlanner.schedule(now: now, lastAttemptDate: nil, calendar: calendar)

        #expect(!plan.shouldCheckNow)
        #expect(plan.nextCheckDate == expectedNext)
    }

    @Test
    func scheduleCatchesUpAfterTenWhenTodayWasNotChecked() throws {
        let calendar = fixedCalendar()
        let now = try date("2026-05-20T11:30:00Z")
        let yesterdayAttempt = try date("2026-05-19T10:05:00Z")
        let expectedNext = try date("2026-05-21T10:00:00Z")

        let plan = AppUpdatePlanner.schedule(
            now: now,
            lastAttemptDate: yesterdayAttempt,
            calendar: calendar
        )

        #expect(plan.shouldCheckNow)
        #expect(plan.nextCheckDate == expectedNext)
    }

    @Test
    func scheduleChecksImmediatelyAfterTenWhenNeverAttempted() throws {
        let calendar = fixedCalendar()
        let now = try date("2026-05-20T14:00:00Z")
        let expectedNext = try date("2026-05-21T10:00:00Z")

        let plan = AppUpdatePlanner.schedule(
            now: now,
            lastAttemptDate: nil,
            calendar: calendar
        )

        #expect(plan.shouldCheckNow)
        #expect(plan.nextCheckDate == expectedNext)
    }

    @Test
    func scheduleDoesNotCheckTwiceAfterTodayAttempt() throws {
        let calendar = fixedCalendar()
        let now = try date("2026-05-20T11:30:00Z")
        let todayAttempt = try date("2026-05-20T10:05:00Z")
        let expectedNext = try date("2026-05-21T10:00:00Z")

        let plan = AppUpdatePlanner.schedule(
            now: now,
            lastAttemptDate: todayAttempt,
            calendar: calendar
        )

        #expect(!plan.shouldCheckNow)
        #expect(plan.nextCheckDate == expectedNext)
    }

    @Test
    func scheduleDoesNotCatchUpWhenAlreadyAttemptedEarlierToday() throws {
        let calendar = fixedCalendar()
        let now = try date("2026-05-20T14:00:00Z")
        let todayAttempt = try date("2026-05-20T09:05:00Z")
        let expectedNext = try date("2026-05-21T10:00:00Z")

        let plan = AppUpdatePlanner.schedule(
            now: now,
            lastAttemptDate: todayAttempt,
            calendar: calendar
        )

        #expect(!plan.shouldCheckNow)
        #expect(plan.nextCheckDate == expectedNext)
    }

    @Test
    func preferencesVersionPresentationUsesPassiveUpdateText() throws {
        let release = try makeRelease(version: "v0.2.0")

        let current = PreferencesVersionUpdatePresentation.make(
            status: .upToDate,
            currentVersionText: "0.1.3 (3)"
        )
        #expect(current.detail == "当前应用版本")
        #expect(current.value == "0.1.3 (3)")
        #expect(!current.isActionable)

        let checking = PreferencesVersionUpdatePresentation.make(
            status: .checking,
            currentVersionText: "0.1.3 (3)"
        )
        #expect(checking.detail == "正在检查更新")
        #expect(checking.value == "0.1.3 (3)")
        #expect(!checking.isActionable)

        let available = PreferencesVersionUpdatePresentation.make(
            status: .available(release),
            currentVersionText: "0.1.3 (3)"
        )
        #expect(available.detail.contains("0.2.0"))
        #expect(available.detail.contains("应用内更新"))
        #expect(available.value == "有更新 0.2.0")
        #expect(available.isActionable)
    }

    @Test
    @MainActor
    func settingsCheckReportsAvailabilityWithoutPromptingOrConsumingDailyCheck() async throws {
        let release = try makeRelease(version: "v0.2.0")
        let provider = FakeAppUpdateProvider(release: release)
        let promptPresenter = FakeAppUpdatePromptPresenter()
        let stateStore = InMemoryAppUpdateStateStore()
        let coordinator = AppUpdateCoordinator(
            provider: provider,
            promptPresenter: promptPresenter,
            urlOpener: FakeAppUpdateURLOpener(),
            stateStore: stateStore,
            versionProvider: FakeAppVersionProvider(version: "0.1.3"),
            calendar: fixedCalendar(),
            now: { Date(timeIntervalSince1970: 1_779_276_000) }
        )
        var statuses: [AppUpdateSettingsStatus] = []
        coordinator.onSettingsUpdateStatusChanged = { status in
            statuses.append(status)
        }

        coordinator.checkForSettingsUpdate()
        await waitFor {
            statuses.last == .available(release)
        }

        #expect(statuses.first == .checking)
        #expect(statuses.last == .available(release))
        #expect(provider.requestCount == 1)
        #expect(promptPresenter.requestCount == 0)
        #expect(promptPresenter.requestedRelease == nil)
        #expect(promptPresenter.requestedCurrentVersion == nil)
        #expect(stateStore.lastCheckAttemptDate == nil)
    }

    @Test
    @MainActor
    func settingsCheckRespectsDisabledAutomaticUpdateChecks() async throws {
        let release = try makeRelease(version: "v0.2.0")
        let provider = FakeAppUpdateProvider(release: release)
        let promptPresenter = FakeAppUpdatePromptPresenter()
        let stateStore = InMemoryAppUpdateStateStore()
        stateStore.automaticChecksEnabled = false
        let coordinator = AppUpdateCoordinator(
            provider: provider,
            promptPresenter: promptPresenter,
            urlOpener: FakeAppUpdateURLOpener(),
            stateStore: stateStore,
            versionProvider: FakeAppVersionProvider(version: "0.1.3"),
            calendar: fixedCalendar(),
            now: { Date(timeIntervalSince1970: 1_779_276_000) }
        )
        var statuses: [AppUpdateSettingsStatus] = []
        coordinator.onSettingsUpdateStatusChanged = { status in
            statuses.append(status)
        }

        coordinator.checkForSettingsUpdate()

        #expect(statuses == [.idle])
        #expect(provider.requestCount == 0)
        #expect(promptPresenter.requestCount == 0)
    }

    @Test
    func userDefaultsUpdateStateStoreDefaultsAutomaticChecksOn() throws {
        let suiteName = "ClipDockTests.AppUpdate.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let stateStore = UserDefaultsAppUpdateStateStore(defaults: defaults)

        #expect(stateStore.automaticChecksEnabled)
        stateStore.automaticChecksEnabled = false
        #expect(!stateStore.automaticChecksEnabled)
    }

    @Test
    @MainActor
    func settingsCheckReportsAvailabilityWithoutOpeningDownloadURL() async throws {
        let release = try makeRelease(version: "v0.2.0")
        let provider = FakeAppUpdateProvider(release: release)
        let promptPresenter = FakeAppUpdatePromptPresenter(action: .download)
        let urlOpener = FakeAppUpdateURLOpener()
        let coordinator = AppUpdateCoordinator(
            provider: provider,
            promptPresenter: promptPresenter,
            urlOpener: urlOpener,
            stateStore: InMemoryAppUpdateStateStore(),
            versionProvider: FakeAppVersionProvider(version: "0.1.3"),
            calendar: fixedCalendar(),
            now: { Date(timeIntervalSince1970: 1_779_276_000) }
        )
        var statuses: [AppUpdateSettingsStatus] = []
        coordinator.onSettingsUpdateStatusChanged = { status in
            statuses.append(status)
        }

        coordinator.checkForSettingsUpdate()
        await waitFor {
            statuses.last == .available(release)
        }

        #expect(statuses.last == .available(release))
        #expect(promptPresenter.requestCount == 0)
        #expect(urlOpener.openedURLs.isEmpty)
    }

    @Test
    @MainActor
    func automaticCheckPromptDoesNotBlockSettingsChecksWhileAwaitingAction() async throws {
        let release = try makeRelease(version: "v0.2.0")
        let provider = FakeAppUpdateProvider(release: release)
        let promptPresenter = FakeAppUpdatePromptPresenter(action: nil)
        let urlOpener = FakeAppUpdateURLOpener()
        let stateStore = InMemoryAppUpdateStateStore()
        let installer = FakeAppUpdateInstaller()
        let coordinator = AppUpdateCoordinator(
            provider: provider,
            promptPresenter: promptPresenter,
            urlOpener: urlOpener,
            stateStore: stateStore,
            versionProvider: FakeAppVersionProvider(version: "0.1.3"),
            calendar: fixedCalendar(),
            now: { Date(timeIntervalSince1970: 1_779_282_000) },
            installer: installer
        )
        coordinator.relaunchAfterInstall = {}
        var statuses: [AppUpdateSettingsStatus] = []
        coordinator.onSettingsUpdateStatusChanged = { status in
            statuses.append(status)
        }

        coordinator.start()
        await waitFor {
            promptPresenter.requestCount == 1
        }
        coordinator.checkForSettingsUpdate()
        await waitFor {
            statuses.last == .available(release)
        }

        #expect(promptPresenter.requestedRelease == release)
        #expect(promptPresenter.requestedCurrentVersion == "0.1.3")
        #expect(promptPresenter.pendingActionCount == 1)
        #expect(provider.requestCount == 2)
        #expect(statuses.first == .checking)
        #expect(statuses.last == .available(release))
        #expect(urlOpener.openedURLs.isEmpty)

        promptPresenter.completePendingAction(.download)

        // 「安装更新」现在走应用内热更，不再打开浏览器。
        await waitFor { installer.installedReleases.count == 1 }
        #expect(installer.installedReleases == [release])
        #expect(urlOpener.openedURLs.isEmpty)
    }

    @Test
    @MainActor
    func preferencesVersionRowClickRequestsReleasePageWhenUpdateIsAvailable() throws {
        let release = try makeRelease(version: "v0.2.0")
        let controller = PreferencesWindowController()
        defer { controller.close() }
        var requestedRelease: AppUpdateRelease?
        controller.onUpdateReleaseRequested = { release in
            requestedRelease = release
        }

        controller.updateAppUpdateStatus(.available(release))
        let snapshot = controller.preferencesVersionUpdateSmokeSnapshot()
        #expect(snapshot.presentation.isActionable)
        #expect(snapshot.presentation.value == "有更新 0.2.0")
        #expect(snapshot.automaticUpdateChecksEnabled)

        controller.smokeOpenVersionUpdateForQA()

        #expect(requestedRelease == release)
    }

    @Test
    @MainActor
    func installUpdatePublishesProgressAndCompletes() async throws {
        let release = try makeRelease(version: "v0.2.0")
        let installer = FakeAppUpdateInstaller()
        let coordinator = AppUpdateCoordinator(
            provider: FakeAppUpdateProvider(release: release),
            promptPresenter: FakeAppUpdatePromptPresenter(),
            urlOpener: FakeAppUpdateURLOpener(),
            stateStore: InMemoryAppUpdateStateStore(),
            versionProvider: FakeAppVersionProvider(version: "0.1.3"),
            installer: installer
        )
        var relaunched = false
        coordinator.relaunchAfterInstall = { relaunched = true }
        var states: [AppUpdateInstallState] = []
        coordinator.onInstallStateChanged = { states.append($0) }

        coordinator.installUpdate(release)

        await waitFor { relaunched }
        #expect(installer.installedReleases == [release])
        #expect(states.contains { if case .installed = $0 { return true } else { return false } })
        #expect(states.contains { state in
            if case .downloading(let progress) = state { return progress?.fraction == 0.5 }
            return false
        })
    }

    @Test
    @MainActor
    func installFailureIsReportedAndKeepsReleaseAvailable() async throws {
        let release = try makeRelease(version: "v0.2.0")
        let installer = FakeAppUpdateInstaller()
        installer.error = AppUpdateInstaller.InstallError.verificationFailed("mismatch")
        let coordinator = AppUpdateCoordinator(
            provider: FakeAppUpdateProvider(release: release),
            promptPresenter: FakeAppUpdatePromptPresenter(),
            urlOpener: FakeAppUpdateURLOpener(),
            stateStore: InMemoryAppUpdateStateStore(),
            versionProvider: FakeAppVersionProvider(version: "0.1.3"),
            installer: installer
        )
        var relaunched = false
        coordinator.relaunchAfterInstall = { relaunched = true }
        var failedMessage: String?
        coordinator.onInstallStateChanged = { state in
            if case .failed(let message) = state { failedMessage = message }
        }

        coordinator.installUpdate(release)
        await waitFor { failedMessage != nil }

        #expect(!relaunched)
        #expect(failedMessage?.contains("校验") == true)
        #expect(installer.installedReleases.isEmpty)
    }

    @Test
    @MainActor
    func installProgressIsReflectedInAboutPresentation() throws {
        let release = try makeRelease(version: "v0.2.0")
        let downloading = PreferencesVersionUpdatePresentation.make(
            status: .available(release),
            currentVersionText: "0.1.18 (17)",
            installState: .downloading(AppUpdateInstaller.Progress(fraction: 0.42, statusText: "正在下载更新…"))
        )
        #expect(downloading.isInstalling)
        #expect(downloading.installFraction == 0.42)
        #expect(!downloading.isActionable)

        let failed = PreferencesVersionUpdatePresentation.make(
            status: .available(release),
            currentVersionText: "0.1.18 (17)",
            installState: .failed("SHA-256 不匹配")
        )
        #expect(failed.installFailed)
        #expect(failed.isActionable)
        #expect(failed.detail.contains("SHA-256"))
    }

    private func fixedCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func makeRelease(version: String) throws -> AppUpdateRelease {
        AppUpdateRelease(
            version: version,
            releaseName: "ClipDock \(AppReleaseVersion.displayString(from: version))",
            releaseURL: try #require(URL(string: "https://github.com/appdev/ClipDock/releases/tag/\(version)")),
            downloadURL: try #require(URL(string: "https://github.com/appdev/ClipDock/releases/download/\(version)/ClipDock.dmg"))
        )
    }

    private func date(_ value: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: value))
    }

    @MainActor
    private func waitFor(
        attempts: Int = 100,
        _ predicate: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<attempts {
            if predicate() { return }
            await Task.yield()
        }
    }
}

@MainActor
private final class FakeAppUpdateProvider: AppUpdateProviding {
    let release: AppUpdateRelease
    private(set) var requestCount = 0

    init(release: AppUpdateRelease) {
        self.release = release
    }

    func latestRelease() async throws -> AppUpdateRelease {
        requestCount += 1
        return release
    }
}

@MainActor
private final class FakeAppUpdatePromptPresenter: AppUpdatePromptPresenting {
    let action: AppUpdatePromptAction?
    private(set) var requestCount = 0
    private(set) var requestedRelease: AppUpdateRelease?
    private(set) var requestedCurrentVersion: String?
    private var pendingActions: [(AppUpdatePromptAction) -> Void] = []

    var pendingActionCount: Int {
        pendingActions.count
    }

    init(action: AppUpdatePromptAction? = .skipForNow) {
        self.action = action
    }

    func presentUpdatePrompt(
        release: AppUpdateRelease,
        currentVersion: String,
        onAction: @escaping (AppUpdatePromptAction) -> Void
    ) {
        requestCount += 1
        requestedRelease = release
        requestedCurrentVersion = currentVersion
        if let action {
            onAction(action)
        } else {
            pendingActions.append(onAction)
        }
    }

    func completePendingAction(_ action: AppUpdatePromptAction) {
        guard !pendingActions.isEmpty else { return }
        let onAction = pendingActions.removeFirst()
        onAction(action)
    }
}

@MainActor
private final class FakeAppUpdateInstaller: AppUpdateInstalling {
    private(set) var installedReleases: [AppUpdateRelease] = []
    var error: Error?

    func install(
        release: AppUpdateRelease,
        onProgress: @escaping (AppUpdateInstaller.Progress) -> Void
    ) async throws {
        onProgress(AppUpdateInstaller.Progress(fraction: 0.5, statusText: "下载中"))
        if let error { throw error }
        installedReleases.append(release)
    }
}

private final class FakeAppUpdateURLOpener: AppUpdateURLOpening {
    private(set) var openedURLs: [URL] = []

    func open(_ url: URL) {
        openedURLs.append(url)
    }
}

private final class InMemoryAppUpdateStateStore: AppUpdateStateStoring {
    var lastCheckAttemptDate: Date?
    var skippedVersion: String?
    var automaticChecksEnabled = true
}

private struct FakeAppVersionProvider: AppVersionProviding {
    let version: String

    func currentShortVersion() -> String {
        version
    }
}
