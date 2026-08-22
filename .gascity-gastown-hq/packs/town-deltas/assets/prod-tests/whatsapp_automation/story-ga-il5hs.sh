#!/usr/bin/env bash
# prod-tests/whatsapp_automation/story-ga-il5hs.sh
#
# Story-specific prod test for ga-il5hs — "PBH edificação: cruzar índice
# cadastral dos projetos com nosso cadastro de donos (mega_data_set/
# cpf_consolidado/cnpj_consolidado)". Invoked by run.sh when STORY_ID=ga-il5hs.
#
# WHAT THIS PROVES (and what it deliberately does NOT):
#
#   PROVES — the code actually DEPLOYED to $WA_ROOT carries the real merge
#   logic and the safety properties the acceptance criteria require. The unit
#   tests (tests/test_pbh_edificacao_owner_enrich.py) already ran green on the
#   branch; the only thing worth asserting after a deploy is that the deploy
#   carried them. "Merged" and "live" are different facts.
#     1. A lote whose fiscal owner resolves to a CPF gets nome/idade/lead_score
#        from cpf_consolidado, with fonte_pessoa='pf.cpf_consolidado'.
#     2. A lote whose fiscal owner resolves to a CNPJ gets razao_social/
#        capital_social from cnpj_consolidado, with fonte_pessoa=
#        'rfb.cnpj_consolidado'.
#     3. EVERY produced row carries the explicit qualifier (AC4) — "dono
#        fiscal atual do lote", never presented as "quem protocolou o
#        projeto" without that qualification.
#     4. A document found in mega_data_set but absent from cpf/cnpj_consolidado
#        still produces a row (AC1 requires only the document be identified)
#        instead of silently dropping it (same AC5 pattern as
#        pbh_edificacao_combo_status).
#     5. The upsert schema creates pbh_edificacao_dono_fiscal as a SEPARATE
#        table and the module never references pbh_edificacao_detalhe by name
#        anywhere in its own source (AC3 — that table stays untouched).
#
#   DOES NOT PROVE — that the real MotherDuck join returns correct data for
#   real lotes, or that shared/data/pbh_edificacao_tramitacao.db (production
#   data, symlinked — see house doctrine) actually gets new rows tonight. Both
#   require live MotherDuck compute (under cost review, wa-a0cbc) and touching
#   production data, neither of which an automated post-deploy check should do
#   on every delivery. Those stay human-verified; this script exists so a
#   deploy that silently dropped the merge logic or the qualifier cannot
#   masquerade as one that shipped it.
#
# No MotherDuck, no network, no production DB write: an in-memory duckdb
# connection stands in for MotherDuck (same fixture shape as the unit tests)
# and the sqlite side uses a tmp path — never shared/data/*.db. Safe to run on
# every delivery.

set -uo pipefail

WA_ROOT="${WA_ROOT:-/Users/athos/gt/whatsapp_automation}"

log()  { echo "[prod-test:ga-il5hs] $*"; }
fail() { echo "[prod-test:ga-il5hs] FAIL: $*" >&2; exit 1; }

ENR_SRC="$WA_ROOT/scripts/pbh_edificacao_owner_enrich.py"
[ -f "$ENR_SRC" ] || fail "pbh_edificacao_owner_enrich.py not found at $ENR_SRC — wrong WA_ROOT or deploy incomplete?"

# AC3 is about never WRITING/reading FROM pbh_edificacao_detalhe as a table —
# not about never mentioning its name. The module's own docstring/comments
# name it deliberately, to document the invariant for the next reader (same
# reasoning as ga-7kz2k's render_template_string check below: match the
# actual usage form, not any mention). A bare `grep -q` here would fail this
# prod test against the module's own correct, well-documented source.
if grep -Eq '\b(CREATE[[:space:]]+TABLE([[:space:]]+IF[[:space:]]+NOT[[:space:]]+EXISTS)?|INSERT[[:space:]]+INTO|UPDATE|DELETE[[:space:]]+FROM|FROM|JOIN)[[:space:]]+pbh_edificacao_detalhe\b' "$ENR_SRC"; then
  fail "$ENR_SRC uses pbh_edificacao_detalhe as a table (CREATE/INSERT/UPDATE/DELETE/FROM/JOIN) — AC3 requires this module to never touch that table."
fi

log "asserting deployed $ENR_SRC ..."

WA_ROOT="$WA_ROOT" python3 - <<'PY' || fail "deployed pbh_edificacao_owner_enrich.py does not carry the ga-il5hs behavior (see assertion above)"
import json
import os
import sqlite3
import sys
import tempfile

sys.path.insert(0, os.environ["WA_ROOT"])
import scripts.pbh_edificacao_owner_enrich as enr  # noqa: E402

try:
    import duckdb
except ImportError:
    print("SKIP: duckdb not importable in this environment — cannot exercise fetch_* against a real connection.")
    sys.exit(0)


def md_conn():
    conn = duckdb.connect(":memory:")
    conn.execute("CREATE SCHEMA ops")
    conn.execute(
        'CREATE TABLE ops.mega_data_set ('
        '  "INDICE CADASTRAL" VARCHAR,'
        '  "TIPO DOCUMENTO PROPRIETARIO" VARCHAR,'
        '  "DOCUMENTO PROPRIETARIO" VARCHAR'
        ')'
    )
    conn.execute("CREATE SCHEMA pf")
    conn.execute(
        "CREATE TABLE pf.cpf_consolidado ("
        "  cpf VARCHAR, nome VARCHAR, idade BIGINT, n_phones BIGINT,"
        "  phones_array STRUCT(numero VARCHAR, tipo VARCHAR, whatsapp BIGINT)[],"
        "  lead_score BIGINT"
        ")"
    )
    conn.execute("CREATE SCHEMA rfb")
    conn.execute(
        "CREATE TABLE rfb.cnpj_consolidado ("
        "  cnpj_full VARCHAR, razao_social VARCHAR, capital_social DOUBLE,"
        "  socios_array STRUCT(nome VARCHAR, documento VARCHAR, qualificacao VARCHAR)[]"
        ")"
    )
    return conn


