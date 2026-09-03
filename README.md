# Japanese Addresses Client

SwiftPM package that wraps the existing `@geolonia/normalize-japanese-addresses` 3.1.3 UMD bundle for iOS 15+ and macOS 12+.

The address normalization algorithm is not reimplemented in Swift. JavaScriptCore runs the upstream bundle, while an application-provided `AddressDataSource` supplies JSON and byte-range responses. The package includes optional URLSession transport and disk cache layers, but no credentials or provider-specific UI.

## Scope

- `JapaneseAddressNormalizer` and Sendable value types for normalized addresses and points.
- Serial JavaScriptCore access safe for concurrent async calls.
- A fetch bridge that turns the bundle's URL and `Range` requests into `AddressDataSource` calls.
- Configurable base API URL.
- Synthetic fixture tests for level 0, level 3, and a byte-range request.
- `URLSessionAddressDataSource`, which checks HTTP status and exact `Content-Range` semantics.
- `AddressManifestClient`, which accepts schema version 1 manifests and resolves a registered version ID to the immutable host-root path `/versions/<version>/api/ja`. The manifest `prefix` remains validated metadata and is not trusted for URL construction.
- `CachedAddressDataSource`, a regional/request cache that stores only URLs and ranges requested by the application. It does not prefetch or assume that unspecified manifest coverage means national coverage.

Applications may also provide their own `AddressDataSource` (for example, an R2-aware implementation).

## Manifest schema

The client accepts schema version 1 manifests with `schemaVersion`, `current`, `previous`, `updatedAt`, and a `versions` dictionary. Each version has a relative `prefix` (metadata only), `publishedAt`, optional `sourceUpdatedAt`, and optional `coverage` (`national` or an explicit `municipalities` list). Omitted coverage is unknown; a region request then fails instead of falling back to a national dataset. Select a fixed version for reproducible requests. A manifest URL's path is ignored for dataset construction; the host and port are retained and the result is `/versions/<version>/api/ja`.

## Usage

```swift
import Foundation
import JapaneseAddressNormalizer

let transport = try URLSessionAddressDataSource()
let manifest = try AddressManifestClient(
    manifestURL: URL(string: "https://data.example.invalid/manifest.json")!,
    dataSource: transport
)
let dataset = try await manifest.resolve()
let cachedData = try CachedAddressDataSource(
    upstream: transport,
    directory: applicationCacheDirectory
)
let normalizer = try JapaneseAddressNormalizer(
    baseAPIURL: dataset.baseAPIURL,
    dataSource: cachedData
)
let result = try await normalizer.normalize("ExamplePrefectureExampleCityExampleTown", level: 3)
print(result.level, result.prefecture as Any)
```

Fetch the current manifest through the uncached transport, then cache requests under the resolved immutable version URL. This lets a later manifest switch select a new cache namespace while retained fixed-version entries remain available offline. `try await cachedData.clear()` is safe to call during requests: completed pre-clear responses are returned to their caller but cannot repopulate the cleared generation.

For a last-known-valid manifest, give `LastKnownValidManifestStore` an app-private file URL and call `refresh(using:)` on each refresh attempt:

```swift
let manifestStore = try LastKnownValidManifestStore(fileURL: manifestFileURL)
let refresh = try await manifestStore.refresh(using: manifest)
let datasetManifest = refresh.manifest
// refresh.source is .network or .lastKnownValid
```

The refresh always attempts the network and reports whether `.network` or `.lastKnownValid` supplied the result. A transport/network failure may use the previously persisted, fully validated manifest; HTTP status errors, malformed JSON, unsupported schema, and invalid metadata are surfaced and never overwrite it. Manifest persistence is separate from `CachedAddressDataSource` and its 180-day index policy. `try await manifestStore.clear()` removes only its own file and temporary files.

`Range<Int>` is half-open (`start..<end`). Partial responses must be HTTP 206 with one exact `Content-Range: bytes start-end/total` matching the request and payload length. A provider should return the status and headers it received from its transport.

## On-device cache and privacy

`CachedAddressDataSource` uses a directory supplied by the application. Cache keys are SHA-256 digests of the complete URL plus exact half-open byte range, preventing dataset revisions and ranges from sharing responses. The default policy is a 100 MiB hard cap, eviction candidates after 60 days, data expiry after 90 days, and municipality-index retention for 180 days. The hard cap takes precedence. Only response bytes, request URL/range, headers, and cache timestamps are stored; address input, identity, credentials, and location are not persisted. Use an app-private directory and remove it when app data is deleted.

## Development

```sh
swift build
swift test
```

The bundled JavaScript and its MIT license are tracked as resources. Do not add real addresses, production endpoints, credentials, or generated datasets to this repository.
