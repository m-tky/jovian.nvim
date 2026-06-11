# jovian.nvim コードレビュー報告書

- 日付: 2026-06-11
- 対象: リポジトリ全体(Rust コア ~3,500 行 / Lua フロントエンド ~9,000 行 / テスト・ビルド基盤)
- 方法: サブシステム別の精読レビュー(Rust コア / Lua バックエンド・コアロジック / Lua UI レイヤ / テスト・インフラ)。E95 や extmark 境界など一部は headless nvim で実挙動を検証済み。

## 総評

アーキテクチャの方向性は明快で質が高い。msgpack-RPC のフレーミングと部分読み取り処理、sidecar JSON を唯一のデータソースとする 3 面描画、HMAC 署名の送受信両方向検証、persist のデバウンスと atomic rename、過去の障害への対策コメントなど、設計判断の根拠がコードに残されており保守性が高い。critical 級の脆弱性や即死バグはほぼない。

一方で、構造的な弱点が 4 つのテーマに集中している:

1. **クラッシュ・失敗からの復旧経路が未整備** — jovian-core プロセス死亡時にハンドラ未再登録 × State 未リセット × pending 未 flush × コールバック残留が連鎖し、nvim 再起動以外の復旧手段がない(L-1, L-3, L-4, L-5, L-7)。
2. **CI の安全網が実質機能していない** — run-tests に `set -e` がなく、最後のテスト以外の失敗が exit code に反映されない(**I-1、本レビュー最重要**)。
3. **端末チャネルの所有権リーク** — `windows.get_or_create_buf` の副作用で `State.term_chan` が無条件上書きされ、REPL 出力が pin/preview バッファへ流れる(U-1, U-3, U-4)。
4. **後始末の非対称性** — wrap chrome・conceallevel・ウィンドウオプションの「適用」はあるが「保存→復元」がなく、機能 OFF 後に痕跡が残る(U-6)。バックグラウンドタスクの終端処理も同様(R-3, R-5)。

## 最優先対応事項(Top 8)

| # | 重要度 | 内容 | 参照 |
|---|---|---|---|
| 1 | critical | `flake.nix` run-tests に `set -e` がなく、テスト失敗が CI に伝播しない | I-1 |
| 2 | high | `:wq` 時に .ipynb の非同期保存が完了せずデータ損失の恐れ | L-2 |
| 3 | high | jovian-core クラッシュ後にイベントハンドラが再登録されず無言で機能停止 | L-1 |
| 4 | high | core バイナリ未発見時に `is_starting_kernel` が立ちっぱなしになり全コマンドが沈黙 | L-3 |
| 5 | high | `State.term_chan` ハイジャック — :JovianPin で REPL 出力が pin バッファに混入 | U-1 |
| 6 | high | 変数ペインのページ送り 2 回目で E95 クラッシュ | U-2 |
| 7 | high | `execute_collect` がカーネルの read ロックを最長 5 秒保持し全操作をストール | R-1 |
| 8 | high | ダウンロードバイナリのチェックサム検証なし | I-2 |

---

## Rust コア(core/src/)

### High

- **R-1** `rpc.rs:538-561` — **execute_collect がカーネル read ロックを await 越しに最長 5 秒保持**。tokio RwLock は write 優先のため、Vars/View プローブ中に restart(write 待ち)が入ると後続の read 取得(execute/interrupt/complete)もすべてストールし、体感フリーズになる。→ 送信に必要なのは shell_tx だけなので、rx の await 前に `drop(kernel_guard)` する。

### Medium

