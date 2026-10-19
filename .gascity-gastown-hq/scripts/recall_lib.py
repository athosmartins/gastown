#!/usr/bin/env python3
"""recall_lib.py — shared library behind the `recall` CLI (ga-ps28g).

WHAT THIS IS: a hybrid semantic+lexical retrieval index over CLOSED beads
(HQ + WA, telemetry-filtered), so agents can answer "has this been done? /
what broke last time?" by reading ~5 compact bead summaries instead of
`bd list --status closed` + several full `bd show` reads.

Ported from the ga-ps28g scratchpad experiment (filter_corpus.py,
build_index.py, run_experiment.py), which measured pure-semantic top-5 at
recall@5=0.50 and the current bd-list+read baseline at ~65K tokens /
recall@5=0.90. The WINNING method productionized here is the hybrid:

    semantic top-3 (cosine, all-MiniLM-L6-v2, bead = max over its chunks)
    UNION keyword top-3 (title-keyword overlap, tie-break by recency)
    deduped, order = semantic hits first then keyword-only additions

Re-validated on the full 1441-bead / 20-query experiment corpus before
shipping: 19/20 = 0.95 recall@union (mean union size 5.35), mean token cost
~11077 vs the baseline's 65353 -> 5.90x fewer tokens. Do NOT ship pure-
semantic alone (0.50 recall) and do NOT drop the keyword arm (it is what
rescues Portuguese-language queries against English-titled beads that the
semantic arm alone misses cross-lingually).

INDEX STORAGE: all runtime state lives under a single, STABLE, city-wide
location derived from GC_CITY_PATH (same convention as every other gc
script — see e.g. scripts/gate-health-monitor.py) so `recall` gives the
same shared index regardless of which worktree/cwd invokes it:

    $GC_CITY_PATH/.gc/recall-index/    embeddings + bead metadata, as immutable
                                        generations (gen-*/ holding the 4 index
                                        files) + a CURRENT pointer file (ga-m1sa2l)
    $GC_CITY_PATH/.gc/logs/recall-usage.jsonl   instrumentation (one line/call)
    $GC_CITY_PATH/.gc/logs/recall-index-events.jsonl   why an index was rebuilt
    $GC_CITY_PATH/.gc/recall-venv/     the python env (sentence-transformers,
                                        tiktoken, numpy) recall.py runs under

Heavy imports (numpy, sentence_transformers) are deferred into the
functions that need them, so importing this module (and testing the
telemetry filter / keyword / chunking / instrumentation logic) stays cheap
and doesn't require a loaded embedding model.
"""
from __future__ import annotations

import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

# ---------------------------------------------------------------------------
# Config — same GC_CITY_PATH convention used across scripts/*.py
# ---------------------------------------------------------------------------
GC_CITY_PATH = os.environ.get("GC_CITY_PATH", "/Users/athos/gt/.gascity-gastown-hq")
WA_STORE_PATH = os.environ.get("GC_RECALL_WA_STORE", "/Users/athos/gt/whatsapp_automation")
STORES = {"HQ": GC_CITY_PATH, "WA": WA_STORE_PATH}

INDEX_DIR = Path(GC_CITY_PATH) / ".gc" / "recall-index"
LOG_PATH = Path(GC_CITY_PATH) / ".gc" / "logs" / "recall-usage.jsonl"
INDEX_EVENT_LOG = Path(GC_CITY_PATH) / ".gc" / "logs" / "recall-index-events.jsonl"

CURRENT_POINTER = "CURRENT"                # names the published generation dir
GEN_PRUNE_GRACE_SECONDS = 10 * 60          # a superseded generation outlives its
                                            # replacement by at least this long
                                            # (pruning runs on the next save), so a reader
                                            # that resolved CURRENT just before the
                                            # swap (loading takes seconds) still
                                            # finds its files
HEAVY_GUARD_TIMEOUT_S = 30
_GEN_NAME_RE = re.compile(r"^gen-[0-9A-Za-z_-]+$")
_FLAT_INDEX_FILES = ("corpus.json", "chunk_vecs.npy", "chunk_bead_idx.json", "index_meta.json")

MODEL_NAME = "all-MiniLM-L6-v2"
CHUNK_SIZE = 120
CHUNK_OVERLAP = 20
BD_SHOW_BATCH = 40
BD_TIMEOUT_LIST = 90
BD_TIMEOUT_SHOW = 120
MODEL_FETCH_TIMEOUT_S = 180                # one-time weight download (~87MB),
                                            # generous for a slow link (wa-h9dc1)

MAX_AGE_DAYS = 90                          # corpus retention window
STALE_AFTER_SECONDS = 24 * 3600            # rebuild trigger: index age
STALE_NEW_BEAD_THRESHOLD = 50              # rebuild trigger: new real closes
STALENESS_CHECK_MIN_INTERVAL_SECONDS = 5 * 60  # throttle bd polling (Dolt is
                                            # documented-sensitive to poll
                                            # frequency in this repo; bound
                                            # worst case to once/5min city-wide
                                            # regardless of recall call volume)

SCHEMA_VERSION = 1

_ENCODING = None
_MODEL = None


