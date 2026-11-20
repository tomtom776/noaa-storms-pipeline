#!/usr/bin/env bash
#
# pipeline.sh — Download a year of NOAA Storm Events, convert to GeoParquet.
#
# Usage:   ./pipeline.sh [YEAR]
# Example: ./pipeline.sh 2024
#
# Requires: bash, curl, gunzip, ogr2ogr (GDAL >= 3.5)
#
# This is a starter scaffold. Read the comments. Replace the [TODO] markers
# with the actual logic. Do not change the structure unless you have a reason.

set -euo pipefail

# -----------------------------------------------------------------------------
# Config
# -----------------------------------------------------------------------------

# Year to pull. Override by passing as the first argument.
YEAR="${1:-2024}"

# NOAA file naming pattern. The "c{CREATED_DATE}" portion changes when NOAA
# republishes a year. Look at https://www.ncei.noaa.gov/data/storm-events/access/original/
BASE_URL="https://www.ncei.noaa.gov/data/storm-events/access/original"
YEAR_URL="${BASE_URL}/${YEAR}/"

RAW_DIR="data/raw/${YEAR}"
REF_DIR="data/reference"
PROCESSED_DIR="data/processed"
OUT_PARQUET="${PROCESSED_DIR}/storms_${YEAR}.parquet"

# -----------------------------------------------------------------------------
# Step 1: Set up directories
# -----------------------------------------------------------------------------

echo "[1/3] Setting up directories"

mkdir -p "$RAW_DIR" "$PROCESSED_DIR"
# [TODO] Use mkdir -p to create RAW_DIR and PROCESSED_DIR. Both should be
# safe to call even if the directories already exist.

# -----------------------------------------------------------------------------
# Step 2: Download the raw file
# -----------------------------------------------------------------------------

echo "[2/3] Downloading details files for ${YEAR}"

# --- Discover the details files for this year from the NOAA directory listing ---
# Matches the monthly pattern (StormEvents_details_sYYYYMMDD_eYYYYMMDD_cYYYYMMDD.csv)
# and the legacy annual pattern (StormEvents_details-ftp_v1.0_dYYYY_cYYYYMMDD.csv.gz).
# If NOAA republished a file, there may be two with different c-dates; keep the newest.
INDEX_HTML="$(curl -fsSL --retry 3 "$YEAR_URL")" || {
  echo "Could not fetch directory listing: $YEAR_URL" >&2
  exit 1
}

mapfile -t FILE_NAMES < <(
  printf '%s\n' "$INDEX_HTML" \
    | grep -oE 'StormEvents_details[^"<> ]+\.csv(\.gz)?' \
    | sort -u \
    | awk '{ key=$0; sub(/_c[0-9]+\.csv.*/, "", key); latest[key]=$0 }
           END { for (k in latest) print latest[k] }' \
    | sort
)

if [ "${#FILE_NAMES[@]}" -eq 0 ]; then
  echo "No StormEvents details files found for ${YEAR}" >&2
  exit 1
fi
echo "Found ${#FILE_NAMES[@]} details file(s) for ${YEAR}"

# --- Download (skips files already present; partial downloads never kept) ---
for f in "${FILE_NAMES[@]}"; do
  dest="${RAW_DIR}/${f}"
  if [ -s "$dest" ]; then
    echo "Already have $f"
    continue
  fi
  echo "Downloading $f"
  if curl -fsSL --retry 3 -o "${dest}.part" "${YEAR_URL}${f}"; then
    mv "${dest}.part" "$dest"
  else
    echo "Failed: $f" >&2
    rm -f "${dest}.part"
    exit 1
  fi
done

# -----------------------------------------------------------------------------
# Step 3: Convert CSV to GeoParquet
# -----------------------------------------------------------------------------

