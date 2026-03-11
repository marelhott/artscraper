#!/usr/bin/env python3
"""Pinterest DL — Web GUI  (preview-first workflow)."""
from __future__ import annotations

import json
import os
import queue
import shlex
import subprocess
import sys
import threading
import time
import uuid
import webbrowser
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import List
from zipfile import ZIP_DEFLATED, ZipFile

from flask import Flask, Response, jsonify, render_template, request, send_file

from pinterest_dl import PinterestDL
from pinterest_dl.common import io
from pinterest_dl.domain.media import PinterestMedia
from pinterest_dl.scrapers import operations

CLOUD_MODE = any(
    os.getenv(name)
    for name in ("RAILWAY_ENVIRONMENT", "RAILWAY_PROJECT_ID", "RAILWAY_SERVICE_ID")
)
APP_ROOT = Path(os.getenv("PINTEREST_DL_APP_ROOT", "/tmp/pinterest-dl-app"))
APP_ROOT.mkdir(parents=True, exist_ok=True)
PLAYWRIGHT_BROWSERS_PATH = str(
    Path(os.getenv("PLAYWRIGHT_BROWSERS_PATH", str(APP_ROOT / "playwright-browsers")))
)
os.environ.setdefault("PLAYWRIGHT_BROWSERS_PATH", PLAYWRIGHT_BROWSERS_PATH)
SSE_PING_INTERVAL = int(os.getenv("PINTEREST_DL_SSE_PING_INTERVAL", "10"))
DEFAULT_OUTPUT = os.getenv(
    "PINTEREST_DL_OUTPUT_DIR",
    str((APP_ROOT / "downloads") if CLOUD_MODE else (Path.home() / "Downloads" / "pinterest-dl")),
)
COOKIES_FILE = os.getenv("PINTEREST_DL_COOKIES_FILE", str(APP_ROOT / "cookies.json"))
PINTEREST_DL_CMD = os.getenv("PINTEREST_DL_CMD", f"{sys.executable} -m pinterest_dl.cli")

app = Flask(__name__)

# preview_cache[job_id] = list of serialised PinterestMedia dicts
_preview_cache: dict[str, List[dict]] = {}
# job_id -> {queue, status, proc?}
_jobs: dict[str, dict] = {}


def _job_log(q: queue.Queue[dict], text: str) -> None:
    q.put({"type": "log", "text": text})


def _ensure_playwright_browser(q: queue.Queue[dict]) -> None:
    browser_dir = Path(PLAYWRIGHT_BROWSERS_PATH)
    if browser_dir.exists() and any(browser_dir.iterdir()):
        return

    _job_log(q, "Instaluji headless Chromium pro automaticke prihlaseni…")
    result = subprocess.run(
        [sys.executable, "-m", "playwright", "install", "--only-shell", "chromium"],
        capture_output=True,
        text=True,
        env={**os.environ, "PLAYWRIGHT_BROWSERS_PATH": PLAYWRIGHT_BROWSERS_PATH},
    )
    if result.stdout.strip():
        for line in result.stdout.splitlines()[-10:]:
            _job_log(q, line)
    if result.returncode != 0:
        stderr = result.stderr.strip() or "Playwright browser install selhal."
        raise RuntimeError(stderr)


def _cookies_authenticated(cookies: list[dict]) -> bool:
    for cookie in cookies:
        if cookie.get("name") == "_auth":
            return cookie.get("value") == "1"
    return False


# ── pages ──────────────────────────────────────────────────────────────────

@app.route("/")
def index():
    logged_in = Path(COOKIES_FILE).exists()
    return render_template(
        "index.html",
        default_output=DEFAULT_OUTPUT,
        logged_in=logged_in,
        cloud_mode=CLOUD_MODE,
        host_label=request.host,
    )


@app.route("/favicon.ico")
def favicon():
    return send_file(
        Path(app.root_path) / "static" / "favicon.svg",
        mimetype="image/svg+xml",
        download_name="favicon.svg",
    )


# ── login ──────────────────────────────────────────────────────────────────

@app.route("/api/login/status")
def api_login_status():
    return jsonify(
        {
            "logged_in": Path(COOKIES_FILE).exists(),
            "cookies_file": COOKIES_FILE,
            "cloud_mode": CLOUD_MODE,
        }
    )


