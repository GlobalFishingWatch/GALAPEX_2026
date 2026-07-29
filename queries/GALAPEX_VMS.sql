


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
-- filter vms positions that occurred in aoi and have specified gap duration
----------------------------------------------------------------------
vms AS(
 SELECT *
 FROM(
  SELECT
      msgid,
      ssvid,
      vessel_id,
      timestamp as start_gap_timestamp,
      LEAD(timestamp) OVER(PARTITION BY vessel_id ORDER BY timestamp) as end_gap_timestamp,
      TIMESTAMP_DIFF(
        LEAD(timestamp) OVER(PARTITION BY vessel_id ORDER BY timestamp), timestamp,
        SECOND
      ) / 3600 gap_dur_h,
      hours,
      LEAD(hours) OVER(PARTITION BY vessel_id ORDER BY timestamp) as end_hours,
      lat as start_gap_lat,
      lon as start_gap_lon,
      LEAD(lat) OVER(PARTITION BY vessel_id ORDER BY timestamp) as end_gap_lat,
      LEAD(lon) OVER(PARTITION BY vessel_id ORDER BY timestamp) as end_gap_lon,
      seg_id,
      distance_from_port_m / 1000 as start_gap_port_dist_km,
      distance_from_shore_m / 1000 as start_gap_shore_dist_km,
      LEAD(distance_from_port_m) OVER(PARTITION BY vessel_id ORDER BY timestamp) as end_gap_port_dist_m,
      LEAD(distance_from_shore_m) OVER(PARTITION BY vessel_id ORDER BY timestamp) as end_gap_shore_dist_m,
      CAST(FORMAT_TIMESTAMP('%Y', timestamp) AS INT64) AS year
    FROM `global-fishing-watch.pipe_vms_v4_published.messages`
    WHERE
    TIMESTAMP_TRUNC(timestamp, DAY) >= start_date1()  -- make this anytime from (earliest) starting date, then filter start gap to actual period of interest in next step
    ORDER BY ssvid, timestamp
 ), aoi
    WHERE
    start_gap_port_dist_km > 10
    AND start_gap_shore_dist_km > 5
    AND ST_CONTAINS(aoi.polygon, ST_GEOGPOINT(start_gap_lon, start_gap_lat))
    AND (
          (TIMESTAMP_TRUNC(start_gap_timestamp, DAY) BETWEEN start_date1() AND end_date1()) OR
          (TIMESTAMP_TRUNC(start_gap_timestamp, DAY) BETWEEN start_date2() AND end_date2()) OR
          (TIMESTAMP_TRUNC(start_gap_timestamp, DAY) BETWEEN start_date3() AND end_date3()) OR
          (TIMESTAMP_TRUNC(start_gap_timestamp, DAY) BETWEEN start_date4() AND end_date4()) )
),

----------------------------------------------------------------------
-- add list of days pre-5/1/2025 where appears no VMS outage
----------------------------------------------------------------------
non_outage_dates AS (
  SELECT  exception_date
  FROM UNNEST(
    ARRAY_CONCAT(
      -- 2023: July except 7/9
      GENERATE_DATE_ARRAY('2023-07-01', '2023-07-08'),
      GENERATE_DATE_ARRAY('2023-07-10', '2023-07-31'),
      GENERATE_DATE_ARRAY('2023-08-17', '2023-08-19'),
      [DATE '2023-10-07', DATE '2023-10-17', DATE '2023-11-26'],
      -- 2024:
      GENERATE_DATE_ARRAY('2024-01-10', '2024-01-15'),
      GENERATE_DATE_ARRAY('2024-03-28', '2024-03-30'),
      [DATE '2024-05-23'],
      GENERATE_DATE_ARRAY('2024-06-18', '2024-06-20'),
      GENERATE_DATE_ARRAY('2024-08-04', '2024-08-10'),
      GENERATE_DATE_ARRAY('2024-08-15', '2024-08-16'),
      [DATE '2024-09-17', DATE '2024-09-27', DATE '2024-09-28', DATE '2024-10-18', DATE '2024-10-19',
       DATE '2024-11-29', DATE '2024-12-03', DATE '2024-12-05'],
      -- 2025:
      [DATE '2025-01-31', DATE '2025-02-03', DATE '2025-02-24', DATE '2025-02-25'],
      [DATE '2025-03-03', DATE '2025-03-11', DATE '2025-03-22', DATE '2025-03-26'],
      GENERATE_DATE_ARRAY('2025-04-04', '2025-04-06'),
      GENERATE_DATE_ARRAY('2025-04-13', '2025-04-15')
    )) AS exception_date
),

