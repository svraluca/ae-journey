"""Serving-index API and a small durable worker for the existing discovery engine.

The API reads the same result collection that discovery writes. No crawler runs
in an index read. SQLite stores jobs across restarts for the single-server
uvicorn deployment; it is not a distributed Cloud Run queue.
"""
from __future__ import annotations

import asyncio
from concurrent.futures import ThreadPoolExecutor
from contextlib import asynccontextmanager
from contextvars import copy_context
from datetime import datetime, timezone
import hashlib
from functools import partial
import json
import os
from pathlib import Path
import sqlite3
import threading
import time
import uuid

import httpx
from fastapi import HTTPException
from pydantic import BaseModel, Field

JOB_ENGINE_VERSION = "0.11.88"

# HTML extraction/Firestore calls can occupy asyncio's default executor.
# Queue acceptance, focus changes and polling must not wait behind crawlers.
_JOB_CONTROL_EXECUTOR = ThreadPoolExecutor(max_workers=2, thread_name_prefix="explore-control")


async def job_control_call(fn, *args, **kwargs):
    call = partial(copy_context().run, fn, *args, **kwargs)
    return await asyncio.get_running_loop().run_in_executor(_JOB_CONTROL_EXECUTOR, call)

class MarketRequest(BaseModel):
    city: str = Field(min_length=2, max_length=120)
    procedure: str = Field(min_length=2, max_length=120)
    country_code: str = Field(default="", max_length=3)
    limit: int = Field(default=20, ge=1, le=60)
    display_limit: int = Field(default=4, ge=1, le=4)
    collection_target: int = Field(default=12, ge=0, le=40)
    reason: str = "thin_market"
    mode: str = "background"
    client_id: str = Field(default="", max_length=120)
    focus_seq: int = Field(default=0, ge=0)
    client_stored_count: int = Field(default=0, ge=0, le=40)
    client_known_clinic_hosts: list[str] = Field(default_factory=list, max_length=40)
    client_known_clinic_names: list[str] = Field(default_factory=list, max_length=40)
    excluded_source_urls: list[str] = Field(default_factory=list, max_length=40)
    require_client_display_confirmation: bool = False


class DisplayFeedbackRequest(BaseModel):
    client_id: str = Field(min_length=1, max_length=120)
    focus_seq: int = Field(ge=0)
    display_seq: int = Field(ge=1)
    displayed_count: int = Field(ge=0, le=20)


class ClinicSearchRequest(BaseModel):
    city: str = Field(min_length=2, max_length=120)
    query: str = Field(min_length=2, max_length=120)
    country_code: str = Field(default="", max_length=3)
    limit: int = Field(default=6, ge=1, le=20)


