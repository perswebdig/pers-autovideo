#!/usr/bin/env python3

import hashlib
import hmac
import json
import os
import queue
import re
import subprocess
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote

BASE = Path("/opt/pers-autovideo")
INPUT = BASE / "input"
OUTPUT = BASE / "output"
STATUS_DIR = BASE / "data" / "status"
TOKEN = (BASE / ".worker-token").read_text().strip()
RENDER = BASE / "worker" / "render-auto-v2.sh"

SUPPORTED_MEDIA = {
    ".jpg", ".jpeg", ".png", ".webp",
    ".mp4", ".mov", ".webm",
}
SUPPORTED_AUDIO = {
    ".mp3", ".wav", ".m4a",
}

PROJECT_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
QUIET_SECONDS = int(os.environ.get("PERS_AUTOVIDEO_QUIET_SECONDS", "45"))
SCAN_INTERVAL = int(os.environ.get("PERS_AUTOVIDEO_SCAN_INTERVAL", "15"))
RENDER_TIMEOUT = int(os.environ.get("PERS_AUTOVIDEO_RENDER_TIMEOUT", "7200"))

job_queue = queue.Queue()
queue_guard = threading.Lock()
queued_projects = set()
processing_project = None

STATUS_DIR.mkdir(parents=True, exist_ok=True)