----------------------------------------------------------------------
-- join vessel identity info and add gap rating
----------------------------------------------------------------------
add_id_info AS(
SELECT * FROM(
  SELECT
    msgid,
    vessel_id,
    ssvid,
    shipname,
    mmsi_flag,
    gfw_best_flag,
    core_geartype,
    prod_shiptype,
    prod_geartype,
    registry_number,
    source_tenant,
    source_fleet,
    start_gap_timestamp,
    end_gap_timestamp,
    gap_dur_h,
    start_gap_lat,
    start_gap_lon,
    end_gap_lat,
    end_gap_lon,
    start_gap_port_dist_km,
    start_gap_shore_dist_km,
    -- `source`,
    year,

    CASE
   -- Set gap parameters for each country
   WHEN (source_tenant IN ("PER") OR source_tenant IN ("PAN"))
      THEN
      CASE
        WHEN gap_dur_h > 3*24 THEN 3
        WHEN gap_dur_h > 8 THEN 2
        WHEN gap_dur_h > 1.1 THEN 1
        ELSE 0
      END
   WHEN source_tenant IN ("CRI")
      THEN
      CASE
        WHEN gap_dur_h > 3*24 THEN 3
        WHEN gap_dur_h > 8 THEN 2
        WHEN gap_dur_h > 2.1 THEN 1
        ELSE 0
      END
    -- ECUADOR
    -- After 5/1/25 flag any gap > 8 or 3h (or on exception dates)
    WHEN (source_tenant IN ("ECU")
          AND
          (DATE(start_gap_timestamp) >= '2025-05-01'
          OR DATE(start_gap_timestamp) IN (SELECT exception_date FROM non_outage_dates))
          )
      THEN
      CASE
        WHEN gap_dur_h > 3*24 THEN 3  -- >3 days gets a 3
        WHEN gap_dur_h > 8 THEN 2
        WHEN gap_dur_h > 3.1 THEN 1
        ELSE 0
      END

    -- Before 5/1/25 in ECU need to control for daily 5h gap from ~19:00 - 00:00 (except certain dates)
    WHEN (source_tenant IN ("ECU")
          AND DATE(start_gap_timestamp) < '2025-05-01'
          AND DATE(start_gap_timestamp) NOT IN (SELECT exception_date FROM non_outage_dates))
    THEN
      CASE
        -- Same-day gap: no outage overlap possible
        WHEN DATE(end_gap_timestamp) = DATE(start_gap_timestamp)
          AND gap_dur_h >= 8 THEN 2
        WHEN DATE(end_gap_timestamp) = DATE(start_gap_timestamp)
          AND gap_dur_h >= 3 THEN 1

        -- Multi-day, straddles outage window: subtract 5h outage
        WHEN DATE(end_gap_timestamp) > DATE(start_gap_timestamp)
          AND gap_dur_h >= 3*24 THEN 3  -- > 3 days gets a 3
        WHEN DATE(end_gap_timestamp) > DATE(start_gap_timestamp)
          AND gap_dur_h >= 13 THEN 2  -- >8h confirmed after subtracting 5h outage
        WHEN DATE(end_gap_timestamp) > DATE(start_gap_timestamp)
          AND gap_dur_h >= 8 THEN 1   -- >3h confirmed after subtracting 5h outage

        -- Multi-day, straddles outage window: ambiguous
        WHEN DATE(end_gap_timestamp) > DATE(start_gap_timestamp)
          AND TIME(start_gap_timestamp) BETWEEN TIME(16,0,0) AND TIME(23,59,59)
          AND TIME(end_gap_timestamp) BETWEEN TIME(0,0,0) AND TIME(3,0,0)
          AND gap_dur_h BETWEEN 3 AND 8 THEN 0

        ELSE 0
        END

    -- Gap <= 3h regardless of date: discard
      ELSE 0
      END AS gap_time_indicator

  FROM vms a
  LEFT OUTER JOIN
    (SELECT
      ssvid,
      year,
      shipname,
      mmsi_flag,
      gfw_best_flag,
      core_geartype,
      prod_shiptype,
      prod_geartype,
      source_tenant,
      registry_number,
      length,
      source_fleet
    FROM `global-fishing-watch.pipe_vms_v4_published.product_vessel_info_summary`) b
    USING (year, ssvid)
    -- ORDER BY gap_indicator, ssvid, timestamp
    WHERE prod_shiptype IN ('FISHING')
    )
),

