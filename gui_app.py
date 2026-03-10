#!/usr/bin/env python3
"""Pinterest DL — Web GUI  (preview-first workflow)."""
from __future__ import annotations

import json
import os
import queue
import subprocess
import threading
import uuid
import webbrowser
from pathlib import Path
from typing import List

from flask import Flask, Response, jsonify, render_template, request

from pinterest_dl import PinterestDL
from pinterest_dl.domain.media import PinterestMedia

VENV_BIN = "/tmp/pinterest-dl-venv/bin"
PINTEREST_DL_CMD = f"{VENV_BIN}/pinterest-dl"
DEFAULT_OUTPUT  = str(Path.home() / "Downloads" / "pinterest-dl")
COOKIES_FILE    = str(Path.home() / ".pinterest_dl_cookies.json")

app = Flask(__name__)

# preview_cache[job_id] = list of serialised PinterestMedia dicts
_preview_cache: dict[str, List[dict]] = {}
# job_id -> {queue, status, proc?}
_jobs: dict[str, dict] = {}


# ── pages ──────────────────────────────────────────────────────────────────

@app.route("/")
def index():
    logged_in = Path(COOKIES_FILE).exists()
    return render_template("index.html", default_output=DEFAULT_OUTPUT, logged_in=logged_in)


# ── login ──────────────────────────────────────────────────────────────────

@app.route("/api/login/status")
def api_login_status():
    return jsonify({"logged_in": Path(COOKIES_FILE).exists(), "cookies_file": COOKIES_FILE})


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

    cmd = [
        PINTEREST_DL_CMD, "login",
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
                msg = q.get(timeout=90)
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


@app.route("/api/login/open-chrome", methods=["POST"])
def api_login_open_chrome():
    """Open Pinterest login page in the system's default browser."""
    webbrowser.open("https://www.pinterest.com/login/")
    return jsonify({"ok": True})


@app.route("/api/login/extract-chrome", methods=["POST"])
def api_login_extract_chrome():
    """Extract Pinterest cookies from Chrome and save to cookies file."""
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
                msg = q.get(timeout=120)
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

    cmd = [PINTEREST_DL_CMD, "download", cache_file, "-o", output_dir]

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


@app.route("/api/download/stream/<job_id>")
def api_download_stream(job_id: str):
    if job_id not in _jobs:
        return jsonify({"error": "unknown job"}), 404

    def generate():
        q = _jobs[job_id]["queue"]
        yield f"data: {json.dumps({'type': 'connected'})}\n\n"
        while True:
            try:
                msg = q.get(timeout=20)
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
    print("\n  Pinterest DL GUI  ->  http://localhost:5050\n")
    app.run(host="127.0.0.1", port=5050, debug=False, threaded=True)