class JobStore:
    """Atomic enqueue/claim, deduplication, and lease recovery on one host."""

    def __init__(self, path):
        self.path = str(path)
        Path(self.path).parent.mkdir(parents=True, exist_ok=True)
        with self.connect() as db:
            db.execute("""CREATE TABLE IF NOT EXISTS jobs (
                job_id TEXT PRIMARY KEY, market_key TEXT, request TEXT,
                status TEXT, priority INTEGER, created REAL, updated REAL,
                lease_until REAL DEFAULT 0, owner TEXT DEFAULT '',
                results TEXT DEFAULT '[]', error TEXT DEFAULT '',
                verified_written INTEGER DEFAULT 0, attempts INTEGER DEFAULT 0
            )""")
            db.execute("CREATE INDEX IF NOT EXISTS market_jobs ON jobs(market_key, updated)")
            columns = {row[1] for row in db.execute("PRAGMA table_info(jobs)")}
            if "progress" not in columns:
                db.execute("ALTER TABLE jobs ADD COLUMN progress TEXT DEFAULT '{}'")
            db.execute("""CREATE TABLE IF NOT EXISTS client_focus (
                client_id TEXT PRIMARY KEY, sequence INTEGER, market_key TEXT
            )""")
            db.execute("""CREATE TABLE IF NOT EXISTS source_checks (
                market_key TEXT, source_url TEXT, reason TEXT, checked REAL,
                PRIMARY KEY(market_key, source_url)
            )""")

    def connect(self):
        db = sqlite3.connect(self.path, timeout=5)
        db.row_factory = sqlite3.Row
        return db

    @staticmethod
    def unpack(row):
        if row is None:
            return None
        d = dict(row)
        d["request"] = json.loads(d["request"])
        d["display_results"] = json.loads(d.pop("results"))
        d["progress"] = json.loads(d.get("progress") or "{}")
        return d

    def enqueue(self, key, request, cooldown=300):
        now = time.time()
        request = dict(request)
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            foreground = request.get("mode") == "foreground" or request.get("reason") == "user"
            client = request.get("client_id", "")
            sequence = request.get("focus_seq", 0)
            if foreground and client:
                focus = db.execute("SELECT * FROM client_focus WHERE client_id=?", (client,)).fetchone()
                # A slow HTTP request for the previous pill cannot undo a
                # newer selection. Background warmups never change focus.
                if focus and (sequence < focus["sequence"] or
                              (sequence == focus["sequence"] and key != focus["market_key"])):
                    foreground = False
                else:
                    db.execute("INSERT OR REPLACE INTO client_focus VALUES(?,?,?)", (client, sequence, key))
                    for old in db.execute("SELECT * FROM jobs WHERE market_key!=? "
                                          "AND priority>=100 AND status IN ('queued','running')", (key,)).fetchall():
                        old_request = json.loads(old["request"])
                        # v11.76 tickets have no client identity. They are
                        # retained as background work after the first focus.
                        if old_request.get("client_id") and old_request.get("client_id") != client:
                            continue
                        old_request["mode"] = "background"
                        details = json.loads(old["progress"] or "{}")
                        details["scheduling"] = "background"
                        db.execute("UPDATE jobs SET priority=70,request=?,progress=? WHERE job_id=?",
                                   (json.dumps(old_request), json.dumps(details), old["job_id"]))
            if foreground or "mode" in request:
                request["mode"] = "foreground" if foreground else "background"
            priority = 100 if foreground else 70
            # An expired lease is reclaimable by the worker, not a second job.
            row = db.execute(
                "SELECT * FROM jobs WHERE market_key=? AND status IN ('queued','running') "
                "ORDER BY created DESC LIMIT 1", (key,),
            ).fetchone()
            if row:
                if priority >= row["priority"]:
                    old_request = json.loads(row["request"])
                    merged = {**old_request, **request}
                    for field in ("client_known_clinic_hosts", "client_known_clinic_names", "excluded_source_urls"):
                        merged[field] = list(dict.fromkeys([*old_request.get(field, []), *request.get(field, [])]))[:40]
                    details = json.loads(row["progress"] or "{}")
                    details["scheduling"] = "foreground" if foreground else "background"
                    db.execute("UPDATE jobs SET priority=?,request=?,progress=?,updated=? WHERE job_id=?",
                               (priority, json.dumps(merged), json.dumps(details), now, row["job_id"]))
                    row = db.execute("SELECT * FROM jobs WHERE job_id=?", (row["job_id"],)).fetchone()
                return {**self.unpack(row), "enqueued": False}
            row = db.execute(
                "SELECT * FROM jobs WHERE market_key=? AND status='completed' "
                "AND updated>? ORDER BY updated DESC LIMIT 1", (key, now - cooldown),
            ).fetchone()
            if (row and request.get("reason") != "user"
                    and json.loads(row["progress"] or "{}").get("engine_version") == JOB_ENGINE_VERSION):
                return {**self.unpack(row), "enqueued": False, "reason": "recently_finished"}
            job_id = uuid.uuid4().hex
            db.execute(
                "INSERT INTO jobs(job_id,market_key,request,status,priority,created,updated) "
                "VALUES(?,?,?,'queued',?,?,?)",
                (job_id, key, json.dumps(request), priority, now, now),
            )
            return {**self.unpack(db.execute(
                "SELECT * FROM jobs WHERE job_id=?", (job_id,),
            ).fetchone()), "enqueued": True}

    @staticmethod
    def lane_filter(lane):
        return " AND priority>=100" if lane == "foreground" else " AND priority<100" if lane == "background" else ""

    def continue_in_background(self, job):
        """Release UI priority without cancelling the durable collection job."""
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT * FROM jobs WHERE job_id=? AND owner=?",
                             (job["job_id"], job["owner"])).fetchone()
            if not row or row["status"] != "running":
                return
            request = json.loads(row["request"])
            request["mode"] = "background"
            progress = json.loads(row["progress"] or "{}")
            progress.update(display_ready=True, scheduling="background", phase="collecting")
            db.execute("UPDATE jobs SET request=?,priority=70,progress=?,updated=? WHERE job_id=?",
                       (json.dumps(request), json.dumps(progress), time.time(), job["job_id"]))

    def source_check(self, key, url, reason=""):
        with self.connect() as db:
            if reason:
                db.execute("INSERT OR REPLACE INTO source_checks VALUES(?,?,?,?)",
                           (key, url, reason, time.time()))
            else:
                db.execute("DELETE FROM source_checks WHERE market_key=? AND source_url=?", (key, url))

    def acknowledge_display(self, job_id, feedback):
        """Use current-client display feedback for priority, never price trust."""
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT * FROM jobs WHERE job_id=?", (job_id,)).fetchone()
            if not row:
                return {"accepted": False, "reason": "unknown_job"}
            request = json.loads(row["request"])
            focus = db.execute("SELECT * FROM client_focus WHERE client_id=?",
                               (feedback.client_id,)).fetchone()
            if (request.get("client_id") != feedback.client_id or not focus or
                    focus["sequence"] != feedback.focus_seq or
                    focus["market_key"] != row["market_key"] or
                    int(request.get("focus_seq", 0)) != feedback.focus_seq):
                return {"accepted": False, "reason": "stale_focus"}
            progress = json.loads(row["progress"] or "{}")
            last_sequence = (int(progress.get("client_display_seq", 0))
                             if progress.get("client_display_focus_seq") == feedback.focus_seq else 0)
            if feedback.display_seq <= last_sequence:
                return {"accepted": False, "reason": "stale_display"}
            ready = feedback.displayed_count >= min(6, int(request.get("display_limit", 4)))
            progress.update(client_display_seq=feedback.display_seq,
                            client_display_focus_seq=feedback.focus_seq,
                            client_displayed_count=feedback.displayed_count,
                            display_ready=ready,
                            scheduling="background" if ready else "foreground")
            request["mode"] = "background" if ready else "foreground"
            db.execute("UPDATE jobs SET request=?,priority=?,progress=?,updated=? WHERE job_id=?",
                       (json.dumps(request), 70 if ready else 100,
                        json.dumps(progress), time.time(), job_id))
            return {"accepted": True, "display_ready": ready}

    def rejected_sources(self, key):
        with self.connect() as db:
            rows = db.execute("SELECT source_url,reason FROM source_checks WHERE market_key=? AND checked>?",
                              (key, time.time()-86400)).fetchall()
            return {row["source_url"]: row["reason"] for row in rows}

    def waiting(self, lane):
        with self.connect() as db:
            return db.execute("SELECT 1 FROM jobs WHERE (status='queued' OR "
                              "(status='running' AND lease_until<? AND attempts<2))" + self.lane_filter(lane),
                              (time.time(),)).fetchone() is not None

    def claim(self, lease_seconds=660, lane=None):
        now = time.time()
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            # A worker interrupted twice becomes a visible failure, not an
            # endlessly running job.
            db.execute(
                "UPDATE jobs SET status='failed',error='Worker repeatedly interrupted',updated=? "
                "WHERE status='running' AND lease_until<? AND attempts>=2", (now, now),
            )
            row = db.execute(
                "SELECT * FROM jobs WHERE (status='queued' OR "
                "(status='running' AND lease_until<? AND attempts<2))" + self.lane_filter(lane) + " "
                "ORDER BY priority DESC,created ASC LIMIT 1", (now,),
            ).fetchone()
            if not row:
                return None
            owner = uuid.uuid4().hex
            db.execute(
                "UPDATE jobs SET status='running',owner=?,lease_until=?,updated=?,attempts=attempts+1 "
                "WHERE job_id=?", (owner, now + lease_seconds, now, row["job_id"]),
            )
            return self.unpack(db.execute(
                "SELECT * FROM jobs WHERE job_id=?", (row["job_id"],),
            ).fetchone())

    def update_progress(self, job, rows=None, progress=None):
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            current = db.execute(
                "SELECT results,progress FROM jobs WHERE job_id=? AND owner=? AND status='running'",
                (job["job_id"], job["owner"]),
            ).fetchone()
            if not current:
                return
            details = {**json.loads(current["progress"] or "{}"), **(progress or {})}
            payload = current["results"] if rows is None else json.dumps(rows)
            if rows is not None:
                details["verified_count"] = len(rows)
            db.execute(
                "UPDATE jobs SET results=?,progress=?,updated=? WHERE job_id=? AND owner=? AND status='running'",
                (payload, json.dumps(details), time.time(), job["job_id"], job["owner"]),
            )

    def finish(self, job, rows, written=0, error="", progress=None):
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            current = db.execute(
                "SELECT progress FROM jobs WHERE job_id=? AND owner=? AND status='running'",
                (job["job_id"], job["owner"]),
            ).fetchone()
            if not current:
                return
            details = {**json.loads(current["progress"] or "{}"), **(progress or {})}
            details.update(phase="failed" if error else "completed", verified_count=len(rows))
            details["engine_version"] = JOB_ENGINE_VERSION
            db.execute(
                "UPDATE jobs SET status=?,results=?,verified_written=?,error=?,updated=?,lease_until=0,progress=? "
                "WHERE job_id=? AND owner=? AND status='running'",
                ("failed" if error else "completed", json.dumps(rows), written,
                 error, time.time(), json.dumps(details), job["job_id"], job["owner"]),
            )

    def get(self, job_id):
        with self.connect() as db:
            return self.unpack(db.execute(
                "SELECT * FROM jobs WHERE job_id=?", (job_id,),
            ).fetchone())

    def release(self, job):
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT progress FROM jobs WHERE job_id=? AND owner=? AND status='running'",
                             (job["job_id"], job["owner"])).fetchone()
            if not row:
                return
            details = json.loads(row["progress"] or "{}")
            details.update(phase="queued", scheduling="paused_for_active_search")
            # Controlled pause/shutdown is not a crashed lease. Keep every
            # validated partial row and do not exhaust crash recovery retries.
            db.execute(
                "UPDATE jobs SET status='queued',owner='',lease_until=0,attempts=MAX(0,attempts-1),"
                "progress=?,updated=? WHERE job_id=? AND owner=? AND status='running'",
                (json.dumps(details), time.time(), job["job_id"], job["owner"]),
            )

    def latest_results(self, key):
        with self.connect() as db:
            rows = db.execute(
                "SELECT results FROM jobs WHERE market_key=? AND status='completed' "
                "ORDER BY updated DESC LIMIT 8", (key,),
            ).fetchall()
            return [item for row in rows for item in json.loads(row["results"])]

    def prune(self):
        with self.connect() as db:
            db.execute(
                "DELETE FROM jobs WHERE status IN ('completed','failed') AND updated<?",
                (time.time() - 30 * 86400,),
            )