----------------------------------------------------------------------
-- calculate gap avg speed
----------------------------------------------------------------------
gap_metrics AS (
  SELECT
    *,
    -- 1. Calculate distance in meters between gaps
    ST_DISTANCE(
      ST_GEOGPOINT(start_gap_lon, start_gap_lat),
      ST_GEOGPOINT(end_gap_lon, end_gap_lat)
    ) AS gap_distance_m,

  FROM add_id_info
),

speed_calc AS (
  SELECT
    *,
    -- 2. Calculate apparent/average speed in knots (1 m/s = 1.94384 knots)
    CASE
      WHEN gap_dur_h > 0
      THEN (gap_distance_m / (gap_dur_h * 3600)) * 1.94384
      ELSE 0
    END AS gap_speed_kts
  FROM gap_metrics
),

gap_speed_logic AS(
  SELECT
    msgid,
    vessel_id,
    ssvid,
    shipname,
    registry_number,
    source_tenant,
    gfw_best_flag,
    source_fleet,
    prod_shiptype,
    prod_geartype,
    start_gap_timestamp,
    end_gap_timestamp,
    round(gap_dur_h,2) as gap_dur_h,
    round(gap_distance_m / 1000, 2) as gap_distance_km,
    gap_time_indicator,
    round(gap_speed_kts, 2) as gap_speed_kts,
    -- 4. Flagging logic (using 3 knots as a suspicious threshold)
    -- CASE
    --   WHEN gap_speed_kts < 3 THEN 'Potential Loitering/Fishing'
    --   WHEN gap_speed_kts > 25 THEN 'Outlier: High Speed/Sensor Error'
    --   ELSE 'Likely Transit'
    -- END AS gap_classification,
    round(start_gap_lat, 4) as start_gap_lat,
    round(start_gap_lon, 4) as start_gap_lon,
    round(end_gap_lat, 4) as end_gap_lat,
    round(end_gap_lon, 4) as end_gap_lon,
    start_gap_port_dist_km,
    start_gap_shore_dist_km,
  FROM speed_calc
--- filter for non-ambiguous, >3 or >8h gaps that are not 0km or speed outliers (and < 3 days)
  WHERE
    gap_time_indicator >= 1
    AND (gap_speed_kts > 0 AND gap_speed_kts <= 25)
)

----------------------------------------------------------------------
-- split start and end rows
----------------------------------------------------------------------

   SELECT DISTINCT
      msgid,
      -- vessel_id,
      ssvid,
      shipname,
      registry_number,
      source_tenant,
      -- gfw_best_flag,
      source_fleet,
      prod_shiptype,
      prod_geartype,
      'start' AS point_type,
      start_gap_timestamp AS timestamp,
      gap_dur_h,
      -- gap_time_indicator,
      gap_distance_km,
      gap_speed_kts,
      -- gap_classification,
      start_gap_lat AS lat,
      start_gap_lon AS lon
    FROM gap_speed_logic
    UNION ALL
    SELECT DISTINCT
      msgid,
      -- vessel_id,
      ssvid,
      shipname,
      registry_number,
      source_tenant,
      -- gfw_best_flag,
      source_fleet,
      prod_shiptype,
      prod_geartype,
      'end' AS point_type,
      end_gap_timestamp AS timestamp,
      gap_dur_h,
      -- gap_time_indicator,
      gap_distance_km,
      gap_speed_kts,
      -- gap_classification,
      end_gap_lat AS lat,
      end_gap_lon AS lon
    FROM gap_speed_logic
    ORDER by msgid, point_type DESC

