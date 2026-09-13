#!/usr/bin/env bash
# iPhone Mirroring上のProton VPNをJPNサーバーに接続するまで自動リトライするスクリプト
set -euo pipefail

# スクリプトのディレクトリ
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ============================================================
# 設定
# ============================================================
# --- OCRでタイマーが検出できない場合の待機設定 ---
# サーバー切り替え後にタイマーが出ていない（制限なし）が日本でもない場合の、次回の切り替え試行までの間隔
BASE_WAIT="${BASE_WAIT:-45}"
# OCRが完全に失敗した際などの最長待機時間のフォールバック値
LONG_WAIT="${LONG_WAIT:-600}"

# --- OCR連携と待機戦略の設定 ---
# OCRで読み取った残り時間がこの秒数より長ければ、VPNを切断して待機する（リソース節約）
DISCONNECT_THRESHOLD="${DISCONNECT_THRESHOLD:-60}"
# OCRで読み取った秒数に加える安全マージン（通信ラグ対策）
TIMER_BUFFER="${TIMER_BUFFER:-1}"

# --- アプリ操作・画面遷移の待ち時間設定 ---
# 起動直後の Connect クリック後の待機時間
INITIAL_WAIT="${INITIAL_WAIT:-5}"
# サーバー切り替え（Change server）クリック後の待機時間（画面更新を待つため）
CONNECT_WAIT="${CONNECT_WAIT:-10}"
# 制限解除後の再接続クリック後の待機時間
RECONNECT_WAIT="${RECONNECT_WAIT:-15}"

LOG_FILE="${LOG_FILE:-${SCRIPT_DIR}/proton_iphone_watch.log}"

# ============================================================
# ユーティリティ関数
# ============================================================
log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}

countdown() {
  local seconds=$1
  local msg=$2
  log "${msg}（${seconds}秒待機）"
  while [ $seconds -gt 0 ]; do
    printf "\r\033[K[%s] %s (残り %d 秒)" "$(date '+%Y-%m-%d %H:%M:%S')" "$msg" "$seconds"
    sleep 1
    seconds=$((seconds - 1))
  done
  printf "\r\033[K"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1" >&2; exit 1; }
}

# iPhone Mirroringのウィンドウが表示されているか確認
check_window() {
  if ! python3 -c "
import sys
sys.path.insert(0, '${SCRIPT_DIR}')
from iphone_ocr import get_iphone_mirroring_window_bounds
sys.exit(0 if get_iphone_mirroring_window_bounds() else 1)
" 2>/dev/null; then
    echo "⚠️  iPhone Mirroringが起動していません。起動してから再実行してください。" >&2
    exit 1
  fi
}

# ============================================================
# iPhone Mirroring クリック操作
# ============================================================
# iPhone Mirroringはアクセシビリティでボタンを取得できないため、
# OCRで画面上のボタン文字列を探し、その位置をクリックする（ウィンドウ位置は毎回再取得）
click_button() {
  local label=$1 pos
  if pos=$(python3 "${SCRIPT_DIR}/iphone_ocr.py" click "$label" 2>/dev/null); then
    log "${label} をクリック (${pos/ /, })"
  else
    log "「${label}」ボタンが画面上に見つかりませんでした"
    return 1
  fi
}

gui_change_server() {
  click_button "Change server"
}

gui_disconnect() {
  click_button "Disconnect"
}

gui_connect() {
  click_button "Connect"
}

# ============================================================
# 国判定・タイマー検知（OCR）
# ============================================================
get_vpn_status_json() {
  python3 -c "
import sys, json
sys.path.insert(0, '${SCRIPT_DIR}')
from iphone_ocr import get_vpn_status
status = get_vpn_status()
print(json.dumps(status))
" 2>/dev/null || echo '{"country": null, "timer_seconds": 0}'
}

is_japan() {
  local status country
  status=$(get_vpn_status_json)
  country=$(echo "$status" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('country') or '')" 2>/dev/null)
  if [[ -z "$country" ]]; then
    log "国名のOCR取得に失敗しました"
    return 1
  fi
  log "現在の国: ${country}"
  case "$country" in
    Japan|JP|JPN|japan|jp|jpn) return 0 ;;
    *) return 1 ;;
  esac
}

