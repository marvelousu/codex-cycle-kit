---
name: cycle-start
description: トークン効率の良い実装サイクルを開始するときに、orchestrator(parent)セッションから cycle-worker sub-agent へ送る scoped prompt を生成します。parent がこのサイクルのゴールと authored ファイルを決め、worker に「編集スコープ、返すべき Validate / Capture メソッド名、プロジェクト固有の規律ゲート、失敗時の escalation 契約」を伝える scoped prompt を発行する必要があるときに使います。cycle-worker agent(この prompt に従って動く)と tools/cycle-runner.ps1(worker が返した後に 4 フェーズのバッチと commit を実行する)と組み合わせます。視覚 sign-off、サイクル計画の論拠、サイクル後の commit メッセージには使いません。それらは devlog と cycle-runner に置くもので、scoped prompt には入れません。
---

# cycle-start

このスキルは、parent(orchestrator)セッションが `cycle-worker` sub-agent にサイクル開始時に送る scoped prompt を生成します。scoped prompt は、worker をリファレンス資料に書かれたトークン削減のバジェット内に保つための要となる artifact です。

このスキルは構造を担当します。サイクルのトピックは知りません。トピックは parent が供給し、スキルは不変条件の enforce を担当します。

## このスキルが適用される条件

次のすべてが揃っているときに使います。

- parent がこのサイクルのゴールを既に決めている(1 行、たとえば「house exterior を soft shadows で grounding」「proxy resolver に SOCKS5 fallback を追加」「build-info struct を再生成」)
- parent が worker に編集させる authored ファイルを 1 つ特定している
- parent が worker に expose させたい Validate / Capture メソッド名を指定できる(または、下記の慣行に合う名前を worker が提案するのを受け入れる)
- parent は worker が返した後に `tools/cycle-runner.ps1` を起動するつもり

いずれかが欠けている場合、自由計画にフォールバックしてください。このスキルではサイクルゴールの欠如はカバーできません。

## 出力

[references/scoped-prompt-template.md](references/scoped-prompt-template.md) のテンプレートを使い、scoped prompt を 1 つの fenced block として出力します。`<...>` の placeholder はすべて埋めてください。セクションを省略しないでください。`cycle-worker` agent は全セクションが揃っていることを前提にしています。

scoped prompt を出力した後、parent が devlog draft に貼れる 1 行のトレース要約も出します。

```
SCOPED_PROMPT_ISSUED cycle=<N> authored_file=<path> validate=<method> capture=<method>
```

## 不変条件(これは破らない)

1. **編集スコープ = 1 + N**: authored ファイル 1 つと、副作用ファイルの小さな明示的 allowlist です。enumerate してください。「このサイクルで触れたファイルの metadata companion」のように明確なルールを述べる場合を除き、worker に推測させる glob は渡しません。build outputs、package lock files、environment files、CI configuration、ドキュメントは、明示的に必要な場合を除いてリストに含めません。

2. **実装パターン = helper + 1 行 wiring**: worker は authored ファイルに helper メソッドを追加し、既存の call site への 1 行 wiring でつなぎます。call site のリファクタはしない、rename はしない、明示的に named されない限り新しい top-level 構造(class / module / service)は追加しない、を守らせます。

3. **Worker はメソッド名を返す**: scoped prompt は worker に対して、`WORKER_RESULT` ブロックで `validate_method` と `capture_method`(fully-qualified callable 名)を返すよう指示します。parent はそれらを `cycle-runner.ps1 -ValidateMethod ... -CaptureMethod ...` に渡します。

4. **Project gates embedded**: 各 scoped prompt は、このプロジェクトの規律ゲートを `## Project gates` セクションで毎回再掲します。プロジェクトにまだゲートがなければ、一度定義してサイクルごとに含めます。例は次のとおりです。
   - 「視覚 sign-off は baseline との diff を要求します。Validate 合格は視覚 sign-off ではありません」
   - 「対話ツールで行った編集は authored ファイルに反映します」
   - 「Discipline precedes tooling. 上流ステップを省略した場合は表面化し、隠さないでください」

5. **Worker からの commit / push / バッチツール起動はなし**: parent が 4 つのバッチフェーズと commit を回します。worker は編集だけです。

## Validate / Capture メソッドの命名規約

parent が逸脱する理由を持たない限り、次のパターンを使います。一貫性が cycle-runner のログ命名にも効きます。

- Validate: `<Namespace>.<AuthoredClass>.Validate<Topic>Batch`
- Capture: `<Namespace>.<AuthoredClass>.Capture<Topic>Cycle<NN>ScreenshotsBatch`

`<NN>` はゼロ埋めの cycle ordinal です。Capture メソッド名に cycle ordinal を含めるのは意図的で、次サイクルで前回 capture メソッドを残せて、レビュー時の diff 取りに使えます。

namespace の概念がない言語では、プロジェクトに合った慣行を使います(たとえば `project/cycle/validate_topic` のような path、`validate_topic_batch` のようなフラットな callable)。「2 メソッド + Capture 名に ordinal を含める」の考え方は stack 横断で carry できます。

## Audience routing

cycle-runner は `-Audience worker` または `-Audience parent_review` を受け取り、`CYCLE_AUDIENCE` を capture メソッドに export します。scoped prompt は worker に次のように指示します。capture メソッドが `CYCLE_AUDIENCE` を尊重するなら出力ファイル名に `${audience}_` prefix を付ける、尊重しないなら cycle-runner が capture 後に rename する、です。どちらの経路でも `worker_*` / `parent_review_*` の partition が得られます。

## Escalation 契約

worker がスコープ内で実装を成立させられないなら、`WORKER_RESULT status=scope_widen_required` を proposed 追加ファイルのリスト付きで返さなければなりません。scoped prompt はこの exit を worker に思い出させてください。さもないと、capacity が限定的なサイクルが黙ってスコープを広げ、コスト削減が崩壊します。

## リファレンス実装: Unity Editor cycle

このスキルの具体的なインスタンスは [references/reference-implementation-unity.md](references/reference-implementation-unity.md) にあります。プロジェクトが Unity の場合、または別の stack に適応する前に worked example を見るときに読んでください。