class IndexJobs:
    version = JOB_ENGINE_VERSION
    def __init__(self, engine, path=None):
        self.e = engine
        self.path = path or os.getenv(
            "EXPLORE_JOB_DB", str(Path(__file__).with_name("explore_jobs.sqlite3")),
        )
        self._store = None
        self._store_lock = threading.Lock()
        self.task = None
        self.wake = asyncio.Event()
        self.active = {}

    @property
    def store(self):
        if self._store is None:
            with self._store_lock:
                if self._store is None:
                    self._store = JobStore(self.path)
        return self._store

    async def store_call(self, method, *args, **kwargs):
        # Resolve the lazy store in the executor too: opening/migrating a
        # busy SQLite database can wait just like a query can.
        return await job_control_call(lambda: getattr(self.store, method)(*args, **kwargs))

    async def validated_rows(self, rows, req, **kwargs):
        # Validation also reads (and sometimes updates) source quarantine.
        return await job_control_call(self.safe_rows, rows, req.city, req.procedure,
                                      country_code=req.country_code, **kwargs)

    def key(self, req):
        # Preserve country identity when a same-named city exists elsewhere.
        raw = (self.e.canonical_city(req.city) + "|" +
               self.e.canonicalize_procedure(req.procedure) + "|" +
               (req.country_code or self.e.country_hint_for_city(req.city) or "").upper())
        return hashlib.sha256(raw.encode()).hexdigest()

    def safe_rows(self, rows, city, procedure, include_quarantined=False, *,
                  country_code="", recover_quarantined=False):
        result = []
        canonical = self.e.canonicalize_procedure(procedure)
        market = self.key(MarketRequest(city=city, procedure=procedure,
                                      country_code=country_code))
        quarantined = self.store.rejected_sources(market) if not include_quarantined else {}
        for raw in rows:
            try:
                row = self.e.DisplayClinicPrice.model_validate(
                    raw.model_dump() if hasattr(raw, "model_dump") else raw,
                )
                if self.e.canonicalize_procedure(row.procedure_canonical) != canonical:
                    continue
                if self.e.canonical_city(row.city) != self.e.canonical_city(city):
                    continue
                if not self.e._app_can_show_row(row):
                    continue
                if row.source_url in quarantined:
                    # Persisted local rows retain their original live origin.
                    # An index read must not treat that label as a new check.
                    if (recover_quarantined and row.origin in {"live_search", "live_fallback"}
                            and self.e.city_in_text(row.source_location_text, city)):
                        self.store.source_check(market, row.source_url)
                    else:
                        continue
                if self.e.foreign_price_source_path(row.source_url, city):
                    continue
                if any(self.e.same_clinic_identity(row, old) for old in result):
                    continue
                result.append(row)
            except (ValueError, TypeError):
                continue
        return result

    async def index(self, req, include_quarantined=False):
        stored = await self.e.firestore_load_results(
            req.city, req.procedure, max_results=60,
            include_stale=True, read_only=True,
        )
        if not self.e.firestore_enabled():
            # Useful for local development without ADC. Production always
            # reads the configured Firestore result collection.
            stored = await self.store_call("latest_results", self.key(req))
        rows = (await self.validated_rows(stored, req,
                                         include_quarantined=include_quarantined))[:req.limit]
        rejected_sources = await self.store_call("rejected_sources", self.key(req))
        return {
            "city": req.city, "procedure": self.e.canonicalize_procedure(req.procedure),
            "display_results": [r.model_dump(mode="json") for r in rows],
            "source_collection": self.e._results_collection_name(),
            "source": "firestore" if self.e.firestore_enabled() else "local_verified",
            "verified_count": len(rows),
            "invalidated_source_urls": list(rejected_sources),
        }

    async def enqueue(self, req):
        job = await self.store_call("enqueue", self.key(req), req.model_dump())
        self.wake.set()
        # Also starts under ASGI test transports / older lifespan wrappers.
        if self.task is None or self.task.done():
            self.task = asyncio.create_task(self.run())
        return job

    async def run_one(self, job=None):
        timeout = min(600, max(30, int(os.getenv("EXPLORE_JOB_TIMEOUT_SECONDS", "600"))))
        if job is None:
            job = await self.store_call("claim", timeout + 60)
        if not job:
            return False
        req = MarketRequest.model_validate(job["request"])
        try:
            # Retain the existing parser, city checks, ownership and trust
            # gates. A focus change can pause this task without discarding
            # validated partial results or any price already in Firestore.
            await self.store_call("update_progress", job, None,
                                    {"phase": "starting", "engine_version": JOB_ENGINE_VERSION,
                                     "scheduling": req.mode, "collection_target": req.collection_target,
                                     "display_limit": req.display_limit})
            print(f"[GP JOB] {job['job_id']} running {req.city} {req.procedure}", flush=True)
            response = await asyncio.wait_for(self.discover_with_progress(job, req), timeout=timeout)
            rows = await self.validated_rows(
                response.candidate_results or response.display_results, req,
                recover_quarantined=True)
            # Include already indexed clinics as well as this job's finds.
            try:
                indexed = await asyncio.wait_for(
                    self.index(req.model_copy(update={"limit": 60})), timeout=5,
                )
            except asyncio.TimeoutError:
                indexed = {"display_results": []}
            current = await self.store_call("get", job["job_id"])
            retained = await self.validated_rows((current or {}).get("display_results", []), req)
            combined = await self.validated_rows([*rows, *indexed["display_results"]], req)
            extras = [row for row in retained if not any(self.e.same_clinic_identity(row, old) for old in combined)]
            if extras:
                # A paused pass may verify a price before final persistence.
                try:
                    await asyncio.wait_for(self.e.firestore_upsert_results(
                        req.city, req.procedure, req.country_code or self.e.country_hint_for_city(req.city), extras,
                    ), timeout=5)
                except Exception:
                    pass  # The durable ticket still retains validated rows.
            rows = await self.validated_rows([*combined, *retained], req)
            payload = self.row_payload(rows)
            details = {
                "fresh_count": response.novel_live_available,
                "desired_fresh": response.desired_new_for_display,
                "shortfall_reason": response.growth_exhausted_reason,
                "rounds": response.growth_rounds,
                "serper_requests": response.serper_network_requests_total,
                "search_error_count": len(response.search_errors) + sum(
                    len(errors) for errors in response.growth_search_errors.values()
                ),
            }
            diagnostics = [response.live_search_diagnostics, *response.growth_diagnostics.values()]
            rejections = {}
            rejected_urls = []
            for diag in diagnostics:
                if diag is None:
                    continue
                for key, value in diag.model_dump().items():
                    if key.startswith("rejected_") and isinstance(value, int) and value:
                        rejections[key] = rejections.get(key, 0) + value
                for sample in diag.reject_samples:
                    item = {"url": sample.url, "reason": sample.reason}
                    if item not in rejected_urls and len(rejected_urls) < 20:
                        rejected_urls.append(item)
            details["rejections"] = rejections
            details["rejected_urls"] = rejected_urls
            await self.store_call("finish", job, payload, response.persisted_count, "", details)
            print(f"[GP JOB] {job['job_id']} completed verified={len(payload)} "
                  f"fresh={response.novel_live_available} reason={response.growth_exhausted_reason or '-'}",
                  flush=True)
        except asyncio.CancelledError:
            await self.store_call("release", job)
            raise
        except Exception as exc:
            current = await self.store_call("get", job["job_id"])
            await self.store_call(
                "finish", job, (current or {}).get("display_results", []), 0,
                type(exc).__name__ + ": " + str(exc)[:300],
            )
            print(f"[GP JOB] {job['job_id']} failed {type(exc).__name__}", flush=True)
        return True

    def row_payload(self, rows):
        now = datetime.now(timezone.utc).isoformat()
        payload = []
        for row in rows:
            item = row.model_dump(mode="json")
            if row.origin in {"live_search", "live_fallback"} and not item.get("last_verified_at"):
                item["last_verified_at"] = now
            payload.append(item)
        return payload

    async def discover_with_progress(self, job, req):
        queue = asyncio.Queue()
        started = time.monotonic()
        first_result_ms = None
        good_enough_ms = None

        async def producer():
            token = self.e._hybrid_progress.set(queue)
            try:
                request = self.e.HybridDiscoverRequest(
                    city=req.city, procedure=req.procedure,
                    country_code=req.country_code or None,
                    display_limit=req.display_limit,
                    collection_target=req.collection_target,
                    stored_count=min(10, max(0, req.display_limit - 2)),
                    fresh_count=min(2, req.display_limit),
                    enable_growth_search=True, max_growth_rounds=3,
                    fast_interactive_search=False, force_full_growth_search=True,
                    economical_growth=True, stream_progress=True, debug=True, serper_first=True,
                    client_stored_count=req.client_stored_count,
                    client_known_clinic_hosts=req.client_known_clinic_hosts,
                    client_known_clinic_names=req.client_known_clinic_names,
                    excluded_source_urls=req.excluded_source_urls,
                )
                response = await self.e._discover_hybrid_impl(request)
                usable = await self.validated_rows(response.candidate_results or response.display_results,
                                                   req, recover_quarantined=True)
                # A completed fast pass has persisted its cards. The same
                # durable job may now collect its larger pool at low priority.
                # Do not retry an exhausted thin market in another full pass.
                if (self.e.env_bool("ENABLE_PROGRESSIVE_DISCOVERY", True)
                        and 6 <= len(usable) < req.collection_target
                        and self.e.firestore_enabled()):
                    if not req.require_client_display_confirmation:
                        await self.store_call("continue_in_background", job)
                        self.wake.set()
                    response = await self.e._discover_hybrid_impl(
                        request.model_copy(update={"background_collection": True}))
                return response
            finally:
                self.e._hybrid_progress.reset(token)
                await queue.put(None)

        task = asyncio.create_task(producer())
        try:
            while True:
                event = await queue.get()
                if event is None:
                    break
                if event.get("event") == "partial":
                    current = await self.store_call("get", job["job_id"])
                    fresh = await self.validated_rows(event.get("display_results", []), req,
                                                      recover_quarantined=True)
                    rows = await self.validated_rows([*fresh, *(current or {}).get("display_results", [])], req)
                    elapsed = round((time.monotonic() - started) * 1000)
                    if rows and first_result_ms is None:
                        first_result_ms = elapsed
                    if len(rows) >= 6 and good_enough_ms is None:
                        good_enough_ms = elapsed
                    await self.store_call(
                        "update_progress", job, self.row_payload(rows),
                        {"phase": "verified_results", "ttfr_ms": first_result_ms,
                         "time_to_6_verified_ms": good_enough_ms},
                    )
                    if len(rows) >= min(6, req.display_limit) and not req.require_client_display_confirmation:
                        await self.store_call("continue_in_background", job)
                        self.wake.set()
                elif event.get("event") == "progress":
                    await self.store_call("update_progress", job, None, event.get("progress", {}))
            return await task
        finally:
            if not task.done():
                task.cancel()
            await asyncio.gather(task, return_exceptions=True)

    async def dispatch(self):
        for job_id, entry in list(self.active.items()):
            if entry["task"].done():
                await asyncio.gather(entry["task"], return_exceptions=True)
                del self.active[job_id]
            else:
                entry["state"] = await self.store_call("get", job_id)

        waiting = await self.store_call("waiting", "foreground")
        if waiting and len(self.active) >= 2:
            # The reserved foreground slot must follow the selected market.
            # Pause an obsolete focus from this client, retaining its partials.
            candidates = [entry for entry in self.active.values() if entry["state"]["priority"] < 100]
            if candidates and not any(entry["state"]["priority"] >= 100 for entry in self.active.values()):
                entry = max(candidates, key=lambda item: item["lane"] == "foreground")
                entry["task"].cancel()
                await asyncio.gather(entry["task"], return_exceptions=True)
                del self.active[entry["state"]["job_id"]]

        timeout = min(600, max(30, int(os.getenv("EXPLORE_JOB_TIMEOUT_SECONDS", "600"))))
        for lane in ("foreground", "background"):
            if len(self.active) >= 2:
                break
            occupied = any((entry["state"]["priority"] >= 100) == (lane == "foreground")
                           for entry in self.active.values())
            if occupied:
                continue
            job = await self.store_call("claim", timeout + 60, lane)
            if job:
                task = asyncio.create_task(self.run_one(job))
                self.active[job["job_id"]] = {"task": task, "state": job, "lane": lane}
                task.add_done_callback(lambda _: self.wake.set())

    async def run(self):
        try:
            while True:
                self.wake.clear()
                await self.dispatch()
                try:
                    await asyncio.wait_for(self.wake.wait(), timeout=1)
                except asyncio.TimeoutError:
                    pass
        finally:
            tasks = [entry["task"] for entry in self.active.values()]
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            self.active.clear()

    async def start(self):
        await self.store_call("prune")
        if self.task is None or self.task.done():
            self.task = asyncio.create_task(self.run())

    async def stop(self):
        if self.task:
            self.task.cancel()
            try:
                await self.task
            except asyncio.CancelledError:
                pass
        self.task = None

    async def static_html(self, url):
        # Bounded bytes and HTTP only. No Firecrawl, Places or renderer.
        async with httpx.AsyncClient(
            timeout=3, follow_redirects=True, max_redirects=3,
            headers={"User-Agent": self.e.UA},
        ) as client:
            async with client.stream("GET", url) as response:
                if response.status_code != 200:
                    return None
                if self.e.host_of(str(response.url)) != self.e.host_of(url):
                    return None
                chunks, total = [], 0
                async for chunk in response.aiter_bytes():
                    total += len(chunk)
                    if total > 512_000:
                        return None
                    chunks.append(chunk)
                return b"".join(chunks).decode(response.encoding or "utf-8", errors="replace")

    async def refresh_known(self, req):
        indexed = await self.index(req, include_quarantined=True)
        rows = await self.validated_rows(indexed["display_results"], req, include_quarantined=True)
        changed = []
        sem = asyncio.Semaphore(3)

        async def check(stored):
            try:
                async with sem:
                    html = await self.static_html(stored.source_url)
                if not html:
                    return
                text = await asyncio.to_thread(self.e.page_text, html)
                context = await asyncio.to_thread(self.e.tariff_location_context, html)
                # Remove an old city-specific card only with positive proof.
                # 403, timeout and missing metadata never invalidate a tariff.
                invalid = "foreign_tariff_heading" if self.e.tariff_location_conflict(context, req.city) else (
                    "directory_price" if self.e.classify_page_source(stored.source_url, text) == "directory" else
                    "page_disclaims_clinic_prices" if self.e.page_disclaims_clinic_prices(text) else "")
                if invalid:
                    await self.store_call("source_check", self.key(req), stored.source_url, invalid)
                    return
                if not await asyncio.to_thread(self.e.strong_local_page_evidence,
                    html, text, req.city, stored.source_url,
                ):
                    return
                evidence = await asyncio.to_thread(self.e.extract_price_evidence, html, stored.source_url, req.procedure)
                for ev in evidence:
                    accepted, own, confidence, _, evidence_type = await asyncio.to_thread(self.e.validate_evidence,
                        ev, text, html, req.city,
                    )
                    if not accepted or not own:
                        continue
                    row = stored.model_copy(update={
                        "price_min": ev.price_min, "price_max": ev.price_max,
                        "currency": ev.currency, "qualifier": ev.qualifier, "unit": ev.unit,
                        "raw_procedure_text": ev.raw_procedure_text, "raw_evidence": ev.raw_evidence,
                        "procedure_display_name": self.e.published_procedure_display_name(
                            self.e.canonicalize_procedure(req.procedure), ev.raw_procedure_text,
                            ev.raw_evidence, ev.raw_price_text),
                        "source_location_text": context,
                        "procedure_detail": self.e.procedure_detail(ev.raw_evidence,
                            self.e.canonicalize_procedure(req.procedure), ev.raw_price_text),
                        "evidence_type": evidence_type, "confidence": confidence,
                        "last_verified_at": datetime.now(timezone.utc).isoformat(),
                        "cache_age_days": 0,
                    })
                    if await self.validated_rows([row], req, include_quarantined=True):
                        await self.store_call("source_check", self.key(req), stored.source_url)
                        changed.append(row)
                        break
            except (httpx.HTTPError, ValueError):
                return

        await asyncio.gather(*(check(row) for row in rows[:4]))
        if changed:
            await self.e.firestore_upsert_results(
                req.city, req.procedure, req.country_code, changed,
                discovered_by="known_evidence_refresh",
            )
        verified = await self.validated_rows([*changed, *rows], req)
        rejected_sources = await self.store_call("rejected_sources", self.key(req))
        return {**indexed, "invalidated_source_urls": list(rejected_sources), "display_results": [
            r.model_dump(mode="json") for r in verified
        ]}

    async def clinic_search(self, req):
        query = self.e.fold(req.query)
        rows = await self.e.firestore_load_clinic_directory(req.city, max_results=120)
        names, out = set(), []

        def add(name, url, rating=0, reviews=0):
            key = self.e.fold(name)
            if key in names or not self.e.valid_name(name):
                return
            names.add(key)
            out.append({
                "title": name, "subtitle": req.city, "type": "clinic",
                "official_website": url, "rating": rating or 0, "reviews": reviews or 0,
            })

        for hit in rows:
            name = hit.place_name or hit.title
            if query in self.e.fold(name + " " + hit.url):
                add(name, hit.url, hit.place_rating, hit.place_user_rating_count)
        if len(out) < req.limit:
            serper = self.e.SerperClient(request_cap=1)
            if serper.api_key:
                hits = await serper.search(
                    f'"{req.query}" "{req.city}" clinic official website',
                    num=10,
                )
                async def candidate(hit):
                    if self.e.classify_source(hit.url) != "official_clinic":
                        return
                    if self.e.foreign_price_source_path(hit.url, req.city):
                        return
                    html = await self.static_html(hit.url)
                    if not html:
                        return
                    text = self.e.page_text(html)
                    if not self.e.strong_local_page_evidence(html, text, req.city, hit.url):
                        return
                    name = self.e.guess_clinic_name_from_html(html, hit.url, hit.title)
                    if query not in self.e.fold(name + " " + hit.title + " " + hit.url):
                        return
                    ok, _, _ = self.e.clinic_directory_site_quality(
                        html, hit.url, req.city, [], "", name,
                    )
                    if ok:
                        add(name, self.e.official_site_root(hit.url))
                await asyncio.gather(*(candidate(hit) for hit in hits[:4]), return_exceptions=True)
        return {"results": out[:req.limit]}


