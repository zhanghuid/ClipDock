import Foundation
import Testing
@testable import ClipDock

struct S3SettingsStoreTests {
    @Test
    @MainActor
    func configurationRoundTripsThroughUserDefaults() {
        let suiteName = "S3SettingsStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = S3SettingsStore(defaults: defaults)
        var configuration = S3SyncConfiguration()
        configuration.endpoint = "https://s3.example.com/"
        configuration.region = "ap-east-1"
        configuration.bucket = "clipdock-sync"
        configuration.accessKeyID = "AKIAEXAMPLE"
        configuration.objectKey = "custom/library.clipdock"
        configuration.usesPathStyle = false

        store.configuration = configuration

        #expect(store.configuration == configuration)
        #expect(store.configuration.isComplete)
    }

    @Test
    @MainActor
    func automaticSyncDefaultsToDisabledThirtyMinutes() {
        let suiteName = "S3SettingsStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = S3SettingsStore(defaults: defaults)

        #expect(!store.isAutomaticSyncEnabled)
        #expect(store.automaticSyncIntervalMinutes == 30)
        #expect(store.lastSyncDate == nil)
    }

    @Test
    @MainActor
    func automaticSyncSettingsPersist() {
        let suiteName = "S3SettingsStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = S3SettingsStore(defaults: defaults)
        store.isAutomaticSyncEnabled = true
        store.automaticSyncIntervalMinutes = 180
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        store.lastSyncDate = date

        let reloaded = S3SettingsStore(defaults: defaults)
        #expect(reloaded.isAutomaticSyncEnabled)
        #expect(reloaded.automaticSyncIntervalMinutes == 180)
        #expect(reloaded.lastSyncDate == date)
    }
}