# ---------------------------------------------------------------------------
# Telemetry filter — ported verbatim from the ga-ps28g scratchpad's
# filter_corpus.py (is_wisp). Excludes operational wisps (gate-run prompts,
# nudges, session/molecule/convoy/step telemetry, digest steps, auto-refino
# task markers, etc) from the closed-bead corpus, keeping substantive
# bug/feature/task/chore work. This is the ONLY rule change allowed here is
# a rename (is_wisp -> is_telemetry) for clarity at the call site; the
# predicate logic is unchanged so filtering behavior matches the validated
# experiment exactly.
# ---------------------------------------------------------------------------
WISP_TITLE_PATS = (
    'order:', 'nudge:', 'gate-run:', 'sling-', 'mol-dog', 'mol-',
    'reviewer-verdict:', 'gate:', 'ready-for-gate:', 'quality-gate:',
    'auto-refino-task:', 'refino-verdict:', 'State change:',
    'Close drain step', 'Read assignment,',
)
DIGEST_STEP_TITLES = {
    'Finalize workflow', 'Collect activity data from all rigs',
    'Generate digest, send to mayor, archive', 'Determine digest time range',
}
INFRA_TYPES = {'session', 'convoy', 'step', 'molecule', 'event'}
_BRANCH_STEP_RE = re.compile(r'^[a-z0-9_.]+\.(dog|mayor)-\d+$')


def is_telemetry(issue: dict) -> bool:
    """True iff `issue` (a bd JSON record) is operational telemetry rather
    than substantive work, per the ga-ps28g corpus-construction rule."""
    id_ = issue.get('id') or ''
    title = issue.get('title') or ''
    itype = issue.get('issue_type') or ''
    md = issue.get('metadata') or {}
    if '-wisp-' in id_:
        return True
    if itype in INFRA_TYPES:
        return True
    if title in DIGEST_STEP_TITLES:
        return True
    if any(title.startswith(p) for p in WISP_TITLE_PATS):
        return True
    if _BRANCH_STEP_RE.match(title):
        return True
    if isinstance(md, dict) and any(k in md for k in ('nudge_id', 'terminal_at', 'terminal_reason')):
        return True
    return False


# ---------------------------------------------------------------------------
# Keyword arm — ported verbatim from run_experiment.py
# ---------------------------------------------------------------------------
STOPWORDS = set("""
the a an of to in on for and or is are was were be been being this that these those
it its as by with from at not no do does did has have had will would could should
can may might must than then so if but about into over under again further
que de da do das dos em um uma para com por se nao foi ja tem teve era esse essa
isso este esta houve como onde qual quando quem mas ou ao aos as os na no nas nos
did we was there what happened had have has been already fixed bug broke did
""".split())


def keywords(text: str) -> set:
    """Lowercased alnum/id-ish tokens (>=4 chars, stopwords removed). Used
    for the lexical retrieval arm (title-only) — deliberately loose, it is
    what rescues PT-language queries against EN-titled beads that the
    semantic arm misses cross-lingually."""
    toks = re.findall(r"[a-zA-Z0-9_/.:*<>-]+", (text or "").lower())
    out = set()
    for t in toks:
        t2 = t.strip("_/.:*<>-")
        if len(t2) >= 4 and t2 not in STOPWORDS:
            out.add(t2)
    return out


# ---------------------------------------------------------------------------
# Token counting (tiktoken cl100k_base) — lazy encoder
# ---------------------------------------------------------------------------
def ntok(text: str) -> int:
    global _ENCODING
    if not text:
        return 0
    if _ENCODING is None:
        import tiktoken
        _ENCODING = tiktoken.get_encoding("cl100k_base")
    return len(_ENCODING.encode(text, disallowed_special=()))


# ---------------------------------------------------------------------------
# Chunking + full-text — ported verbatim from build_index.py
# ---------------------------------------------------------------------------
def full_text(bead: dict) -> str:
    parts = [bead.get("title") or "", bead.get("description") or ""]
    for c in (bead.get("comments") or []):
        t = c.get("text") or ""
        if t:
            parts.append(t)
    return "\n\n".join(p for p in parts if p)


def chunk_words(text: str, size: int = CHUNK_SIZE, overlap: int = CHUNK_OVERLAP) -> list:
    words = (text or "").split()
    if not words:
        return []
    if len(words) <= size:
        return [text]
    chunks = []
    i = 0
    while i < len(words):
        chunks.append(" ".join(words[i:i + size]))
        if i + size >= len(words):
            break
        i += size - overlap
    return chunks


# ---------------------------------------------------------------------------
# Model loading (lazy — this is the expensive import/load)
# ---------------------------------------------------------------------------
class RecallUnavailableError(RuntimeError):
    """recall could not search at all (CLI exit 3) -- as opposed to searching
    and finding nothing (exit 0). Base of the two reasons below."""


class RecallIndexRebuildDeferred(RecallUnavailableError):
    """The on-disk index is unusable and has to be rebuilt from scratch, but
    the disk guard (scripts/heavy-guard.sh, ga-vln2py) did not allow that
    heavy step right now -- or could not be asked. Nothing was changed on
    disk; run recall again once the disk has room."""


class RecallModelUnavailableError(RecallUnavailableError):
    """The embedding model could not be loaded — cache miss under offline
    mode AND the one-time online fetch also failed. Raised instead of
    letting the raw huggingface_hub/transformers traceback surface, so
    callers can tell "searched, found nothing" (exit 0) apart from
    "could not search at all" (wa-h9dc1) instead of collapsing both into
    the same outcome."""


