import Foundation

public struct PreferencesSystemError: LocalizedError, Equatable, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        message
    }
}

public struct PreferencesApplyResult: Equatable, Sendable {
    public let preferences: RustPreferencesDocument
    public let launchAtLoginState: LaunchAtLoginPresentation
    public let accessibilityPermissionState: AccessibilityPermissionPresentation
    public let statusText: String?
    public let shouldRefreshList: Bool

    public init(
        preferences: RustPreferencesDocument,
        launchAtLoginState: LaunchAtLoginPresentation,
        accessibilityPermissionState: AccessibilityPermissionPresentation,
        statusText: String?,
        shouldRefreshList: Bool
    ) {
        self.preferences = preferences
        self.launchAtLoginState = launchAtLoginState
        self.accessibilityPermissionState = accessibilityPermissionState
        self.statusText = statusText
        self.shouldRefreshList = shouldRefreshList
    }
}

public struct PreferencesAccessibilityActionResult: Equatable, Sendable {
    public let accessibilityPermissionState: AccessibilityPermissionPresentation
    public let statusText: String

    public init(
        accessibilityPermissionState: AccessibilityPermissionPresentation,
        statusText: String
    ) {
        self.accessibilityPermissionState = accessibilityPermissionState
        self.statusText = statusText
    }
}

public struct PreferencesSceneSnapshot: Equatable, Sendable {
    public let preferences: RustPreferencesDocument
    public let launchAtLoginState: LaunchAtLoginPresentation
    public let accessibilityPermissionState: AccessibilityPermissionPresentation

    public init(
        preferences: RustPreferencesDocument,
        launchAtLoginState: LaunchAtLoginPresentation,
        accessibilityPermissionState: AccessibilityPermissionPresentation
    ) {
        self.preferences = preferences
        self.launchAtLoginState = launchAtLoginState
        self.accessibilityPermissionState = accessibilityPermissionState
    }
}

@MainActor
public final class PreferencesCoordinator {
    private let loadPreferencesOperation: () -> Result<RustPreferencesResult, RustCoreError>
    private let savePreferencesOperation: (RustPreferencesDocument) -> Result<RustPreferencesResult, RustCoreError>
    private let currentLaunchAtLoginState: () -> LaunchAtLoginPresentation
    private let setLaunchAtLoginEnabled: (Bool) -> Result<LaunchAtLoginPresentation, PreferencesSystemError>
    private let currentAccessibilityPermissionState: () -> AccessibilityPermissionPresentation
    private let openAccessibilitySettings: () -> Void

    public private(set) var currentPreferences = RustPreferencesDocument()

    public init(
        loadPreferencesOperation: @escaping () -> Result<RustPreferencesResult, RustCoreError>,
        savePreferencesOperation: @escaping (RustPreferencesDocument) -> Result<RustPreferencesResult, RustCoreError>,
        currentLaunchAtLoginState: @escaping () -> LaunchAtLoginPresentation,
        setLaunchAtLoginEnabled: @escaping (Bool) -> Result<LaunchAtLoginPresentation, PreferencesSystemError>,
        currentAccessibilityPermissionState: @escaping () -> AccessibilityPermissionPresentation,
        openAccessibilitySettings: @escaping () -> Void
    ) {
        self.loadPreferencesOperation = loadPreferencesOperation
        self.savePreferencesOperation = savePreferencesOperation
        self.currentLaunchAtLoginState = currentLaunchAtLoginState
        self.setLaunchAtLoginEnabled = setLaunchAtLoginEnabled
        self.currentAccessibilityPermissionState = currentAccessibilityPermissionState
        self.openAccessibilitySettings = openAccessibilitySettings
    }

    public func load() -> Result<PreferencesApplyResult, RustCoreError> {
        switch loadPreferencesOperation() {
        case .success(let result):
            let reconciliation = reconcileLaunchAtLoginPreference(
                result.preferences,
                applyRequestedChange: false
            )

            if reconciliation.preferences != result.preferences {
                _ = savePreferencesOperation(reconciliation.preferences)
            }

            currentPreferences = reconciliation.preferences
            return .success(PreferencesApplyResult(
                preferences: reconciliation.preferences,
                launchAtLoginState: reconciliation.launchAtLoginState,
                accessibilityPermissionState: currentAccessibilityPermissionState(),
                statusText: reconciliation.statusText,
                shouldRefreshList: false
            ))

        case .failure(let error):
            return .failure(error)
        }
    }

