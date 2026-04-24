#!/usr/bin/env bash
set -euo pipefail

BASE_WAIT="${BASE_WAIT:-45}"
LONG_WAIT="${LONG_WAIT:-600}"
MAX_TRIES="${MAX_TRIES:-0}"

# コマンド定義（タイムアウト設定を追加し、安定性を向上）
CONNECT_CMD="osascript -e 'with timeout of 5 seconds
  tell application \"System Events\" to tell process \"ProtonVPN\" to click button \"Change server\" of window 1
end timeout'"
QUICK_CONNECT_CMD="osascript -e 'with timeout of 5 seconds
  tell application \"System Events\" to tell process \"ProtonVPN\" to click button \"Quick Connect\" of window 1
end timeout'"
DISCONNECT_CMD="osascript -e 'with timeout of 5 seconds
  tell application \"System Events\" to tell process \"ProtonVPN\" to click button \"Disconnect\" of window 1
end timeout'"
INFO_CMD="osascript -e 'with timeout of 5 seconds
  tell application \"System Events\" to tell process \"ProtonVPN\" to get enabled of button \"Change server\" of window 1
end timeout'"

IP_API_URL="${IP_API_URL:-https://ipinfo.io/json}"
LOG_FILE="${LOG_FILE:-./proton_japan_watch.log}"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}

# カウントダウン表示用の関数
countdown() {
  local seconds=$1
  local msg=$2
  while [ $seconds -gt 0 ]; do
    printf "\r[%s] %s (残り %d 秒)    " "$(date '+%Y-%m-%d %H:%M:%S')" "$msg" "$seconds"
    sleep 1
    seconds=$((seconds - 1))
  done
  printf "\r"
  echo ""
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1" >&2; exit 1; }
}

get_country() {
  local raw=""
  local apis=(
    "$IP_API_URL"
    "http://ip-api.com/json/"
    "https://ipapi.co/json/"
  )

  for url in "${apis[@]}"; do
    raw="$(curl -fsSL --max-time 10 "$url" 2>/dev/null || true)"
    if [[ -n "$raw" && "$raw" == *"country"* ]]; then
      break
    fi
  done

  JSON_INPUT="$raw" python3 - <<'PY'
import json, os
raw = os.environ.get('JSON_INPUT', '')
try:
    data = json.loads(raw)
except Exception:
    print('')
    raise SystemExit(0)
for key in ('country_name', 'country', 'country_code', 'countryCode'):
    value = data.get(key)
    if value:
        print(str(value).strip())
        break
PY
}

is_japan() {
  local c
  c="$(get_country)"
  case "$c" in
    Japan|JP|JPN)
      log "現在の国: $c"
      return 0
      ;;
    *)
      if [[ -n "$c" ]]; then
        log "現在の国: $c"
      else
        log "国の判定に失敗しました"
      fi
      return 1
      ;;
  esac
}

# アプリ上のタイマー（09:59など）を取得
get_timer() {
  osascript -e 'with timeout of 5 seconds
    tell application "System Events" to tell process "ProtonVPN"
      set timer_text to ""
      set all_texts to value of every static text of window 1
      repeat with t in all_texts
        if t contains ":" and (count of t) is 5 then
          set timer_text to t
          exit repeat
        end if
      end repeat
      return timer_text
    end tell
  end timeout' 2>/dev/null || echo ""
}

vpn_info() {
  eval "$INFO_CMD" 2>/dev/null || echo "false"
}

change_not_available() {
  local info_text
  info_text="$(vpn_info)"
  [[ "$info_text" == "false" ]]
}

reconnect() {
  log "サーバーを切り替えます（Change server）"
  if ! eval "$CONNECT_CMD" >/dev/null 2>&1; then
    log "切り替えボタンが見つからないか、クリックできませんでした。状態を確認します。"
    return 1
  fi
}

main() {
  need_cmd curl
  need_cmd python3
  need_cmd osascript

  log "Proton VPN 日本接続監視を開始します"
  log "通常待機: ${BASE_WAIT}秒, 制限時待機: ${LONG_WAIT}秒"

  # 初回起動時、未接続なら Quick Connect を試みる
  log "初期チェック: Quick Connect を試行します..."
  eval "$QUICK_CONNECT_CMD" >/dev/null 2>&1 || log "Quick Connectは不要か、ボタンが見つかりません"
  sleep 5

  while true; do
    # 1. 現在の国を確認
    if is_japan; then
      log "日本への接続を確認しました。終了します。"
      exit 0
    fi

    # 2. Change server を試行
    log "日本ではありません。サーバーを切り替えます..."
    reconnect || log "切り替え試行中ですが、ボタンが一時的に無効な可能性があります。"
    
    # 接続完了を待つ
    sleep 10
    
    # 3. 直後の国判定
    if is_japan; then
      log "日本への接続を確認しました。終了します。"
      exit 0
    fi

    # 4. タイマー（制限時間）が出ていないか確認
    local vpn_timer=""
    vpn_timer=$(get_timer)
    if [[ -n "$vpn_timer" ]]; then
      log "制限タイマーを検知しました（残り ${vpn_timer}）。10分待機モードに入ります。"
    elif change_not_available; then
      # ボタンが無効なら通常の待機をして再確認
      countdown "$BASE_WAIT" "日本ではありません。通常待機中..."
      if change_not_available; then
        log "待機後もボタンが無効です。10分待機モードに入ります。"
      else
        continue
      fi
    else
      # ボタンが有効なら、45秒待って次へ
      countdown "$BASE_WAIT" "日本ではありません。通常待機中..."
      continue
    fi

    # 5. 10分待機モード（切断して待つ）
    log "VPNを切断し、${LONG_WAIT}秒間待機します..."
    eval "$DISCONNECT_CMD" >/dev/null 2>&1 || true
    countdown "$LONG_WAIT" "制限解除を待機中..."
    
    log "待機終了。再接続します..."
    eval "$QUICK_CONNECT_CMD" >/dev/null 2>&1 || true
    sleep 15
  done
}

main "$@"
