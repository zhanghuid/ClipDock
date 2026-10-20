import CryptoKit
import Foundation

/// S3 连接配置。非敏感字段存 UserDefaults，密钥存钥匙串。
struct S3SyncConfiguration: Equatable, Sendable {
    var endpoint: String
    var region: String
    var bucket: String
    var accessKeyID: String
    var objectKey: String
    var usesPathStyle: Bool

    static let defaultObjectKey = "clipdock/library.clipdock"

    init(
        endpoint: String = "",
        region: String = "us-east-1",
        bucket: String = "",
        accessKeyID: String = "",
        objectKey: String = S3SyncConfiguration.defaultObjectKey,
        usesPathStyle: Bool = true
    ) {
        self.endpoint = endpoint
        self.region = region
        self.bucket = bucket
        self.accessKeyID = accessKeyID
        self.objectKey = objectKey
        self.usesPathStyle = usesPathStyle
    }

    var isComplete: Bool {
        missingFieldNames.isEmpty
    }

    /// 还缺少哪些必填字段，用于界面提示（密钥单独由钥匙串判断）。
    var missingFieldNames: [String] {
        var missing: [String] = []
        if normalizedEndpoint.isEmpty {
            missing.append("Endpoint")
        }
        if bucket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.append("Bucket")
        }
        if accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.append("Access Key ID")
        }
        return missing
    }

    var normalizedEndpoint: String {
        var value = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }

    /// 解析 endpoint，允许用户省略 scheme（默认 https）。
    var endpointURL: URL? {
        var value = normalizedEndpoint
        guard !value.isEmpty else { return nil }
        if !value.contains("://") {
            value = "https://\(value)"
        }
        return URL(string: value)
    }
}

enum S3SyncError: LocalizedError, Equatable {
    case incompleteConfiguration
    case invalidEndpoint
    case missingSecretKey
    case invalidResponse
    case http(status: Int, message: String?)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .incompleteConfiguration:
            return AppLocalization.text("s3.error.incomplete", defaultValue: "请先填写 Endpoint、Bucket 与 Access Key")
        case .invalidEndpoint:
            return AppLocalization.text("s3.error.invalidEndpoint", defaultValue: "Endpoint 格式不正确")
        case .missingSecretKey:
            return AppLocalization.text("s3.error.missingSecret", defaultValue: "请先填写 Secret Access Key")
        case .invalidResponse:
            return AppLocalization.text("s3.error.invalidResponse", defaultValue: "服务端返回了无法解析的响应")
        case .http(let status, let message):
            if let message, !message.isEmpty {
                return "HTTP \(status)：\(message)"
            }
            return "HTTP \(status)"
        case .transport(let message):
            return AppLocalization.format("s3.error.transport", defaultValue: "网络请求失败：%@", message)
        }
    }
}

/// 最小可用的 S3 客户端：只需 PUT / GET / HEAD，签名使用 AWS Signature V4。
///
/// 不使用第三方 SDK，按 AWS 官方文档实现签名，兼容 MinIO、Cloudflare R2、
/// Backblaze B2 等 S3 兼容服务。默认使用 path-style 寻址，兼容性最好。
struct S3Client: Sendable {
    let configuration: S3SyncConfiguration
    let secretAccessKey: String
    var session: URLSession = .shared

    func upload(fileURL: URL) async throws {
        let body = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        try await send(method: "PUT", payload: body, contentType: "application/octet-stream")
    }

    func download(to destinationURL: URL) async throws {
        let response = try await send(method: "GET", payload: Data(), contentType: nil)
        try response.data.write(to: destinationURL, options: .atomic)
    }

    /// 远端对象是否存在，以及最后修改时间（用于判断是否需要先下载）。
    func head() async throws -> Date? {
        let response = try await send(method: "HEAD", payload: Data(), contentType: nil, returnsBody: false)
        return response.lastModified
    }

    // MARK: - 请求

    private struct Response {
        let data: Data
        let status: Int
        let lastModified: Date?
    }