@app.route("/api/login", methods=["POST"])
def api_login():
    data     = request.get_json(force=True)
    email    = (data.get("email") or "").strip()
    password = (data.get("password") or "")
    wait     = max(10, min(60, int(data.get("wait", 20))))

    if not email or not password:
        return jsonify({"error": "Email a heslo jsou povinné"}), 400

    job_id = uuid.uuid4().hex
    q: queue.Queue[dict] = queue.Queue()
    _jobs[job_id] = {"queue": q, "status": "running", "proc": None}

    if CLOUD_MODE:
        def worker():
            status = "error"
            scraper = None
            try:
                _job_log(q, "Zkousim automaticke prihlaseni pres headless Chromium…")
                _ensure_playwright_browser(q)
                scraper = PinterestDL.with_browser(
                    browser_type="chromium",
                    headless=True,
                    incognito=True,
                    verbose=False,
                    enable_images=True,
                )
                scraper.login(email, password)
                _job_log(q, f"Cekam {wait} s na dokonceni autentizace…")
                time.sleep(wait)
                cookies = scraper.browser.context.cookies()  # type: ignore[assignment]
                selenium_cookies = []
                for cookie in cookies:
                    entry = {
                        "name": cookie.get("name", ""),
                        "value": cookie.get("value", ""),
                        "domain": cookie.get("domain", ""),
                        "path": cookie.get("path", "/"),
                        "secure": cookie.get("secure", False),
                    }
                    if "expires" in cookie and cookie["expires"] > 0:
                        entry["expiry"] = int(cookie["expires"])
                    selenium_cookies.append(entry)

                Path(COOKIES_FILE).parent.mkdir(parents=True, exist_ok=True)
                io.write_json(selenium_cookies, COOKIES_FILE, 2)

                if _cookies_authenticated(selenium_cookies):
                    _job_log(q, "✓ Prihlaseni uspesne, cookies ulozeny.")
                    status = "done"
                else:
                    _job_log(
                        q,
                        "Automaticky login nevratil overene auth cookies. Zkuste upload cookies JSON jako fallback.",
                    )
            except Exception as exc:
                _job_log(q, f"Chyba: {exc}")
            finally:
                if scraper:
                    try:
                        scraper.close()
                    except Exception:
                        pass
                _jobs[job_id]["status"] = status
                q.put({"type": "done", "status": status})

        threading.Thread(target=worker, daemon=True).start()
        return jsonify({"job_id": job_id})

    cmd = [
        *shlex.split(PINTEREST_DL_CMD), "login",
        "--headful", "--wait", str(wait),
        "-o", COOKIES_FILE,
    ]

    def worker():
        status = "error"
        try:
            proc = subprocess.Popen(
                cmd,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, bufsize=1,
                env={**os.environ, "PYTHONUNBUFFERED": "1"},
            )
            _jobs[job_id]["proc"] = proc
            # feed credentials — getpass() falls back to stdin when no tty
            proc.stdin.write(f"{email}\n{password}\n")
            proc.stdin.flush()
            proc.stdin.close()

            for raw in iter(proc.stdout.readline, ""):
                line = raw.rstrip()
                if line:
                    q.put({"type": "log", "text": line})
            proc.stdout.close()
            rc     = proc.wait()
            status = "done" if rc == 0 else "error"
        except Exception as exc:
            q.put({"type": "log", "text": f"Chyba: {exc}"})
        _jobs[job_id]["status"] = status
        q.put({"type": "done", "status": status})

    threading.Thread(target=worker, daemon=True).start()
    return jsonify({"job_id": job_id})


