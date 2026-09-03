import Foundation

/// Schema version 1 manifest describing immutable address dataset revisions.
public struct AddressManifest: Codable, Sendable, Equatable {
  public let schemaVersion: Int
  public let current: String
  public let previous: String?
  public let updatedAt: String
  public let versions: [String: AddressManifestVersion]

  public init(
    schemaVersion: Int, current: String, previous: String? = nil, updatedAt: String,
    versions: [String: AddressManifestVersion]
  ) {
    self.schemaVersion = schemaVersion
    self.current = current
    self.previous = previous
    self.updatedAt = updatedAt
    self.versions = versions
  }
}

public struct AddressManifestCoverage: Codable, Sendable, Equatable {
  public enum Scope: String, Codable, Sendable { case national, municipalities }
  public let scope: Scope
  public let municipalities: [String]?
  public init(scope: Scope, municipalities: [String]? = nil) {
    self.scope = scope
    self.municipalities = municipalities
  }
}

/// A fixed dataset revision. `prefix` is retained and validated as metadata;
/// public URLs use the registered version ID at the host root.
public struct AddressManifestVersion: Codable, Sendable, Equatable {
  public let prefix: String
  public let publishedAt: String
  public let sourceUpdatedAt: String?
  public let coverage: AddressManifestCoverage?
  public init(
    prefix: String, publishedAt: String, sourceUpdatedAt: String? = nil,
    coverage: AddressManifestCoverage? = nil
  ) {
    self.prefix = prefix
    self.publishedAt = publishedAt
    self.sourceUpdatedAt = sourceUpdatedAt
    self.coverage = coverage
  }
}

public enum AddressManifestError: Error, Sendable, Equatable, LocalizedError {
  case unsupportedSchemaVersion(Int)
  case emptyManifest
  case versionNotFound(String)
  case invalidVersionPrefix
  case coverageUnavailable(String)
  case regionNotCovered(String)
  case malformedManifest
  public var errorDescription: String? {
    switch self {
    case .unsupportedSchemaVersion(let v):
      return "Unsupported address manifest schema version: \(v)."
    case .emptyManifest: return "The address manifest contains no versions."
    case .versionNotFound(let v): return "Address dataset version was not found: \(v)."
    case .invalidVersionPrefix: return "The address dataset version prefix is invalid."
    case .coverageUnavailable(let v):
      return "Regional coverage is unspecified for dataset version \(v)."
    case .regionNotCovered(let r): return "The requested region is not covered: \(r)."
    case .malformedManifest: return "The address manifest is malformed."
    }
  }
}

public struct ResolvedAddressDataset: Sendable, Equatable {
  public let version: String
  public let baseAPIURL: URL
  public let coverage: AddressManifestCoverage?
  public init(version: String, baseAPIURL: URL, coverage: AddressManifestCoverage?) {
    self.version = version
    self.baseAPIURL = baseAPIURL
    self.coverage = coverage
  }
}

/// Fetches and resolves a schema version 1 manifest.
public struct AddressManifestClient: Sendable {
  public let manifestURL: URL
  private let dataSource: any AddressDataSource

  public init(manifestURL: URL, dataSource: any AddressDataSource) throws {
    guard let scheme = manifestURL.scheme?.lowercased(), ["http", "https"].contains(scheme),
      manifestURL.host != nil,
      manifestURL.user == nil, manifestURL.password == nil, manifestURL.query == nil,
      manifestURL.fragment == nil
    else { throw AddressTransportError.invalidURL }
    self.manifestURL = manifestURL
    self.dataSource = dataSource
  }

  public init(manifestURL: URL, session: URLSession = .shared) throws {
    try self.init(
      manifestURL: manifestURL, dataSource: try URLSessionAddressDataSource(session: session))
  }