- **R-2** `kernel.rs:705-721` — **接続リトライが成功済みソケットにも connect を重複発行**。部分成功(shell 成功・iopub 失敗)後の再試行で 2 本目の接続が張られ、pure-rust zeromq はエンドポイント重複排除をしないため SUB の二重受信(出力の二重表示)等につながり得る。→ ソケットごとに接続状態を追跡し、未接続のものだけリトライ。
- **R-3** `session.rs:89-104` — **デバウンス永続化タスクがセッション drop 後も永久にリーク**。ループ先頭が `notified().await` のため、drop 後は通知が来ず weak.upgrade() チェックに到達しない(コメントと実装が不一致)。バッファ開閉ごとに 1 タスク蓄積。→ `tokio::select!` で shutdown シグナルと併待ち。
- **R-4** `ipynb.rs:63-67` + `notebook.rs:41-46` — **raw セルのラウンドトリップ破損**。`[raw]` ヘッダを書き出すが `CellType::from_str` が raw を認識せず code にフォールバックするため、ipynb→py→ipynb で raw セルが「コメントだらけの code セル」に化ける。→ `CellType::Raw` を追加して全経路対応。
- **R-5** `kernel.rs:819-848` — **iopub_loop の恒久エラー終了がフロントエンドに通知されない**。バックオフ上限到達で黙って return し、events チャネルは他の clone が生きているため閉じない。セルが永遠に Running のまま。→ ループ終了前に `KernelDied` 相当のイベントを送る。
- **R-6** `kitty.rs:50-73` + `rpc.rs:707-719` — **async コンテキスト内のブロッキング tty I/O**。数 MB の PNG で ~340 チャンク、チャンクごとに同期 open/write/close を tokio Mutex 保持のまま実行し、ワーカースレッドをブロック。→ fd を保持して再利用し、`spawn_blocking` でラップ。
- **R-7** `rpc.rs:104-108, 158-176` — **RPC リクエストをフレームごとに spawn するため処理順序が無保証**。現状は Lua 側の応答 await による直列化で成立しているが、reparse を notification 化した瞬間に「古いセル境界で execute」の競合が顕在化する。→ 状態変更系メソッドはセッション単位で逐次 dispatch。
- **R-8** `ipynb.rs:139-142` — **import_ipynb が既存の同名 .py を無確認で上書き**。→ 既存時はエラー、または `overwrite` パラメータのオプトイン。

### Low

- **R-9** `protocol.rs:122-135` — HMAC 検証が定数時間比較でなく、エラーメッセージに正しい署名値を出力している。→ `Mac::verify_slice` を使い、期待値をメッセージから除去。
- **R-10** `rpc.rs:425-440` — KernelDied 時のセッション破棄前にデバウンス中の出力(クラッシュ原因の手掛かり)が flush されない。→ remove 前に `persist_outputs()`。
- **R-11** `kernel.rs:305-309` — SSH の host 引数が `-` 始まりだとオプション解釈される(引数インジェクション)。→ 宛先検証(先頭 `-` 禁止)を追加。
- **R-12** `notebook.rs:154-155` — id なしセルが reparse のたびに新規ランダム id を得て、サイドカーに孤児エントリが蓄積。→ 決定的 id の導出または persist 時 GC。
- **R-13** `notebook.rs:258-268` — write_sidecar の tmp パスが固定名でプロセス間共有(2 つの nvim インスタンスで競合)、rename 前 fsync なし。→ `tempfile::NamedTempFile` + sync_all。
- **R-14** `rpc.rs:94-97` — RPC フレーム長の上限チェックなし(ずれると最大 4GiB 溜め込み、同期は回復しない)。→ 上限(例 256MiB)超過でフェイルファスト。
- **R-15** `kernel.rs:567` — complete/inspect の 2 秒固定タイムアウトはカーネル busy 中に必ず失敗し、エラー文言からも判別できない。→ タイムアウトの引数化 + busy 区別。
- **R-16** `kernel.rs:580-592` — kernelspec の `interrupt_mode` をパースするが未使用(Jupyter 仕様のデフォルトは SIGINT 方式)。→ ローカルは message 指定以外で SIGINT 経路を追加。
- **R-17** `rpc.rs:25` — `Server::shutdown`(Notify)が一度も notify されないデッドコード。終了経路で persist の強制 flush も走らない。→ graceful shutdown の実装か削除。
- **R-18** `session.rs:298-303` — `clear_output(wait=true)` が未実装で、プログレス表示系セルの出力がサイドカーに無限蓄積。→ `clear_pending` フラグを実装。
- **R-19** `kernelspec.rs:44-55` — `$CONDA_PREFIX`/`$VIRTUAL_ENV` の kernelspec 探索が不必要に home_dir 解決に依存(`$HOME` 未設定の CI/コンテナで失敗)。→ home 依存の項目以外をブロック外へ。

