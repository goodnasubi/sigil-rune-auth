# sigil-rune-auth

[ADR 0060 段 1][adr0060] の Sigil モジュールは `sigil/rune_auth.sigil` にあります。呼び出し側はモジュールを Sigil のソースルートに置き、必要な公開関数を `use rune_auth.<関数名>;` で取り込みます。

| 機能 | 公開 API |
| --- | --- |
| パスワード記録 | `new_password` は OS 乱数の塩を使って 100,000 回で導出します。`encode_password` は塩と反復回数を引数で受け、`verify_password` は記録の反復回数で導出して `ct_eq` で照合します。 |
| ID と KV キー | `new_user_id` と `new_session_id` はそれぞれ 16、32 バイトの OS 乱数を返します。`user_subject` は `u` ＋小文字 hex 32 桁、`session_key` は `rune:session:` ＋ SHA-256 の小文字 hex 64 桁を返します。 |
| セッション記録 | `encode_session` は利用者 ID・世代・発行秒・期限秒を受け取ります。`decode_session` は検査済みの項目を `SessionRecord` として返します。 |
| アクセストークン | 呼び出し側が対象 audience の 32 バイト鍵、利用者 ID、発行秒、有効期間（60〜3,600 秒）を `issue_access_token` に渡します。戻り値は [ADR 0037][adr0037] の `sigil1.<payload>.<tag>` の ASCII バイト列です。 |

版 1 の永続化形式では、多バイト整数は符号なし大端です。

| 記録 | バイト幅と項目 |
| --- | --- |
| パスワード（53 バイト） | 版 1、反復回数 4、塩 16、PBKDF2-HMAC-SHA256 の導出鍵 32 |
| セッション（41 バイト） | 版 1、利用者 ID 16、世代 8、発行 Unix 秒 8、期限 Unix 秒 8 |

セッションの整数は Sigil の非負 `Int` に収まる値を使い、期限は発行より後にします。呼び出し側で KV の TTL を設定し、読み出し時に期限を検査します。

## 段 2: 利用者の表とログイン

[ADR 0060][adr0060] 決定 4 の段 2 です。sigil-db 核（`9483e36f`）の型付き関係 API とトランザクション API だけに依存します。

| モジュール | 内容 |
| --- | --- |
| `sigil/rune_users.sigil` | 利用者表 `users(id 主キー, username, record, status, generation, created)` と、`username` の一意索引 `users_username`。`open_users`・`register_user`（`insert_user`）・`disable_user`・`bump_generation`・`set_password`（`replace_password`）・`lookup_user`・`upgrade_record`。1 回の操作は核の直列トランザクション 1 つで、成功は WAL の同期の後にだけ返します。成否が不明になった（`CommitUnknown`）店は止まり、閉じて開き直すまで何も受けません。 |
| `sigil/rune_throttle.sigil` | 利用者名ごとの失敗の抑制。プロセス内だけで持ち、再起動で消えます。 |
| `sigil/rune_login.sigil` | ログイン照合 `login`。段 1 の `verify_password` を使い、`Success`・`Failed`・`Throttled` を返します。 |
| `sigil/rune_cli.sigil` | 利用者管理の CLI。 |

決めたこと（ADR に書かれていない細部）:

- **利用者名**は 1〜64 バイトの `[a-z0-9._@-]`。大文字小文字の正規化はしません（書式に合わない名前は未知の利用者と同じ扱いです）。
- **状態**は 0 が有効、1 が無効。**世代**は 0 から始まり、上がるだけです。無効化は世代を変えません（セッションの検証は状態も見ます。段 3）。
- **`set_password` は世代も上げます**（同じトランザクション）。パスワードを替えたら既存のセッションが失効するのが安全側の既定のため。
- **データベース識別子**は `sha256("sigil-rune-auth/users/v1")` の先頭 16 バイトの固定値です。核は開くたびに保存済みの識別子と照合します。
- **PBKDF2 はトランザクションの外**で行います（保持時間を延ばさないため）。同じ名前の登録は PBKDF2 の前にも拒否します。

