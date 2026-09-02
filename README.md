# Japanese Addresses Client

SwiftPM package that wraps the existing `@geolonia/normalize-japanese-addresses` 3.1.3 UMD bundle for iOS 15+ and macOS 12+.

The address normalization algorithm is not reimplemented in Swift. JavaScriptCore runs the upstream bundle, while an application-provided `AddressDataSource` supplies JSON and byte-range responses. This package has no built-in URLSession, network client, credentials, provider-specific UI, or persistent cache.

## M0 scope

- `JapaneseAddressNormalizer` and Sendable value types for normalized addresses and points.
- Serial JavaScriptCore access safe for concurrent async calls.
- A fetch bridge that turns the bundle's URL and `Range` requests into `AddressDataSource` calls.
- Configurable base API URL.
- Synthetic fixture tests for level 0, level 3, and a byte-range request.

The manifest, version switching, regional device cache, retention policy, and transport implementation belong in later layers. Applications can put their existing network or R2-aware implementation behind `AddressDataSource`.

## Usage

```swift
import JapaneseAddressNormalizer

let normalizer = try JapaneseAddressNormalizer(
    baseAPIURL: URL(string: "https://data.example.invalid/api/ja")!,
    dataSource: appDataSource
)
let result = try await normalizer.normalize("ExamplePrefectureExampleCityExampleTown", level: 3)
print(result.level, result.prefecture as Any)
```

`Range<Int>` is half-open (`start..<end`). A provider should return the status and headers it received from its transport, including `Content-Range` for partial responses when applicable.

## Development

```sh
swift build
swift test
```

The bundled JavaScript and its MIT license are tracked as resources. Do not add real addresses, production endpoints, credentials, or generated datasets to this repository.
