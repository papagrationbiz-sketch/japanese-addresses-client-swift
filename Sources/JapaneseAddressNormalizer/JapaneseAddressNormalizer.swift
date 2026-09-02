import Foundation
@preconcurrency import JavaScriptCore

/// A response returned by an address data provider.
public struct AddressDataResponse: Sendable, Equatable {
  public let data: Data
  public let statusCode: Int
  public let headers: [String: String]

  public init(data: Data, statusCode: Int, headers: [String: String] = [:]) {
    self.data = data
    self.statusCode = statusCode
    self.headers = headers
  }
}

/// Supplies the JSON and byte ranges requested by the bundled normalizer.
/// The package intentionally does not provide a URLSession or another network client.
public protocol AddressDataSource: Sendable {
  func response(for url: URL, range: Range<Int>?) async throws -> AddressDataResponse
}

public struct AddressPoint: Sendable, Equatable {
  public let latitude: Double
  public let longitude: Double
  public let level: Int

  public init(latitude: Double, longitude: Double, level: Int) {
    self.latitude = latitude
    self.longitude = longitude
    self.level = level
  }
}

public struct NormalizedAddress: Sendable, Equatable {
  public let prefecture: String?
  public let city: String?
  public let town: String?
  public let address: String?
  public let other: String
  public let level: Int
  public let point: AddressPoint?

  public init(
    prefecture: String?,
    city: String?,
    town: String?,
    address: String?,
    other: String,
    level: Int,
    point: AddressPoint?
  ) {
    self.prefecture = prefecture
    self.city = city
    self.town = town
    self.address = address
    self.other = other
    self.level = level
    self.point = point
  }
}

public enum JapaneseAddressError: Error, Sendable, Equatable, LocalizedError {
  case emptyInput
  case invalidLevel(Int)
  case invalidBaseURL
  case resourceUnavailable
  case scriptEvaluationFailed
  case invalidResponse
  case dataSourceFailure(String)

  public var errorDescription: String? {
    switch self {
    case .emptyInput: return "Address input must not be empty."
    case .invalidLevel(let level):
      return "Normalization level must be between 0 and 8, not \(level)."
    case .invalidBaseURL: return "The base API URL is invalid."
    case .resourceUnavailable: return "The bundled normalizer resource is unavailable."
    case .scriptEvaluationFailed: return "The bundled normalizer could not be evaluated."
    case .invalidResponse: return "The normalizer returned an invalid response."
    case .dataSourceFailure(let message): return "Address data request failed: \(message)"
    }
  }
}

private final class JavaScriptContextBox: @unchecked Sendable {
  let value: JSContext

  init(_ value: JSContext) {
    self.value = value
  }
}

private final class JavaScriptValueBox: @unchecked Sendable {
  let value: JSValue?

  init(_ value: JSValue?) {
    self.value = value
  }
}

private final class ContinuationBox<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var resumed = false
  private let continuation: CheckedContinuation<Value, Error>

  init(_ continuation: CheckedContinuation<Value, Error>) {
    self.continuation = continuation
  }

  func resume(returning value: sending Value) {
    lock.lock()
    guard !resumed else {
      lock.unlock()
      return
    }
    resumed = true
    lock.unlock()
    continuation.resume(returning: value)
  }

  func resume(throwing error: Error) {
    lock.lock()
    guard !resumed else {
      lock.unlock()
      return
    }
    resumed = true
    lock.unlock()
    continuation.resume(throwing: error)
  }
}

private final class CancellationRelay<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var isCancelled = false
  private var continuation: ContinuationBox<Value>?

  func install(_ continuation: ContinuationBox<Value>) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !isCancelled else { return false }
    self.continuation = continuation
    return true
  }

  func cancel() {
    lock.lock()
    isCancelled = true
    let continuation = self.continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume(throwing: CancellationError())
  }
}

private final class ExecutorState: @unchecked Sendable {
  let ready = DispatchSemaphore(value: 0)
  var runLoop: CFRunLoop?
}