def load_model():
    """Local embeddings only in steady state — no external API (see
    recall_lib.py header). Force HF offline mode before import: without
    this, sentence-transformers silently phones home to the HF Hub on
    every load to check for model updates ("sending unauthenticated
    requests to the HF Hub"), which both adds ~1-2s of avoidable latency
    and makes `recall` depend on network reachability it should never need
    once the weights are cached.

    Bootstrap/self-heal (wa-h9dc1): a fresh machine, a wiped cache, or a
    new user has no cached weights yet, and forced-offline turned that into
    a permanent failure with no recovery path (nothing else in the repo
    downloads the weights). On a cache-miss under offline, fetch the
    weights once via a SUBPROCESS started with offline disabled, then
    retry in THIS process (still offline) now that the cache is warm.

    Why a subprocess and not just flipping os.environ and retrying inline
    (what this function did on the first attempt at this fix, rejected by
    the quality gate — ga-444oq): huggingface_hub reads HF_HUB_OFFLINE into
    a module-level constant AT IMPORT TIME (constants.py) and never
    re-reads os.environ afterward. By the time the offline attempt below
    fails, huggingface_hub is already imported with that constant frozen
    True, so flipping os.environ and calling SentenceTransformer() again
    IN THIS PROCESS is a no-op — it still runs offline internally and
    fails identically. Only a fresh interpreter, started with the env var
    already correct before its own import happens, actually goes online.
    If the fetch subprocess also fails (no network), raise
    RecallModelUnavailableError rather than letting the raw
    huggingface_hub traceback surface."""
    global _MODEL
    if _MODEL is not None:
        return _MODEL

    os.environ.setdefault("HF_HUB_OFFLINE", "1")
    os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
    from sentence_transformers import SentenceTransformer

    try:
        _MODEL = SentenceTransformer(MODEL_NAME)
        return _MODEL
    except Exception as exc:
        # `except ... as name` auto-deletes `name` when the block exits
        # (Python 3 scoping) — stash it in a plain variable so it's still
        # readable/raisable below, past the end of this except clause.
        offline_err = exc

    bootstrap_env = dict(os.environ, HF_HUB_OFFLINE="0", TRANSFORMERS_OFFLINE="0")
    try:
        proc = subprocess.run(
            [sys.executable, "-c",
             "from sentence_transformers import SentenceTransformer; "
             f"SentenceTransformer({MODEL_NAME!r})"],
            env=bootstrap_env, capture_output=True, text=True,
            timeout=MODEL_FETCH_TIMEOUT_S,
        )
        fetch_ok = proc.returncode == 0
        fetch_detail = proc.stderr[-2000:] if not fetch_ok else ""
    except subprocess.TimeoutExpired:
        fetch_ok = False
        fetch_detail = f"timed out after {MODEL_FETCH_TIMEOUT_S}s"
    except Exception as bootstrap_err:  # e.g. interpreter not spawnable
        fetch_ok = False
        fetch_detail = str(bootstrap_err)

    if not fetch_ok:
        raise RecallModelUnavailableError(
            f"embedding model '{MODEL_NAME}' is not in the local HF cache "
            f"and the one-time online fetch failed (no network?). Populate "
            f"the cache manually with:\n"
            f"  HF_HUB_OFFLINE=0 TRANSFORMERS_OFFLINE=0 "
            f"{GC_CITY_PATH}/.gc/recall-venv/bin/python3 -c "
            f"\"from sentence_transformers import SentenceTransformer; "
            f"SentenceTransformer('{MODEL_NAME}')\"\n"
            f"offline error: {offline_err}\nfetch error: {fetch_detail}"
        ) from offline_err

    # Cache is now warm on disk — this process stays offline and just
    # reads it from local cache, no network involved.
    try:
        _MODEL = SentenceTransformer(MODEL_NAME)
    except Exception as post_bootstrap_err:
        raise RecallModelUnavailableError(
            f"embedding model '{MODEL_NAME}' fetch subprocess reported "
            f"success but the model still failed to load locally: "
            f"{post_bootstrap_err}"
        ) from post_bootstrap_err
    return _MODEL


def embed(model, texts: list):
    import numpy as np
    if not texts:
        return np.zeros((0, 384), dtype=np.float32)
    vecs = model.encode(texts, batch_size=64, convert_to_numpy=True, normalize_embeddings=True)
    return vecs.astype(np.float32)


# ---------------------------------------------------------------------------
# bd fetch helpers
# ---------------------------------------------------------------------------
def _parse_bd_json(raw: str):
    """bd's --json envelope has varied across versions: sometimes a bare
    array, sometimes {"issues": [...]}. Handle both defensively."""
    raw = (raw or "").strip()
    if not raw:
        return []
    data = json.loads(raw)
    if isinstance(data, dict) and "issues" in data:
        return data["issues"]
    if isinstance(data, list):
        return data
    return []


