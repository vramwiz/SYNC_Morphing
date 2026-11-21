# SYNC_Morphing の配布パッケージ

`make_release_zip.bat` を実行すると、v1.0.0 の `SYNC_Morphing.auf2` を案内書・ライセンス・作例と一緒に梱包し、カタログに本体の XXH3-128 を記録します。

## 入力

- `SYNC_Morphing.auf2` の Release 版。既定ではプロジェクトの `Win64\Release` を探し、そのファイルがなければ `%ProgramData%\aviutl2\Plugin\SYNC_Morphing` を使います。
- `xxhsum.exe`。PATH またはプロジェクトの `Win64\Dependencies\xxHash-0.8.4` に置くか、`-XxhsumPath` で指定します。
- `SYNC_Morphing.catalog.json` の `release_date`。公開日が変わった場合は、この日付を合わせてから梱包します。

別の場所にある入力を指定する例です。

```bat
setup\make_release_zip.bat -ReleaseDirectory "D:\Release\SYNC_Morphing" -XxhsumPath "D:\Tools\xxhsum.exe"
```

## 出力

- `SYNC_Morphing.zip` — `SYNC_Morphing/` 以下に本体、利用者向け README、ライセンス、作例を格納します。
- `SYNC_Morphing.catalog.json` — 設置先、アンインストール対象、バージョンとハッシュを含む AviUtl2 カタログの登録用データです。

公開用の GitHub Releases には、タグ `v1.0.0` でこの2ファイルを添付します。
