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

## 検証

Linux x86-64 で Git、Rustup、C リンカーを用意し、`scripts/check.sh` を実行します。Sigil のコンパイラ・埋め込み標準ライブラリ・ネイティブ核は同一のコミット `ba4a5f1b7bf4764521cdef1ee60daf1819d30f81` を使用します。Rust は 1.100.0、依存クレートは同コミットの `Cargo.lock` で固定します。スクリプトは固定した処理系で Cargo の fmt と Clippy を実行し、その処理系の評価器とネイティブ出力で同じ試験を実行します。

試験の固定値は Python 標準ライブラリの `hashlib.pbkdf2_hmac`、`hashlib.sha256`、`struct.pack`、`base64.urlsafe_b64encode`、`hmac.digest` で独立に算出しました。[Issue #1][issue] に定数時間性の検査登録について記録します。

[adr0060]: https://github.com/goodnasubi/sigil/blob/ba4a5f1b7bf4764521cdef1ee60daf1819d30f81/docs/decisions/0060-rune-auth.md
[adr0037]: https://github.com/goodnasubi/sigil/blob/ba4a5f1b7bf4764521cdef1ee60daf1819d30f81/docs/decisions/0037-p1-authentication.md
[issue]: https://github.com/goodnasubi/sigil-rune-auth/issues/1