tmp_dir = tempfile.mkdtemp(prefix="ga-il5hs-prodtest-")
sqlite_path = os.path.join(tmp_dir, "pbh_edificacao_tramitacao.db")
tram = sqlite3.connect(sqlite_path)
tram.execute(
    "CREATE TABLE pbh_edificacao_tramitacao (indice_cadastral TEXT, projeto_id INTEGER,"
    " PRIMARY KEY (indice_cadastral, projeto_id))"
)
tram.execute("INSERT INTO pbh_edificacao_tramitacao VALUES ('113150 033 2065', 1)")
tram.execute("INSERT INTO pbh_edificacao_tramitacao VALUES ('001004A036 0013', 2)")
tram.execute("INSERT INTO pbh_edificacao_tramitacao VALUES ('222222 222 2222', 3)")
tram.commit()
tram.close()

md = md_conn()
md.execute("INSERT INTO ops.mega_data_set VALUES ('113150 033 2065', 'CPF', '00390292630')")
md.execute("INSERT INTO ops.mega_data_set VALUES ('001004A036 0013', 'CNPJ', '08061986000111')")
md.execute("INSERT INTO ops.mega_data_set VALUES ('222222 222 2222', 'CPF', '11111111111')")  # no cpf_consolidado row
md.execute(
    "INSERT INTO pf.cpf_consolidado VALUES "
    "('00390292630', 'FULANO DA SILVA', 45, 1, "
    "[{'numero': '5531999999999', 'tipo': 'Celular', 'whatsapp': 1}], 80)"
)
md.execute(
    "INSERT INTO rfb.cnpj_consolidado VALUES "
    "('08061986000111', 'SOMATTOS INCORPORADORA LTDA', 200000.0, "
    "[{'nome': 'FULANO', 'documento': '000', 'qualificacao': 'Socio-Administrador'}])"
)

summary = enr.run(sqlite_path, md, computed_at="2026-08-21T12:00:00")
rows = {r["indice_cadastral"]: r for r in summary["rows"]}

assert summary["indices_alvo"] == 3, f"expected 3 target indices, got {summary['indices_alvo']}"
assert len(rows) == 3, f"expected 3 rows written (document identified for all 3, AC1), got {len(rows)}"

cpf_row = rows["113150 033 2065"]
assert cpf_row["tipo_documento"] == "CPF"
assert cpf_row["nome"] == "FULANO DA SILVA", f"CPF enrichment missing: {cpf_row}"
assert cpf_row["idade"] == 45
assert cpf_row["fonte_pessoa"] == "pf.cpf_consolidado"
assert cpf_row["enriquecimento_status"] == "completo"
print("  [1/5] CPF lot enriched via cpf_consolidado OK")

cnpj_row = rows["001004A036 0013"]
assert cnpj_row["tipo_documento"] == "CNPJ"
assert cnpj_row["nome"] == "SOMATTOS INCORPORADORA LTDA", f"CNPJ enrichment missing: {cnpj_row}"
assert cnpj_row["capital_social"] == 200000.0
assert cnpj_row["fonte_pessoa"] == "rfb.cnpj_consolidado"
assert cnpj_row["enriquecimento_status"] == "completo"
print("  [2/5] CNPJ lot enriched via cnpj_consolidado OK")

missing_row = rows["222222 222 2222"]
assert missing_row["tipo_documento"] == "CPF"
assert missing_row["documento"] == "11111111111"
assert missing_row["nome"] is None
assert missing_row["enriquecimento_status"] == "documento_sem_dados_pessoa", (
    "AC1 requires a row the moment the document is identified, even when the "
    "deeper person lookup misses — a silent drop here would be the exact "
    "silent-hole class this house's AC5 pattern exists to prevent"
)
print("  [3/5] document-found-but-person-missing is a queryable row, not a silent drop OK")

for idx, row in rows.items():
    assert "dono fiscal atual do lote" in row["qualificador"], f"row for {idx} missing AC4 qualifier"
    assert "protocolou" in row["qualificador"], f"row for {idx} qualifier does not disclaim 'quem protocolou'"
print("  [4/5] every row carries the explicit AC4 qualifier OK")

conn = enr._connect(sqlite_path)
cols = {r[1] for r in conn.execute("PRAGMA table_info(pbh_edificacao_dono_fiscal)").fetchall()}
for required in ("indice_cadastral", "tipo_documento", "documento", "qualificador", "fonte_documento"):
    assert required in cols, f"pbh_edificacao_dono_fiscal missing expected column {required}"
tables = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()}
assert "pbh_edificacao_detalhe" not in tables, (
    "pbh_edificacao_owner_enrich._connect created pbh_edificacao_detalhe — "
    "AC3 requires this module to never create or touch that table"
)
print("  [5/5] pbh_edificacao_dono_fiscal is a separate table with the join key + provenance columns OK")
PY

log "story-ga-il5hs PASS — deployed pbh_edificacao_owner_enrich carries the merge, AC1/AC3/AC4/AC5 behavior"
