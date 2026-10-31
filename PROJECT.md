# PROJECT: japanese-addresses-client-swift（GenNavi プロジェクトの構成要素）

公開 OSS として用意した iOS / macOS 向け住所クライアント。実利用は GenNavi のみ。
目的地・現在地・判断ログの正本は GenNavi リポジトリの PROJECT.md。

- 役割: 住所正規化ライブラリ @geolonia/normalize-japanese-addresses を JavaScriptCore で包む（再実装しない）。
  あわせて r2-distribution の配信契約（manifest schema v1、/versions/<version>/api/ja）を解決する
  AddressManifestClient と、要求された地域・範囲だけを保持するキャッシュを持つ
- データの流れ: r2-distribution の R2 配信 → このクライアントが manifest 解決と地域取得 → アプリ内で正規化
- ペア: 配置側は japanese-addresses-r2-distribution
- Observatory プロジェクト名: GenNavi
- 正本: https://github.com/papagrationbiz-sketch/GenNavi の PROJECT.md
