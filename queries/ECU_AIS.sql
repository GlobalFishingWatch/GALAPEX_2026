
/*
Query to get a list of vessels with AIS gaps
in the 30 nm buffer around Galapagos Marine Reserve + Hermandad

option to filter by FVs in vessel list
*/


WITH

    aoi AS (
        SELECT
          geom as polygon
        FROM `world-fishing-827.scratch_joef.Combined_buffer_30nm_wkt`
        -- FROM `world-fishing-827.scratch_joef.GAL_EEZ_wkt`
    )
    ,

    ----------------------------------------------------------------------
    -- filter gaps that occurred in aoi by fvs identified in buffer
    ----------------------------------------------------------------------
    fv_gaps_aoi AS (
        SELECT
            ssvid,
            gap_id,
            gap_start,
            gap_end,
            round(gap_hours, 2) as gap_dur_h,
            round(gap_distance_m / 1000, 2) as gap_distance_km,
            round(gap_implied_speed_knots, 2) AS gap_speed_kts,
            round(gap_start_lat, 4) AS gap_start_lat,
            round(gap_start_lon, 4) AS gap_start_lon,
            round(gap_end_lat, 4) AS gap_end_lat,
            round(gap_end_lon, 4) AS gap_end_lon,
            gap_start_distance_from_shore_m,
            positions_12_hours_before,
            FORMAT_TIMESTAMP('%Y', gap_start) || '-Q' || CAST(DIV(EXTRACT(MONTH FROM gap_start) - 1, 3) + 1 AS STRING) AS year_quarter
        FROM `global-fishing-watch.pipe_ais_v3_published.product_events_ais_gaps`, aoi
        WHERE
            ST_CONTAINS(aoi.polygon, ST_GEOGPOINT(gap_start_lon, gap_start_lat))
            AND
            gap_start between '2023-07-01' AND '2025-07-01'
            -- AND
            -- gap_hours > 12
            AND
            positions_12_hours_before > 14
            AND
            gap_start_distance_from_shore_m > 10000
            AND
            ssvid IN (select CAST(MMSI AS STRING) AS MMSI from `world-fishing-827.scratch_joef.GAL_vessellist`)
    ),

    -- add categories/metrics for gap characteristics, filter as appropriate
    gap_metrics AS(
      SELECT * FROM(
      SELECT
      *,
      CASE
        WHEN gap_dur_h >= 3*24 THEN 3  -- > >3 days gets a 3
        WHEN gap_dur_h >= 12 THEN 2
        WHEN gap_dur_h >= 6 THEN 1
        ELSE 0
      END AS gap_time_indicator,
      -- CASE
      --   WHEN gap_speed_kts < 3 THEN 'Potential Loitering/Fishing'
      --   WHEN gap_speed_kts > 25 THEN 'Outlier: High Speed/Sensor Error'
      --   ELSE 'Likely Transit'
      -- END AS gap_classification,
      FROM fv_gaps_aoi)

      -- filter by time/speed
      WHERE
      (gap_dur_h > 12) -- AND gap_dur_h < 7*24)
      AND (gap_speed_kts > 0 AND gap_speed_kts <= 25)
    )

    SELECT
      ssvid,
      gap_id,
      'start' AS point_type,
      gap_start AS timestamp,
      year_quarter,
      gap_dur_h,
      -- gap_time_indicator,
      gap_distance_km,
      gap_speed_kts,
      -- gap_classification,
      gap_start_lat AS lat,
      gap_start_lon AS lon
    FROM gap_metrics
    UNION ALL
    SELECT
      ssvid,
      gap_id,
      'stop' AS point_type,
      gap_end AS timestamp,
      year_quarter,
      gap_dur_h,
      -- gap_time_indicator,
      gap_distance_km,
      gap_speed_kts,
      -- gap_classification,
      gap_end_lat AS lat,
      gap_end_lon AS lon
    FROM gap_metrics;