echo "[3/3] Converting to GeoParquet"
# The Parquet driver can't append, so merge the monthly CSVs (same header) into
# one CSV first, then convert once.
#
# The details CSVs have no coordinates, so each event is located by joining to
# reference GeoParquet files in data/reference/ (WGS 84, EPSG:4326 points):
#   cz_type = 'C'  -> county: Census county internal point, matched on
#                     state_fips + cz_fips (county_fips)
#   otherwise      -> NWS forecast zone (land, marine, offshore): zone point,
#                     matched on state_fips + cz_fips (zone)
# Events with no match keep a NULL geometry (location_source is NULL).
MERGED_CSV="${RAW_DIR}/storms_${YEAR}_merged.csv"
MERGED_LAYER="$(basename "$MERGED_CSV" .csv)"
COUNTIES_PQ="${REF_DIR}/census_counties_2024.parquet"
ZONES_PQ="${REF_DIR}/nws_zones.parquet"
TMP_PARQUET="${OUT_PARQUET%.parquet}.tmp.parquet"

for ref in "$COUNTIES_PQ" "$ZONES_PQ"; do
  if [ ! -s "$ref" ]; then
    echo "Missing reference file: $ref" >&2
    exit 1
  fi
done

if [ -s "$OUT_PARQUET" ]; then
  echo "Already have ${OUT_PARQUET}"
else
  mapfile -t CSVS < <(ls "${RAW_DIR}"/StormEvents_details_*.csv | grep -v merged | sort)
  if [ "${#CSVS[@]}" -eq 0 ]; then
    echo "No CSV files found in ${RAW_DIR}" >&2
    exit 1
  fi

  # Header from the first file, data rows from all files
  head -n 1 "${CSVS[0]}" > "$MERGED_CSV"
  for f in "${CSVS[@]}"; do
    tail -n +2 "$f" >> "$MERGED_CSV"
  done

  # Write to a temp file and rename on success, so a failed run never leaves a
  # partial Parquet file that the skip check above would mistake for finished.
  rm -f "$TMP_PARQUET"
  ogr2ogr \
    -f Parquet "$TMP_PARQUET" "$MERGED_CSV" \
    -oo AUTODETECT_TYPE=YES \
    -oo AUTODETECT_SIZE_LIMIT=0 \
    -oo EMPTY_STRING_AS_NULL=YES \
    -a_srs EPSG:4326 \
    -nln storms \
    -nlt POINT \
    -lco COMPRESSION=ZSTD \
    -lco GEOMETRY_NAME=geometry \
    -dialect sqlite \
    -sql "
WITH c AS MATERIALIZED (
       SELECT state_fips, county_fips, geoid, geometry
       FROM '${COUNTIES_PQ}'.census_counties_2024),
     z AS MATERIALIZED (
       SELECT state_fips, zone, zone_id, geometry
       FROM '${ZONES_PQ}'.nws_zones)
SELECT s.*,
       CASE WHEN s.cz_type = 'C'  AND c.geoid   IS NOT NULL THEN 'county'
            WHEN s.cz_type <> 'C' AND z.zone_id IS NOT NULL THEN 'zone'
       END AS location_source,
       CASE WHEN s.cz_type = 'C' THEN c.geometry ELSE z.geometry END AS geometry
FROM ${MERGED_LAYER} s
LEFT JOIN c ON s.cz_type = 'C'
           AND c.state_fips = CAST(s.state_fips AS INTEGER)
           AND c.county_fips = s.cz_fips
LEFT JOIN z ON s.cz_type <> 'C'
           AND z.state_fips = CAST(s.state_fips AS INTEGER)
           AND z.zone = s.cz_fips"
  mv "$TMP_PARQUET" "$OUT_PARQUET"
fi

echo "Done. Output: ${OUT_PARQUET}"
echo "Open it in DuckDB:"
echo "  duckdb -c \"INSTALL spatial; LOAD spatial; SELECT COUNT(*) FROM read_parquet('${OUT_PARQUET}');\""
