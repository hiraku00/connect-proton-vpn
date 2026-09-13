"""
iPhone Mirroring上のProton VPNアプリを読み取り・操作するOCRモジュール。
auto-daily-report/src/ocr_utils.py と同じVision Frameworkを使用。

iPhone Mirroringのウィンドウ中身は映像ストリームのため、macOS版のように
アクセシビリティ経由でボタンを取得できない。代わりにOCRで認識した
テキストの位置からボタンの座標を求めてクリックする。
"""

import re
import subprocess
import sys
import time

import Quartz
import Vision


APP_NAME = "iPhone Mirroring"

# Proton VPN無料プランで利用可能な国名（英語表記）
PROTON_FREE_COUNTRIES = {
    "Japan", "United States", "Netherlands", "Canada",
    "Mexico", "Norway", "Poland", "Romania", "Singapore", "Switzerland",
    # 略称も念のため
    "JP", "US", "NL", "CA", "MX", "NO", "PL", "RO", "SG", "CH",
}


def _find_mirroring_window() -> dict | None:
    """iPhone Mirroringのメインウィンドウ情報（CGWindowList）を返す。"""
    windows = Quartz.CGWindowListCopyWindowInfo(
        Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements,
        Quartz.kCGNullWindowID,
    ) or []
    candidates = [
        w for w in windows
        if w.get("kCGWindowOwnerName") == APP_NAME and w.get("kCGWindowLayer") == 0
    ]
    if not candidates:
        return None
    # 補助的な細長いウィンドウを除外するため、最大面積のものを選ぶ
    return max(
        candidates,
        key=lambda w: w["kCGWindowBounds"]["Width"] * w["kCGWindowBounds"]["Height"],
    )


def get_iphone_mirroring_window_bounds() -> tuple[int, int, int, int] | None:
    """iPhone Mirroringウィンドウの座標と大きさを取得する。"""
    win = _find_mirroring_window()
    if win is None:
        return None
    b = win["kCGWindowBounds"]
    return int(b["X"]), int(b["Y"]), int(b["Width"]), int(b["Height"])


def capture_window_to_cgimage(window_id: int):
    """指定ウィンドウのみをCGImageとして撮影する（他のウィンドウが重なっていても影響を受けない）。"""
    return Quartz.CGWindowListCreateImage(
        Quartz.CGRectNull,
        Quartz.kCGWindowListOptionIncludingWindow,
        window_id,
        Quartz.kCGWindowImageBoundsIgnoreFraming,
    )


def _recognize(image_ref) -> list:
    """CGImageからVision FrameworkでOCRを実行し、[(テキスト, 正規化矩形), ...] を返す。"""
    if image_ref is None:
        return []

    request = Vision.VNRecognizeTextRequest.alloc().init()
    request.setRecognitionLevel_(Vision.VNRequestTextRecognitionLevelAccurate)
    request.setUsesLanguageCorrection_(True)
    request.setRecognitionLanguages_(["en-US"])  # 国名は英語

    handler = Vision.VNImageRequestHandler.alloc().initWithCGImage_options_(image_ref, None)
    success, error = handler.performRequests_error_([request], None)

    if not success:
        print(f"[OCR] テキスト認識エラー: {error}", flush=True)
        return []

    return [
        (obs.topCandidates_(1)[0].string(), obs.boundingBox())
        for obs in request.results() or []
    ]


def recognize_text_from_cgimage(image_ref) -> str:
    """CGImageからVision FrameworkでOCRを実行してテキストを返す。"""
    return "\n".join(text for text, _ in _recognize(image_ref))