    public func persist(
        _ preferences: RustPreferencesDocument
    ) -> Result<PreferencesApplyResult, RustCoreError> {
        let launchAtLoginChanged =
            preferences.general.launchAtLogin != currentPreferences.general.launchAtLogin
        let reconciliation = reconcileLaunchAtLoginPreference(
            preferences,
            applyRequestedChange: launchAtLoginChanged
        )

        let previousPreferences = currentPreferences
        switch savePreferencesOperation(reconciliation.preferences) {
        case .success(let result):
            currentPreferences = result.preferences
            return .success(PreferencesApplyResult(
                preferences: result.preferences,
                launchAtLoginState: reconciliation.launchAtLoginState,
                accessibilityPermissionState: currentAccessibilityPermissionState(),
                statusText: reconciliation.statusText ?? AppLocalization.text("preferences.saved", defaultValue: "偏好：已保存"),
                shouldRefreshList: Self.affectsClipboardList(
                    previous: previousPreferences,
                    next: result.preferences
                )
            ))

        case .failure(let error):
            return .failure(error)
        }
    }

    /// 纯外观类偏好不会改变列表内容，无需重查列表。
    /// 其余设置保持不变（影响采集、过滤、保留策略，或与既有行为一致）。
    /// 之前任何一项（含主题、预览浮层等）保存后都会触发一次列表查询。
    private static func affectsClipboardList(
        previous: RustPreferencesDocument,
        next: RustPreferencesDocument
    ) -> Bool {
        previous.general != next.general
            || previous.history != next.history
            || previous.linkPreview != next.linkPreview
            || previous.shortcuts != next.shortcuts
            || previous.ignoreList != next.ignoreList
    }

    public func refreshAccessibilityPermissionState() -> AccessibilityPermissionPresentation {
        currentAccessibilityPermissionState()
    }

    public func currentSceneSnapshot() -> PreferencesSceneSnapshot {
        PreferencesSceneSnapshot(
            preferences: currentPreferences,
            launchAtLoginState: currentLaunchAtLoginState(),
            accessibilityPermissionState: currentAccessibilityPermissionState()
        )
    }

    public func openAccessibilitySettingsFromPreferences() -> PreferencesAccessibilityActionResult {
        let currentState = currentAccessibilityPermissionState()
        let statusText: String

        if currentState.isTrusted {
            statusText = AppLocalization.text("accessibility.status.trusted", defaultValue: "权限：辅助功能已允许")
        } else {
            openAccessibilitySettings()
            statusText = AppLocalization.text("accessibility.status.requestPermission", defaultValue: "权限：请在辅助功能中允许 ClipDock")
        }

        return PreferencesAccessibilityActionResult(
            accessibilityPermissionState: currentAccessibilityPermissionState(),
            statusText: statusText
        )
    }

    private func reconcileLaunchAtLoginPreference(
        _ preferences: RustPreferencesDocument,
        applyRequestedChange: Bool
    ) -> (
        preferences: RustPreferencesDocument,
        launchAtLoginState: LaunchAtLoginPresentation,
        statusText: String?
    ) {
        var resolvedPreferences = preferences
        let currentState = currentLaunchAtLoginState()

        guard applyRequestedChange else {
            resolvedPreferences.general.launchAtLogin = currentState.isOn
            if preferences.general.launchAtLogin != currentState.isOn {
                return (resolvedPreferences, currentState, AppLocalization.format("launchAtLogin.statusFormat", defaultValue: "登录项：%@", currentState.detail))
            }
            return (resolvedPreferences, currentState, nil)
        }

        guard currentState.canChange else {
            resolvedPreferences.general.launchAtLogin = currentState.isOn
            return (resolvedPreferences, currentState, AppLocalization.format("launchAtLogin.statusFormat", defaultValue: "登录项：%@", currentState.detail))
        }

        switch setLaunchAtLoginEnabled(preferences.general.launchAtLogin) {
        case .success(let state):
            resolvedPreferences.general.launchAtLogin = state.isOn
            return (resolvedPreferences, state, AppLocalization.format("launchAtLogin.statusFormat", defaultValue: "登录项：%@", state.detail))

        case .failure(let error):
            let fallbackState = currentLaunchAtLoginState()
            resolvedPreferences.general.launchAtLogin = fallbackState.isOn
            return (resolvedPreferences, fallbackState, AppLocalization.format("launchAtLogin.statusFormat", defaultValue: "登录项：%@", error.localizedDescription))
        }
    }

}