---

## Lua バックエンド・コアロジック(lua/jovian/ ※UI 以外)

### High

- **L-1** `backend/rust_kernel.lua:24,318-329` — **コア再起動後に通知ハンドラが再登録されない**。`_event_handler_registered` がモジュールローカルで一度立つとリセットされず、core クラッシュ→再 spawn 後の新クライアントに `cell_event`/`kernel_event` ハンドラが付かない。実行結果が無言で消失し nvim 再起動まで復旧不能。→ フラグをクライアント単位に持つ、または on_exit でリセット。
- **L-2** `ipynb_open.lua:103-131` — **BufWriteCmd の保存が非同期でデータ損失の恐れ**。`ipynb_encode` RPC のコールバックで書き込むため、`:wq` で E37 になるか、最悪 nvim 終了で **ノートブックが書かれない**(VimLeave 後に scheduled コールバックは走らない)。→ `request_sync` で同期エンコード・書き込みし、失敗は `error()` で Vim に伝える。
- **L-3** `core.lua:63-69` — **Core.ensure() の error() で `is_starting_kernel` が立ちっぱなし**。バイナリ未発見(初回ユーザーの典型経路)で以後の全 :JovianRun/:JovianStart がコールバックを積むだけになり、通知も出ない。→ pcall で包み、失敗時にフラグとコールバックキューをクリアして notify。

### Medium

- **L-4** `backend/core.lua:72-79` — **コアプロセス終了時に State がリセットされない**(job_id/rust_active/rust_session_id/is_starting_kernel/実行中セル)。以後セルが永遠に Running 表示。→ on_exit で kernel_died 相当の掃除を行う。
- **L-5** `backend/rpc.lua:60-65,214-228` — **プロセス終了時に pending コールバックが flush されず、パイプ・ハンドルも close されない**。request_sync はタイムアウトまでブロック。`stop()` も `running=false` にしないため close 済み stdin への write で例外。→ exit 時に pending を "core exited" エラーで flush + close、stop で running を落とす。
- **L-6** `backend/rust_kernel.lua:157-165` — **maybe_finalize_cell 内の最終 refresh_inline_outputs が常に no-op**(set_final が先に cell_buf_map をクリアするため)。無出力になったセルの再実行で古い出力が残る。→ refresh を set_final より前に呼ぶ。
- **L-7** `backend/rust_kernel.lua:348-394` — **起動失敗時に on_ready_callbacks が残留**し、後で別の起動が成功した瞬間に過去のセル実行がまとめて発火する。→ 失敗パスと kernel_died でキューをクリア。
- **L-8** `init.lua:41-350` — **setup() に augroup がなく再呼び出しで 10 個超の autocmd が重複登録**。diagnostics.setup() も handlers を多重ラップ。→ `nvim_create_augroup("Jovian", { clear = true })` を全 autocmd に付与(ipynb_open.lua に正しい先例あり)。
- **L-9** `diagnostics.lua:98-129` — **LspAttach のたびに client.handlers を再ラップし N 段の入れ子になる**(LspAttach はバッファ×クライアントごとに発火)。→ クライアント単位の wrapped フラグでガード。
- **L-10** `core.lua:405-419` — **モジュールロード時のホスト復元が setup() と競合**(Config.setup が options テーブルを作り直すため復元値が消える)。`remote_cwd` も復元されず再起動後の :JovianSync が "." に同期。→ setup() 末尾で use_host と同一コードパスで明示復元。
- **L-11** `rust_kernel.lua:407` + `core.lua:107` — **非同期カーネル起動後の実行がカレントバッファ前提**。起動待ちの数秒間に別バッファへ移動すると、別ファイルの内容が reparse され、ステータスも無関係バッファに描かれる。→ 発行時点で bufnr をクロージャに捕捉して引き回す。
- **L-12** `session.lua:105-135` — **id なし `# %%` ヘッダがセル境界として扱われず、直前セルが誤って Stale 判定**。前セル処理と最終セル処理の完全重複コードもある。→ ヘッダ判定を先に行い current_cell_id を必ず更新、確定処理を flush() に括り出し。
- **L-13** `config.lua:298` + `python.lua:30-41` — **setup() 時の ipykernel プローブが同期 vim.fn.system で nvim 起動を最大 1 秒超ブロック**。`out:match("[Ee]rror")` は警告文を含む正常な python を誤判定。→ 初回カーネル起動まで遅延 or 非同期化、判定は shell_error のみで十分。
- **L-14** `rust_kernel.lua:426-440` + `state.lua:39` — **interrupt/kernel_died で State.batch と完了追跡テーブルが残留**。RunAll 割り込み後に stale な batch が次の実行と混線し得る。→ クリーンアップ関数を 1 つ設けて全経路から呼ぶ。