def now_iso():
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def atomic_json_write(path: Path, data: dict):
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(
        json.dumps(data, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    tmp.replace(path)


def status_path(project):
    return STATUS_DIR / f"{project}.json"


def read_status(project):
    path = status_path(project)
    if not path.exists():
        return None

    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None


def write_status(project, **fields):
    current = read_status(project) or {"project": project}
    current.update(fields)
    current["updated_at"] = now_iso()
    atomic_json_write(status_path(project), current)
    return current


def project_files(project_dir):
    files = []

    for path in project_dir.iterdir():
        if not path.is_file():
            continue

        suffix = path.suffix.lower()
        if suffix in SUPPORTED_MEDIA or suffix in SUPPORTED_AUDIO:
            files.append(path)

    return files


def media_files(project_dir):
    return [
        p for p in project_dir.iterdir()
        if p.is_file() and p.suffix.lower() in SUPPORTED_MEDIA
    ]


def project_signature(project_dir):
    files = project_files(project_dir)

    if not files:
        return None

    records = []

    for path in sorted(files, key=lambda p: p.name.casefold()):
        st = path.stat()
        records.append(
            f"{path.name}|{st.st_size}|{st.st_mtime_ns}"
        )

    digest = hashlib.sha256(
        "\n".join(records).encode("utf-8")
    ).hexdigest()

    newest_mtime = max(p.stat().st_mtime for p in files)

    return {
        "signature": digest,
        "newest_mtime": newest_mtime,
        "file_count": len(files),
    }


def project_is_stable(project_dir):
    info = project_signature(project_dir)

    if not info:
        return False, None

    age = time.time() - info["newest_mtime"]

    return age >= QUIET_SECONDS, info


def final_output(project):
    return OUTPUT / f"{project}-v3-final.mp4"


def valid_project_name(project):
    return bool(PROJECT_RE.fullmatch(project))


def project_needs_render(project, project_dir, info):
    output = final_output(project)
    status = read_status(project)

    if status and status.get("state") in {"queued", "processing"}:
        return False

    if not output.exists():
        return True

    if output.stat().st_mtime < info["newest_mtime"]:
        return True

    if status and status.get("source_signature") != info["signature"]:
        return True

    if not status:
        write_status(
            project,
            state="completed",
            message="Saida existente detectada.",
            output=str(output),
            source_signature=info["signature"],
        )

    return False


def enqueue_project(project, reason="manual"):
    global queued_projects

    if not valid_project_name(project):
        return False, "invalid_project"

    project_dir = INPUT / project

    if not project_dir.is_dir():
        return False, "project_not_found"

    if not media_files(project_dir):
        return False, "no_media"

    stable, info = project_is_stable(project_dir)

    if not stable:
        return False, "project_not_stable"

    with queue_guard:
        if project in queued_projects or project == processing_project:
            return False, "already_queued"

        queued_projects.add(project)

    write_status(
        project,
        state="queued",
        reason=reason,
        queued_at=now_iso(),
        source_signature=info["signature"],
        file_count=info["file_count"],
        message="Projeto aguardando processamento.",
    )

    job_queue.put(project)

    return True, "queued"


def scan_projects():
    discovered = []
    queued = []
    skipped = []

    if not INPUT.exists():
        return {
            "discovered": discovered,
            "queued": queued,
            "skipped": skipped,
        }

    for project_dir in sorted(
        [p for p in INPUT.iterdir() if p.is_dir()],
        key=lambda p: p.name.casefold(),
    ):
        project = project_dir.name

        if not valid_project_name(project):
            skipped.append({
                "project": project,
                "reason": "invalid_project_name",
            })
            continue

        media = media_files(project_dir)

        if not media:
            skipped.append({
                "project": project,
                "reason": "no_media",
            })
            continue

        stable, info = project_is_stable(project_dir)

        discovered.append(project)

        if not stable:
            skipped.append({
                "project": project,
                "reason": "waiting_for_upload",
            })
            continue

        if not project_needs_render(project, project_dir, info):
            skipped.append({
                "project": project,
                "reason": "already_current",
            })
            continue

        ok, reason = enqueue_project(
            project,
            reason="automatic_scan",
        )

        if ok:
            queued.append(project)
        else:
            skipped.append({
                "project": project,
                "reason": reason,
            })

    return {
        "discovered": discovered,
        "queued": queued,
        "skipped": skipped,
    }


def run_render(project):
    global processing_project

    with queue_guard:
        queued_projects.discard(project)
        processing_project = project

    project_dir = INPUT / project
    info = project_signature(project_dir)

    write_status(
        project,
        state="processing",
        started_at=now_iso(),
        source_signature=info["signature"] if info else None,
        message="Renderizacao em andamento.",
    )

    try:
        result = subprocess.run(
            [str(RENDER), project],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=RENDER_TIMEOUT,
            env={
                **os.environ,
                "PERS_RENDER_THREADS": "2",
            },
        )

        output = final_output(project)

        if result.returncode != 0 or not output.exists():
            write_status(
                project,
                state="error",
                finished_at=now_iso(),
                return_code=result.returncode,
                log_tail=result.stdout[-12000:],
                message="Falha durante a renderizacao.",
            )
            return

        latest = project_signature(project_dir)

        write_status(
            project,
            state="completed",
            finished_at=now_iso(),
            return_code=0,
            output=str(output),
            output_size=output.stat().st_size,
            source_signature=latest["signature"] if latest else None,
            log_tail=result.stdout[-5000:],
            message="Video concluido com sucesso.",
        )

    except subprocess.TimeoutExpired:
        write_status(
            project,
            state="error",
            finished_at=now_iso(),
            message="Tempo limite de renderizacao excedido.",
        )

    except Exception as exc:
        write_status(
            project,
            state="error",
            finished_at=now_iso(),
            message=str(exc),
        )

    finally:
        with queue_guard:
            processing_project = None


def queue_worker():
    while True:
        project = job_queue.get()

        try:
            run_render(project)
        finally:
            job_queue.task_done()


def scan_worker():
    # Evita uma varredura no mesmo instante em que o servico sobe.
    time.sleep(5)

    while True:
        try:
            scan_projects()
        except Exception as exc:
            print(
                f"[scanner] erro: {exc}",
                flush=True,
            )

        time.sleep(SCAN_INTERVAL)


def list_statuses():
    items = []

    for path in STATUS_DIR.glob("*.json"):
        try:
            items.append(
                json.loads(path.read_text(encoding="utf-8"))
            )
        except Exception:
            pass

    items.sort(
        key=lambda x: x.get("updated_at", ""),
        reverse=True,
    )

    return items


class Handler(BaseHTTPRequestHandler):

    server_version = "PersAutoVideoWorker/2.0"

    def json_response(self, code, data):
        body = json.dumps(
            data,
            ensure_ascii=False,
        ).encode("utf-8")

        self.send_response(code)
        self.send_header(
            "Content-Type",
            "application/json; charset=utf-8",
        )
        self.send_header(
            "Content-Length",
            str(len(body)),
        )
        self.end_headers()
        self.wfile.write(body)

    def authorized(self):
        supplied = self.headers.get(
            "X-Worker-Token",
            "",
        )

        return hmac.compare_digest(
            supplied,
            TOKEN,
        )

    def read_json(self):
        length = int(
            self.headers.get(
                "Content-Length",
                "0",
            )
        )

        if length < 0 or length > 65536:
            raise ValueError("body_too_large")

        return json.loads(
            self.rfile.read(length) or b"{}"
        )

    def do_GET(self):
        global processing_project

        if self.path == "/health":
            with queue_guard:
                queued = len(queued_projects)
                processing = processing_project

            return self.json_response(200, {
                "status": "ok",
                "service": "pers-autovideo-worker",
                "busy": processing is not None,
                "processing": processing,
                "queue_size": queued,
                "scan_interval_seconds": SCAN_INTERVAL,
                "quiet_seconds": QUIET_SECONDS,
            })

        if not self.authorized():
            return self.json_response(
                401,
                {"error": "unauthorized"},
            )

        if self.path == "/jobs":
            return self.json_response(200, {
                "jobs": list_statuses(),
            })

        if self.path.startswith("/jobs/"):
            project = unquote(
                self.path[len("/jobs/"):]
            )

            if not valid_project_name(project):
                return self.json_response(
                    400,
                    {"error": "invalid_project"},
                )

            status = read_status(project)

            if not status:
                return self.json_response(
                    404,
                    {"error": "job_not_found"},
                )

            return self.json_response(
                200,
                status,
            )

        return self.json_response(
            404,
            {"error": "not_found"},
        )

    def do_POST(self):
        if not self.authorized():
            return self.json_response(
                401,
                {"error": "unauthorized"},
            )

        try:
            if self.path == "/scan":
                result = scan_projects()

                return self.json_response(
                    200,
                    result,
                )

            if self.path == "/queue":
                data = self.read_json()
                project = str(
                    data.get("project", "")
                )

                ok, reason = enqueue_project(
                    project,
                    reason="api",
                )

                code = 202 if ok else 409

                return self.json_response(code, {
                    "project": project,
                    "status": reason,
                })

            if self.path == "/render":
                # Compatibilidade com o endpoint antigo:
                # agora ele adiciona a fila e retorna rapidamente.
                data = self.read_json()
                project = str(
                    data.get("project", "")
                )

                ok, reason = enqueue_project(
                    project,
                    reason="api_render",
                )

                code = 202 if ok else 409

                return self.json_response(code, {
                    "project": project,
                    "status": reason,
                    "async": True,
                })

            return self.json_response(
                404,
                {"error": "not_found"},
            )

        except json.JSONDecodeError:
            return self.json_response(
                400,
                {"error": "invalid_json"},
            )

        except ValueError as exc:
            return self.json_response(
                413,
                {"error": str(exc)},
            )

        except Exception as exc:
            return self.json_response(
                500,
                {"error": str(exc)},
            )

    def log_message(self, fmt, *args):
        print(
            "%s - %s" % (
                self.address_string(),
                fmt % args,
            ),
            flush=True,
        )


threading.Thread(
    target=queue_worker,
    name="render-queue",
    daemon=True,
).start()

threading.Thread(
    target=scan_worker,
    name="folder-scanner",
    daemon=True,
).start()

server = ThreadingHTTPServer(
    ("127.0.0.1", 8787),
    Handler,
)

print(
    "Pers AutoVideo Worker API V4 "
    "em http://127.0.0.1:8787",
    flush=True,
)

print(
    f"Scanner: a cada {SCAN_INTERVAL}s; "
    f"pasta precisa ficar estavel por {QUIET_SECONDS}s",
    flush=True,
)

server.serve_forever()