@app.route("/api/login/stream/<job_id>")
def api_login_stream(job_id: str):
    if job_id not in _jobs:
        return jsonify({"error": "unknown job"}), 404

    def generate():
        q = _jobs[job_id]["queue"]
        yield f"data: {json.dumps({'type': 'connected'})}\n\n"
        while True:
            try:
                msg = q.get(timeout=SSE_PING_INTERVAL)
                yield f"data: {json.dumps(msg)}\n\n"
                if msg.get("type") == "done":
                    break
            except queue.Empty:
                yield f"data: {json.dumps({'type': 'ping'})}\n\n"

    return Response(
        generate(),
        mimetype="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


@app.route("/api/logout", methods=["POST"])
def api_logout():
    try:
        Path(COOKIES_FILE).unlink(missing_ok=True)
    except Exception:
        pass
    return jsonify({"ok": True})


@app.route("/api/login/upload", methods=["POST"])
def api_login_upload():
    uploaded = request.files.get("cookies_file")
    if not uploaded:
        return jsonify({"error": "Chybi cookies JSON soubor."}), 400

    try:
        payload = json.load(uploaded.stream)
    except json.JSONDecodeError:
        return jsonify({"error": "Soubor neni validni JSON."}), 400

    if not isinstance(payload, list):
        return jsonify({"error": "Cookies soubor musi obsahovat seznam cookie objektu."}), 400

    Path(COOKIES_FILE).parent.mkdir(parents=True, exist_ok=True)
    with open(COOKIES_FILE, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2)

    return jsonify({"ok": True, "count": len(payload)})


@app.route("/api/login/open-chrome", methods=["POST"])
def api_login_open_chrome():
    """Open Pinterest login page in the system's default browser."""
    if CLOUD_MODE:
        return jsonify({"error": "Tato akce neni v Railway dostupna."}), 400
    webbrowser.open("https://www.pinterest.com/login/")
    return jsonify({"ok": True})


@app.route("/api/login/extract-chrome", methods=["POST"])
def api_login_extract_chrome():
    """Extract Pinterest cookies from Chrome and save to cookies file."""
    if CLOUD_MODE:
        return jsonify({"error": "Extrakce z lokalniho Chrome neni v Railway dostupna."}), 400
    try:
        import browser_cookie3  # type: ignore

        raw_cookies = browser_cookie3.chrome(domain_name=".pinterest.com")
        cookie_list = []
        for c in raw_cookies:
            entry: dict = {
                "name": c.name,
                "value": c.value,
                "domain": c.domain,
                "path": c.path,
                "secure": bool(c.secure),
            }
            if c.expires:
                entry["expiry"] = c.expires
            cookie_list.append(entry)

        if not cookie_list:
            return jsonify({"error": "Žádné Pinterest cookies nenalezeny v Chrome. Prosím přihlaste se do Pinterest v prohlížeči a zkuste znovu."}), 404

        with open(COOKIES_FILE, "w") as f:
            json.dump(cookie_list, f, indent=2)

        return jsonify({"ok": True, "count": len(cookie_list)})

    except ImportError:
        return jsonify({"error": "Modul browser-cookie3 není nainstalován."}), 500
    except Exception as exc:
        return jsonify({"error": f"Chyba při extrakci cookies: {exc}"}), 500


# ── preview ────────────────────────────────────────────────────────────────

def _build_artist_queries(name: str, chips: List[str]) -> List[str]:
    """Build focused search query variants — all include the full artist name."""
    base = name.strip()
    chip_str = " ".join(chips).strip() if chips else ""

    queries: List[str] = []
    # primary: name + user chips (most specific)
    if chip_str:
        queries.append(f"{base} {chip_str}")
    # art-type variants — always anchor to full artist name
    for suffix in ("paintings", "artwork", "art", "works", "drawing"):
        q = f"{base} {suffix}"
        if q not in queries:
            queries.append(q)
    return queries


def _relevance_filter(medias: List[PinterestMedia], name: str) -> List[PinterestMedia]:
    """Keep only results whose alt text contains at least one significant name word."""
    # use words with 4+ chars (skips short words like "luc", "jan", "van")
    keywords = [w.lower() for w in name.split() if len(w) >= 4]
    if not keywords:
        keywords = [w.lower() for w in name.split()]
    if not keywords:
        return medias

    kept = []
    for m in medias:
        alt = (m.alt or "").lower()
        if any(kw in alt for kw in keywords):
            kept.append(m)
    return kept


@app.route("/api/preview", methods=["POST"])
def api_preview():
    data  = request.get_json(force=True)
    count = max(1, int(data.get("count", 500)))
    mode  = data.get("mode", "search")   # "search" | "scrape" | "artist"

    job_id = uuid.uuid4().hex
    q: queue.Queue[dict] = queue.Queue()
    _jobs[job_id] = {"queue": q, "status": "running"}

    # artist mode — multi-query
    if mode == "artist":
        name  = (data.get("name") or "").strip()
        chips = [c.strip() for c in data.get("chips", []) if c.strip()]
        if not name:
            return jsonify({"error": "Jméno umělce je povinné"}), 400
        queries = _build_artist_queries(name, chips)

        def worker():
            try:
                logged_in = Path(COOKIES_FILE).exists()
                if logged_in:
                    q.put({"type": "log", "text": "🔓 Přihlášen — používám cookies"})
                else:
                    q.put({"type": "log", "text": "🔒 Nepřihlášen — omezené výsledky"})

                q.put({"type": "log", "text": f"Spouštím {len(queries)} dotazů paralelně…"})

                per_query = max(300, count // len(queries) + 100)
                results_lock = threading.Lock()
                all_medias: List[PinterestMedia] = []
                n_total = len(queries)
                n_done = [0]  # mutable counter for threads

                def run_query(qtext: str):
                    try:
                        scraper = PinterestDL.with_api(max_retries=2)
                        if logged_in:
                            scraper.with_cookies_path(COOKIES_FILE)
                        found = scraper.search(qtext, per_query, min_resolution=(0, 0), bookmarksCount=3)
                        batch_dicts = [m.to_dict() for m in found]
                        with results_lock:
                            all_medias.extend(found)
                            n_done[0] += 1
                            pct = round(n_done[0] / n_total * 100)
                            q.put({"type": "batch",
                                   "images": batch_dicts,
                                   "pct": pct,
                                   "found": len(all_medias),
                                   "done": n_done[0],
                                   "total": n_total})
                        q.put({"type": "log", "text": f'  \u2713 "{qtext}" -> {len(found)} vysledku'})
                    except Exception as exc:
                        with results_lock:
                            n_done[0] += 1
                            pct = round(n_done[0] / n_total * 100)
                            q.put({"type": "progress",
                                   "pct": pct,
                                   "found": len(all_medias),
                                   "done": n_done[0],
                                   "total": n_total})
                        q.put({"type": "log", "text": f'  \u2717 "{qtext}" -> chyba: {exc}'})

                threads = [threading.Thread(target=run_query, args=(qt,), daemon=True) for qt in queries]
                for t in threads:
                    t.start()
                for t in threads:
                    t.join()

                # deduplicate by src URL
                seen: set = set()
                unique: List[PinterestMedia] = []
                for m in all_medias:
                    if m.src not in seen:
                        seen.add(m.src)
                        unique.append(m)

                q.put({"type": "log", "text": f"Celkem unikátních výsledků: {len(unique)}"})
                media_dicts = [m.to_dict() for m in unique]
                _preview_cache[job_id] = media_dicts
                _jobs[job_id]["status"] = "done"
                q.put({"type": "preview_done", "count": len(media_dicts)})

            except Exception as exc:
                _jobs[job_id]["status"] = "error"
                q.put({"type": "log", "text": f"Chyba: {exc}"})
                q.put({"type": "done", "status": "error"})

        threading.Thread(target=worker, daemon=True).start()
        return jsonify({"job_id": job_id})

    # single search / scrape
    query = (data.get("query") or "").strip()
    if not query:
        return jsonify({"error": "Query required"}), 400

    def worker():
        try:
            scraper = PinterestDL.with_api()
            if Path(COOKIES_FILE).exists():
                scraper.with_cookies_path(COOKIES_FILE)
                q.put({"type": "log", "text": "🔓 Přihlášen — používám cookies"})
            else:
                q.put({"type": "log", "text": "🔒 Nepřihlášen — omezené výsledky"})

            q.put({"type": "log", "text": f"{'Hledám' if mode == 'search' else 'Scraping'}: {query!r}"})

            if mode == "search":
                medias: List[PinterestMedia] = scraper.search(
                    query, count, min_resolution=(0, 0), bookmarksCount=3
                )
            else:
                url = query if query.endswith("/") else query + "/"
                medias = scraper.scrape(url, count)

            q.put({"type": "log", "text": f"Nalezeno {len(medias)} výsledků."})
            media_dicts = [m.to_dict() for m in medias]
            _preview_cache[job_id] = media_dicts
            _jobs[job_id]["status"] = "done"
            q.put({"type": "preview_done", "count": len(media_dicts)})

        except Exception as exc:
            _jobs[job_id]["status"] = "error"
            q.put({"type": "log", "text": f"Chyba: {exc}"})
            q.put({"type": "done", "status": "error"})

    threading.Thread(target=worker, daemon=True).start()
    return jsonify({"job_id": job_id})


@app.route("/api/preview/result/<job_id>")
def api_preview_result(job_id: str):
    if job_id not in _preview_cache:
        return jsonify({"error": "not found"}), 404
    return jsonify({"images": _preview_cache[job_id], "count": len(_preview_cache[job_id])})


@app.route("/api/preview/stream/<job_id>")
def api_preview_stream(job_id: str):
    if job_id not in _jobs:
        return jsonify({"error": "unknown job"}), 404

    def generate():
        q = _jobs[job_id]["queue"]
        yield f"data: {json.dumps({'type': 'connected'})}\n\n"
        while True:
            try:
                msg = q.get(timeout=SSE_PING_INTERVAL)
                yield f"data: {json.dumps(msg)}\n\n"
                if msg.get("type") in ("preview_done", "done"):
                    break
            except queue.Empty:
                yield f"data: {json.dumps({'type': 'ping'})}\n\n"

    return Response(
        generate(),
        mimetype="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


# ── download ───────────────────────────────────────────────────────────────

@app.route("/api/download", methods=["POST"])
def api_download():
    data = request.get_json(force=True)
    preview_job_id = data.get("preview_job_id", "")
    selected_ids   = {str(i) for i in data.get("selected_ids", [])}
    output_dir     = (data.get("output") or DEFAULT_OUTPUT).strip()

    if preview_job_id not in _preview_cache:
        return jsonify({"error": "Session vypršela — spusťte nové hledání."}), 404

    all_media = _preview_cache[preview_job_id]
    selected  = (
        [m for m in all_media if str(m["id"]) in selected_ids]
        if selected_ids else all_media
    )
    if not selected:
        return jsonify({"error": "Žádné obrázky nevybrány."}), 400

    # write filtered cache for the CLI download command
    cache_file = f"/tmp/pdl_dl_{preview_job_id}.json"
    with open(cache_file, "w") as f:
        json.dump(selected, f)

    Path(output_dir).mkdir(parents=True, exist_ok=True)

    job_id = uuid.uuid4().hex
    q: queue.Queue[dict] = queue.Queue()
    _jobs[job_id] = {"queue": q, "status": "running", "proc": None}

    cmd = [*shlex.split(PINTEREST_DL_CMD), "download", cache_file, "-o", output_dir]

    def worker():
        status = "error"
        try:
            proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, bufsize=1,
                env={**os.environ, "PYTHONUNBUFFERED": "1"},
            )
            _jobs[job_id]["proc"] = proc
            for raw in iter(proc.stdout.readline, ""):
                line = raw.rstrip()
                if line:
                    q.put({"type": "log", "text": line})
            proc.stdout.close()
            rc     = proc.wait()
            status = "done" if rc == 0 else "error"
        except Exception as exc:
            q.put({"type": "log", "text": f"Fatal: {exc}"})
        _jobs[job_id]["status"] = status
        q.put({"type": "done", "status": status})

    threading.Thread(target=worker, daemon=True).start()
    return jsonify({"job_id": job_id, "count": len(selected)})


@app.route("/api/download-file", methods=["POST"])
def api_download_file():
    data = request.get_json(force=True)
    preview_job_id = data.get("preview_job_id", "")
    selected_ids = {str(i) for i in data.get("selected_ids", [])}

    if preview_job_id not in _preview_cache:
        return jsonify({"error": "Session vyprsela - spuste nove hledani."}), 404

    all_media = _preview_cache[preview_job_id]
    selected = [m for m in all_media if str(m["id"]) in selected_ids] if selected_ids else all_media
    if not selected:
        return jsonify({"error": "Zadne obrazky nevybrany."}), 400

    media = [PinterestMedia.from_dict(item) for item in selected]

    with TemporaryDirectory(prefix="pdl_zip_") as tmpdir:
        temp_root = Path(tmpdir)
        download_dir = temp_root / "files"
        archive_path = temp_root / "pinterest-dl-selection.zip"

        operations.download_media(media, download_dir, download_streams=False)

        with ZipFile(archive_path, "w", compression=ZIP_DEFLATED) as archive:
            for item in media:
                if item.local_path and item.local_path.exists():
                    archive.write(item.local_path, arcname=item.local_path.name)

        return send_file(
            archive_path,
            mimetype="application/zip",
            as_attachment=True,
            download_name="pinterest-dl-selection.zip",
        )


@app.route("/api/download/stream/<job_id>")
def api_download_stream(job_id: str):
    if job_id not in _jobs:
        return jsonify({"error": "unknown job"}), 404

    def generate():
        q = _jobs[job_id]["queue"]
        yield f"data: {json.dumps({'type': 'connected'})}\n\n"
        while True:
            try:
                msg = q.get(timeout=SSE_PING_INTERVAL)
                yield f"data: {json.dumps(msg)}\n\n"
                if msg.get("type") == "done":
                    break
            except queue.Empty:
                yield f"data: {json.dumps({'type': 'ping'})}\n\n"

    return Response(
        generate(),
        mimetype="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


@app.route("/api/stop/<job_id>", methods=["POST"])
def api_stop(job_id: str):
    job = _jobs.get(job_id)
    if job:
        proc = job.get("proc")
        if proc and proc.poll() is None:
            proc.terminate()
        job["status"] = "stopped"
        job["queue"].put({"type": "done", "status": "stopped"})
    return jsonify({"ok": True})


if __name__ == "__main__":
    host = "0.0.0.0"
    port = int(os.getenv("PORT", "5050"))
    print(f"\n  Pinterest DL GUI  ->  http://{host}:{port}\n")
    app.run(host=host, port=port, debug=False, threaded=True)