### Low

- **L-15** `core.lua:378-398` — デッドコード: `show_error_diagnostics`(未呼出)、`State.msg_id_cell_map`(未使用)、それらのためだけの毎実行の全行スキャン。→ 削除。
- **L-16** `core.lua:223` vs `core.lua:142` — markdown セル判定が send_cell と _execute_lines で不一致(非正規形ヘッダが RunAll で python として実行され SyntaxError)。→ Cell モジュールの単一関数に統一。
- **L-17** `commands.lua:360-419` — :JovianSync の引数が rsync オプションとして解釈され得る(`--delete` 等の argument injection)。stdout 集計も jobstart 末尾の空要素を未考慮。→ 相対パスを `./` 正規化、空要素を除外。
- **L-18** `hosts.lua:21-28` — hosts.json の `configs` キー欠如で nil index クラッシュ(全ホスト系コマンドが落ちる)。→ decode 直後に形状正規化。
- **L-19** `ssh_config.lua:41-54,81` — Host ブロック以降の `Include` が到達不能、引数なし Include / DNSName なし peer で nil エラー。→ 分岐位置の修正と nil ガード。
- **L-20** `commands.lua:764-771` — :JovianRestartAndRunAll が Core.restart_kernel の本体を再実装(レイヤ境界違反 + 重複)。→ restart_kernel にコールバック引数を追加。
- **L-21** `backend/core.lua:63-69` — env 構築で JOVIAN_LOG を先頭に置くため、継承環境の同名変数に後勝ちで上書きされ得る。→ environ() をコピーしてキー上書き。
- **L-22** `ipynb_open.lua:73-84` — decode 失敗フォールバック時に modified が立ちっぱなし(`:q` が E37)。さらにその状態の `:w` で raw JSON が ipynb_encode に送られる危険。→ フォールバック後も _mark_pristine + raw 表示中フラグで保存拒否。
- **L-23** `cell.lua:86-114` — get_cell_range が実カーソルを移動させる副作用(範囲外 lnum で未保護例外、CursorMoved autocmd の不要発火)。→ nvim_buf_get_lines ベースの純関数に書き換え。
- **L-24** `complete.lua:25-31` — complete_request の cursor_pos がバイトオフセット(Jupyter 仕様はコードポイント)。多バイト文字で補完位置がずれる。→ `vim.str_utfindex` で変換。
- **L-25** `core.lua:189` — run_line のセル ID が `os.time()` の秒精度で衝突(1 秒内の連打で出力混線)。→ Cell.generate_id() か単調カウンタ。
- **L-26** `init.lua:60-83` + `session.lua:157-174` — デバウンスタイマーをイベント毎に new/close し、scheduled 側が新タイマーを誤って閉じる。→ タイマー 1 本を `stop()/start()` で使い回す。
- **L-27** `commands.lua:585,722,750` — BackendCore.ensure() の error() がユーザーコマンド内で未保護(複数行エラーがそのまま表示)。→ try_ensure() 共通ヘルパ。
- **L-28** `rust_kernel.lua:356,571,633` — RPC 成功応答で result が nil の場合の nil index が rpc.lua の pcall に握りつぶされ、症状だけ残ってデバッグ困難。→ コールバック冒頭で result のガード。

