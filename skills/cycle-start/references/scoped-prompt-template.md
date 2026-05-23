# Scoped prompt テンプレート

`<...>` の placeholder をすべて埋めて、結果を fenced block として cycle-worker sub-agent に渡します。

---

```
あなたは cycle <N> の cycle-worker sub-agent です: <one-line cycle goal>

## Authored file(これ 1 つだけ編集する)

<path/to/AuthoredFile.ext>

## 副作用ファイル(編集 allowlist。リスト外は触らない)

- <path/to/side-effect-1>
- <path/to/side-effect-2>
# 生成 companion のルールがある場合の例:
# 「このサイクルで触れたファイルの *.meta companion」

## 実装内容

<2〜6 行: worker が生成すべき具体的な変更。追加する helper 関数の名前と、既存の call site の位置。このセクションが短く具体的なほど、サイクル単位のトークン消費が下がる。>

実装パターン: authored ファイルに helper メソッドを追加。既存フローへの 1 行 wiring で call site に組み込む。call site をリファクタしない。既存メソッドを rename しない。本 prompt で明示的に named されない限り、新しい top-level 構造を追加しない。

## Batch entry points to expose

Validate method: <fully-qualified callable name, e.g. Namespace.Class.ValidateTopicBatch>
Capture method:  <fully-qualified callable name, e.g. Namespace.Class.CaptureTopicCycle<NN>ScreenshotsBatch>

両方とも、parent のバッチツールから追加引数なしで呼び出せること。

`CYCLE_AUDIENCE` 環境変数が設定されていたら、capture 出力ファイル名に `${audience}_` prefix を付ける。付けない場合は cycle-runner が capture 後に rename する。

## Project gates

<プロジェクトの規律ゲートをインラインで列挙。例:>
# - 視覚 sign-off は baseline との PNG diff を要求する。Validate 合格は視覚 sign-off ではない。
# - 対話ツールで行った編集は authored ファイルに反映する。
# - provenance gap を見つけたら表面化する。隠さない。

## やってはいけないこと

- バッチツールを自分で実行する(parent が validate / capture / build / smoke を tools/cycle-runner.ps1 経由で実行する)
- commit / stage / push(parent が 1 サイクル = 1 コミットで commit する)
- build outputs、package lock files、environment files、CI configuration、ドキュメントの編集
- テストの追加(validation は Validate バッチメソッドで走る)

## 出力フォーマット

turn の最後に 1 つの fenced block を出す:

WORKER_RESULT
authored_file: <path>
side_effect_files:
  - <path>
validate_method: <fully-qualified>
capture_method: <fully-qualified>
notes: <one sentence; flag any drift you avoided>

スコープ内で landing できないなら、代わりに返す:

WORKER_RESULT
status: scope_widen_required
reason: <one sentence>
proposed_added_files:
  - <path>
```

---

## 穴埋めのコツ

- **Cycle goal**: devlog draft の H1 タイトル、または parent の session plan からそのまま引用します。1 行にとどめてください。worker は motivation prose を必要としません。
- **Authored file**: 既存ファイルか、新規 1 ファイルのどちらかです。新規なら「single new file」と明示し、namespace + class(または path + module)を named します。
- **副作用ファイル**: 可能な限り enumerate します。worker に推測させる glob は渡しません。本当に enumerate できないなら、ルールを正確に述べます(たとえば「このサイクルで触れたファイルの metadata companion」)。
- **実装内容**: helper メソッドと call site を line range または symbol で named します。短く具体的なほど、サイクル単位のトークン消費が下がります。
- **Batch entry points**: parent が事前に名前を決めていないなら、topic placeholder のままにして worker に提案させます。ただし、`WORKER_RESULT` でメソッド名を返させて、cycle-runner を確実に起動できるようにしてください。
- **Project gates**: プロジェクトにまだゲートがなければ、一度書いてサイクルごとに再利用します。ゲートはサイクルを正直に保つために存在します。省略すると、worker は Validate を通しつつ、人間が本当に気にする部分を壊しうるからです。
