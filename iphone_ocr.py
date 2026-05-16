"""
iPhone Mirroring上のProton VPNアプリから接続国を読み取るOCRモジュール。
auto-daily-report/src/ocr_utils.py と同じVision Frameworkを使用。
"""

import subprocess
import tempfile
import os
import re

import Quartz
import Vision
import AppKit


# Proton VPN無料プランで利用可能な国名（英語表記）
PROTON_FREE_COUNTRIES = {
    "Japan", "United States", "Netherlands", "Canada",
    "Mexico", "Norway", "Poland", "Romania", "Singapore", "Switzerland",
    # 略称も念のため
    "JP", "US", "NL", "CA", "MX", "NO", "PL", "RO", "SG", "CH",
}


def get_iphone_mirroring_window_bounds() -> tuple[int, int, int, int] | None:
    """iPhone Mirroringウィンドウの座標と大きさを取得する。"""
    script = '''
    tell application "System Events"
        set proc to first process whose name is "iPhone Mirroring"
        set w to first window of proc
        set pos to position of w
        set sz to size of w
        return (item 1 of pos as string) & "," & (item 2 of pos as string) & "," & (item 1 of sz as string) & "," & (item 2 of sz as string)
    end tell
    '''
    try:
        result = subprocess.check_output(["osascript", "-e", script], text=True).strip()
        x, y, w, h = map(int, result.split(","))
        return x, y, w, h
    except Exception as e:
        print(f"[OCR] ウィンドウ座標の取得に失敗: {e}", flush=True)
        return None


def capture_region_to_cgimage(x: int, y: int, w: int, h: int):
    """指定した矩形領域のスクリーンショットをCGImageとして返す。"""
    rect = Quartz.CGRectMake(x, y, w, h)
    image_ref = Quartz.CGWindowListCreateImage(
        rect,
        Quartz.kCGWindowListOptionOnScreenOnly,
        Quartz.kCGNullWindowID,
        Quartz.kCGWindowImageDefault,
    )
    return image_ref


def recognize_text_from_cgimage(image_ref) -> str:
    """CGImageからVision FrameworkでOCRを実行してテキストを返す。"""
    if image_ref is None:
        return ""

    request = Vision.VNRecognizeTextRequest.alloc().init()
    request.setRecognitionLevel_(Vision.VNRequestTextRecognitionLevelAccurate)
    request.setUsesLanguageCorrection_(True)
    request.setRecognitionLanguages_(["en-US"])  # 国名は英語

    handler = Vision.VNImageRequestHandler.alloc().initWithCGImage_options_(image_ref, None)
    success, error = handler.performRequests_error_([request], None)

    if not success:
        print(f"[OCR] テキスト認識エラー: {error}", flush=True)
        return ""

    lines = []
    for obs in request.results():
        candidate = obs.topCandidates_(1)[0]
        lines.append(candidate.string())

    return "\n".join(lines)


def extract_country_from_text(text: str) -> str | None:
    """
    OCR結果のテキストから接続国名を抽出する。
    Proton VPN iPhoneアプリは「Browsing safely from」の下に国名を表示する。
    """
    lines = text.splitlines()
    for i, line in enumerate(lines):
        # 「Browsing safely from」の次の行またはその付近に国名がある
        if "browsing" in line.lower() and "from" in line.lower():
            for j in range(i + 1, min(i + 4, len(lines))):
                candidate = lines[j].strip()
                if re.match(r"^[A-Za-z ]+$", candidate) and len(candidate) >= 2:
                    return candidate
        # 直接国名が見つかる場合
        stripped = line.strip()
        if stripped in PROTON_FREE_COUNTRIES:
            return stripped

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


def get_connected_country() -> str | None:
    """
    iPhone Mirroringウィンドウを撮影・OCRして接続中の国名を返す。
    取得できなければ None を返す。
    """
    bounds = get_iphone_mirroring_window_bounds()
    if bounds is None:
        return None
    x, y, w, h = bounds
    image_ref = capture_region_to_cgimage(x, y, w, h)
    text = recognize_text_from_cgimage(image_ref)
    if not text:
        return None
    return extract_country_from_text(text)


def get_timer_seconds() -> int:
    """
    iPhone Mirroringウィンドウを撮影・OCRして制限タイマーの残り秒数を返す。
    タイマーがなければ 0 を返す。
    """
    bounds = get_iphone_mirroring_window_bounds()
    if bounds is None:
        return 0
    x, y, w, h = bounds
    image_ref = capture_region_to_cgimage(x, y, w, h)
    text = recognize_text_from_cgimage(image_ref)
    if not text:
        return 0
    return extract_timer_seconds_from_text(text)


def get_vpn_status() -> dict:
    """
    iPhone Mirroringウィンドウを一度撮影・OCRして、国名とタイマーをまとめて返す。
    {'country': str|None, 'timer_seconds': int}
    """
    bounds = get_iphone_mirroring_window_bounds()
    if bounds is None:
        return {"country": None, "timer_seconds": 0}
    x, y, w, h = bounds
    image_ref = capture_region_to_cgimage(x, y, w, h)
    text = recognize_text_from_cgimage(image_ref)
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


if __name__ == "__main__":
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
