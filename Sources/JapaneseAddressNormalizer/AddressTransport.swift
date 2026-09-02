import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Errors produced while fetching address data over HTTP.
public enum AddressTransportError: Error, Sendable, Equatable, LocalizedError {
  case invalidURL
  case invalidTimeout
  case invalidRange
  case unacceptableStatus(Int)
  case missingContentRange
  case invalidContentRange(String)
  case responseLengthMismatch(expected: Int, actual: Int)
  case rangeMismatch(expected: Range<Int>, actual: Range<Int>)
  case requestFailed(String)

  public var errorDescription: String? {
    switch self {
    case .invalidURL: return "The address data URL is invalid."
    case .invalidTimeout: return "The request timeout must be finite and greater than zero."
    case .invalidRange: return "The requested byte range is invalid."
    case .unacceptableStatus(let status): return "The address data server returned HTTP \(status)."
    case .missingContentRange: return "A partial response did not include Content-Range."
    case .invalidContentRange(let value): return "Content-Range is invalid: \(value)"
    case .responseLengthMismatch(let expected, let actual):
      return "The response length was \(actual) bytes; expected \(expected)."
    case .rangeMismatch(let expected, let actual):
      return "The response range \(actual) did not match requested range \(expected)."
    case .requestFailed(let message): return "Address data request failed: \(message)"
    }
  }
}

/// A production `AddressDataSource` backed by URLSession.
///
/// Range requests use one exact, inclusive HTTP byte range. The public API uses
/// Swift's half-open `Range<Int>` representation (`start..<end`).
public final class URLSessionAddressDataSource: AddressDataSource, @unchecked Sendable {
  private let session: URLSession
  private let requestTimeout: TimeInterval

  public init(session: URLSession = .shared, requestTimeout: TimeInterval = 60) throws {
    guard requestTimeout.isFinite, requestTimeout > 0 else {
      throw AddressTransportError.invalidTimeout
    }
    self.session = session
    self.requestTimeout = requestTimeout
  }

  public func response(for url: URL, range: Range<Int>? = nil) async throws -> AddressDataResponse {
    guard
      let scheme = url.scheme?.lowercased(),
      ["http", "https"].contains(scheme),
      url.host != nil,
      url.user == nil,
      url.password == nil
    else { throw AddressTransportError.invalidURL }

    if let range, range.lowerBound < 0 || range.isEmpty {
      throw AddressTransportError.invalidRange
    }

    var request = URLRequest(url: url)
    request.timeoutInterval = requestTimeout
    if let range {
      request.setValue(
        "bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
    }

    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        throw AddressTransportError.requestFailed("The response was not HTTP.")
      }
      let headers = Self.headers(from: http)
      try ResponseValidator.validate(
        data: data,
        statusCode: http.statusCode,
        headers: headers,
        requestedRange: range
      )
      return AddressDataResponse(data: data, statusCode: http.statusCode, headers: headers)
    } catch let error as AddressTransportError {
      throw error
    } catch {
      throw AddressTransportError.requestFailed(String(describing: error))
    }
  }

  private static func headers(from response: HTTPURLResponse) -> [String: String] {
    response.allHeaderFields.reduce(into: [String: String]()) { result, item in
      guard let key = item.key as? String else { return }
      result[key] = String(describing: item.value)
    }
  }
}

enum ResponseValidator {
  static func validate(
    data: Data,
    statusCode: Int,
    headers: [String: String],
    requestedRange: Range<Int>?
  ) throws {
    guard (200...299).contains(statusCode) else {
      throw AddressTransportError.unacceptableStatus(statusCode)
    }
    if let requestedRange {
      guard statusCode == 206 else { throw AddressTransportError.unacceptableStatus(statusCode) }
      guard let contentRange = header("Content-Range", in: headers) else {
        throw AddressTransportError.missingContentRange
      }
      let actual = try parseContentRange(contentRange)
      guard actual.range == requestedRange else {
        throw AddressTransportError.rangeMismatch(expected: requestedRange, actual: actual.range)
      }
      let expectedLength = requestedRange.count
      guard data.count == expectedLength else {
        throw AddressTransportError.responseLengthMismatch(
          expected: expectedLength, actual: data.count)
      }
    } else if statusCode == 206 {
      throw AddressTransportError.missingContentRange
    }
  }

  private static func header(_ name: String, in headers: [String: String]) -> String? {
    headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
  }

  private static func parseContentRange(_ value: String) throws -> (range: Range<Int>, total: Int) {
    let fields = value.trimmingCharacters(in: .whitespacesAndNewlines).split(
      separator: " ", maxSplits: 1)
    guard fields.count == 2, fields[0].lowercased() == "bytes" else {
      throw AddressTransportError.invalidContentRange(value)
    }
    let pieces = fields[1].split(separator: "/", omittingEmptySubsequences: false)
    guard pieces.count == 2, let total = Int(pieces[1]), total > 0 else {
      throw AddressTransportError.invalidContentRange(value)
    }
    let bounds = pieces[0].split(separator: "-", omittingEmptySubsequences: false)
    guard
      bounds.count == 2,
      let start = Int(bounds[0]),
      let end = Int(bounds[1]),
      start >= 0,
      end >= start,
      end < total
    else { throw AddressTransportError.invalidContentRange(value) }
    return (start..<(end + 1), total)
  }
}