### ログインの規則

- 拒否中（下記）は DB にも PBKDF2 にも触れず `Throttled(残り秒)` を返します。利用者名の実在によらず同じ条件で返ります。
- それ以外は常に 1 回の PBKDF2 を行います。未知の利用者名・書式が不正な名前は、`new_login_gate` が起動時に作るダミーの記録（店の反復回数・新しい塩・捨てる乱数）で照合し、無効な利用者は正しいパスワードでも照合のあと `Failed` にします。応答は一様な `Failed` です。パスワードが長さの規則（12〜256 バイト）に合わないときだけ、PBKDF2 を行わず `Failed` になります（規則は公開されています）。
- 成功したとき、保存された記録の反復回数が店の設定より少なければ、同じパスワードで新しい記録（新しい塩）に置き換えます。置き換えは「保存中の記録がログイン時に読んだものと同じ」ときだけで、世代と状態は変えません。誤ったパスワードでは置き換えません。
- DB の失敗は `Err` で返し、失敗の回数には数えません。

### 抑制

窓は最初の失敗から 900 秒です。窓の中で 5 回目の失敗が起きると 900 秒の拒否に入ります。拒否中の失敗は数えず、拒否を延ばしません。成功で記録を消します（拒否中は消しません）。時刻は呼び出し側が渡し、戻ったら見た中で最大の時刻に丸めるので、拒否が早く解けることはありません。追跡する名前は 1024 個までで、満杯のときは窓が過ぎた記録を先に、次に拒否中でない最も古い記録を捨てます。キーは利用者名の SHA-256 です。

この段では、利用者名ごとの抑制だけを作りました。ADR 0060 が挙げる接続元ごとの上限と、同時に走る PBKDF2 の数の上限は、接続元と並行する要求を持つ HTTP サービス（段 4）で作ります。

### CLI

```
rune_cli <register|disable|bump-generation|set-password> --dir=<DB ディレクトリ> --user=<利用者名>
```

`sigil build --raw-argv --root <根> sigil/rune_cli.sigil main -o rune-cli` で作ります（`sigil run` でも `--raw-argv` を付けます）。サービスを止めて、同じディレクトリに対して使います（核は 1 プロセスが排他ロックで所有します）。パスワードは引数に載せず、`register` と `set-password` のときだけ環境変数 `RUNE_AUTH_PASSWORD` から読みます。出力は固定の文だけで、パスワードや記録は出しません。`register` は利用者の主体表記（`u`＋hex 32 桁）を、`bump-generation` と `set-password` は新しい世代を出します。

| 終了コード | 意味 |
| --- | --- |
| 0 | 成功 |
| 1 | 内部の失敗（ディスク・核・乱数・時計）、または別のプロセスが使用中 |
| 2 | 使い方（引数・環境変数） |
| 3 | 利用者がいない |
| 4 | 同じ利用者名が既にある |
| 5 | 利用者名またはパスワードが規則に合わない |

新しい記録の反復回数は 100,000（ADR 0024 の上限）です。

## 段 3　セッション

`sigil/rune_sessions.sigil` は [ADR 0060][adr0060] 決定 2 のセッション管理を提供します。`stash.persistent` を専用ディレクトリに `require_ttl = true` で開き、サービスで一つの `PendingLogouts` を共有します。