def install(engine):
    service = IndexJobs(engine)
    original_lifespan = engine.app.router.lifespan_context

    @asynccontextmanager
    async def lifespan(app):
        async with original_lifespan(app):
            await service.start()
            try:
                yield
            finally:
                await service.stop()

    engine.app.router.lifespan_context = lifespan
    engine.app.state.index_jobs = service

    @engine.app.post("/price-index")
    async def price_index(req: MarketRequest):
        try:
            return await asyncio.wait_for(service.index(req), timeout=5)
        except asyncio.TimeoutError:
            raise HTTPException(504, "Price index temporarily unavailable")

    @engine.app.post("/refresh-prices")
    async def refresh_prices(req: MarketRequest):
        try:
            return await asyncio.wait_for(service.refresh_known(req), timeout=10)
        except asyncio.TimeoutError:
            # The client keeps its saved cards. A second index read here
            # would extend the ten-second refresh budget by another five.
            raise HTTPException(504, "Known prices could not refresh in time")

    @engine.app.post("/discover-jobs")
    async def enqueue_job(req: MarketRequest):
        return await service.enqueue(req)

    @engine.app.get("/discover-jobs/{job_id}")
    async def job_status(job_id: str):
        job = await service.store_call("get", job_id)
        if job is None:
            raise HTTPException(404, "Unknown discovery job")
        return job

    @engine.app.post("/discover-jobs/{job_id}/display")
    async def acknowledge_display(job_id: str, req: DisplayFeedbackRequest):
        result = await service.store_call("acknowledge_display", job_id, req)
        service.wake.set()
        return result

    @engine.app.post("/search-clinics")
    async def search_clinics(req: ClinicSearchRequest):
        try:
            return await asyncio.wait_for(service.clinic_search(req), timeout=9)
        except asyncio.TimeoutError:
            raise HTTPException(504, "Clinic search timed out; try again")

    return service
