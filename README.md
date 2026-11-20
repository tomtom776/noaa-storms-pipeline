# NOAA Storms Pipeline

A one-command pipeline that downloads a year of NOAA Storm Events data, locates each event, and writes a GeoParquet file of points ready for analysis in DuckDB, GeoPandas, or QGIS.

## What it does

`pipeline.sh` takes a year (default: 2024) and:

1. Discovers and downloads that year's monthly `StormEvents_details` CSVs from NOAA's public archive (about 12 files, roughly 110 MB for 2024).
2. Merges them into one CSV.
3. Locates each event by joining it to the reference files in `data/reference/`, then writes `data/processed/storms_{YEAR}.parquet`.

Runtime is a few minutes for a typical year: the download depends on your connection, and the location join takes about 2 minutes.

## How events get a location

The NOAA `details` files **do not contain latitude or longitude**. They identify where an event happened with a state FIPS code, a `cz_fips` code, and a `cz_type` flag (`C` = county/parish, `Z` = NWS forecast zone, `M` = marine zone). The type is set by event type: Hail, Tornado and Thunderstorm Wind are county-based, while Heat, Winter Storm and Drought are zone-based.

So each event gets the center point of its county or zone:

| Event type (`cz_type`) | Located using | Reference file |
|---|---|---|
| County (`C`) | Census county internal point | `data/reference/census_counties_2024.parquet` |
| Zone / marine (everything else) | NWS zone point (land, marine, offshore) | `data/reference/nws_zones.parquet` |

The output has a `location_source` column (`county`, `zone`, or empty) and a `geometry` column.

**Limits to be aware of**

- These are area centers, not where the event actually occurred. Many events share the same point.
- About 2-4% of events can't be matched and have a NULL geometry (2024: 2,474 of 106,334; 2022: 3,320 of 94,121). Common causes are territories such as Puerto Rico (NOAA's codes differ from Census), old Connecticut and Alaska county codes, and zones that changed after the reference data was published.
- See [data/reference/README.md](data/reference/README.md) for sources, codes and known gaps.

## The data

- **Source:** [NOAA Storm Events Database](https://www.ncei.noaa.gov/data/storm-events/)
- **License:** Public domain (US federal data)
- **What's in it:** storm events in the United States and its territories for the given year, including type, location (county or zone), and damages
- **Tested years:** 2022, 2023 and 2024. Older years may differ (legacy `.csv.gz` files aren't decompressed, and some years list overlapping files that would be double-counted).

## How to run it

Requires:

- `bash` 4 or later (the script uses `mapfile`) and `curl`
- `ogr2ogr` from a GDAL (3.5+) that can **write GeoParquet** and supports the SQLite SQL dialect

GDAL builds differ here. The QGIS 4.2.3 build of GDAL 3.13.3 can't write Parquet with a geometry column (it fails with a "thrift ... buffer size overflow" error), while the OSGeo4W GDAL 3.13.0 works. Check which one you get with `ogr2ogr --version`.

```bash
git clone https://github.com/tomtom776/noaa-storms-pipeline.git
cd noaa-storms-pipeline
chmod +x pipeline.sh
./pipeline.sh
```

To run for a specific year:

```bash
./pipeline.sh 2023
```

Downloads and outputs are kept in `data/raw/` and `data/processed/` (not committed). Re-running skips files already downloaded and an output that already exists. Delete `data/processed/storms_{YEAR}.parquet` to rebuild it.

## What I learned

1) You cannot rely on previously assumed URL format. NOAA changed the way that they formatted the file directories of their detailed storm data. They also changed the downloaded file type, time increments of data, and data headers.
2) Claude is a great in-line tutor, helps with strategy before committing code, and can troubleshoot machine errors like unusable GDAL installs.
3) Test your assumptions against the data, not just the scaffold. The starter code assumed `BEGIN_LAT` / `BEGIN_LON` columns, but the current details files have no coordinates at all. Checking the real header is what led to joining on county and zone codes.
4) Read the documentation for the codes before using them. I assumed the county FIPS columns identified a county on every row. NOAA's documentation says `cz_type` marks county (`C`), zone (`Z`) or marine (`M`) rows, and zone numbers are NWS forecast zones, not counties. Using them as county codes would have placed 40% of events in the wrong place.
5) Validate a join before trusting it. Matching codes and names against Census and NWS reference data showed which rows could be located (about 97%) and which couldn't, and why.
6) A tool can be broken in your environment even when your script is right. The same GDAL version failed to write GeoParquet on one install and worked on another. Isolating the failure (tiny file, geometry vs. no geometry, other libraries) found that it wasn't the data or the script.
7) Pre-building small, stable reference data and committing it means the pipeline has less to download and less that can break.

## Stack

- bash
- curl
- GDAL / ogr2ogr (SQL join)
- GeoParquet
- Reference data: US Census county gazetteer, NWS forecast zone shapefiles