def _run_bd(args: list, timeout: int):
    r = subprocess.run(["bd", *args], capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        raise RuntimeError(f"bd {' '.join(args)} failed rc={r.returncode}: {r.stderr[:400]}")
    return _parse_bd_json(r.stdout)


def fetch_closed_meta(store_path: str, closed_after: str = None) -> list:
    """Cheap call: `bd list --status closed --json` (description included,
    no comment bodies). Optionally scoped with --closed-after for
    incremental fetches."""
    args = ["-C", store_path, "list", "--status", "closed", "--json", "-n", "0"]
    if closed_after:
        args += ["--closed-after", closed_after]
    return _run_bd(args, timeout=BD_TIMEOUT_LIST)


def fetch_full(store_path: str, ids: list, batch: int = BD_SHOW_BATCH) -> list:
    """Batch `bd show --include-comments` for the given ids (call only on
    the already-telemetry-filtered id set — comment bodies are the
    expensive part)."""
    out = []
    for i in range(0, len(ids), batch):
        chunk = ids[i:i + batch]
        try:
            out.extend(_run_bd(["-C", store_path, "show", *chunk, "--json", "--include-comments"],
                                timeout=BD_TIMEOUT_SHOW))
        except Exception:
            # fall back one-by-one so one bad id doesn't drop the whole batch
            for single in chunk:
                try:
                    out.extend(_run_bd(["-C", store_path, "show", single, "--json", "--include-comments"],
                                        timeout=30))
                except Exception:
                    continue
    return out


# ---------------------------------------------------------------------------
# Bead trimming — keep only what the index/CLI need, not the full bd record
# ---------------------------------------------------------------------------
def _trim_bead(b: dict, store: str) -> dict:
    comments = [
        {"author": c.get("author"), "text": c.get("text"), "created_at": c.get("created_at")}
        for c in (b.get("comments") or []) if c.get("text")
    ]
    return {
        "id": b["id"],
        "store": store,
        "title": b.get("title") or "",
        "description": b.get("description") or "",
        "close_reason": b.get("close_reason") or "",
        "closed_at": b.get("closed_at") or "",
        "issue_type": b.get("issue_type") or "",
        "priority": b.get("priority"),
        "comments": comments,
    }


def finalize_bead(b: dict, store: str) -> dict:
    trimmed = _trim_bead(b, store)
    trimmed["_ntok_full"] = ntok(full_text(trimmed))
    return trimmed


def list_render_tokens_for(corpus: list) -> int:
    """Tokens of the 'bd list' rendering an agent would scan without
    recall — same line format as the ga-ps28g experiment's baseline arm."""
    lines = [f"{b['id']}\t{b.get('issue_type', '')}\tP{b.get('priority', '')}\t{b.get('title', '')}"
             for b in corpus]
    return ntok("\n".join(lines))


def _cutoff_iso(days: int = MAX_AGE_DAYS) -> str:
    return (datetime.now(timezone.utc) - timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")


def _shift_iso(iso: str, hours: int) -> str:
    """Parse a closed_at-style ISO8601 timestamp and shift by `hours`
    (negative = earlier). Falls back to the 90-day cutoff if unparseable."""
    if not iso:
        return _cutoff_iso()
    try:
        ts = iso.replace("Z", "+00:00")
        dt = datetime.fromisoformat(ts)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return (dt + timedelta(hours=hours)).strftime("%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        return _cutoff_iso()


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ---------------------------------------------------------------------------
# Index container + persistence
# ---------------------------------------------------------------------------
class RecallIndex:
    def __init__(self, corpus, chunk_vecs, chunk_bead_idx, meta):
        self.corpus = corpus                # list[dict], trimmed bead records
        self.chunk_vecs = chunk_vecs        # np.ndarray (n_chunks, dim) float32
        self.chunk_bead_idx = chunk_bead_idx  # np.ndarray (n_chunks,) int -> corpus index
        self.meta = meta                    # dict of index metadata
        self.gen_dir = None                 # generation dir it was loaded from / last saved to


# The index is four files that only mean something TOGETHER (vector row i
# belongs to bead chunk_bead_idx[i] of corpus). ga-m1sa2l: they used to be
# replaced one by one in the shared dir, so a writer that stopped between two
# replaces -- or two writers interleaving -- left new vectors next to an old
# bead_idx (live: 98401 rows vs 97765 entries, corpus 6479 vs meta 6453) and
# every `recall` crashed. Each _atomic_write is atomic; the SET was not.
# Now a save writes a whole new immutable generation dir (gen-*/) and
# publishes it with ONE atomic rename of the CURRENT pointer file, so a reader
# sees the old index or the new one, never a blend, and two writers never
# share a directory. A flat-layout index (pre-generations) is still read.
def _index_files(base: Path) -> dict:
    return {
        "corpus": base / "corpus.json",
        "vecs": base / "chunk_vecs.npy",
        "bead_idx": base / "chunk_bead_idx.json",
        "meta": base / "index_meta.json",
    }


def _read_current_pointer():
    """-> (generation dir, problem). (None, None): no pointer published (first
    run, or the flat layout); (dir, None): the published generation;
    (None, "<why>"): a pointer exists but is unusable -- damage, not first run."""
    pointer = INDEX_DIR / CURRENT_POINTER
    try:
        # vazio → problema "nome inválido" (índice corrompido, não 1ª execução); ausente → (None, None) 1ª execução/layout antigo; ilegível → problema (corrompido), nunca "sem índice"
        name = pointer.read_text().strip()
    except FileNotFoundError:
        return None, None
    except (OSError, ValueError) as e:
        return None, f"CURRENT pointer unreadable ({e})"
    if not _GEN_NAME_RE.match(name):
        return None, f"CURRENT pointer holds an invalid generation name {name!r}"
    gen = INDEX_DIR / name
    if not gen.is_dir():
        return None, f"CURRENT points to missing generation {name}"
    return gen, None


def _paths():
    """Files of the index load_index() would read right now: the published
    generation, else the legacy flat layout."""
    gen, _ = _read_current_pointer()
    return _index_files(gen if gen is not None else INDEX_DIR)


def index_inconsistency(corpus, chunk_vecs, chunk_bead_idx, meta):
    """Why these four parts cannot be one index, or None when they can.
    Pure (no I/O). Persisted counts missing from meta are not held against an
    index (older metas); counts that are there must match the arrays."""
    import numpy as np
    vecs_shape = getattr(chunk_vecs, "shape", None)
    if vecs_shape is None or len(vecs_shape) != 2:
        return f"chunk_vecs is not a 2-D matrix (shape={vecs_shape})"
    n_vecs, n_bead_idx, n_corpus = vecs_shape[0], len(chunk_bead_idx), len(corpus)
    if n_vecs != n_bead_idx:
        return f"chunk_vecs has {n_vecs} rows but chunk_bead_idx has {n_bead_idx} entries"
    if n_bead_idx:
        lo, hi = int(np.min(chunk_bead_idx)), int(np.max(chunk_bead_idx))
        if lo < 0 or hi >= n_corpus:
            return f"chunk_bead_idx spans [{lo}, {hi}] but the corpus has {n_corpus} beads"
    for key, actual in (("n_beads", n_corpus), ("n_chunks", n_bead_idx)):
        recorded = (meta or {}).get(key)
        if recorded is not None and recorded != actual:
            return f"index_meta.{key}={recorded} but the files hold {actual}"
    return None


def _log_index_event(kind: str, detail: str) -> None:
    """One JSON line saying why an index was thrown away. Best effort: a log
    line must never be the reason recall fails."""
    rec = {"ts": now_iso(), "event": kind, "detail": detail, "pid": os.getpid()}
    try:
        INDEX_EVENT_LOG.parent.mkdir(parents=True, exist_ok=True)
        with open(INDEX_EVENT_LOG, "a") as f:
            f.write(json.dumps(rec) + "\n")
    except OSError:
        pass


def load_index(progress=lambda msg: None):
    """Returns a RecallIndex, or None if no index has been built yet OR the
    on-disk index is corrupted/unreadable/inconsistent (ga-zy725: a disk-full
    mid-write truncated chunk_vecs.npy — 640 of 12,647,040 elements missing —
    and np.load raised on every subsequent call, with no self-heal; `recall
    --rebuild` couldn't recover either, since this function ran, and raised,
    before the rebuild flag was ever consulted). Either way the caller
    (ensure_index) already knows how to recover from None: treat it as "no
    usable cache, build fresh from bd" — it doesn't need to know *why* the
    cache was unusable, only that it was. save_index() below publishes whole
    generations atomically so a live process being killed mid-write can no
    longer produce a truncated or mixed index in the first place; this is
    the complementary half — self-heal from damage left behind by the OLD
    non-atomic writer, or from any other on-disk damage. Files that all
    load but do not belong together (ga-m1sa2l: vector rows != bead_idx
    entries) count as damage too: they used to load fine and crash later."""
    gen, problem = _read_current_pointer()
    if problem:
        progress(f"recall: on-disk index is corrupted/unreadable ({problem}) -- rebuilding from scratch")
        return None
    p = _index_files(gen if gen is not None else INDEX_DIR)
    if not all(path.exists() for path in p.values()):
        if gen is not None:  # published generations are written whole: a hole is damage
            progress(f"recall: on-disk index is corrupted/unreadable (generation {gen.name} is missing files) -- rebuilding from scratch")
        return None
    import numpy as np
    try:
        corpus = json.loads(p["corpus"].read_text())
        vecs = np.load(p["vecs"])
        bead_idx = np.array(json.loads(p["bead_idx"].read_text()), dtype=np.int64)
        meta = json.loads(p["meta"].read_text())
    except (OSError, ValueError, EOFError, json.JSONDecodeError) as e:
        progress(f"recall: on-disk index is corrupted/unreadable ({e}) -- rebuilding from scratch")
        return None
    why = index_inconsistency(corpus, vecs, bead_idx, meta)
    if why:
        progress(f"recall: on-disk index is inconsistent ({why}) -- rebuilding from scratch")
        _log_index_event("inconsistent_index_on_load", why)
        return None
    idx = RecallIndex(corpus, vecs, bead_idx, meta)
    idx.gen_dir = gen
    return idx


def _atomic_write(path: Path, write_fn) -> None:
    """Write via a tmp file in the same directory + os.replace, so a process
    killed mid-write (e.g. disk-full) leaves either the old complete file or
    the new complete file -- never a truncated one. The tmp file lives next
    to `path` so the rename is same-filesystem (required for atomicity;
    os.replace across filesystems silently falls back to non-atomic
    copy+delete on some platforms). On failure the partial tmp file is
    best-effort removed (never masking the original error) so a disk that's
    still full doesn't also litter the index dir with dead .tmp files."""
    tmp = path.with_name(path.name + ".tmp")
    try:
        with open(tmp, "wb") as f:
            write_fn(f)
        os.replace(tmp, path)
    except BaseException:
        tmp.unlink(missing_ok=True)
        raise


def save_index(idx: RecallIndex) -> None:
    """Publish `idx` as a NEW generation: write all four files into a private
    gen-*/ dir, then move CURRENT to it with one atomic rename. Dying at any
    point before that rename leaves the previous generation published and
    untouched; the half-written dir is removed (or, if we were killed outright,
    pruned later by age). Refuses an index whose parts do not belong together,
    so a broken one can never be re-stamped as fresh (ga-m1sa2l)."""
    import numpy as np
    why = index_inconsistency(idx.corpus, idx.chunk_vecs, idx.chunk_bead_idx, idx.meta)
    if why:
        raise ValueError(f"refusing to persist an inconsistent recall index: {why}")
    INDEX_DIR.mkdir(parents=True, exist_ok=True)
    previous, _ = _read_current_pointer()  # ausente/ilegível → None: nada a aposentar, só não há geração anterior
    gen_name = "gen-%s-%d-%s" % (time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()), os.getpid(), secrets.token_hex(4))
    gen = INDEX_DIR / gen_name
    gen.mkdir()
    try:
        p = _index_files(gen)
        _atomic_write(p["corpus"], lambda f: f.write(json.dumps(idx.corpus).encode()))
        _atomic_write(p["vecs"], lambda f: np.save(f, idx.chunk_vecs.astype(np.float32)))
        bead_idx_list = idx.chunk_bead_idx.tolist() if hasattr(idx.chunk_bead_idx, "tolist") else list(idx.chunk_bead_idx)
        _atomic_write(p["bead_idx"], lambda f: f.write(json.dumps(bead_idx_list).encode()))
        _atomic_write(p["meta"], lambda f: f.write(json.dumps(idx.meta, indent=2).encode()))
        _atomic_write(INDEX_DIR / CURRENT_POINTER, lambda f: f.write(gen_name.encode()))
    except BaseException:
        shutil.rmtree(gen, ignore_errors=True)
        raise
    idx.gen_dir = gen
    if previous is not None and previous != gen:
        try:
            os.utime(previous)  # start the previous generation's grace period NOW, not at its last write
        except OSError:
            pass  # already gone: nothing to protect
    _prune_generations(keep=gen)


def save_index_meta(idx: RecallIndex) -> None:
    """Persist only index_meta.json -- what the 'nothing new' branch needs to
    move the throttle timestamp. Pre-ga-m1sa2l that branch re-saved the whole
    index (~240 MB) for one number, which also re-stamped a broken index as
    fresh. An index that never came from a generation on disk is published
    whole instead (that is also the one-time migration off the flat layout)."""
    gen = idx.gen_dir
    if gen is None:
        save_index(idx)
        return
    try:
        _atomic_write(_index_files(gen)["meta"], lambda f: f.write(json.dumps(idx.meta, indent=2).encode()))
    except OSError:
        # falhou → keep the old timestamp (the next call simply re-checks); a
        # generation pruned under us must not be resurrected or raise
        pass


def _prune_generations(keep: Path) -> None:
    """Best-effort tidy-up AFTER CURRENT moved: drop superseded generations
    older than the grace period, orphaned unpublished ones (killed writers),
    and the pre-generation flat files. Touches only names this module creates;
    never `keep`, never whatever CURRENT names right now (another writer may
    have published after us). A failure here costs disk, never correctness."""
    live, _ = _read_current_pointer()  # ausente/ilegível → None: só `keep` fica protegido
    now = time.time()
    try:
        entries = list(INDEX_DIR.iterdir())  # vazio → nada a podar; falhou → pula a poda
    except OSError:
        return
    for entry in entries:
        try:
            if entry == keep or entry == live:
                continue
            if entry.is_dir() and _GEN_NAME_RE.match(entry.name):
                if now - entry.stat().st_mtime >= GEN_PRUNE_GRACE_SECONDS:
                    shutil.rmtree(entry, ignore_errors=True)
            elif entry.is_file() and entry.name.removesuffix(".tmp") in _FLAT_INDEX_FILES:
                entry.unlink(missing_ok=True)
        except OSError:
            continue


# ---------------------------------------------------------------------------
# Chunk+embed a set of already-fetched, already-finalized beads
# ---------------------------------------------------------------------------
def _chunks_for_corpus(corpus: list):
    chunk_texts, chunk_idx = [], []
    for i, b in enumerate(corpus):
        chunks = chunk_words(full_text(b)) or [b.get("title") or ""]
        for c in chunks:
            chunk_texts.append(c)
            chunk_idx.append(i)
    return chunk_texts, chunk_idx


def _require_heavy_step_allowed(what: str) -> None:
    """A from-scratch build embeds every chunk and rewrites the whole index:
    a heavy step in the sense of scripts/heavy-guard.sh (ga-vln2py, 17/10: heavy
    steps run with the disk already low filled it and Dolt took ENOSPC). Ask
    the guard; raise RecallIndexRebuildDeferred on anything but a clear yes
    (rc 75 low disk, rc 76 cannot read the disk, any other rc, cannot run it)
    -- under doubt the inert state is 'do not start'. A checkout without the
    guard script has nobody to ask and proceeds."""
    guard = Path(GC_CITY_PATH) / "scripts" / "heavy-guard.sh"
    if not guard.exists():
        return
    try:
        proc = subprocess.run([str(guard), "--check", "--what", what],
                              capture_output=True, text=True, timeout=HEAVY_GUARD_TIMEOUT_S)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise RecallIndexRebuildDeferred(
            f"recall needs to rebuild its index from scratch ({what}) but could not ask the disk "
            f"guard {guard} ({e}); nothing was changed -- try again later") from e
    if proc.returncode != 0:
        detail = (proc.stdout + proc.stderr).strip()[-400:]
        raise RecallIndexRebuildDeferred(
            f"recall needs to rebuild its index from scratch ({what}) but the disk guard did not "
            f"allow it (rc {proc.returncode}): {detail}\nnothing was changed -- run recall again "
            f"once the disk has room")


def build_full_index(progress=lambda msg: None) -> "RecallIndex":
    """Cold-start build: fetch closed beads (both stores) within
    MAX_AGE_DAYS, telemetry-filter, fetch full text for survivors,
    chunk+embed. First-ever run only — subsequent invocations use
    update_index_if_stale for cheap incremental refresh. Also the self-heal
    for an index that failed to load or turned out inconsistent; raises
    RecallIndexRebuildDeferred when the disk guard says not now."""
    import numpy as np

    _require_heavy_step_allowed("recall index rebuild (embed every chunk, rewrite the index)")
    model = load_model()
    cutoff = _cutoff_iso()
    corpus = []
    hwm = {}
    for store_key, store_path in STORES.items():
        meta = fetch_closed_meta(store_path, closed_after=cutoff)
        real = [b for b in meta if not is_telemetry(b)]
        progress(f"{store_key}: {len(meta)} closed (last {MAX_AGE_DAYS}d), {len(real)} real after telemetry filter")
        ids = [b["id"] for b in real]
        full = fetch_full(store_path, ids)
        full_by_id = {b["id"]: b for b in full}
        for b in real:
            fb = full_by_id.get(b["id"], b)
            corpus.append(finalize_bead(fb, store_key))
        dates = [b.get("closed_at") for b in meta if b.get("closed_at")]
        if dates:
            hwm[store_key] = max(dates)

    chunk_texts, chunk_idx = _chunks_for_corpus(corpus)
    progress(f"embedding {len(chunk_texts)} chunks for {len(corpus)} beads...")
    vecs = embed(model, chunk_texts)

    meta = {
        "schema_version": SCHEMA_VERSION,
        "model_name": MODEL_NAME,
        "built_at": now_iso(),
        "last_build_at": time.time(),
        "last_staleness_check_at": time.time(),
        "hwm_closed_at": hwm,
        "n_beads": len(corpus),
        "n_chunks": len(chunk_texts),
        "list_render_tokens": list_render_tokens_for(corpus),
        "max_age_days": MAX_AGE_DAYS,
    }
    return RecallIndex(corpus, vecs, np.array(chunk_idx, dtype=np.int64), meta)


# ---------------------------------------------------------------------------
# Incremental update — pure-logic helpers (unit-testable without bd/model)
# ---------------------------------------------------------------------------
def prune_and_reindex(corpus: list, chunk_vecs, chunk_bead_idx, cutoff_iso: str):
    """Drop beads older than cutoff_iso and remap chunk_bead_idx/chunk_vecs
    to match. Pure function over plain lists/arrays — no bd/model needed,
    so this is directly unit-testable."""
    import numpy as np
    keep_positions = [i for i, b in enumerate(corpus) if (b.get("closed_at") or "") >= cutoff_iso]
    old_to_new = {old: new for new, old in enumerate(keep_positions)}
    new_corpus = [corpus[i] for i in keep_positions]

    if len(chunk_bead_idx) == 0:
        return new_corpus, np.zeros((0, chunk_vecs.shape[1] if chunk_vecs.ndim == 2 else 384), dtype=np.float32), np.array([], dtype=np.int64)

    keep_mask = np.array([int(bi) in old_to_new for bi in chunk_bead_idx])
    new_vecs = chunk_vecs[keep_mask]
    new_bead_idx = np.array([old_to_new[int(bi)] for bi in chunk_bead_idx[keep_mask]], dtype=np.int64)
    return new_corpus, new_vecs, new_bead_idx


def append_new_beads(corpus: list, chunk_vecs, chunk_bead_idx, new_beads: list, model):
    """Embed + append new_beads (already finalize_bead()'d) onto the
    existing arrays. Returns (corpus, chunk_vecs, chunk_bead_idx)."""
    import numpy as np
    if not new_beads:
        return corpus, chunk_vecs, chunk_bead_idx
    base = len(corpus)
    new_corpus = corpus + new_beads
    chunk_texts, local_idx = _chunks_for_corpus(new_beads)
    new_vecs = embed(model, chunk_texts)
    offset_idx = np.array([base + i for i in local_idx], dtype=np.int64)
    merged_vecs = np.concatenate([chunk_vecs, new_vecs], axis=0) if len(chunk_vecs) else new_vecs
    merged_idx = np.concatenate([chunk_bead_idx, offset_idx], axis=0) if len(chunk_bead_idx) else offset_idx
    return new_corpus, merged_vecs, merged_idx


def should_rebuild(meta: dict, new_real_count: int, now: float = None) -> bool:
    """The two independent staleness triggers from the spec: index older
    than ~1 day, OR >~50 new real closed beads since the last build."""
    now = time.time() if now is None else now
    age_triggered = (now - meta.get("last_build_at", 0)) >= STALE_AFTER_SECONDS
    count_triggered = new_real_count >= STALE_NEW_BEAD_THRESHOLD
    return age_triggered or count_triggered


def _rebuild_from_scratch(reason: str, progress) -> "RecallIndex":
    progress(f"recall: index is inconsistent ({reason}) -- rebuilding from scratch")
    _log_index_event("rebuild_inconsistent_index", reason)
    new_idx = build_full_index(progress=progress)
    save_index(new_idx)
    return new_idx


def update_index_if_stale(idx: "RecallIndex", force: bool = False, progress=lambda msg: None):
    """Throttled staleness check + incremental update. Returns (idx,
    changed: bool). At most one bd round-trip per store per
    STALENESS_CHECK_MIN_INTERVAL_SECONDS city-wide, regardless of how often
    `recall` is invoked (Dolt is documented-sensitive to poll frequency in
    this repo).

    First of all (ga-m1sa2l) the index must be one index: vectors, bead_idx,
    corpus and meta that disagree used to crash prune_and_reindex -- or, on the
    throttled early return below, hybrid_retrieve -- on every call. An index
    that does not hold together is rebuilt from scratch instead, ignoring the
    throttle (it cannot answer anything); a rebuild the disk guard defers
    raises RecallIndexRebuildDeferred rather than returning the broken one."""
    why = index_inconsistency(idx.corpus, idx.chunk_vecs, idx.chunk_bead_idx, idx.meta)
    if why:
        return _rebuild_from_scratch(why, progress), True

    now = time.time()
    meta = idx.meta
    last_check = meta.get("last_staleness_check_at", 0)
    if not force and (now - last_check) < STALENESS_CHECK_MIN_INTERVAL_SECONDS:
        return idx, False

    new_by_store = {}
    total_new_real = 0
    known_ids_by_store = {}
    for store_key in STORES:
        known_ids_by_store[store_key] = {b["id"] for b in idx.corpus if b.get("store") == store_key}

    for store_key, store_path in STORES.items():
        hwm = meta.get("hwm_closed_at", {}).get(store_key)
        after = _shift_iso(hwm, hours=-1) if hwm else _cutoff_iso()
        try:
            fetched = fetch_closed_meta(store_path, closed_after=after)
        except Exception as e:
            progress(f"recall: staleness check failed for {store_key}: {e}")
            fetched = []
        known = known_ids_by_store[store_key]
        fresh = [b for b in fetched if b["id"] not in known]
        real = [b for b in fresh if not is_telemetry(b)]
        new_by_store[store_key] = (fetched, real)
        total_new_real += len(real)

    meta["last_staleness_check_at"] = now

    if not force and not should_rebuild(meta, total_new_real, now=now):
        save_index_meta(idx)  # persist the throttle timestamp even on a no-op check (meta only)
        return idx, False

    progress(f"recall: refreshing index (new_real_beads={total_new_real}) ...")
    model = load_model()
    cutoff = _cutoff_iso()
    corpus, chunk_vecs, chunk_bead_idx = prune_and_reindex(idx.corpus, idx.chunk_vecs, idx.chunk_bead_idx, cutoff)

    new_beads = []
    for store_key, (fetched, real) in new_by_store.items():
        if real:
            ids = [b["id"] for b in real]
            full = fetch_full(STORES[store_key], ids)
            full_by_id = {b["id"]: b for b in full}
            for b in real:
                fb = full_by_id.get(b["id"], b)
                new_beads.append(finalize_bead(fb, store_key))
        # Advance the high-water-mark over every closed bead the poll SAW
        # (`fetched`), not just the subset that survived the telemetry
        # filter (`real`). A round where every new-since-last-check bead
        # is telemetry (common — 97.8% of HQ closes) must still move the
        # mark forward, or `after` (derived from the mark) never advances
        # past that window and the same telemetry beads get re-fetched
        # from bd on every subsequent call, forever — the index silently
        # freezes for that store. This must NOT collapse into the
        # genuinely-empty case: when `fetched` itself is empty (nothing
        # closed at all since last check), `dates` is empty too and the
        # `if dates:` guard below correctly leaves the mark untouched.
        dates = [b.get("closed_at") for b in fetched if b.get("closed_at")]
        if dates:
            meta.setdefault("hwm_closed_at", {})
            meta["hwm_closed_at"][store_key] = max(meta["hwm_closed_at"].get(store_key, ""), max(dates))

    corpus, chunk_vecs, chunk_bead_idx = append_new_beads(corpus, chunk_vecs, chunk_bead_idx, new_beads, model)

    meta["last_build_at"] = now
    meta["n_beads"] = len(corpus)
    meta["n_chunks"] = int(len(chunk_bead_idx))
    meta["list_render_tokens"] = list_render_tokens_for(corpus)

    new_idx = RecallIndex(corpus, chunk_vecs, chunk_bead_idx, meta)
    save_index(new_idx)
    return new_idx, True


# ---------------------------------------------------------------------------
# Hybrid retrieval — the validated winner: semantic top-3 U keyword-title
# top-3, deduped (order: semantic hits first, then keyword-only additions)
# ---------------------------------------------------------------------------
def hybrid_retrieve(query: str, idx: "RecallIndex", model=None, k: int = 3) -> list:
    import numpy as np
    n_beads = len(idx.corpus)
    if n_beads == 0:
        return []
    model = model or load_model()

    q_vec = embed(model, [query])[0]
    sims = idx.chunk_vecs @ q_vec if len(idx.chunk_vecs) else np.zeros(0)
    bead_max_sim = np.full(n_beads, -1.0, dtype=np.float32)
    if len(sims):
        np.maximum.at(bead_max_sim, idx.chunk_bead_idx, sims)
    sem_order = np.argsort(-bead_max_sim)
    sem_top = sem_order[:k].tolist()
    sem_set = set(sem_top)

    qk = keywords(query)
    scored = []
    for i, b in enumerate(idx.corpus):
        overlap = len(qk & keywords(b.get("title") or ""))
        if overlap > 0:
            scored.append((overlap, b.get("closed_at") or "", i))
    scored.sort(key=lambda x: (x[0], x[1]), reverse=True)
    kw_top = [i for _, _, i in scored[:k]]
    kw_set = set(kw_top)

    union_idx = list(dict.fromkeys(sem_top + kw_top))
    results = []
    for i in union_idx:
        via = []
        if i in sem_set:
            via.append("semantic")
        if i in kw_set:
            via.append("keyword")
        results.append({
            "bead": idx.corpus[i],
            "semantic_score": float(bead_max_sim[i]),
            "via": via,
        })
    return results


def top_comments(bead: dict, query: str, model=None, n: int = 2) -> list:
    """Most-relevant 1-2 comments for display, scored fresh against the
    query at display time (bounded — only called for the ~5 winning beads,
    so this is cheap and doesn't touch the persisted index/ranking)."""
    comments = bead.get("comments") or []
    texts = [c.get("text") or "" for c in comments if c.get("text")]
    if not texts:
        return []
    model = model or load_model()
    q_vec = embed(model, [query])[0]
    c_vecs = embed(model, [t[:2000] for t in texts])
    sims = c_vecs @ q_vec
    import numpy as np
    order = np.argsort(-sims)[:n]
    return [texts[i] for i in order]


# ---------------------------------------------------------------------------
# Instrumentation — one JSONL line per invocation
# ---------------------------------------------------------------------------
def log_usage(query: str, results: list, idx: "RecallIndex", elapsed_s: float, log_path: Path = None) -> dict:
    """Append one usage record and return it. baseline_estimate_tokens is
    the ga-ps28g baseline formula: the bd-list render an agent would scan
    (cached in index meta, refreshed each build) plus full-body reads of
    the same number of beads recall returned -- i.e. what 'bd list + read
    N candidates' would have cost for this same query."""
    log_path = log_path or LOG_PATH
    returned_tokens = sum(r["bead"].get("_ntok_full", 0) for r in results)
    list_render_tokens = idx.meta.get("list_render_tokens", 0)
    baseline_estimate_tokens = list_render_tokens + returned_tokens
    record = {
        "ts": now_iso(),
        "query": query,
        "bead_ids": [r["bead"]["id"] for r in results],
        "returned_tokens": int(returned_tokens),
        "baseline_estimate_tokens": int(baseline_estimate_tokens),
        "savings_ratio": (baseline_estimate_tokens / returned_tokens) if returned_tokens else None,
        "elapsed_s": round(elapsed_s, 3),
    }
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with open(log_path, "a") as f:
        f.write(json.dumps(record) + "\n")
    return record
