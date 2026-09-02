import Foundation
import XCTest

@testable import JapaneseAddressNormalizer

private struct FixtureDataSource: AddressDataSource {
  let responses: [String: Data]
  let ranges: Lock

  func response(for url: URL, range: Range<Int>?) async throws -> AddressDataResponse {
    if let range { ranges.append(range) }
    let key = url.path
    guard let data = responses[key] else {
      throw FixtureError.missing(key)
    }
    if let range {
      guard range.lowerBound >= 0, range.upperBound <= data.count else {
        throw FixtureError.invalidRange(range)
      }
      let bounded = data[range]
      return AddressDataResponse(
        data: bounded,
        statusCode: 206,
        headers: [
          "Content-Range": "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(data.count)"
        ]
      )
    }
    return AddressDataResponse(data: data, statusCode: 200)
  }
}

private final class Lock: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [Range<Int>] = []

  func append(_ value: Range<Int>) {
    lock.lock()
    values.append(value)
    lock.unlock()
  }

  var snapshot: [Range<Int>] {
    lock.lock()
    defer { lock.unlock() }
    return values
  }
}

private enum FixtureError: Error {
  case missing(String)
  case invalidRange(Range<Int>)
}

private func json(_ value: Any) -> Data {
  try! JSONSerialization.data(withJSONObject: value)
}

private func source(includeRange: Bool = false) -> (FixtureDataSource, Lock) {
  let residentData = Data("ignored\nblk_num,rsdt_num,rsdt_num2,lng,lat\n1,2,,140,35\n".utf8)
  let root = json([
    "meta": ["updated": 1],
    "data": [
      [
        "pref": "ExamplePrefecture",
        "code": "01",
        "point": [140.0, 35.0],
        "cities": [
          [
            "city": "ExampleCity",
            "code": "001",
            "point": [140.0, 35.0],
          ]
        ],
      ]
    ],
  ])
  let city: [String: Any] = [
    "data": [
      [
        "oaza_cho": "ExampleTown",
        "chome": "",
        "point": [140.0, 35.0],
        "rsdt": includeRange,
        "csv_ranges": includeRange
          ? ["住居表示": ["start": 0, "length": residentData.count]]
          : [:],
      ]
    ]
  ]
  var responses = [
    "/api/ja.json": root,
    "/api/ja/ExamplePrefecture/ExampleCity.json": json(city),
  ]
  if includeRange {
    responses["/api/ja/ExamplePrefecture/ExampleCity-住居表示.txt"] = residentData
  }
  let lock = Lock()
  return (FixtureDataSource(responses: responses, ranges: lock), lock)
}

final class JapaneseAddressNormalizerTests: XCTestCase {
  func testLevelZeroUsesSyntheticRoot() async throws {
    let (dataSource, _) = source()
    let normalizer = try JapaneseAddressNormalizer(
      baseAPIURL: URL(string: "https://data.example.invalid/api/ja")!,
      dataSource: dataSource
    )
    let result = try await normalizer.normalize("UnknownInput", level: 0)
    XCTAssertEqual(result.level, 0)
    XCTAssertNil(result.prefecture)
  }

  func testLevelThreeUsesSyntheticUpstreamData() async throws {
    let (dataSource, _) = source()
    let normalizer = try JapaneseAddressNormalizer(
      baseAPIURL: URL(string: "https://data.example.invalid/api/ja")!,
      dataSource: dataSource
    )
    let result = try await normalizer.normalize("ExamplePrefectureExampleCityExampleTown", level: 3)
    XCTAssertEqual(result.level, 3)
    XCTAssertEqual(result.prefecture, "ExamplePrefecture")
    XCTAssertEqual(result.city, "ExampleCity")
    XCTAssertEqual(result.town, "ExampleTown")
  }

  func testLevelEightBridgesOneByteRange() async throws {
    let (dataSource, ranges) = source(includeRange: true)
    let normalizer = try JapaneseAddressNormalizer(
      baseAPIURL: URL(string: "https://data.example.invalid/api/ja")!,
      dataSource: dataSource
    )
    let result = try await normalizer.normalize(
      "ExamplePrefectureExampleCityExampleTown1-2", level: 8)
    XCTAssertEqual(result.level, 8)
    XCTAssertEqual(ranges.snapshot.count, 1)
    XCTAssertEqual(ranges.snapshot.first?.lowerBound, 0)
  }

  func testConcurrentNormalizationIsSafe() async throws {
    let (dataSource, _) = source()
    let normalizer = try JapaneseAddressNormalizer(
      baseAPIURL: URL(string: "https://data.example.invalid/api/ja")!,
      dataSource: dataSource
    )
    async let first = normalizer.normalize("ExamplePrefectureExampleCityExampleTown", level: 3)
    async let second = normalizer.normalize("UnknownInput", level: 0)
    let results = try await [first, second]
    XCTAssertEqual(results.map(\.level).sorted(), [0, 3])
  }
}
