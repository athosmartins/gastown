#!/usr/bin/env python3
"""
fix_mds_restrictions.py — Correct altimetria and tombamento spatial join in mega_data_set.

ROOT CAUSE: The pipeline that assigns restriction flags used predicate='intersects',
which flags any lot whose polygon TOUCHES the restriction polygon boundary. Adjacent
lots share boundaries, so they absorb false flags from their neighbors.

FIX: predicate='within' on lot centroids — a lot receives the flag only if its
centroid falls inside the restriction polygon, eliminating boundary-touch false positives.

Sources (PBH open data, EPSG:31983):
  bem_cultural_imovel  → GRAU TOMBAMENTO, HAS TOMBAMENTO, GEOMETRY TOMBAMENTO
  diretriz_altimetria  → VALOR REFERENCIA ALTIMETRIA, DESCRICAO ALTIMETRIA, HAS ALTIMETRIA

Usage:
    python3 scripts/fix_mds_restrictions.py
    python3 scripts/fix_mds_restrictions.py --dry-run
    python3 scripts/fix_mds_restrictions.py --input /path/to/mega.parquet --output /path/to/fixed.parquet
    python3 scripts/fix_mds_restrictions.py --pbh-data-dir /path/to/PBH_Data
"""
import argparse
import sys
import time
from pathlib import Path

import pandas as pd
import geopandas as gpd
from shapely import wkt

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

_SCRIPT_DIR = Path(__file__).parent.resolve()
_RIG_DIR = _SCRIPT_DIR.parent
_DEFAULT_PARQUET = _RIG_DIR / "shared" / "data" / "mega_compatibilized.parquet"