get_timer_seconds() {
  local status
  status=$(get_vpn_status_json)
  echo "$status" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('timer_seconds', 0))" 2>/dev/null || echo "0"
}

# ============================================================
# メインループ
# ============================================================
main() {
  need_cmd python3
  need_cmd osascript

  check_window

  log "Proton VPN iPhone 日本接続監視を開始します"
  log "設定: 通常待機=${BASE_WAIT}s, 制限切断閾値=${DISCONNECT_THRESHOLD}s, バッファ=${TIMER_BUFFER}s"

  log "初期チェック: 接続状態を確認します..."
  local status country
  status=$(get_vpn_status_json)
  country=$(echo "$status" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('country') or '')" 2>/dev/null)

  if [[ "$country" =~ ^(Japan|JP|JPN|japan|jp|jpn)$ ]]; then
    log "すでに日本への接続を確認しました。終了します。"
    exit 0
  fi

  if [[ -z "$country" ]]; then
    # 未接続の場合のみ Connect をクリック
    log "未接続の状態です。接続を試行します..."
    gui_connect || true
    sleep "$INITIAL_WAIT"
  else
    # すでに他国に接続中の場合は、そのままループに入ってタイマー等の処理を行う
    log "他国 (${country}) に接続中です。監視を開始します..."
  fi

  while true; do
    # 1. 現在の状態（国 + タイマー）を取得
    local status country timer_sec
    status=$(get_vpn_status_json)
    country=$(echo "$status" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('country') or '')" 2>/dev/null)
    timer_sec=$(echo "$status" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('timer_seconds', 0))" 2>/dev/null || echo "0")

    if [[ -n "$country" ]]; then
      log "現在の国: ${country}"
    fi

    # 2. 日本なら終了
    case "${country:-}" in
      Japan|JP|JPN|japan|jp|jpn)
        log "日本への接続を確認しました。終了します。"
        exit 0
        ;;
    esac

    # 3. タイマーがない場合のみサーバー切り替えを試行
    if [ "$timer_sec" -le 0 ]; then
      log "日本ではありません。サーバーを切り替えます..."
      # 未接続で Change server がない場合は Connect を押す
      gui_change_server || gui_connect || true
      sleep "$CONNECT_WAIT"

      # 切り替え後の状態を再取得
      status=$(get_vpn_status_json)
      country=$(echo "$status" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('country') or '')" 2>/dev/null)
      timer_sec=$(echo "$status" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('timer_seconds', 0))" 2>/dev/null || echo "0")

      if [[ -n "$country" ]]; then
        log "切り替え後の国: ${country}"
      fi

      if [[ "$country" =~ ^(Japan|JP|JPN|japan|jp|jpn)$ ]]; then
        log "日本への接続を確認しました。終了します。"
        exit 0
      fi
    fi

    # 4. タイマーに基づいた待機戦略
    local wait_sec=$timer_sec
    if [ "$wait_sec" -gt 0 ]; then
      local m s
      m=$((wait_sec / 60))
      s=$((wait_sec % 60))
      log "制限タイマーを検知しました（残り ${m}分${s}秒 = ${wait_sec}秒）。"
      wait_sec=$((wait_sec + TIMER_BUFFER))
    else
      # タイマーなし → 通常の45秒待機
      countdown "$BASE_WAIT" "日本ではありません。通常待機中..."

      # 待機後に再度確認
      if is_japan; then
        log "日本への接続を確認しました。終了します。"
        exit 0
      fi
      # 次ループへ（Change serverを再試行）
      continue
    fi

    # 5. 待機（短ければ接続維持、長ければ切断）
    if [ "$wait_sec" -ge "$DISCONNECT_THRESHOLD" ]; then
      log "待ち時間が長いため（${wait_sec}秒）、VPNを切断して待機します..."
      gui_disconnect || true
      countdown "$wait_sec" "制限解除を待機中..."
      log "待機終了。再接続します..."
      gui_connect || true
      sleep "$RECONNECT_WAIT"
    else
      countdown "$wait_sec" "制限解除を接続したまま待機中..."
    fi
  done
}

main "$@"