---

## Lua UI レイヤ(lua/jovian/ui/)

### High

- **U-1** `windows.lua:15`(影響: shared.lua / layout.lua) — **get_or_create_buf が無条件に State.term_chan を上書き**。"JovianPreview"/"JovianPin"/"JovianConsole" の作成でもチャネルが差し替わるため、:JovianPin 実行後のカーネル出力がすべて pin バッファに混入する。ensure_output_term では検知不能。→ 端末チャネル open を分離し、output バッファと chan を対で保持・検証する。
- **U-2** `renderers.lua:103-104` — **show_variables が毎回 "JovianVariables" 名でバッファを作るため E95 でクラッシュ**(headless nvim で確認済み)。フロートのページ送り(`<PageUp>/<PageDown>`)2 回目で必ず失敗。→ show_dataframe と同様に既存バッファの再利用。フロート判定(`relative ~= ""`)もウィンドウ検索に必要。

### Medium

- **U-3** `ui.lua:42-61` — **clear_repl の 2 回目で表示中バッファを force delete**(get_or_create_buf が old_buf 自身を返してから削除するため)。Output ウィンドウが迷子になり書き込み先と表示が乖離。→ 先に旧バッファを無名化/削除してから作成。
- **U-4** `shared.lua:28-37` — ensure_output_term が「バッファ存在・chan なし/他バッファ向き」の状態を修復できず、出力が黙って捨てられる。→ chan とバッファの対応を検証して張り直す(U-1 とセットで解決)。
- **U-5** `virtual_text.lua:75,81-102` — **cell_status_extmarks が cell_id のみキーで、複数バッファ間で extmark ID が衝突・誤削除**。→ `{ bufnr, id }` の形で保存し、bufnr が一致するエントリのみ処理。
- **U-6** `cell_frame.lua:256-292,428-433` — **cell_frame OFF 後に wrap chrome(showbreak `│ `、NonText 色)が残留し、ユーザーの元設定も失われる**。→ 初回適用時に退避し、clear/toggle OFF で復元する remove_wrap_chrome を追加。
- **U-7** `renderers.lua:165-174,77-86` — **ハイライト列をバイト列でなく表示幅で計算 + 区切り幅 `+3` のハードコード**(`│`は 3 バイト)。ASCII のみでも 2 バイトずれ、CJK で更に乖離。→ 行構築時にバイト位置を同時記録、`#SEPARATOR` に統一。
- **U-8** `markdown_cell.lua:407-418` — ファイル画像をレンダリングのたびに同期 read + base64 エンコード(CursorMoved 起点の再描画ごと)。→ path+mtime → b64 のキャッシュを追加。
- **U-9** `output_render.lua:79-114` — wrap() が `strcharpart(line, pos, 1)` を 1 文字ずつ呼ぶ O(n²)。巨大トレースバックの inline 表示で固まる。→ コードポイント配列を一度作って線形分割。
- **U-10** `markdown_cell.lua:673-788` / `cell_frame.lua:221-240` — アンチコンシール再描画がカーソル行変更ごとにバッファ全体の再走査・再構築(active_cell_kind はデバウンス無しで parse_cells 全行 match)。→ 前回セルと現在セルの 2 セルのみの差分描画、ヘッダ行リストの changedtick キャッシュ。
- **U-11** `markdown_cell.lua:474` / `markdown_table.lua:196` — フレーム内幅の計算に `nvim_get_current_win()` を使用。WinResized は非カレントウィンドウも描画するため、テーブル罫線・画像ラベルの幅がセルフレーム右罫線と揃わない。→ winid を render/schedule に引き回す。

