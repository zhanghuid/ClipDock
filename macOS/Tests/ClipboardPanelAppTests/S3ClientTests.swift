import Foundation
import Testing
@testable import ClipDock

struct S3ClientTests {
    // AWS 官方文档 "Signature Calculation Examples" 的签名派生向量：
    // https://docs.aws.amazon.com/general/latest/gr/signature-v4-examples.html
    @Test
    func signingKeyMatchesAwsReferenceVector() {
        let secret = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
        let key: Data = Self.derive(
            secret: secret,
            dateStamp: "20120215",
            region: "us-east-1"
        )
        #expect(S3Client.hex(key) == "f22dfcb5da3bb8d6c924d26e9bb28e9f96ba691a1b1791d907c06f10ede94251")
        // 中间值：验证 HMAC 链按原始字节串联，而非十六进制字符串。
        let kDate = S3Client.hmacValueHex(key: Data("AWS4wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY".utf8), data: Data("20120215".utf8))
        #expect(kDate == "969fbb94feb542b71ede6f87fe4d5fa29c789342b0f407474670f0c2489e0a0d")
    }

    @Test
    func sha256MatchesKnownDigest() {
        #expect(
            S3Client.sha256Hex(Data("".utf8))
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    @Test
    func uriEncodingFollowsAwsRules() {
        #expect(S3Client.uriEncode("a b") == "a%20b")
        #expect(S3Client.uriEncode("a/b") == "a%2Fb")
        #expect(S3Client.uriEncode("a+b") == "a%2Bb")
        #expect(S3Client.uriEncode("a-_.~") == "a-_.~")
        #expect(S3Client.uriEncode("中文") == "%E4%B8%AD%E6%96%87")
    }

    @Test
    func endpointAcceptsMissingScheme() {
        var configuration = S3SyncConfiguration()
        configuration.endpoint = "s3.example.com/"
        #expect(configuration.normalizedEndpoint == "s3.example.com")
        #expect(configuration.endpointURL?.absoluteString == "https://s3.example.com")
    }

    @Test
    func configurationRequiresEndpointBucketAndKey() {
        var configuration = S3SyncConfiguration()
        #expect(!configuration.isComplete)

        configuration.endpoint = "https://s3.example.com"
        #expect(!configuration.isComplete)

        configuration.bucket = "clipdock"
        #expect(!configuration.isComplete)

        configuration.accessKeyID = "AKIAEXAMPLE"
        #expect(configuration.isComplete)
    }

    @Test
    func defaultObjectKeyIsScopedToClipDock() {
        #expect(S3SyncConfiguration().objectKey == "clipdock/library.clipdock")
    }

    private static func derive(secret: String, dateStamp: String, region: String) -> Data {
        S3Client.signingKeyValue(secretAccessKey: secret, dateStamp: dateStamp, region: region)
    }
}