private final class JavaScriptExecutor: @unchecked Sendable {
  private let state: ExecutorState
  private let thread: Thread

  init() {
    let state = ExecutorState()
    self.state = state
    thread = Thread { [state] in
      state.runLoop = CFRunLoopGetCurrent()
      state.ready.signal()
      while !Thread.current.isCancelled {
        _ = CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.1, true)
      }
    }
    thread.name = "JapaneseAddressNormalizer.JavaScript"
    thread.start()
    state.ready.wait()
  }

  func perform(_ block: @escaping @Sendable () -> Void) {
    guard let runLoop = state.runLoop else { return }
    CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
    CFRunLoopWakeUp(runLoop)
  }

  func sync<Value>(_ body: @escaping @Sendable () throws -> Value) throws -> Value {
    let result = SynchronousResult<Value>()
    perform {
      do {
        result.set(.success(try body()))
      } catch {
        result.set(.failure(error))
      }
    }
    return try result.wait()
  }

  deinit {
    thread.cancel()
    if let runLoop = state.runLoop {
      CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {}
      CFRunLoopStop(runLoop)
      CFRunLoopWakeUp(runLoop)
    }
  }
}

private final class SynchronousResult<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var result: Result<Value, Error>?
  private let semaphore = DispatchSemaphore(value: 0)

  func set(_ result: Result<Value, Error>) {
    lock.lock()
    self.result = result
    lock.unlock()
    semaphore.signal()
  }

  func wait() throws -> Value {
    semaphore.wait()
    lock.lock()
    let result = self.result!
    lock.unlock()
    return try result.get()
  }
}

/// Thread-safe Swift access to the upstream JavaScript normalizer.
/// Every JavaScriptCore operation is serialized on one private run-loop thread.
public final class JapaneseAddressNormalizer: @unchecked Sendable {
  private final class Runtime: @unchecked Sendable {
    let executor: JavaScriptExecutor
    let context: JavaScriptContextBox
    let normalize: JavaScriptValueBox
    let dataSource: any AddressDataSource

