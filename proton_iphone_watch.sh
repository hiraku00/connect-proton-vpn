#!/usr/bin/env bash
# iPhone Mirroring上のProton VPNをJPNサーバーに接続するまで自動リトライするスクリプト
set -euo pipefail

# スクリプトのディレクトリ
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ============================================================
# 設定
# ============================================================
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/proton_iphone.conf}"

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

# ============================================================
# セットアップ（起動時インライン確認）
# ============================================================

# マウスの現在座標を取得
get_mouse_pos() {
  python3 -c "
import Quartz
loc = Quartz.CGEventGetLocation(Quartz.CGEventCreate(None))
print(int(loc.x), int(loc.y))
"
}

# 座標取得プロンプト（プロンプトはstderr、座標のみstdout）
capture_pos() {
  local label=$1
  echo "  >>> 「${label}」ボタンの上にマウスを移動し、Enterキーを押してください..." >&2
  read -r
  local pos
  pos=$(get_mouse_pos)
  local x y
  x=$(echo "$pos" | awk '{print $1}')
  y=$(echo "$pos" | awk '{print $2}')
  echo "      → (${x}, ${y}) を記録しました。" >&2
  echo "${x} ${y}"
}

# iPhone Mirroringウィンドウの現在位置を取得
get_window_bounds() {
  osascript -e '
    tell application "System Events"
      set proc to first process whose name is "iPhone Mirroring"
      set w to first window of proc
      set pos to position of w
      set sz to size of w
      return (item 1 of pos as string) & "," & (item 2 of pos as string) & "," & (item 1 of sz as string) & "," & (item 2 of sz as string)
    end tell
  ' 2>/dev/null || echo ""
}

# 座標がウィンドウ内に含まれるか確認
is_coord_in_window() {
  local px=$1 py=$2 wx=$3 wy=$4 ww=$5 wh=$6
  [ "$px" -ge "$wx" ] && [ "$py" -ge "$wy" ] && \
  [ "$px" -le $((wx + ww)) ] && [ "$py" -le $((wy + wh)) ]
}

# セットアップ処理
run_setup() {
  echo "" >&2
  echo "  ▼ ボタン座標の登録を開始します。" >&2
  echo "" >&2
  local main_pos disconnect_pos
  read -r main_pos < <(capture_pos "Connect / Change server")
  read -r disconnect_pos < <(capture_pos "Disconnect")

  CHANGE_SERVER_X=$(echo "$main_pos" | awk '{print $1}')
  CHANGE_SERVER_Y=$(echo "$main_pos" | awk '{print $2}')
  CONNECT_X=${CHANGE_SERVER_X}
  CONNECT_Y=${CHANGE_SERVER_Y}
  DISCONNECT_X=$(echo "$disconnect_pos" | awk '{print $1}')
  DISCONNECT_Y=$(echo "$disconnect_pos" | awk '{print $2}')

  cat > "$CONFIG_FILE" <<EOF
# Proton VPN iPhone Watcher 設定ファイル
# 生成: $(date)
IPHONE_APP="iPhone Mirroring"
CHANGE_SERVER_X=${CHANGE_SERVER_X}
CHANGE_SERVER_Y=${CHANGE_SERVER_Y}
DISCONNECT_X=${DISCONNECT_X}
DISCONNECT_Y=${DISCONNECT_Y}
CONNECT_X=${CONNECT_X}
CONNECT_Y=${CONNECT_Y}
EOF
  echo "" >&2
  echo "  設定を保存しました:" >&2
  echo "    Connect / Change server: (${CONNECT_X}, ${CONNECT_Y})" >&2
  echo "    Disconnect             : (${DISCONNECT_X}, ${DISCONNECT_Y})" >&2
}

# 起動時のセットアップ確認
check_and_setup() {
  # 設定ファイルがない場合は初回セットアップ
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "設定ファイルが見つかりません。ボタン座標を登録します。" >&2
    run_setup
    return
  fi

  # shellcheck source=/dev/null
  source "$CONFIG_FILE"

  # ウィンドウの現在位置を取得して座標の整合性を確認
  local bounds
  bounds=$(get_window_bounds)
  if [[ -z "$bounds" ]]; then
    echo "⚠️  iPhone Mirroringが起動していません。起動してから再実行してください。" >&2
    exit 1
  fi

  local wx wy ww wh
  IFS=',' read -r wx wy ww wh <<< "$bounds"

  # 保存済み座標がウィンドウ内にあるか確認
  if is_coord_in_window "$CHANGE_SERVER_X" "$CHANGE_SERVER_Y" "$wx" "$wy" "$ww" "$wh" && \
     is_coord_in_window "$DISCONNECT_X" "$DISCONNECT_Y" "$wx" "$wy" "$ww" "$wh"; then
    echo "前回の設定を使用します（Change server: ${CHANGE_SERVER_X},${CHANGE_SERVER_Y} / Disconnect: ${DISCONNECT_X},${DISCONNECT_Y}）" >&2
    printf "  続行しますか？ [Y/n] " >&2
    read -r answer
    if [[ "$answer" =~ ^[Nn]$ ]]; then
      echo "ボタン座標を再登録します。" >&2
      run_setup
    fi
  else
    echo "⚠️  ウィンドウ位置が変わっているため、ボタン座標を再登録します。" >&2
    run_setup
  fi
}

# ============================================================
# iPhone Mirroring クリック操作
# ============================================================
click_at() {
  local x=$1
  local y=$2
  osascript -e 'tell application "iPhone Mirroring" to activate' >/dev/null 2>&1 || true
  sleep 0.3
  python3 -c "
import Quartz, time
pos = ($x, $y)
e_down = Quartz.CGEventCreateMouseEvent(None, Quartz.kCGEventLeftMouseDown, pos, Quartz.kCGMouseButtonLeft)
Quartz.CGEventPost(Quartz.kCGHIDEventTap, e_down)
time.sleep(0.1)
e_up = Quartz.CGEventCreateMouseEvent(None, Quartz.kCGEventLeftMouseUp, pos, Quartz.kCGMouseButtonLeft)
Quartz.CGEventPost(Quartz.kCGHIDEventTap, e_up)
"
}

gui_change_server() {
  log "Change server をクリック (${CHANGE_SERVER_X}, ${CHANGE_SERVER_Y})"
  click_at "$CHANGE_SERVER_X" "$CHANGE_SERVER_Y"
}

gui_disconnect() {
  log "Disconnect をクリック (${DISCONNECT_X}, ${DISCONNECT_Y})"
  click_at "$DISCONNECT_X" "$DISCONNECT_Y"
}

gui_connect() {
  log "Connect をクリック (${CONNECT_X}, ${CONNECT_Y})"
  click_at "$CONNECT_X" "$CONNECT_Y"
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

  # セットアップ確認（起動時インライン）
  check_and_setup

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
    gui_connect
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
      gui_change_server
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
      gui_disconnect
      countdown "$wait_sec" "制限解除を待機中..."
      log "待機終了。再接続します..."
      gui_connect
      sleep "$RECONNECT_WAIT"
    else
      countdown "$wait_sec" "制限解除を接続したまま待機中..."
    fi
  done
}

main "$@"
