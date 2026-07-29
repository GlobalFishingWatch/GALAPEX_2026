
/*
Query to get a list of vessels with AIS gaps
in the 30 nm buffer around Galapagos Marine Reserve + Hermandad

option to filter by FVs in vessel list
*/

## set time frame of interest
CREATE TEMP FUNCTION  start_date1() AS (TIMESTAMP({start_date1}));
CREATE TEMP FUNCTION  end_date1() AS (TIMESTAMP({end_date1}));
CREATE TEMP FUNCTION  start_date2() AS (TIMESTAMP({start_date2}));
CREATE TEMP FUNCTION  end_date2() AS (TIMESTAMP({end_date2}));
CREATE TEMP FUNCTION  start_date3() AS (TIMESTAMP({start_date3}));
CREATE TEMP FUNCTION  end_date3() AS (TIMESTAMP({end_date3}));
CREATE TEMP FUNCTION  start_date4() AS (TIMESTAMP({start_date4}));
CREATE TEMP FUNCTION  end_date4() AS (TIMESTAMP({end_date4}));

WITH

    aoi AS (
        SELECT ST_GEOGFROMTEXT('{wkt_string}') AS polygon
    )
    ,

    ----------------------------------------------------------------------
    -- filter gaps that occurred in aoi by fvs identified in buffer
    ----------------------------------------------------------------------
    ais_disabling AS (
        SELECT
            -- ssvid,
            vessel_id,
            event_id AS gap_id,
            event_start AS start_gap_timestamp,
            event_end AS end_gap_timestamp,
            ROUND(SAFE_CAST(JSON_EXTRACT_SCALAR(event_info, "$.gap_distance_km") AS FLOAT64), 2) as gap_distance_km,
            ROUND(SAFE_CAST(JSON_EXTRACT_SCALAR(event_info, "$.gap_hours") AS FLOAT64), 2) as gap_dur_h,
            ROUND(SAFE_CAST(JSON_EXTRACT_SCALAR(event_info, "$.gap_implied_speed_knots") AS FLOAT64), 2) as gap_speed_kts,
            ROUND(SAFE_CAST(JSON_EXTRACT_SCALAR(event_info, "$.gap_start_lat") AS FLOAT64), 4) as gap_start_lat,
            ROUND(SAFE_CAST(JSON_EXTRACT_SCALAR(event_info, "$.gap_start_lon") AS FLOAT64), 4) as gap_start_lon,
            ROUND(SAFE_CAST(JSON_EXTRACT_SCALAR(event_info, "$.gap_end_lat") AS FLOAT64), 4) as gap_end_lat,
            ROUND(SAFE_CAST(JSON_EXTRACT_SCALAR(event_info, "$.gap_end_lon") AS FLOAT64), 4) as gap_end_lon,
            CAST(FORMAT_TIMESTAMP('%Y', event_start) AS INT64) AS year
        FROM `global-fishing-watch.pipe_ais_v4_published.product_events_proto_ais_disabling`),

    disabling_filtered AS(
      SELECT * FROM ais_disabling, aoi
      WHERE
        ST_CONTAINS(aoi.polygon, ST_GEOGPOINT(gap_start_lon, gap_start_lat))
        AND
        (start_gap_timestamp between start_date1() AND end_date1() OR
        start_gap_timestamp between start_date2() AND end_date2() OR
        start_gap_timestamp between start_date3() AND end_date3() OR
        start_gap_timestamp between start_date4() AND end_date4() )
        AND
        -- filter by time/speed
        gap_speed_kts > 0 AND gap_speed_kts <= 25
    ),

    ----------------------------------------------------------------------
    -- join vessel identity info, filter for fishing/carrier vessels
    ----------------------------------------------------------------------
    add_id_info AS(
    -- SELECT * FROM(
      SELECT
        a.vessel_id,
        a.gap_id,
        a.start_gap_timestamp,
        a.end_gap_timestamp,
        a.gap_dur_h,
        a.gap_distance_km,
        a.gap_speed_kts,
        a.gap_start_lat,
        a.gap_start_lon,
        a.gap_end_lat,
        a.gap_end_lon,
        a.year,
        b.ais_shipname,
        b.gfw_best_flag,
        b.registry_flag,
        b.best_vessel_class,
        b.prod_shiptype,
        b.prod_geartype,
        b.registry_is_carrier,
        b.on_fishing_list_best,
        b.potential_fishing

      FROM disabling_filtered a
      LEFT OUTER JOIN
        (SELECT
          -- ssvid,
          vessel_id,
          year,
          ais_shipname,
          gfw_best_flag,
          registry_flag,
          best_vessel_class,
          prod_shiptype,
          prod_geartype,
          registry_is_carrier,
          registry_is_bunker,
          on_fishing_list_best,
          potential_fishing
        FROM `global-fishing-watch.pipe_ais_identity_v4_published.product_vessel_info_summary`) b
        USING (year, vessel_id)
        -- ORDER BY gap_indicator, ssvid, timestamp
        WHERE potential_fishing IS TRUE OR registry_is_carrier IS TRUE OR registry_is_bunker IS TRUE
        )

   SELECT
      vessel_id,
      ais_shipname,
      gfw_best_flag,
      prod_shiptype,
      prod_geartype,
      gap_id,
      'start' AS point_type,
      start_gap_timestamp AS timestamp,
      gap_dur_h,
      gap_distance_km,
      gap_speed_kts,
      gap_start_lat AS lat,
      gap_start_lon AS lon
    FROM add_id_info
    UNION ALL
    SELECT
      vessel_id,
      ais_shipname,
      gfw_best_flag,
      prod_shiptype,
      prod_geartype,
      gap_id,
      'stop' AS point_type,
      end_gap_timestamp AS timestamp,
      gap_dur_h,
      gap_distance_km,
      gap_speed_kts,
      gap_end_lat AS lat,
      gap_end_lon AS lon
    FROM add_id_info