def ocr_window() -> list[tuple[str, int, int]] | None:
    """
    iPhone Mirroringウィンドウを撮影・OCRし、[(テキスト, 画面X, 画面Y), ...] を返す。
    座標は各テキストの中心のスクリーン座標。ウィンドウがなければ None を返す。
    """
    win = _find_mirroring_window()
    if win is None:
        return None
    b = win["kCGWindowBounds"]
    x, y, w, h = b["X"], b["Y"], b["Width"], b["Height"]
    image_ref = capture_window_to_cgimage(win["kCGWindowNumber"])

    items = []
    for text, box in _recognize(image_ref):
        # Visionは左下原点の正規化座標なので、左上原点のスクリーン座標へ変換
        cx = x + (box.origin.x + box.size.width / 2) * w
        cy = y + (1 - box.origin.y - box.size.height / 2) * h
        items.append((text, int(cx), int(cy)))
    return items


def _read_window_text() -> str:
    items = ocr_window()
    if not items:
        return ""
    return "\n".join(text for text, _, _ in items)


def extract_country_from_text(text: str) -> str | None:
    """
    OCR結果のテキストから接続国名を抽出する。
    """
    text_lower = text.lower()

    # 1. 「Japan」がテキスト内のどこかに含まれていれば、最優先で Japan を返す
    if "japan" in text_lower or "jpn" in text_lower:
        return "Japan"

    # 2. その他の有効な国名が含まれているかチェック
    for country in PROTON_FREE_COUNTRIES:
        if len(country) > 2 and country.lower() in text_lower:
            return country

    # 3. 国名が直接見つからない場合のフォールバック
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if "browsing" in line.lower() and "from" in line.lower():
            for j in range(i + 1, min(i + 4, len(lines))):
                candidate = lines[j].strip()
                cand_lower = candidate.lower()

                # UIボタンのテキストはスキップ
                if cand_lower in ("disconnect", "connect", "change server", "change"):
                    continue

                if re.match(r"^[A-Za-z ]+$", candidate) and len(candidate) >= 2:
                    return candidate

    return None


def extract_timer_seconds_from_text(text: str) -> int:
    """
    OCR結果のテキストからProton VPN制限タイマー（MM:SS）を抽出し、秒数で返す。
    見つからなければ 0 を返す。

    注意:
    - Proton VPN無料プランの制限は最大10分（600秒）のため、
      MM は 0〜9（一桁）のもののみタイマーとして扱う。
    - これにより、iPhoneのステータスバーの時刻表示（16:40 等）を
      誤検知しない。
    - "Change server" テキスト近傍を優先的に探す。
    """
    # MM:SS 形式のパターン（分は1〜2桁、秒は00〜59）
    TIMER_PATTERN = r"\b([0-9]{1,2}):([0-5][0-9])\b"

    lines = text.splitlines()

    # "Change server"（または"change"）テキストの近傍のみを探す
    for i, line in enumerate(lines):
        if "change server" in line.lower() or "change" in line.lower():
            # 前後2行も含めて確認（OCRで別の行として認識される場合を考慮）
            search_range = range(max(0, i - 2), min(len(lines), i + 3))
            for j in search_range:
                matches = re.findall(TIMER_PATTERN, lines[j])
                for min_str, sec_str in matches:
                    minutes = int(min_str)
                    seconds = int(sec_str)
                    if minutes == 0 and seconds == 0:
                        continue
                    return minutes * 60 + seconds

    return 0


def find_button(items: list[tuple[str, int, int]], label: str) -> tuple[int, int] | None:
    """
    OCR結果からラベルで始まるテキストを探し、その中心座標を返す。
    "Connect" が "Disconnect" や "Connected" に誤マッチしないよう、先頭一致＋単語境界で判定する。
    """
    pattern = re.compile(rf"^{re.escape(label)}\b", re.IGNORECASE)
    matches = [(x, y) for text, x, y in items if pattern.match(text.strip())]
    if not matches:
        return None
    # 同じ文字列が複数ある場合は、ボタンが配置される画面下側を優先
    return max(matches, key=lambda p: p[1])


def activate_mirroring() -> None:
    subprocess.run(
        ["osascript", "-e", f'tell application "{APP_NAME}" to activate'],
        capture_output=True,
    )