- `issue_session` にログイン成功時の利用者 ID と世代を渡します。既定の絶対寿命は 28,800 秒（8 時間）、指定可能な範囲は 300〜2,592,000 秒です。新しい 32 バイトの ID は永続化成功後に `Secret` で返ります。KV には、ID のハッシュから導いたキーと版 1 の固定長レコードを保存します。検証で寿命を延長する処理はありません。
- `validate_session` は保留リスト、KV の TTL、レコードの期限、利用者の状態と世代を検査します。いずれかで失敗すると `None` を返します。発行と検証には Unix 秒を返す関数を渡します（運用時は `clock.unix_seconds`）。
- `logout_session` は `DELETE` 成功で失効を確定します。KV エラー時はハッシュキーを保留に入れ、`Unavailable`（HTTP 503 相当）を返します。呼び出し側は `retry_pending_logouts` を定期的に呼び、KV が停止した場合は開き直してから同じ保留リストで再試行します。再試行は 1 回の呼び出しにつき各キーに 1 回です。プロセスを再起動すると保留リストは失われます。
- `session_cookie` は小文字 hex の ID と `Secure; HttpOnly; SameSite=Lax; Path=/` を持つ `__Host-sigil_session` の発行用ヘッダー値を `Secret` で返します。ログアウトでは結果にかかわらず `clear_session_cookie` の値を使います。HTTP 応答への組み込みと Cookie ヘッダーの読み取りは段 4 で行います。

## 段 4: HTTP サービス

[ADR 0060][adr0060] 決定 4 の段 4 です。`sigil/rune_http.sigil` は 4 つのエンドポイントと CSRF 検査、一様な失敗応答、Cookie 管理、抑制を提供します。

| エンドポイント | メソッド | 内容 |
| --- | --- | --- |
| `/auth/login` | `POST` | `{username, password}`。成功で新しいセッションを作り `__Host-sigil_session` cookie を返します。失敗は一様な 401。制限超過は 429。 |
| `/auth/logout` | `POST` | セッションを失効し、cookie の削除（`Max-Age=0`）を指示します。成否不明は 503。 |
| `/auth/session` | `GET` | 有効なセッションなら `{"sub":"u..."}`。無ければ 401。転送された cookie を持つアプリの確認にも使えます。 |
| `/auth/token` | `POST` | `{audience}`。セッションが有効で audience が登録済みなら、アクセストークンと期限を返します。それ以外は 401 または 403。 |

決めたこと:

- **CSRF 検査**: 状態を変える要求（`POST /auth/login`・`POST /auth/logout`・`POST /auth/token`）は `Content-Type` のメディアタイプが `application/json`（大文字小文字は区別せず、後ろは終端または `;` のパラメーターだけ。`application/jsonx` などは不可）かつ `Origin` が設定した公開オリジンと完全一致のときだけ受け付けます。`Origin` が無い要求や一致しない要求は 403、不正な Content-Type は 400 で拒否します。`GET /auth/session` は状態を変えないため Origin 検査を免除します。
- **固定の失敗応答と一様性**: すべての応答は JSON で、理由別の本文は作りません（400 は `{"error":"bad_request"}`、401 は `{"error":"unauthorized"}`、403 は `{"error":"forbidden"}`、429 は `{"error":"too_many_requests"}`、503 は `{"error":"service_unavailable"}`）。利用者の有無・パスワードの誤り・無効な利用者によらず一様な 401 を返します。
- **Cookie と固定化防止**: ログイン成功ごとに新しい乱数からセッション ID を発行します。クライアントが提示したセッション ID は再利用せず、固定化攻撃を防ぎます。
- **秘密の非漏洩**: キー・パスワード・セッション ID・トークン・`Authorization`・`Cookie` をログ・エラー・応答に出しません。ログに出せるのは利用者 ID と固定の分類だけです。`/auth/token` の audience 署名鍵は `Secret` のまま署名関数へ渡し、`expose` で `Bytes` に出しません。
- **要求のファジングと上限**: 本文長上限（既定 4096 バイト）、フィールド長上限（`username` 1〜64 バイト、`password` 12〜256 バイト、`audience` 1〜128 バイト）、厳格な JSON（キー重複・未知キー・型不一致の拒否）、同時 PBKDF2 数上限（段 4 では逐次実行のため未実装。超過時 429 の境界のみ提供・試験）。
- **sigix 背後での結合**: 信頼するプロキシ（`trusted_proxies`）からの要求では `X-Forwarded-For` のクライアント IP を使用し、接続元ごとの抑制（15 分に 5 回失敗で 15 分拒否。成功で IP 失敗数はリセットしない）を行います。信頼するプロキシ経由なのに `X-Forwarded-For` が無い・空・読めない要求は、全利用者が 1 つの抑制を共有しないよう `POST /auth/login` で 400 を返します（プロキシを介さない直接の接続は接続元 IP を使います）。信頼できない接続元からの `X-Forwarded-For` は無視します。
- **ADR 0037 との往復**: 発行したアクセストークンは、アプリ側で `web.verify_bearer` により検証可能であり、同一の主体（`sub`）が得られます。