    init(baseAPIURL: URL, dataSource: any AddressDataSource) throws {
      let executor = JavaScriptExecutor()
      self.executor = executor
      self.dataSource = dataSource
      let initialized = try executor.sync {
        () throws -> (JavaScriptContextBox, JavaScriptValueBox) in
        guard let context = JSContext() else {
          throw JapaneseAddressError.scriptEvaluationFailed
        }
        let contextBox = JavaScriptContextBox(context)
        let setupScript = """
          (function() {
            globalThis.URL = function(value) { this.href = String(value); };
            globalThis.URL.prototype.toString = function() { return this.href; };
            globalThis.__japaneseAddressesPending = Object.create(null);
            globalThis.__japaneseAddressesCreateRequest = function(id) {
              return new Promise(function(resolve, reject) {
                globalThis.__japaneseAddressesPending[id] = { resolve: resolve, reject: reject };
              });
            };
            globalThis.__japaneseAddressesDeliver = function(id, ok, body, status, headers, error) {
              var pending = globalThis.__japaneseAddressesPending[id];
              if (!pending) return;
              delete globalThis.__japaneseAddressesPending[id];
              if (!ok) { pending.reject(error || "address data request failed"); return; }
              var values = headers || {};
              pending.resolve({
                ok: status >= 200 && status < 300,
                status: status,
                headers: { get: function(name) {
                  var key = Object.keys(values).find(function(k) {
                    return k.toLowerCase() === String(name).toLowerCase();
                  });
                  return key === undefined ? null : values[key];
                } },
                text: function() { return body; },
                json: function() { return JSON.parse(body); }
              });
            };
          })();
          """
        guard context.evaluateScript(setupScript) != nil else {
          throw JapaneseAddressError.scriptEvaluationFailed
        }
        guard
          let resourceURL = Bundle.module.url(
            forResource: "normalize-japanese-addresses-3.1.3",
            withExtension: "cjs"
          ),
          let source = try? String(contentsOf: resourceURL, encoding: .utf8),
          context.evaluateScript(source) != nil
        else {
          throw JapaneseAddressError.resourceUnavailable
        }
        guard
          let normalizeNamespace = context.objectForKeyedSubscript("normalize"),
          let normalizeFunction = normalizeNamespace.objectForKeyedSubscript("normalize"),
          !normalizeFunction.isUndefined,
          let config = normalizeNamespace.objectForKeyedSubscript("config")
        else {
          throw JapaneseAddressError.scriptEvaluationFailed
        }
        config.setObject(
          baseAPIURL.absoluteString, forKeyedSubscript: "japaneseAddressesApi" as NSString)
        let fetch: @convention(block) (JSValue, JSValue?) -> JSValue? = {
          [executor, contextBox, dataSource] urlValue, optionsValue in
          guard
            let urlString = urlValue.toString(),
            let url = URL(string: urlString),
            let createRequest = contextBox.value.objectForKeyedSubscript(
              "__japaneseAddressesCreateRequest")
          else {
            return nil
          }
          let requestID = UUID().uuidString
          guard let promise = createRequest.call(withArguments: [requestID]) else { return nil }
          let range = Self.range(from: optionsValue)
          Task.detached {
            do {
              let response = try await dataSource.response(for: url, range: range)
              executor.perform {
                Self.deliver(response: response, requestID: requestID, context: contextBox)
              }
            } catch {
              let message = String(describing: error)
              executor.perform {
                Self.deliverFailure(message: message, requestID: requestID, context: contextBox)
              }
            }
          }
          return promise
        }
        context.setObject(fetch, forKeyedSubscript: "fetch" as NSString)
        return (contextBox, JavaScriptValueBox(normalizeFunction))
      }
      context = initialized.0
      normalize = initialized.1
    }

    func normalize(_ input: String, level: Int?) async throws -> NormalizedAddress {
      let cancellation = CancellationRelay<NormalizedAddress>()
      return try await withTaskCancellationHandler {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
          let continuationBox = ContinuationBox<NormalizedAddress>(continuation)
          guard cancellation.install(continuationBox) else {
            continuationBox.resume(throwing: CancellationError())
            return
          }
          executor.perform {
            guard let options = self.context.value.evaluateScript("({})") else {
              continuationBox.resume(throwing: JapaneseAddressError.scriptEvaluationFailed)
              return
            }
            if let level {
              options.setObject(level, forKeyedSubscript: "level" as NSString)
            }
            guard
              let normalize = self.normalize.value,
              let promise = normalize.call(withArguments: [input, options])
            else {
              continuationBox.resume(throwing: JapaneseAddressError.scriptEvaluationFailed)
              return
            }
            let success: @convention(block) (JSValue?) -> Void = {
              [executor = self.executor] value in
              let valueBox = JavaScriptValueBox(value)
              executor.perform {
                do {
                  continuationBox.resume(returning: try Self.address(from: valueBox.value))
                } catch {
                  continuationBox.resume(throwing: error)
                }
              }
            }
            let failure: @convention(block) (JSValue?) -> Void = {
              [executor = self.executor] value in
              let valueBox = JavaScriptValueBox(value)
              executor.perform {
                continuationBox.resume(
                  throwing: JapaneseAddressError.dataSourceFailure(
                    valueBox.value?.toString() ?? "unknown JavaScript error"
                  )
                )
              }
            }
            guard promise.invokeMethod("then", withArguments: [success, failure]) != nil else {
              continuationBox.resume(throwing: JapaneseAddressError.invalidResponse)
              return
            }
          }
        }
      } onCancel: {
        cancellation.cancel()
      }
    }

