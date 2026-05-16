# Proton VPN Japan Watcher (macOS & iPhone Mirroring)

Proton VPN の無料プランを利用して、日本（Japan）のサーバーに接続されるまで自動切り替えを試行し続けるツール群です。macOS版（デスクトップアプリ用）と iPhone Mirroring版（iPhoneアプリ用）の両方に対応しています。

---

## 1. macOS版 (`proton_japan_watch.sh`)

macOS のデスクトップ版 Proton VPN アプリを操作します。

### 特徴
- **UIオートメーション**: AppleScript を使用して、アプリ内のテキスト情報を直接読み取ります。
- **スマート待機**: アプリ上のタイマー（MM:SS）を解析し、最適な待ち時間を算出します。
- **条件付き切断**: 待ち時間が長い（60秒超）場合はVPNを切断してリソースを節約します。

---

## 2. iPhone Mirroring版 (`proton_iphone_watch.sh`)

macOS の iPhone Mirroring 機能を通じて、iPhone上の Proton VPN アプリを操作します。

### 特徴
- **OCRによる画面認識**: macOS標準の Vision Framework を使用して、ミラーリング画面上の国名とタイマーを読み取ります。
- **座標ベースの自動操作**: ボタン位置を指定した座標クリックで操作します。
- **自動再セットアップ**: ウィンドウ位置が変わった場合や初回起動時に、マウス操作によるボタン座標の登録を促します。
- **テザリング不要の国判定**: 画面を直接読み取るため、Mac側のネットワーク構成に依存せず判定可能です。

---

## 主な共通機能

- **スマート待機ロジック**:
  - 正確な残り時間を算出し、待ち時間が短い（デフォルト60秒未満）場合は接続を維持、長い場合は切断して待機します。
- **リアルタイム表示**:
  - コンソール上で残り時間を同一行でカウントダウン表示します。
- **詳細なカスタマイズ**:
  - スクリプト冒頭の変数で各種待機時間やバッファを調整可能です。

## 前提条件

- **OS**: macOS
- **アプリ**: [Proton VPN] のデスクトップ版または iPhone版
- **ツール**: `python3` (Quartz, Vision 連携用)
- **権限**: ターミナル等に「アクセシビリティ」および「画面収録」の許可が必要です。

## セットアップと実行

### macOS版
```bash
chmod +x ./proton_japan_watch.sh
./proton_japan_watch.sh
```

### iPhone Mirroring版
```bash
# 事前に iPhone Mirroring で Proton VPN を開いておいてください
chmod +x ./proton_iphone_watch.sh
./proton_iphone_watch.sh
```
※ 初回またはウィンドウ位置変更時は、画面の指示に従ってマウスをボタンの上に置いて Enter を押してください。

## カスタマイズ（スクリプト冒頭）

| 変数名 | デフォルト | 内容 |
| :--- | :--- | :--- |
| `BASE_WAIT` | `45` | タイマー未検知時のリトライ間隔（秒） |
| `DISCONNECT_THRESHOLD` | `60` | これ以上の待ち時間ならVPNを切断する閾値（秒） |
| `TIMER_BUFFER` | `1` | タイマーに対する安全マージン（秒） |
| `INITIAL_WAIT` | `5` | 起動直後の安定待ち時間（秒） |
| `CONNECT_WAIT` | `10` | 操作後の反映待ち（秒） |

## ライセンス

MIT License