def click_at(x: int, y: int) -> None:
    pos = (x, y)
    e_down = Quartz.CGEventCreateMouseEvent(None, Quartz.kCGEventLeftMouseDown, pos, Quartz.kCGMouseButtonLeft)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, e_down)
    time.sleep(0.1)
    e_up = Quartz.CGEventCreateMouseEvent(None, Quartz.kCGEventLeftMouseUp, pos, Quartz.kCGMouseButtonLeft)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, e_up)


def click_button(label: str, attempts: int = 3, interval: float = 1.0) -> tuple[int, int] | None:
    """
    画面上から label のボタンをOCRで探してクリックする。
    クリックした座標を返し、見つからなければ None を返す。
    ウィンドウ位置は毎回取得し直すため、ウィンドウを移動しても再設定は不要。
    接続直後などの画面遷移中は文字が読めないことがあるため、数回リトライする。
    """
    activate_mirroring()
    time.sleep(0.3)
    for i in range(attempts):
        if i > 0:
            time.sleep(interval)
        pos = find_button(ocr_window() or [], label)
        if pos is not None:
            click_at(*pos)
            return pos
    return None


def get_connected_country() -> str | None:
    """
    iPhone Mirroringウィンドウを撮影・OCRして接続中の国名を返す。
    取得できなければ None を返す。
    """
    text = _read_window_text()
    if not text:
        return None
    return extract_country_from_text(text)


def get_timer_seconds() -> int:
    """
    iPhone Mirroringウィンドウを撮影・OCRして制限タイマーの残り秒数を返す。
    タイマーがなければ 0 を返す。
    """
    text = _read_window_text()
    if not text:
        return 0
    return extract_timer_seconds_from_text(text)


def get_vpn_status() -> dict:
    """
    iPhone Mirroringウィンドウを一度撮影・OCRして、国名とタイマーをまとめて返す。
    {'country': str|None, 'timer_seconds': int}
    """
    text = _read_window_text()
    if not text:
        return {"country": None, "timer_seconds": 0}
    return {
        "country": extract_country_from_text(text),
        "timer_seconds": extract_timer_seconds_from_text(text),
    }


def is_connected_to_japan() -> bool:
    """アプリ画面かOCRで日本接続を確認。"""
    country = get_connected_country()
    if country is None:
        print("[OCR] 国名を取得できませんでした", flush=True)
        return False
    print(f"[OCR] 接続国: {country}", flush=True)
    return country.strip().lower() in ("japan", "jp", "jpn")


def _main(argv: list[str]) -> int:
    # ボタンクリック: python3 iphone_ocr.py click "Change server"  → 成功時 "X Y" を出力
    if len(argv) == 2 and argv[0] == "click":
        pos = click_button(argv[1])
        if pos is None:
            print(f"[OCR] ボタンが見つかりません: {argv[1]}", file=sys.stderr)
            return 1
        print(f"{pos[0]} {pos[1]}")
        return 0

    # 認識結果の一覧（ボタンが見つからない時の調査用）: python3 iphone_ocr.py list
    if argv == ["list"]:
        items = ocr_window()
        if items is None:
            print(f"[OCR] {APP_NAME} のウィンドウが見つかりません", file=sys.stderr)
            return 1
        for text, x, y in items:
            print(f"({x:5d}, {y:5d})  {text}")
        return 0

    # 動作確認用
    print("iPhone Mirroringウィンドウを読み取ります...")
    status = get_vpn_status()
    country = status["country"]
    timer = status["timer_seconds"]
    print(f"検出した国: {country}")
    if timer > 0:
        m, s = divmod(timer, 60)
        print(f"制限タイマー: {m:02d}:{s:02d} （{timer}秒）")
    else:
        print("制限タイマー: なし")
    print(f"日本接続: {country and country.lower() in ('japan', 'jp', 'jpn')}")
    return 0


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))
