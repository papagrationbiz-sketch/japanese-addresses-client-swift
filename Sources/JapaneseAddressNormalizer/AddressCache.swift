import CryptoKit
import Foundation

/// Retention and size limits for the on-device address response cache.
public struct AddressCachePolicy: Sendable, Equatable {
  public var maximumBytes: Int
  public var evictionCandidateAge: TimeInterval
  public var forcedExpiryAge: TimeInterval
  public var municipalityIndexMetadataRetention: TimeInterval

  public init(
    maximumBytes: Int = 100 * 1024 * 1024,
    evictionCandidateAge: TimeInterval = 60 * 24 * 60 * 60,
    forcedExpiryAge: TimeInterval = 90 * 24 * 60 * 60,
    municipalityIndexMetadataRetention: TimeInterval = 180 * 24 * 60 * 60
  ) {
    self.maximumBytes = maximumBytes
    self.evictionCandidateAge = evictionCandidateAge
    self.forcedExpiryAge = forcedExpiryAge
    self.municipalityIndexMetadataRetention = municipalityIndexMetadataRetention
  }

  public static let `default` = AddressCachePolicy()
}

public enum AddressCacheError: Error, Sendable, Equatable, LocalizedError {
  case invalidDirectory
  case invalidPolicy
  public var errorDescription: String? {
    switch self {
    case .invalidDirectory: return "The address cache directory is not available."
    case .invalidPolicy: return "The address cache policy is invalid."
    }
  }
}

