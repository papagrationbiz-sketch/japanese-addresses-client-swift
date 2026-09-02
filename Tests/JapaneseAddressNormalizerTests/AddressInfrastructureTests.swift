import Foundation
import XCTest

@testable import JapaneseAddressNormalizer

private final class CountingSource: AddressDataSource, @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var fail = false
  var requests: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  func response(for url: URL, range: Range<Int>?) async throws -> AddressDataResponse {
    let shouldFail = lock.withLock {
      count += 1
      return fail
    }
    if shouldFail { throw AddressTransportError.requestFailed("offline") }
    let data = Data("synthetic-payload".utf8)
    if let range {
      guard range.lowerBound >= 0, range.upperBound <= data.count, !range.isEmpty else {
        throw AddressTransportError.invalidRange
      }
      return AddressDataResponse(
        data: data[range], statusCode: 206,
        headers: [
          "Content-Range": "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(data.count)"
        ]
      )
    }
    return AddressDataResponse(data: data, statusCode: 200)
  }
}

final class AddressInfrastructureTests: XCTestCase {
  func testCacheSeparatesURLAndExactRangeAndServesOffline() async throws {
    let source = CountingSource()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("JapaneseAddressesCache-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = try CachedAddressDataSource(upstream: source, directory: directory)
    let url = URL(string: "https://data.example.invalid/v1/api/ja/synthetic.txt")!

    _ = try await cache.response(for: url, range: 0..<4)
    _ = try await cache.response(for: url, range: 0..<4)
    _ = try await cache.response(for: url, range: 4..<8)
    XCTAssertEqual(source.requests, 2)

    source.fail = true
    let offline = try await cache.response(for: url, range: 0..<4)
    XCTAssertEqual(offline.data, Data("synt".utf8))
  }

  func testResponseValidatorRejectsNonExactRange() throws {
    XCTAssertThrowsError(
      try ResponseValidator.validate(
        data: Data("1234".utf8), statusCode: 206,
        headers: ["Content-Range": "bytes 1-4/10"], requestedRange: 0..<4
      )
    ) { error in
      XCTAssertEqual(
        error as? AddressTransportError, .rangeMismatch(expected: 0..<4, actual: 1..<5))
    }
  }

  func testShardExpiresAtNinetyDaysButMunicipalityIndexIsRetainedToOneHundredEighty() async throws {
    let source = CountingSource()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("JapaneseAddressesRetention-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = try CachedAddressDataSource(upstream: source, directory: directory)
    let shardURL = URL(string: "https://data.example.invalid/v1/api/ja/synthetic.txt")!
    let indexURL = URL(string: "https://data.example.invalid/v1/api/ja/synthetic.json")!
    _ = try await cache.response(for: shardURL)
    _ = try await cache.response(for: indexURL)
    try shiftCreatedAt(in: directory, by: 100 * 24 * 60 * 60)
    source.fail = true
    await cache.prune()
    do {
      _ = try await cache.response(for: shardURL)
      XCTFail("Expired shard should not be served offline")
    } catch {
      // Expected: the shard passed its forced expiry.
    }
    let retained = try await cache.response(for: indexURL)
    XCTAssertEqual(retained.data, Data("synthetic-payload".utf8))

    try shiftCreatedAt(in: directory, by: 181 * 24 * 60 * 60)
    await cache.prune()
    do {
      _ = try await cache.response(for: indexURL)
      XCTFail("Expired municipality index should not be served offline")
    } catch {
      // Expected: the index passed its extended retention period.
    }
  }

  func testHardCapIncludesMetadataAndSixtyDayCandidateIsEvictedFirst() async throws {
    let source = CountingSource()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("JapaneseAddressesCapacity-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let oldURL = URL(string: "https://data.example.invalid/v1/api/ja/old.txt")!
    let freshURL = URL(string: "https://data.example.invalid/v1/api/ja/fresh.txt")!
    let initial = try CachedAddressDataSource(
      upstream: source,
      directory: directory,
      policy: AddressCachePolicy(maximumBytes: 1_000_000)
    )
    _ = try await initial.response(for: oldURL)
    _ = try await initial.response(for: freshURL)
    try shiftCreatedAt(in: directory, by: 61 * 24 * 60 * 60, matching: "old.txt")
    let total = try directoryBytes(directory)

    let constrained = try CachedAddressDataSource(
      upstream: source,
      directory: directory,
      policy: AddressCachePolicy(maximumBytes: total - 1)
    )
    await constrained.prune()
    source.fail = true
    do {
      _ = try await constrained.response(for: oldURL)
      XCTFail("The 60-day eviction candidate should be removed first")
    } catch {
      // Expected: upstream is offline and the old entry was evicted.
    }
    _ = try await constrained.response(for: freshURL)
  }

  func testHardCapCanDeclineAnEntryAndInvalidPolicyIsRejected() async throws {
    let source = CountingSource()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("JapaneseAddressesTinyCapacity-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = try CachedAddressDataSource(
      upstream: source, directory: directory, policy: AddressCachePolicy(maximumBytes: 1))
    let url = URL(string: "https://data.example.invalid/v1/api/ja/tiny.txt")!
    _ = try await cache.response(for: url)
    _ = try await cache.response(for: url)
    XCTAssertEqual(source.requests, 2)
    XCTAssertLessThanOrEqual(try directoryBytes(directory), 1)

    XCTAssertThrowsError(
      try CachedAddressDataSource(
        upstream: source,
        directory: directory,
        policy: AddressCachePolicy(
          evictionCandidateAge: 90, forcedExpiryAge: 60,
          municipalityIndexMetadataRetention: 180))
    ) {
      XCTAssertEqual($0 as? AddressCacheError, .invalidPolicy)
    }
  }

  private func shiftCreatedAt(
    in directory: URL, by seconds: TimeInterval, matching fragment: String? = nil
  ) throws {
    for url in try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil)
    where url.pathExtension == "json" {
      var object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
      if let fragment, !(object["url"] as? String ?? "").contains(fragment) { continue }
      let timestamp = Date(timeIntervalSinceNow: -seconds).timeIntervalSinceReferenceDate
      object["createdAt"] = timestamp
      object["lastAccessAt"] = timestamp
      try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)
    }
  }

  private func directoryBytes(_ directory: URL) throws -> Int {
    try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.fileSizeKey]
    ).reduce(0) { total, url in
      total + (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }
  }