### Low

- **U-12** `markdown_cell.lua:226-333` — レガシーテーブル整形がバイト幅基準で CJK セルの列ずれ(主経路の MarkdownTable は対応済み)。→ dw ベース化かフォールバック削除。
- **U-13** `virtual_text.lua:47` — markdown セル判定が固定リテラル find で、cell_frame.parse_header が許容する `#%% [markdown]` / `[md]` 等をすり抜ける。→ parse_header に統一。
- **U-14** `virtual_text.lua:119-125` — get_cell_status_extmark の検索終端 `{line, 0}` が次行 col 0 のマークを誤って含む(extmarks の終端は inclusive)。→ `{ line - 1, -1 }`。
- **U-15** `windows.lua:20-26` — placeholder_buf が呼び出しごとに使い捨てバッファを作り bufhidden 未設定で蓄積。→ `bufhidden = "wipe"` かキャッシュ再利用。
- **U-16** `kitty.lua:358-366` — 行/列ダイアクリティクスが 297 超で先頭にフォールバックし、超ワイド端末の全幅 preview で画像左端が複製描画される。→ cols/rows を DIACRITICS 長にクランプ。
- **U-17** `kitty.lua:388-399` — quick_hash がストライドサンプリング+長さのみで、同サイズ PNG の衝突時に別画像が表示される(デバッグ困難)。→ `vim.fn.sha256` に置き換え。
- **U-18** `renderers.lua:279` — show_dataframe のバッファ検索で data.name を Lua パターンに無エスケープ連結(`-` `(` `%` で誤マッチ・例外)。→ `vim.pesc` か plain 比較。
- **U-19** `math.lua:209-230` — 外部コンバータが描画パスで数式ごとに同期 vim.fn.system(初回ノーキャッシュ、_cache も無制限成長)。→ 組み込み変換で即描画 + async で差し替えの 2 段構え。
- **U-20** `markdown_cell.lua:511-516` — 画像行が 2 行連続すると 2 枚目の virt_lines アンカーが conceal_lines 行に落ちて表示されない。→ 上方向の非 conceal 行までアンカーを遡る。
- **U-21** `markdown_table.lua:205-213` — 同一行に複数 namespace の virt_lines(テーブル下罫線とセル閉じ罫線)が付くとき表示順が作成順依存で非決定的。→ 片方に集約(output ブロックと同じ統合方式)。
- **U-22** `output_render.lua:224-294 vs 518-594` — build_virt_lines と outputs_to_preview_lines が出力種別ウォーカーのほぼ完全な重複(「one source of truth」の意図に反する)。append_to_repl も `..` 連結の O(n²)。→ `{ text, hl }` 中間列の共通イテレータ化、table.concat 化。

---

## テスト・ビルド基盤・ドキュメント

### Critical

- **I-1** `flake.nix:168-219`(run-tests) — **テスト失敗が CI に伝播しない**。スクリプトに `set -e` がなく各 nvim 呼び出しの exit code も未確認。終了コードは最後のコマンド = test_remote_ssh.lua(CI では常に SKIP で 0)のものになるため、**他の全テストが失敗していても CI は green**。各テスト自体は os.exit(1) を正しく返しており、欠陥はスクリプト側のみ。→ `set -euo pipefail` を冒頭に追加し、修正後に全テストがまだ green か必ず再確認する。