    private static func deliver(
      response: AddressDataResponse,
      requestID: String,
      context: JavaScriptContextBox
    ) {
      guard let deliver = context.value.objectForKeyedSubscript("__japaneseAddressesDeliver") else {
        return
      }
      deliver.call(withArguments: [
        requestID,
        true,
        String(decoding: response.data, as: UTF8.self),
        response.statusCode,
        response.headers as NSDictionary,
        NSNull(),
      ])
    }

    private static func deliverFailure(
      message: String,
      requestID: String,
      context: JavaScriptContextBox
    ) {
      guard let deliver = context.value.objectForKeyedSubscript("__japaneseAddressesDeliver") else {
        return
      }
      deliver.call(withArguments: [
        requestID,
        false,
        "",
        0,
        NSDictionary(),
        message,
      ])
    }

    private static func range(from options: JSValue?) -> Range<Int>? {
      guard
        let headers = options?.objectForKeyedSubscript("headers"),
        let value = headers.objectForKeyedSubscript("Range"),
        !value.isUndefined,
        !value.isNull,
        let header = value.toString(),
        header.hasPrefix("bytes=")
      else {
        return nil
      }
      let numbers = header.dropFirst("bytes=".count).split(
        separator: "-", omittingEmptySubsequences: false)
      guard
        numbers.count == 2,
        let start = Int(numbers[0]),
        let end = Int(numbers[1]),
        start >= 0,
        end >= start,
        end < Int.max
      else {
        return nil
      }
      return start..<(end + 1)
    }

    private static func address(from value: JSValue?) throws -> NormalizedAddress {
      guard let value, !value.isUndefined, !value.isNull else {
        throw JapaneseAddressError.invalidResponse
      }
      let pointValue = value.objectForKeyedSubscript("point")
      var point: AddressPoint?
      if let pointValue, !pointValue.isUndefined, !pointValue.isNull {
        guard
          let latitude = pointValue.objectForKeyedSubscript("lat"),
          let longitude = pointValue.objectForKeyedSubscript("lng"),
          let pointLevel = pointValue.objectForKeyedSubscript("level")
        else {
          throw JapaneseAddressError.invalidResponse
        }
        point = AddressPoint(
          latitude: latitude.toDouble(),
          longitude: longitude.toDouble(),
          level: Int(pointLevel.toInt32())
        )
      }
      guard let levelValue = value.objectForKeyedSubscript("level"), !levelValue.isUndefined else {
        throw JapaneseAddressError.invalidResponse
      }
      return NormalizedAddress(
        prefecture: Self.string(value, key: "pref"),
        city: Self.string(value, key: "city"),
        town: Self.string(value, key: "town"),
        address: Self.string(value, key: "addr"),
        other: Self.string(value, key: "other") ?? "",
        level: Int(levelValue.toInt32()),
        point: point
      )
    }

    private static func string(_ value: JSValue, key: String) -> String? {
      guard let child = value.objectForKeyedSubscript(key) else { return nil }
      guard !child.isUndefined, !child.isNull else { return nil }
      return child.toString()
    }
  }

  private let runtime: Runtime

  public init(baseAPIURL: URL, dataSource: any AddressDataSource) throws {
    guard
      let scheme = baseAPIURL.scheme?.lowercased(),
      ["http", "https"].contains(scheme),
      baseAPIURL.host != nil,
      baseAPIURL.user == nil,
      baseAPIURL.password == nil,
      baseAPIURL.query == nil,
      baseAPIURL.fragment == nil,
      !baseAPIURL.absoluteString.hasSuffix("/")
    else {
      throw JapaneseAddressError.invalidBaseURL
    }
    runtime = try Runtime(baseAPIURL: baseAPIURL, dataSource: dataSource)
  }

  public func normalize(_ input: String, level: Int? = nil) async throws -> NormalizedAddress {
    guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw JapaneseAddressError.emptyInput
    }
    if let level, !(0...8).contains(level) {
      throw JapaneseAddressError.invalidLevel(level)
    }
    return try await runtime.normalize(input, level: level)
  }
}