  func testManifestResolvesFixedRelativeVersionAndDoesNotAssumeCoverage() throws {
    let encoded = Data(
      #"{"schemaVersion":1,"current":"revision-1","previous":null,"updatedAt":"2026-01-01T00:00:00.000Z","versions":{"revision-1":{"prefix":"v1","publishedAt":"2026-01-01T00:00:00.000Z","coverage":{"scope":"municipalities","municipalities":["synthetic-region"]}}}}"#
        .utf8)
    let decoded = try JSONDecoder().decode(AddressManifest.self, from: encoded)
    XCTAssertEqual(decoded.current, "revision-1")
    XCTAssertEqual(decoded.versions["revision-1"]?.coverage?.scope, .municipalities)

    let manifest = AddressManifest(
      schemaVersion: 1,
      current: "2026-01",
      updatedAt: "2026-01-01T00:00:00.000Z",
      versions: [
        "2026-01": AddressManifestVersion(
          prefix: "v2026-01", publishedAt: "2026-01-01T00:00:00.000Z")
      ]
    )
    let origin = URL(string: "https://data.example.invalid/manifest.json")!
    let resolved = try AddressManifestClient.resolve(manifest: manifest, origin: origin)
    XCTAssertEqual(
      resolved.baseAPIURL.absoluteString, "https://data.example.invalid/v2026-01/api/ja")
    XCTAssertThrowsError(
      try AddressManifestClient.resolve(
        manifest: manifest, origin: origin, region: "synthetic-region")
    ) {
      XCTAssertEqual($0 as? AddressManifestError, .coverageUnavailable("2026-01"))
    }
    let unsafe = AddressManifest(
      schemaVersion: 1, current: "x", updatedAt: "2026-01-01T00:00:00.000Z",
      versions: [
        "x": AddressManifestVersion(
          prefix: "https://other.invalid", publishedAt: "2026-01-01T00:00:00.000Z")
      ])
    XCTAssertThrowsError(try AddressManifestClient.resolve(manifest: unsafe, origin: origin))
  }

  func testManifestRejectsNonCanonicalMetadataAndOverlappingPrefixes() throws {
    let origin = URL(string: "https://data.example.invalid/manifest.json")!
    let nonCanonical = AddressManifest(
      schemaVersion: 1, current: "a", updatedAt: "2026-01-01T00:00:00Z",
      versions: [
        "a": AddressManifestVersion(
          prefix: "versions/a", publishedAt: "2026-01-01T00:00:00.000Z")
      ])
    XCTAssertThrowsError(
      try AddressManifestClient.resolve(manifest: nonCanonical, origin: origin))

    let overlapping = AddressManifest(
      schemaVersion: 1, current: "a", previous: "b",
      updatedAt: "2026-01-01T00:00:00.000Z",
      versions: [
        "a": AddressManifestVersion(
          prefix: "versions/a", publishedAt: "2026-01-01T00:00:00.000Z"),
        "b": AddressManifestVersion(
          prefix: "versions/a/child", publishedAt: "2026-01-01T00:00:00.000Z"),
      ])
    XCTAssertThrowsError(try AddressManifestClient.resolve(manifest: overlapping, origin: origin))
  }
}