### High

- **I-2** `lua/jovian/install.lua:71-94` — **ダウンロードバイナリのチェックサム検証なし**(release.yml もチェックサム未公開)。→ release.yml で sha256 を添付し、install.lua で照合、失敗時は cargo フォールバック。

### Medium

- **I-3** `install.lua:34-44` — detect_tag のフォールバック(`--abbrev=0`)が HEAD より古いタグのバイナリをダウンロードし、Lua/バイナリのプロトコルがずれ得る。バージョン照合機構もなし。→ タグ一致時のみプレビルド使用、または起動時 version RPC で照合。
- **I-4** `doc/jovian.txt:539` — 存在しないコマンド `:JovianInstall` に言及(正しくは install.run の build フック)。これ以外の README/doc 記載コマンドは全照合で実在確認済み。→ 記述修正。

### Low

- **I-5** `tests/test_rust_phase1.lua:50-52` 他 4 ファイル — 存在しない設定 `use_rust_core`/`use_lua_native_shell` を渡している(Phase 5 で削除された二重バックエンド時代の残骸)。rust_kernel.lua:2 のコメントも stale。→ 削除・更新。
- **I-6** `flake.nix:27` vs `core/Cargo.toml:3` — バージョン文字列の二重管理(過去に実際にずれた前科あり、現在は 0.10.0 で一致)。→ `builtins.fromTOML` で Cargo.toml を単一の真実源に。
- **I-7** `install.lua:88-89` — curl 失敗時の警告がほぼ常に空(エラーは stderr に出るが stdout のみ捕捉)。→ `vim.system` で stderr を捕捉。
- **I-8** `tests/test_rust_phase1.lua:30-33` — 依存欠如時にサイレント成功(exit 0)。ローカル直接実行で「全部通った」ように見える。→ run-tests 側で SKIP を集計・表示。
- **I-9** `tests/test_kitty_images.lua:154` 他 — 条件なし `vim.wait(200)` スリープ(条件付き wait と混在)。→ 述語付き wait に統一。
- **I-10** `tests/test_features.lua:61-78` — フロート title の型(table/string)前提が同一ファイル内で不一致。nvim 更新時の壊れやすいポイント。→ 正規化ヘルパの共通化。

**テスト登録状況**: tests/ 配下の全 17 ファイルすべてが flake.nix run-tests に登録済み(未登録なし)。ただし I-1 により登録されていても失敗が CI 結果に反映されないため、実効カバレッジは現状「最後の 1 ファイル分」のみ。

---

## 統計

| 領域 | critical | high | medium | low | 計 |
|---|---|---|---|---|---|
| Rust コア | 0 | 1 | 7 | 11 | 19 |
| Lua バックエンド・コア | 0 | 3 | 11 | 14 | 28 |
| Lua UI | 0 | 2 | 9 | 11 | 22 |
| テスト・インフラ | 1 | 1 | 2 | 6 | 10 |
| **計** | **1** | **7** | **29** | **42** | **79** |

## 推奨する着手順

1. **I-1(run-tests の set -e)** — 1 行の修正で CI の安全網が復活する。他のすべての修正の検証基盤になるため最初に。
2. **L-2(ipynb 同期保存)** — 唯一のデータ損失リスク。
3. **クラッシュ復旧経路の一括整理(L-1, L-3, L-4, L-5, L-7, L-14)** — backend/core.lua の on_exit に後始末を集約し、「セッション終了クリーンアップ」関数を 1 つ定義して全経路(interrupt/stop/restart/kernel_died/on_exit)から呼ぶ。
4. **U-1/U-3/U-4(term_chan の所有権)** — output バッファと chan を対のオブジェクトとして shared.lua が所有する形に。
5. **R-1(ロック保持区間)、U-2(E95)、I-2(チェックサム)** — それぞれ独立に修正可能。
6. 残りの medium/low は通常の開発サイクルで順次。