## 検証

Linux x86-64 で Git、Rustup、C リンカーを用意し、`scripts/check.sh` を実行します。Sigil のコンパイラ・埋め込み標準ライブラリ・ネイティブ核は同一のコミット `15beabc44aff08a0566abe3405d722e35b9b8aa5`、sigil-db 核は `9483e36f08c35bfc62b3beeb008a531887506037` を使用します（どちらも取得後にコミットと変更なしを確認します）。Rust は 1.100.0、依存クレートは同コミットの `Cargo.lock` で固定します。KV は段 2 の `7dfcf15b24251d80904f8d54e54b735652b89303` に固定します。スクリプトは Cargo の fmt と Clippy を実行し、固定した処理系の `sigil test --ct` で `Sigil.toml` に登録した導出鍵の照合関数を静的検査と CLIF 検査にかけます。同じ処理系の評価器とネイティブ出力で段 1〜4 の試験も実行します。段 4 の試験は 4 つのエンドポイント、cookie の発行・受け取りと固定化防止、Origin・Content-Type（`application/jsonx` の拒否を含む）の CSRF 検査、一様な 401 応答、秘密の非漏洩、要求のファジングと上限境界（413、405、404、キー重複拒否）、同時 PBKDF2 上限の境界と接続元 IP 抑制（失敗累積による 429・IP ごとの独立追跡・成功で IP 失敗数をリセットしないこと）、sigix の背後での結合（`X-Forwarded-For`。信頼プロキシ経由で無い・空の場合は 400）、ADR 0037 の検証器との往復を検査します。段 3 の試験は永続 KV の期限境界、WAL 障害後の再試行と失効、世代変更と無効化を検査します。TCP 経由の試験は後続対応です。段 2 の試験は、抑制の境界（`stage_two_throttle_test`）、利用者表・ログイン・移行（`stage_two_users_test`）、中断・復旧（`stage_two_recovery_test`）、CLI（`stage_two_cli_test`）です。中断・復旧は、4 つの更新の全 I/O の関門を 3 通り（I/O 失敗・クラッシュ・書き込みの途中切れ）で中断し、再起動後の行が「完全に入った」か「まったく入っていない」かのどちらかであることと、一意索引と表が食い違わないことを確かめます。最後に、実行ファイルの引数・終了コード・出力を煙試験で確かめます。試験は PBKDF2 の反復回数を規則の下限 4096 にして時間を抑えています（煙試験の `register` 1 回だけ実運用の 100,000 回です）。

試験の固定値は Python 標準ライブラリの `hashlib.pbkdf2_hmac`、`hashlib.sha256`、`struct.pack`、`base64.urlsafe_b64encode`、`hmac.digest` で独立に算出しました。

[adr0060]: https://github.com/goodnasubi/sigil/blob/ba4a5f1b7bf4764521cdef1ee60daf1819d30f81/docs/decisions/0060-rune-auth.md
[adr0037]: https://github.com/goodnasubi/sigil/blob/ba4a5f1b7bf4764521cdef1ee60daf1819d30f81/docs/decisions/0037-p1-authentication.md
