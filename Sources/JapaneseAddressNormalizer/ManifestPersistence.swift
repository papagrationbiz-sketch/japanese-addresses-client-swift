import Foundation

public enum LastKnownValidManifestError: Error, Sendable, Equatable, LocalizedError {
  case invalidFileURL
  case persistenceFailed(String)

  public var errorDescription: String? {
    switch self {
    case .invalidFileURL: return "The last-known manifest URL must be a file URL."
    case .persistenceFailed(let message):
      return "The last-known manifest could not be persisted: \(message)"
    }
  }
}

public enum AddressManifestRefreshSource: Sendable, Equatable {
  case network
  case lastKnownValid
}

public struct AddressManifestRefreshResult: Sendable, Equatable {
  public let manifest: AddressManifest
  public let source: AddressManifestRefreshSource

  public init(manifest: AddressManifest, source: AddressManifestRefreshSource) {
    self.manifest = manifest
    self.source = source
  }
}

/// Persists the last schema-valid manifest and provides a refresh contract.
///
/// Every `refresh()` calls the network-backed client. Only a transport/network
/// failure can use the persisted value; HTTP status errors and malformed or
/// unsupported manifests are surfaced and never replace the persisted value.
/// A clear concurrent with refresh advances a generation, preventing a response
/// started before the clear from being written afterwards.
public actor LastKnownValidManifestStore {
  private let fileURL: URL
  private let directory: URL
  private let temporaryFilePrefix: String
  private let fileManager: FileManager
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()
  private var generation: UInt64 = 0

  public init(fileURL: URL, fileManager: FileManager = .default) throws {
    guard fileURL.isFileURL, !fileURL.lastPathComponent.isEmpty else {
      throw LastKnownValidManifestError.invalidFileURL
    }
    self.fileURL = fileURL
    self.directory = fileURL.deletingLastPathComponent()
    self.temporaryFilePrefix = ".\(fileURL.lastPathComponent).manifest-store-"
    self.fileManager = fileManager
    do {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      throw LastKnownValidManifestError.persistenceFailed(String(describing: error))
    }
  }

  /// Attempts an online refresh on every call, falling back only on transport
  /// failure when a previously persisted valid manifest is available.
  public func refresh(using client: AddressManifestClient) async throws
    -> AddressManifestRefreshResult
  {
    let requestGeneration = generation
    do {
      let manifest = try await client.fetchManifest()
      try Task.checkCancellation()
      guard requestGeneration == generation else {
        return AddressManifestRefreshResult(manifest: manifest, source: .network)
      }
      try persist(manifest)
      return AddressManifestRefreshResult(manifest: manifest, source: .network)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      try Task.checkCancellation()
      guard Self.isNetworkFailure(error), let known = loadPersisted() else {
        throw error
      }
      return AddressManifestRefreshResult(manifest: known, source: .lastKnownValid)
    }
  }

  /// Reads a persisted manifest without making a network request. Corrupt or
  /// schema-invalid storage is treated as a cache miss.
  public func load() -> AddressManifest? { loadPersisted() }

  /// Removes only this store's manifest file and temporary files.
  public func clear() async throws {
    generation &+= 1
    do {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      if fileManager.fileExists(atPath: fileURL.path) {
        try fileManager.removeItem(at: fileURL)
      }
      let urls = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      for url in urls where isTemporaryStoreFile(url) {
        try fileManager.removeItem(at: url)
      }
    } catch {
      throw LastKnownValidManifestError.persistenceFailed(String(describing: error))
    }
  }

  private func loadPersisted() -> AddressManifest? {
    guard let data = try? Data(contentsOf: fileURL),
      let manifest = try? decoder.decode(AddressManifest.self, from: data),
      (try? AddressManifestClient.validate(manifest)) != nil
    else { return nil }
    return manifest
  }

  private func persist(_ manifest: AddressManifest) throws {
    try AddressManifestClient.validate(manifest)
    do {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      let temporaryURL = directory.appendingPathComponent(
        "\(temporaryFilePrefix)\(UUID().uuidString).tmp")
      let data = try encoder.encode(manifest)
      try data.write(to: temporaryURL, options: .atomic)
      if fileManager.fileExists(atPath: fileURL.path) {
        _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporaryURL)
      } else {
        try fileManager.moveItem(at: temporaryURL, to: fileURL)
      }
    } catch let error as LastKnownValidManifestError {
      throw error
    } catch {
      throw LastKnownValidManifestError.persistenceFailed(String(describing: error))
    }
  }

  private func isTemporaryStoreFile(_ url: URL) -> Bool {
    let name = url.lastPathComponent
    return name.hasPrefix(temporaryFilePrefix) && name.hasSuffix(".tmp")
  }

  private static func isNetworkFailure(_ error: Error) -> Bool {
    if error is CancellationError { return false }
    if let urlError = error as? URLError { return urlError.code != .cancelled }
    if let transportError = error as? AddressTransportError {
      if case .requestFailed = transportError { return true }
    }
    return false
  }
}