  public func fetchManifest() async throws -> AddressManifest {
    let response = try await dataSource.response(for: manifestURL, range: nil)
    try Task.checkCancellation()
    try ResponseValidator.validate(
      data: response.data, statusCode: response.statusCode, headers: response.headers,
      requestedRange: nil)
    do {
      let manifest = try JSONDecoder().decode(AddressManifest.self, from: response.data)
      try Self.validate(manifest)
      return manifest
    } catch let error as AddressManifestError { throw error } catch {
      throw AddressManifestError.malformedManifest
    }
  }

  public func resolve(version requestedVersion: String? = nil, region: String? = nil) async throws
    -> ResolvedAddressDataset
  {
    let manifest = try await fetchManifest()
    return try Self.resolve(
      manifest: manifest, origin: manifestURL, version: requestedVersion, region: region)
  }

  public static func resolve(
    manifest: AddressManifest, origin: URL, version requestedVersion: String? = nil,
    region: String? = nil
  ) throws -> ResolvedAddressDataset {
    try validate(manifest)
    let id = requestedVersion ?? manifest.current
    guard let dataset = manifest.versions[id] else {
      throw AddressManifestError.versionNotFound(id)
    }
    if let region {
      guard let coverage = dataset.coverage else {
        throw AddressManifestError.coverageUnavailable(id)
      }
      switch coverage.scope {
      case .national: break
      case .municipalities:
        guard coverage.municipalities?.contains(region) == true else {
          throw AddressManifestError.regionNotCovered(region)
        }
      }
    }
    return ResolvedAddressDataset(
      version: id, baseAPIURL: try fixedBaseURL(origin: origin, versionID: id),
      coverage: dataset.coverage)
  }

  /// Validates a decoded manifest before it is used or persisted.
  public static func validate(_ manifest: AddressManifest) throws {
    guard manifest.schemaVersion == 1 else {
      throw AddressManifestError.unsupportedSchemaVersion(manifest.schemaVersion)
    }
    guard !manifest.current.isEmpty, !manifest.versions.isEmpty else {
      throw AddressManifestError.emptyManifest
    }
    guard manifest.versions[manifest.current] != nil else {
      throw AddressManifestError.versionNotFound(manifest.current)
    }
    if let previous = manifest.previous, manifest.versions[previous] == nil {
      throw AddressManifestError.versionNotFound(previous)
    }
    guard manifest.previous != manifest.current else {
      throw AddressManifestError.malformedManifest
    }
    try validateMetadata(manifest)
  }

  private static func fixedBaseURL(origin: URL, versionID: String) throws -> URL {
    guard let scheme = origin.scheme?.lowercased(), ["http", "https"].contains(scheme),
      let host = origin.host,
      origin.user == nil, origin.password == nil, origin.query == nil, origin.fragment == nil,
      safeVersionID(versionID)
    else { throw AddressManifestError.invalidVersionPrefix }
    var components = URLComponents()
    components.scheme = scheme
    components.host = host
    components.port = origin.port
    components.path = "/versions/\(versionID)/api/ja"
    guard let url = components.url else { throw AddressManifestError.invalidVersionPrefix }
    return url
  }