/// A disk-backed cache that wraps any `AddressDataSource`.
///
/// Keys include the complete URL and exact half-open byte range. Only requests
/// made through this data source are stored; no national dataset is prefetched.
public actor CachedAddressDataSource: AddressDataSource {
  private struct Metadata: Codable, Sendable {
    let key: String
    let url: String
    let lowerBound: Int?
    let upperBound: Int?
    let statusCode: Int
    let headers: [String: String]
    let byteCount: Int
    let createdAt: Date
    var lastAccessAt: Date
    let isMunicipalityIndex: Bool
  }

  private struct Entry {
    let metadataURL: URL
    let payloadURL: URL
    let metadata: Metadata
    let payloadSize: Int
    let metadataSize: Int
  }

  private struct CacheKey: Sendable {
    let value: String
    let digest: String
    let url: URL
    let range: Range<Int>?

    init(url: URL, range: Range<Int>?) {
      self.url = url
      self.range = range
      let rangeValue = range.map { "\($0.lowerBound)..<\($0.upperBound)" } ?? "none"
      value = "url=\(url.absoluteString)\nrange=\(rangeValue)"
      digest = SHA256.hash(data: Data(value.utf8)).compactMap { String(format: "%02x", $0) }
        .joined()
    }
  }

  private let upstream: any AddressDataSource
  private let directory: URL
  private let policy: AddressCachePolicy
  private let fileManager: FileManager
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()
  private var lastPrunedAt: Date?

  public init(
    upstream: any AddressDataSource, directory: URL, policy: AddressCachePolicy = .default,
    fileManager: FileManager = .default
  ) throws {
    guard directory.isFileURL else { throw AddressCacheError.invalidDirectory }
    guard policy.maximumBytes >= 0, policy.evictionCandidateAge.isFinite,
      policy.evictionCandidateAge >= 0, policy.forcedExpiryAge.isFinite,
      policy.forcedExpiryAge >= policy.evictionCandidateAge,
      policy.municipalityIndexMetadataRetention.isFinite,
      policy.municipalityIndexMetadataRetention >= policy.forcedExpiryAge
    else {
      throw AddressCacheError.invalidPolicy
    }
    self.upstream = upstream
    self.directory = directory
    self.policy = policy
    self.fileManager = fileManager
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  public func response(for url: URL, range: Range<Int>? = nil) async throws -> AddressDataResponse {
    let key = CacheKey(url: url, range: range)
    let now = Date()
    if lastPrunedAt.map({ now.timeIntervalSince($0) >= 24 * 60 * 60 }) ?? true {
      prune(now: now)
    }
    if let cached = read(key: key, now: now) { return cached }
    let response = try await upstream.response(for: url, range: range)
    try ResponseValidator.validate(
      data: response.data, statusCode: response.statusCode, headers: response.headers,
      requestedRange: range)
    store(response: response, key: key, now: now)
    return response
  }

  /// Removes expired entries and enforces the hard byte limit immediately.
  public func prune(now: Date = Date()) {
    lastPrunedAt = now
    let entries = entries()
    for entry in entries {
      let age = max(0, now.timeIntervalSince(entry.metadata.createdAt))
      let expiry =
        entry.metadata.isMunicipalityIndex
        ? policy.municipalityIndexMetadataRetention : policy.forcedExpiryAge
      if age >= expiry || entry.payloadSize != entry.metadata.byteCount { remove(entry: entry) }
    }
    removeOrphanPayloads()
    enforceSizeLimit(now: now)
  }

  private func read(key: CacheKey, now: Date) -> AddressDataResponse? {
    guard let entry = loadEntry(digest: key.digest), entry.metadata.key == key.value else {
      return nil
    }
    let age = max(0, now.timeIntervalSince(entry.metadata.createdAt))
    let expiry =
      entry.metadata.isMunicipalityIndex
      ? policy.municipalityIndexMetadataRetention : policy.forcedExpiryAge
    guard age < expiry, entry.payloadSize == entry.metadata.byteCount else {
      remove(entry: entry)
      return nil
    }
    guard let data = try? Data(contentsOf: entry.payloadURL) else {
      remove(entry: entry)
      return nil
    }
    do {
      try ResponseValidator.validate(
        data: data, statusCode: entry.metadata.statusCode, headers: entry.metadata.headers,
        requestedRange: range(from: entry.metadata))
    } catch {
      remove(entry: entry)
      return nil
    }
    var updated = entry.metadata
    if now.timeIntervalSince(updated.lastAccessAt) >= 24 * 60 * 60 {
      updated.lastAccessAt = now
      try? encoder.encode(updated).write(to: entry.metadataURL, options: .atomic)
    }
    return AddressDataResponse(data: data, statusCode: updated.statusCode, headers: updated.headers)
  }

  private func store(response: AddressDataResponse, key: CacheKey, now: Date) {
    guard response.data.count <= policy.maximumBytes else { return }
    let payloadURL = directory.appendingPathComponent("\(key.digest).payload")
    let metadataURL = directory.appendingPathComponent("\(key.digest).json")
    let metadata = Metadata(
      key: key.value, url: key.url.absoluteString, lowerBound: key.range?.lowerBound,
      upperBound: key.range?.upperBound,
      statusCode: response.statusCode, headers: response.headers, byteCount: response.data.count,
      createdAt: now, lastAccessAt: now,
      isMunicipalityIndex: key.range == nil && key.url.pathExtension.lowercased() == "json")
    do {
      try response.data.write(to: payloadURL, options: .atomic)
      try encoder.encode(metadata).write(to: metadataURL, options: .atomic)
    } catch {
      try? fileManager.removeItem(at: payloadURL)
      try? fileManager.removeItem(at: metadataURL)
      return
    }
    enforceSizeLimit(now: now)
  }

  private func enforceSizeLimit(now: Date) {
    var all = entries()
    var total = all.reduce(0) { $0 + $1.payloadSize + $1.metadataSize }
    guard total > policy.maximumBytes else { return }
    all.sort {
      let leftCandidate =
        now.timeIntervalSince($0.metadata.createdAt) >= policy.evictionCandidateAge
      let rightCandidate =
        now.timeIntervalSince($1.metadata.createdAt) >= policy.evictionCandidateAge
      if leftCandidate != rightCandidate { return leftCandidate }
      return $0.metadata.lastAccessAt < $1.metadata.lastAccessAt
    }
    for entry in all where total > policy.maximumBytes {
      total -= entry.payloadSize + entry.metadataSize
      remove(entry: entry)
    }
  }

  private func entries() -> [Entry] {
    guard
      let urls = try? fileManager.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.fileSizeKey])
    else { return [] }
    var result: [Entry] = []
    for metadataURL in urls
    where metadataURL.pathExtension == "json"
      && isCacheStem(metadataURL.deletingPathExtension().lastPathComponent)
    {
      if let entry = loadEntry(metadataURL: metadataURL) {
        result.append(entry)
      } else {
        let payloadURL = directory.appendingPathComponent(
          "\(metadataURL.deletingPathExtension().lastPathComponent).payload")
        try? fileManager.removeItem(at: metadataURL)
        try? fileManager.removeItem(at: payloadURL)
      }
    }
    return result
  }

  private func loadEntry(digest: String) -> Entry? {
    loadEntry(metadataURL: directory.appendingPathComponent("\(digest).json"))
  }

  private func loadEntry(metadataURL: URL) -> Entry? {
    guard let bytes = try? Data(contentsOf: metadataURL),
      let metadata = try? decoder.decode(Metadata.self, from: bytes)
    else { return nil }
    let payloadURL = directory.appendingPathComponent(
      "\(metadataURL.deletingPathExtension().lastPathComponent).payload")
    let payloadSize = (try? payloadURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    let metadataSize =
      (try? metadataURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? bytes.count
    return Entry(
      metadataURL: metadataURL, payloadURL: payloadURL, metadata: metadata,
      payloadSize: payloadSize, metadataSize: metadataSize)
  }

  private func removeOrphanPayloads() {
    guard
      let urls = try? fileManager.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
    else { return }
    let known = Set(
      urls.filter {
        $0.pathExtension == "json" && isCacheStem($0.deletingPathExtension().lastPathComponent)
      }.map {
        $0.deletingPathExtension().lastPathComponent
      })
    for payload in urls
    where payload.pathExtension == "payload"
      && isCacheStem(payload.deletingPathExtension().lastPathComponent)
      && !known.contains(payload.deletingPathExtension().lastPathComponent)
    { try? fileManager.removeItem(at: payload) }
  }

  private func remove(entry: Entry) {
    try? fileManager.removeItem(at: entry.payloadURL)
    try? fileManager.removeItem(at: entry.metadataURL)
  }
  private func range(from metadata: Metadata) -> Range<Int>? {
    guard let lower = metadata.lowerBound, let upper = metadata.upperBound else { return nil }
    return lower..<upper
  }

  private func isCacheStem(_ value: String) -> Bool {
    value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
  }
}