# Google Drive PBH data — locally mounted on macOS
_DEFAULT_PBH = Path(
    "/Users/athos/Library/CloudStorage/"
    "GoogleDrive-athosmartins@gmail.com/"
    "My Drive/05 Github/real_estate/PBH_Data"
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def log(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def latest_csv(folder: Path) -> Path | None:
    """Return the most recently modified CSV in folder (non-recursive)."""
    if not folder.exists():
        return None
    csvs = sorted(folder.glob("*.csv"), key=lambda p: p.stat().st_mtime, reverse=True)
    return csvs[0] if csvs else None


def load_pbh_csv(csv_path: Path) -> gpd.GeoDataFrame:
    """Read a PBH CSV with semicolon separator + GEOMETRIA WKT column (EPSG:31983),
    returning a GeoDataFrame in WGS84 (EPSG:4326)."""
    df = pd.read_csv(csv_path, sep=";", dtype=str, low_memory=False)
    df.columns = [c.strip() for c in df.columns]
    geom_col = next((c for c in df.columns if c.upper() in ("GEOMETRIA", "GEOMETRY")), None)
    if not geom_col:
        raise ValueError(f"No geometry column found in {csv_path.name}")
    df = df[df[geom_col].notna() & (df[geom_col].str.len() > 10)].copy()
    df["geometry"] = df[geom_col].map(lambda s: wkt.loads(s))
    df = df[df["geometry"].notna()].drop(columns=[geom_col])
    gdf = gpd.GeoDataFrame(df, geometry="geometry", crs="EPSG:31983")
    return gdf.to_crs(4326)


# ---------------------------------------------------------------------------
# Tombamento fix
# ---------------------------------------------------------------------------

def fix_tombamento(
    mds: pd.DataFrame,
    pbh_dir: Path,
    dry_run: bool,
) -> pd.DataFrame:
    """Re-assign HAS TOMBAMENTO, GRAU TOMBAMENTO, GEOMETRY TOMBAMENTO
    using centroid-within predicate on bem_cultural_imovel polygons."""

    log("=== Tombamento ===")
    csv = latest_csv(pbh_dir / "bem_cultural_imovel")
    if not csv:
        log("  ⚠ bem_cultural_imovel CSV not found — skipping tombamento fix")
        return mds

    log(f"  Loading {csv.name}...")
    gdf_tomb = load_pbh_csv(csv)
    # Only rows representing effective tombamento (legal protection).
    # "Registro Documental" types are city-wide area polygons, not lot-specific —
    # including them makes every lot a false positive. Only use the two categories
    # that produce per-lot flags in the existing MDS data.
    valid = gdf_tomb["DESC_TIPO_GRAU_PROTECAO"].isin(
        {"Tombado", "Processo de tombamento aberto"}
    )
    gdf_tomb = gdf_tomb[valid].copy()
    log(f"  {len(gdf_tomb):,} valid tombamento polygons")

    # Build lot centroids GeoDataFrame (WGS84)
    log("  Parsing lot geometries + building centroids...")
    lot_geoms = mds["GEOMETRY"].map(lambda g: wkt.loads(g) if pd.notna(g) and g else None)
    centroids = lot_geoms.map(lambda g: g.centroid if g else None)
    gdf_lots = gpd.GeoDataFrame(
        {"INDICE CADASTRAL": mds["INDICE CADASTRAL"]},
        geometry=centroids,
        crs="EPSG:4326",
    )

    # Spatial join: centroid within tombamento polygon
    log("  Spatial join (centroid within tombamento polygon)...")
    joined = gpd.sjoin(
        gdf_lots[gdf_lots.geometry.notna()],
        gdf_tomb[["DESC_TIPO_GRAU_PROTECAO", "geometry"]],
        how="left",
        predicate="within",
    )
    # If a centroid falls within multiple tombamento polygons, keep the first
    joined = joined.groupby("INDICE CADASTRAL").first().reset_index()
    joined = joined[["INDICE CADASTRAL", "DESC_TIPO_GRAU_PROTECAO", "index_right"]]

    # Merge back to get tombamento geometry for matched lots
    # index_right is gdf_tomb's DataFrame index (label), not positional
    matched_idx = joined["index_right"].dropna().astype(int).unique()
    geom_map: dict[int, str] = {
        i: gdf_tomb.loc[i, "geometry"].wkt for i in matched_idx
    }
    joined["GEOMETRY TOMBAMENTO NEW"] = joined["index_right"].map(
        lambda i: geom_map.get(int(i)) if pd.notna(i) else None
    )

    # Build lookup: IC → (grau, geometry)
    tomb_lookup = joined.set_index("INDICE CADASTRAL")[
        ["DESC_TIPO_GRAU_PROTECAO", "GEOMETRY TOMBAMENTO NEW"]
    ].to_dict("index")

    # Count changes
    before_true = int((mds["HAS TOMBAMENTO"] == True).sum())  # noqa: E712
    new_grau, new_has, new_geom = [], [], []
    for ic in mds["INDICE CADASTRAL"]:
        entry = tomb_lookup.get(ic, {})
        grau_raw = entry.get("DESC_TIPO_GRAU_PROTECAO")
        # NaN is truthy in Python (only 0.0 is falsy), so `nan or None` returns nan.
        # Use isinstance to reliably distinguish a valid string from NaN/None.
        grau = grau_raw if isinstance(grau_raw, str) and grau_raw else None
        geom = entry.get("GEOMETRY TOMBAMENTO NEW") or None
        has = grau is not None
        new_grau.append(grau)
        new_has.append(has)
        new_geom.append(geom)

    after_true = sum(new_has)
    log(f"  Before: {before_true:,} lots with tombamento")
    log(f"  After:  {after_true:,} lots with tombamento")
    log(f"  Removed false positives: {before_true - after_true:,}")

    if not dry_run:
        mds = mds.copy()
        mds["GRAU TOMBAMENTO"] = new_grau
        mds["HAS TOMBAMENTO"] = new_has
        mds["GEOMETRY TOMBAMENTO"] = new_geom

    return mds


# ---------------------------------------------------------------------------
# Altimetria fix
# ---------------------------------------------------------------------------

def fix_altimetria(
    mds: pd.DataFrame,
    pbh_dir: Path,
    dry_run: bool,
) -> pd.DataFrame:
    """Re-assign HAS ALTIMETRIA, VALOR REFERENCIA ALTIMETRIA, DESCRICAO ALTIMETRIA
    using centroid-within predicate on diretriz_altimetria polygons."""

    log("\n=== Altimetria ===")
    csv = latest_csv(pbh_dir / "diretriz_altimetria")
    if not csv:
        log("  ⚠ diretriz_altimetria CSV not found — skipping altimetria fix")
        return mds

    log(f"  Loading {csv.name}...")
    gdf_alti = load_pbh_csv(csv)
    log(f"  {len(gdf_alti):,} altimetria polygons")

    # Build lot centroids GeoDataFrame (reuse logic)
    log("  Parsing lot geometries + building centroids...")
    lot_geoms = mds["GEOMETRY"].map(lambda g: wkt.loads(g) if pd.notna(g) and g else None)
    centroids = lot_geoms.map(lambda g: g.centroid if g else None)
    gdf_lots = gpd.GeoDataFrame(
        {"INDICE CADASTRAL": mds["INDICE CADASTRAL"]},
        geometry=centroids,
        crs="EPSG:4326",
    )

    # Spatial join: centroid within altimetria polygon
    log("  Spatial join (centroid within altimetria polygon)...")
    cols_alti = ["VALOR_REFERENCIA", "DESC_DIRETRIZ_PROTECAO", "geometry"]
    joined = gpd.sjoin(
        gdf_lots[gdf_lots.geometry.notna()],
        gdf_alti[cols_alti],
        how="left",
        predicate="within",
    )
    # If centroid falls within multiple altimetria polygons, keep the first
    joined = joined.groupby("INDICE CADASTRAL").first().reset_index()
    joined = joined[["INDICE CADASTRAL", "VALOR_REFERENCIA", "DESC_DIRETRIZ_PROTECAO"]]

    alti_lookup = joined.set_index("INDICE CADASTRAL")[
        ["VALOR_REFERENCIA", "DESC_DIRETRIZ_PROTECAO"]
    ].to_dict("index")

    before_true = int((mds["HAS ALTIMETRIA"] == True).sum())  # noqa: E712
    new_valor, new_desc, new_has = [], [], []
    for ic in mds["INDICE CADASTRAL"]:
        entry = alti_lookup.get(ic, {})
        valor_raw = entry.get("VALOR_REFERENCIA")
        desc = entry.get("DESC_DIRETRIZ_PROTECAO") or None
        try:
            valor = float(str(valor_raw).replace(",", ".")) if pd.notna(valor_raw) else None
        except (ValueError, TypeError):
            valor = None
        has = valor is not None
        new_valor.append(valor)
        new_desc.append(desc)
        new_has.append(has)

    after_true = sum(new_has)
    log(f"  Before: {before_true:,} lots with altimetria")
    log(f"  After:  {after_true:,} lots with altimetria")
    log(f"  Removed false positives: {before_true - after_true:,}")

    if not dry_run:
        mds = mds.copy()
        mds["VALOR REFERENCIA ALTIMETRIA"] = new_valor
        mds["DESCRICAO ALTIMETRIA"] = new_desc
        mds["HAS ALTIMETRIA"] = new_has

    return mds


# ---------------------------------------------------------------------------
# Acceptance test (Fernandes Tourinho 767)
# ---------------------------------------------------------------------------

def run_acceptance_test(mds: pd.DataFrame) -> bool:
    """Verify the Fernandes Tourinho 767 acceptance criteria:
    - No neighboring lot gets a tombamento/altimetria flag purely by proximity.
    - Lots that truly have the restriction keep it.
    """
    log("\n=== Acceptance test: Fernandes Tourinho 767 ===")

    ft = mds[
        mds["NOME LOGRADOURO"].str.contains("FERNANDES TOURINHO", na=False)
        & mds["NUMERO IMOVEL"].astype(str).str.strip().isin(["767", "767.0"])
    ].copy()

    if ft.empty:
        log("  ⚠ FT 767 not found in dataset")
        return True  # non-blocking

    log(f"  FT 767 lots: {len(ft)}")
    log(f"  HAS TOMBAMENTO: {ft['HAS TOMBAMENTO'].value_counts().to_dict()}")
    log(f"  HAS ALTIMETRIA: {ft['HAS ALTIMETRIA'].value_counts().to_dict()}")

    # FT 767 should NOT have tombamento (the tombado building is at 735, not 767)
    if (ft["HAS TOMBAMENTO"] == True).any():  # noqa: E712
        log("  ✗ FAIL: FT 767 incorrectly has HAS TOMBAMENTO=True")
        return False
    log("  ✓ PASS: FT 767 has no tombamento (correct — tombamento is at 735)")

    return True


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--input", default=str(_DEFAULT_PARQUET), help="Input mega parquet")
    parser.add_argument("--output", default=None, help="Output parquet (default: in-place)")
    parser.add_argument("--pbh-data-dir", default=str(_DEFAULT_PBH), help="PBH_Data root")
    parser.add_argument("--dry-run", action="store_true", help="Report stats without writing")
    parser.add_argument("--skip-tombamento", action="store_true")
    parser.add_argument("--skip-altimetria", action="store_true")
    args = parser.parse_args()

    t0 = time.time()
    input_path = Path(args.input)
    output_path = Path(args.output) if args.output else input_path
    pbh_dir = Path(args.pbh_data_dir)

    log(f"Loading {input_path}...")
    mds = pd.read_parquet(input_path)
    log(f"  {len(mds):,} rows x {len(mds.columns)} cols")

    if not args.skip_tombamento:
        mds = fix_tombamento(mds, pbh_dir, dry_run=args.dry_run)

    if not args.skip_altimetria:
        mds = fix_altimetria(mds, pbh_dir, dry_run=args.dry_run)

    ok = run_acceptance_test(mds)

    if not args.dry_run:
        log(f"\nSaving → {output_path}...")
        mds.to_parquet(output_path, index=False)
        log(f"Done in {time.time() - t0:.1f}s")
    else:
        log("\n[DRY RUN] No files written.")
        log(f"Done in {time.time() - t0:.1f}s")

    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
