import Foundation
import Testing
@testable import ClipDock

/// 需要本地 S3 模拟服务（127.0.0.1:9100）时运行：
///   python3 /tmp/s3test/server.py
/// 未启动时自动跳过。
struct S3ClientIntegrationTests {
    private var isServerAvailable: Bool {
        guard let url = URL(string: "http://127.0.0.1:9100/") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 1
        let semaphore = DispatchSemaphore(value: 0)
        var available = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            available = (response as? HTTPURLResponse)?.statusCode == 200
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 2)
        return available
    }

    @Test
    func uploadSendsSignedPutAndDownloadRoundTrips() async throws {
        // 本地模拟服务未启动时跳过，避免 CI 或本地全量测试因环境失败。
        guard isServerAvailable else { return }

        var configuration = S3SyncConfiguration()
        configuration.endpoint = "http://127.0.0.1:9100"
        configuration.bucket = "testbucket"
        configuration.accessKeyID = "testkey"
        configuration.objectKey = "clipdock/library.clipdock"

        let client = S3Client(configuration: configuration, secretAccessKey: "testsecret")

        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("s3test-\(UUID().uuidString).clipdock")
        defer { try? FileManager.default.removeItem(at: source) }
        let payload = Data("clipdock-snapshot-payload".utf8)
        try payload.write(to: source)

        try await client.upload(fileURL: source)

        let downloaded = FileManager.default.temporaryDirectory
            .appendingPathComponent("s3test-\(UUID().uuidString).clipdock")
        defer { try? FileManager.default.removeItem(at: downloaded) }
        try await client.download(to: downloaded)

        #expect(try Data(contentsOf: downloaded) == payload)

        let modified = try await client.head()
        #expect(modified != nil)
    }

    @Test
    func verifyAccessSucceedsForExistingBucket() async throws {
        guard isServerAvailable else { return }

        var configuration = S3SyncConfiguration()
        configuration.endpoint = "http://127.0.0.1:9100"
        configuration.bucket = "testbucket"
        configuration.accessKeyID = "testkey"

        let client = S3Client(configuration: configuration, secretAccessKey: "testsecret")
        try await client.verifyAccess()
    }

    @Test
    func missingCredentialsAreRejectedBeforeNetworkCall() async throws {
        var configuration = S3SyncConfiguration()
        configuration.endpoint = "http://127.0.0.1:9100"
        configuration.bucket = "testbucket"
        configuration.accessKeyID = "testkey"

        let client = S3Client(configuration: configuration, secretAccessKey: "")
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("s3test-\(UUID().uuidString).clipdock")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        await #expect(throws: S3SyncError.missingSecretKey) {
            try await client.upload(fileURL: file)
        }
    }
}