    private func send(
        method: String,
        payload: Data,
        contentType: String?,
        returnsBody: Bool = true
    ) async throws -> Response {
        guard configuration.isComplete else {
            throw S3SyncError.incompleteConfiguration
        }
        guard !secretAccessKey.isEmpty else {
            throw S3SyncError.missingSecretKey
        }
        guard let endpointURL = configuration.endpointURL,
              let host = endpointURL.host,
              let url = objectURL(endpointURL: endpointURL) else {
            throw S3SyncError.invalidEndpoint
        }

        let payloadHash = Self.sha256Hex(payload)
        let date = Date()
        let amzDate = Self.amzDateFormatter.string(from: date)
        let dateStamp = Self.dateStampFormatter.string(from: date)

        var headers: [String: String] = [
            "host": hostHeader(endpointURL: endpointURL),
            "x-amz-content-sha256": payloadHash,
            "x-amz-date": amzDate
        ]
        if let contentType {
            headers["content-type"] = contentType
        }

        let signedHeaders = headers.keys.sorted()
        let canonicalHeaders = signedHeaders
            .map { "\($0):\(headers[$0]!.trimmingCharacters(in: .whitespaces))\n" }
            .joined()
        let signedHeadersValue = signedHeaders.joined(separator: ";")

        let canonicalRequest = [
            method,
            Self.canonicalURI(path: url.path),
            Self.canonicalQuery(url.query),
            canonicalHeaders,
            signedHeadersValue,
            payloadHash
        ].joined(separator: "\n")

        let scope = "\(dateStamp)/\(configuration.region)/s3/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            Self.sha256Hex(Data(canonicalRequest.utf8))
        ].joined(separator: "\n")

        let signingKey = Self.signingKey(
            secretAccessKey: secretAccessKey,
            dateStamp: dateStamp,
            region: configuration.region
        )
        let signature = Self.hmacHex(key: signingKey, data: Data(stringToSign.utf8))
        let authorization = "AWS4-HMAC-SHA256 Credential=\(configuration.accessKeyID)/\(scope), "
            + "SignedHeaders=\(signedHeadersValue), Signature=\(signature)"

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60
        for (name, value) in headers where name != "host" {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        if method == "PUT" {
            request.httpBody = payload
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw S3SyncError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw S3SyncError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = data.isEmpty ? nil : String(data: data, encoding: .utf8)
            throw S3SyncError.http(status: http.statusCode, message: message?.prefix(300).description)
        }

        let modified = http.value(forHTTPHeaderField: "Last-Modified").flatMap {
            Self.httpDateFormatter.date(from: $0)
        }
        return Response(data: returnsBody ? data : Data(), status: http.statusCode, lastModified: modified)
    }

    private func objectURL(endpointURL: URL) -> URL? {
        let bucket = configuration.bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = configuration.objectKey.trimmingCharacters(in: .whitespaces)
        guard !bucket.isEmpty, !key.isEmpty else { return nil }

        guard var components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var path = components.path
        while path.hasSuffix("/") {
            path.removeLast()
        }
        if configuration.usesPathStyle {
            path += "/\(bucket)/\(key)"
        } else {
            // 虚拟主机风格：bucket 作为子域。
            guard let host = components.host else { return nil }
            components.host = "\(bucket).\(host)"
            path += "/\(key)"
        }
        components.path = path
        return components.url
    }

    private func hostHeader(endpointURL: URL) -> String {
        let bucket = configuration.bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = endpointURL.host ?? ""
        if configuration.usesPathStyle {
            return endpointURL.port.map { "\(host):\($0)" } ?? host
        }
        let base = "\(bucket).\(host)"
        return endpointURL.port.map { "\(base):\($0)" } ?? base
    }

    // MARK: - SigV4 工具

    private static func canonicalURI(path: String) -> String {
        let encoded = path
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { segment in uriEncode(String(segment)) }
            .joined(separator: "/")
        return encoded.isEmpty ? "/" : encoded
    }

    private static func canonicalQuery(_ query: String?) -> String {
        guard let query, !query.isEmpty else { return "" }
        return query
            .split(separator: "&")
            .map { pair -> String in
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let name = uriEncode(String(parts.first ?? ""))
                let value = parts.count > 1 ? uriEncode(String(parts[1])) : ""
                return "\(name)=\(value)"
            }
            .sorted()
            .joined(separator: "&")
    }

    /// AWS 要求：除 A-Z a-z 0-9 - _ . ~ 之外全部百分号编码，空格编码为 %20。
    static func uriEncode(_ value: String) -> String {
        var allowed = CharacterSet()
        allowed.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func hmac(key: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    static func hmacHex(key: Data, data: Data) -> String {
        hex(hmac(key: key, data: data))
    }

    /// 供测试验证 HMAC 链的中间值。
    static func hmacValueHex(key: Data, data: Data) -> String {
        hmacHex(key: key, data: data)
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// 供测试直接验证 AWS 官方签名派生向量。
    static func signingKeyValue(secretAccessKey: String, dateStamp: String, region: String) -> Data {
        signingKey(secretAccessKey: secretAccessKey, dateStamp: dateStamp, region: region)
    }

    static func signingKey(secretAccessKey: String, dateStamp: String, region: String) -> Data {
        let kDate = hmac(key: Data("AWS4\(secretAccessKey)".utf8), data: Data(dateStamp.utf8))
        let kRegion = hmac(key: kDate, data: Data(region.utf8))
        let kService = hmac(key: kRegion, data: Data("s3".utf8))
        return hmac(key: kService, data: Data("aws4_request".utf8))
    }

    static let amzDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()

    static let dateStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()

    static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
}