  private static func validateMetadata(_ manifest: AddressManifest) throws {
    guard isCanonicalTimestamp(manifest.updatedAt) else {
      throw AddressManifestError.malformedManifest
    }
    for (id, version) in manifest.versions {
      guard safeVersionID(id)
      else {
        throw AddressManifestError.malformedManifest
      }
      guard safePrefix(version.prefix) else { throw AddressManifestError.malformedManifest }
      if !isCanonicalTimestamp(version.publishedAt) {
        throw AddressManifestError.malformedManifest
      }
      if let sourceUpdatedAt = version.sourceUpdatedAt, !isCanonicalTimestamp(sourceUpdatedAt) {
        throw AddressManifestError.malformedManifest
      }
      if let coverage = version.coverage {
        switch coverage.scope {
        case .national:
          guard coverage.municipalities == nil else { throw AddressManifestError.malformedManifest }
        case .municipalities:
          guard let municipalities = coverage.municipalities, !municipalities.isEmpty,
            Set(municipalities).count == municipalities.count,
            municipalities.allSatisfy({
              let parts = $0.split(separator: "/", omittingEmptySubsequences: false)
              return parts.count == 2 && parts.allSatisfy({ !$0.isEmpty })
                && !$0.contains("..") && !$0.contains("\\") && !$0.contains("?")
                && !$0.contains("#")
                && !$0.contains("\0")
                && !$0.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
            })
          else { throw AddressManifestError.malformedManifest }
        }
      }
    }

    let prefixes = manifest.versions.map { (id: $0.key, prefix: $0.value.prefix) }
    for leftIndex in prefixes.indices {
      for rightIndex in prefixes.indices where rightIndex > leftIndex {
        let left = prefixes[leftIndex].prefix
        let right = prefixes[rightIndex].prefix
        if left == right || left.hasPrefix("\(right)/") || right.hasPrefix("\(left)/") {
          throw AddressManifestError.malformedManifest
        }
      }
    }
  }

  private static func safePrefix(_ prefix: String) -> Bool {
    guard (1...512).contains(prefix.count), let first = prefix.first,
      first.isASCII && (first.isLetter || first.isNumber),
      !prefix.hasPrefix("/"), !prefix.hasSuffix("/"),
      !prefix.contains(".."), !prefix.contains("//"), !prefix.contains("\\"),
      !prefix.contains("?"), !prefix.contains("#")
    else { return false }
    return prefix.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
      !$0.isEmpty && $0 != "." && $0 != ".."
        && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }
  }

  private static func safeVersionID(_ value: String) -> Bool {
    guard (1...128).contains(value.count), let first = value.first,
      first.isASCII && (first.isLetter || first.isNumber)
    else { return false }
    return value.allSatisfy {
      $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0))
    }
  }

  private static func isCanonicalTimestamp(_ value: String) -> Bool {
    let characters = Array(value.utf8)
    guard characters.count >= 20, characters.last == 0x5A else { return false }
    let baseLength = 19
    let base = Array(characters.prefix(baseLength))
    guard base.count == baseLength,
      base[4] == 0x2D, base[7] == 0x2D, base[10] == 0x54,
      base[13] == 0x3A, base[16] == 0x3A,
      base.enumerated().allSatisfy({ index, byte in
        [4, 7, 10, 13, 16].contains(index) || (0x30...0x39).contains(byte)
      })
    else { return false }
    let fraction: ArraySlice<UInt8>
    if characters.count == 20 {
      fraction = []
    } else {
      guard characters[19] == 0x2E else { return false }
      fraction = characters[20..<characters.count - 1]
      guard (1...9).contains(fraction.count), fraction.allSatisfy({ (0x30...0x39).contains($0) })
      else { return false }
    }
    func number(_ start: Int, _ end: Int) -> Int? {
      Int(String(decoding: characters[start..<end], as: UTF8.self))
    }
    guard let year = number(0, 4), let month = number(5, 7), let day = number(8, 10),
      let hour = number(11, 13), let minute = number(14, 16), let second = number(17, 19),
      year > 0, (1...12).contains(month), (1...31).contains(day), (0...23).contains(hour),
      (0...59).contains(minute), (0...59).contains(second)
    else { return false }
    var nanosecond = 0
    for byte in fraction { nanosecond = nanosecond * 10 + Int(byte - 0x30) }
    for _ in fraction.count..<9 { nanosecond *= 10 }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    var components = DateComponents()
    components.calendar = calendar
    components.timeZone = calendar.timeZone
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    components.second = second
    components.nanosecond = nanosecond
    guard let date = calendar.date(from: components) else { return false }
    let actual = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
    return actual.year == year && actual.month == month && actual.day == day
      && actual.hour == hour && actual.minute == minute && actual.second == second
  }
}
