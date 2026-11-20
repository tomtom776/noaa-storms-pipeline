# Reference data for locating Storm Events

The NOAA Storm Events *details* files contain no coordinates. `pipeline.sh` locates
each event by joining it to these two GeoParquet files (points, WGS 84 / EPSG:4326).
They are built once and committed so the pipeline needs no extra downloads.

## census_counties_2024.parquet  (3,222 rows)
- Source: US Census 2024 Gazetteer, counties
  https://www2.census.gov/geo/docs/maps-data/data/gazetteer/2024_Gaz_counties_national.zip
- Geometry: Census "internal point" of each county (INTPTLAT / INTPTLONG).
- Join key: `state_fips` (int) + `county_fips` (3-char text), matched to the storm
  file's `state_fips` + `cz_fips` when `cz_type = 'C'`.

## nws_zones.parquet  (4,721 rows)
- Source: NWS GIS shapefiles, release 16 Apr 2026 (https://www.weather.gov/gis/PublicZones,
  https://www.weather.gov/gis/MarineZones):
  `z_16ap26` (public forecast zones), `mz16ap26` (marine zones), `oz16ap26` (offshore zones).
- Geometry: the zone point given in the shapefile's LAT / LON fields.
- `zone_type`: public | marine | offshore.
- Join key: `state_fips` (int, NOAA's code, see below) + `zone` (3-char text), matched to
  `state_fips` + `cz_fips` when `cz_type` is not 'C'.
- Zones split into several polygons appear once; the northernmost part's point is kept.

### NOAA state_fips codes
Census and NOAA agree for the 50 states + DC. NOAA uses its own codes for territories
and water areas, which were folded into `state_fips` when these files were built:
PR 99, VI 96, GU 98, AS 97; marine prefixes GM 85, AN 88, AM 87, PZ 86, PK 89,
PM 83, LC 81, LH 90, LM 91, LS 92, SL 93, LO 94, LE 95.

### Known gaps (events get a NULL geometry)
- County rows in Puerto Rico, Alaska (changed boroughs), Connecticut (old counties),
  Guam, Virgin Islands, American Samoa: NOAA codes differ from Census GEOIDs.
- Zones in FM, MH, PW, MP, Hawaii/American Samoa waters (no NOAA state code known), and
  zones renumbered since 2024 (reference is the April 2026 release).
