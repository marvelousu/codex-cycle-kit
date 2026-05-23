# リファレンス実装: Unity Editor cycle

これがテンプレ群の元になった worked example です。他の stack(Node.js codegen、Python データパイプライン、組み込みファームウェアなど)に適応するときは、バッチツールとファイルパターンの慣行を置き換えます。サイクルの形と WORKER_RESULT 契約は変わりません。

## プロジェクトの形

- Unity 6 以降のプロジェクト(URP)、editor scriptable なバッチエントリポイントあり
- サイクルごとに authored ファイルを 1 つ。通常 `Assets/Editor/` 配下(例: `AnemoraFastVsHouseSliceSetup.cs`)
- 副作用 allowlist:
  - `*.meta`
  - `Assets/Settings/*.asset`
  - `Assets/Prefabs/**/*.prefab`
  - `Assets/Materials/**/*.mat`
  - `Assets/AddressableAssetsData/**`
  - `Assets/Scenes/*.unity`(シーンレベルの編集が本当に必要な場合のみ追加)

## バッチツールの起動

```powershell
& "C:\Program Files\Unity\Hub\Editor\6000.3.14f1\Editor\Unity.exe" `
    -batchmode -quit `
    -projectPath "<repo root>" `
    -executeMethod <FullyQualified.Class.Method> `
    -logFile "<log path>"
```

`-nographics` は付けません。Capture フェーズが screenshot をレンダーする必要があるためです。smoke フェーズ(ビルド済みプレイヤー)は `-batchmode -nographics` を使います。

## メソッドの命名規約

- Validate: `Namespace.AuthoredClass.Validate<Topic>Batch`(冪等、post-state を assert します)
  - 例: `Anemora.EditorTools.AnemoraFastVsHouseSliceSetup.ValidateHouseSliceBatch`
- Capture: `Namespace.AuthoredClass.Capture<Topic>Cycle<NN>ScreenshotsBatch`(PNG + metrics)
  - 例: `Anemora.EditorTools.AnemoraFastVsHouseSliceSetup.CaptureHd2dShadingFoundationCycle01ScreenshotsBatch`

Capture メソッド名に cycle ordinal `<NN>` を含めると、次サイクルで前回 capture メソッドを残せて、視覚 diff のレビューに使えます。

## Project gates(Anemora での canonical なセット)

Anemora プロジェクトの規律ゲートは ADR-0010(Unity MCP Editor Bridge)に由来します。

- **G1(対話編集のコード反映)**: MCP Editor Bridge 経由で行った構造変更は、authored ファイルにも反映します。ad-hoc な MCP-only のシーン編集は禁止です。checked-in な再現経路を bypass してしまうためです。
- **G2(視覚ゲートの維持)**: MCP bridge は構造アサーション(hierarchy / transform / component)を提供します。PNG capture 経由の人間視覚 sign-off の代わりにはなりません。「構造 assert green」だけでは green とは言えません。
- **G3(規律はツールに先行する)**: provenance gap(たとえば Apply / Integrator なしの Refresh-only)は規律の問題であって、ツールの問題ではありません。MCP は検出ループを早く閉じますが、オーケストレーション修正の代わりにはなりません。

Unity 以外のプロジェクトでは、自分のゲートを定義します。よくある形は次のとおりです。

- 視覚または product-quality ゲート(人間が出力を見ます)
- コード反映ゲート(対話ツールでの編集はコードに再表現します)
- provenance ゲート(中間ステップは省略せず実行します)

## End-to-end のサイクル起動(Anemora のリファレンス形)

worker が `WORKER_RESULT` を返した後の起動例です。

```powershell
pwsh -File tools/cycle-runner.ps1 `
    -CycleNumber 2 `
    -ValidateMethod Anemora.EditorTools.AnemoraFastVsHouseSliceSetup.ValidateHouseSliceBatch `
    -CaptureMethod  Anemora.EditorTools.AnemoraFastVsHouseSliceSetup.CaptureHd2dShadingFoundationCycle02ScreenshotsBatch `
    -BuildMethod    Anemora.EditorTools.AnemoraFastVsHouseSliceSetup.BuildAndValidateBatch `
    -DevlogPath     docs/devlog/2026-05-23_fast_vs_hd2d_shading_foundation_cycle02.md `
    -Audience       parent_review
```

`-BuildMethod` は必須です。プロジェクト横断で意味のあるデフォルトがないため、プロジェクトごと(または cycle ごとに variable なら cycle ごと)に Build バッチメソッドを指定します。

## 観測されたコスト削減

Anemora の 348 サイクルスレッド(Era1 baseline vs Era2 with this template set)で、per-thread のトークン消費が 84% 減少しました(36.7M → 6.0M)。この削減は次の要因に分解できます。

- 単一ファイルスコープにしたことで、クロスファイルの context 読み込みが消滅した
- 実装を小型モデル worker(gpt-5.4-mini)が担当し、大型モデル parent(gpt-5.5)はオーケストレーションだけになった
- 自由形式の QA を決定的なバッチ validation に置き換えた
- 失敗モードの escalation により、capacity 問題が runaway サイクル経由ではなく早期に表面化するようになった

別プロジェクトでの数値は、過去のサイクルがどれだけクロスファイルの context 読み込みに消費されていたかで変わります。
