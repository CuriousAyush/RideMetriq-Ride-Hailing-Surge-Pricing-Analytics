CREATE TABLE stg_rides_raw (
    ride_id              TEXT,
    city                 TEXT,
    zone_id              TEXT,
    zone_name            TEXT,
    zone_type            TEXT,
    request_timestamp    TEXT,
    vehicle_type         TEXT,
    distance_km          TEXT,
    duration_min         TEXT,
    drivers_online_zone  TEXT,
    open_requests_zone   TEXT,
    dsr                  TEXT,
    surge_multiplier     TEXT,
    base_fare            TEXT,
    final_fare           TEXT,
    driver_eta_min       TEXT,
    weather_flag         TEXT,
    event_flag           TEXT,
    ride_status          TEXT,
    cancel_reason        TEXT,
    rider_id             TEXT,
    driver_id            TEXT,
    payment_mode         TEXT
);

CREATE TABLE zones_dim (
    zone_id     TEXT PRIMARY KEY,
    zone_name   TEXT,
    city        TEXT,
    zone_type   TEXT
);

CREATE TABLE driver_supply_snapshot (
    zone_id           TEXT,
    snapshot_time     TIMESTAMP,
    drivers_online    INT,
    drivers_on_trip   INT,
    drivers_idle      INT
);

--Step 5: Profile the raw data (this is "data understanding" in SQL form)
-- 5a. Row count and a quick look
SELECT COUNT(*) FROM stg_rides_raw;
SELECT * FROM stg_rides_raw LIMIT 10;
-- 5b. Null counts per column that we know has gaps
SELECT
    COUNT(*) FILTER (WHERE distance_km IS NULL OR distance_km = '')      AS null_distance,
    COUNT(*) FILTER (WHERE driver_eta_min IS NULL OR driver_eta_min = '') AS null_eta,
    COUNT(*) FILTER (WHERE weather_flag IS NULL OR weather_flag = '')     AS null_weather,
    COUNT(*) FILTER (WHERE payment_mode IS NULL OR payment_mode = '')     AS null_payment,
    COUNT(*) FILTER (WHERE vehicle_type IS NULL OR vehicle_type = '')     AS null_vehicle
FROM stg_rides_raw;
--5c. Duplicate rows
SELECT ride_id, COUNT(*) 
FROM stg_rides_raw
GROUP BY ride_id
HAVING COUNT(*) > 1;
-- 5d. What invalid values actually look like in the messy columns
SELECT DISTINCT surge_multiplier
FROM stg_rides_raw
WHERE surge_multiplier !~ '^\d+(\.\d+)?$'
LIMIT 20;
--5e. Outlier check
SELECT MIN(distance_km::NUMERIC), MAX(distance_km::NUMERIC)
FROM stg_rides_raw
WHERE distance_km ~ '^\d+(\.\d+)?$';

--Step 6: Cleaning queries — building the real rides_fact table
--6a. Create the final clean table structure
CREATE TABLE rides_fact (
    ride_id              TEXT PRIMARY KEY,
    city                 TEXT,
    zone_id              TEXT,
    zone_name            TEXT,
    zone_type            TEXT,
    request_timestamp    TIMESTAMP,
    vehicle_type         TEXT,
    distance_km          NUMERIC,
    duration_min         NUMERIC,
    drivers_online_zone  INT,
    open_requests_zone   INT,
    dsr                  NUMERIC,
    surge_multiplier     NUMERIC,
    base_fare            NUMERIC,
    final_fare           NUMERIC,
    driver_eta_min       NUMERIC,
    weather_flag         TEXT,
    event_flag           TEXT,
    ride_status          TEXT,
    cancel_reason        TEXT,
    rider_id             TEXT,
    driver_id            TEXT,
    payment_mode         TEXT
);
--6b. The cleaning + insert query
INSERT INTO rides_fact
SELECT DISTINCT ON (ride_id)
    ride_id,
    city,
    zone_id,
    zone_name,
    zone_type,
    CASE WHEN request_timestamp ~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
     THEN request_timestamp::TIMESTAMP END,
    vehicle_type,
    CASE WHEN distance_km ~ '^\d+(\.\d+)?$' AND distance_km::NUMERIC BETWEEN 0.1 AND 60
         THEN distance_km::NUMERIC END,
    duration_min::NUMERIC,
    CASE WHEN drivers_online_zone ~ '^\d+$' THEN drivers_online_zone::INT END,
    open_requests_zone::INT,
    dsr::NUMERIC,
    CASE WHEN surge_multiplier ~ '^\d+(\.\d+)?$' THEN surge_multiplier::NUMERIC END,
    base_fare::NUMERIC,
    CASE WHEN final_fare ~ '^\d+(\.\d+)?$' AND final_fare::NUMERIC BETWEEN 10 AND 3000
         THEN final_fare::NUMERIC END,
    CASE WHEN driver_eta_min ~ '^\d+(\.\d+)?$' AND driver_eta_min::NUMERIC >= 0
         THEN driver_eta_min::NUMERIC END,
    weather_flag,
    event_flag,
    ride_status,
    cancel_reason,
    rider_id,
    driver_id,
    payment_mode
FROM stg_rides_raw
WHERE ride_id IS NOT NULL
ORDER BY ride_id;

SELECT DISTINCT request_timestamp 
FROM stg_rides_raw 
WHERE request_timestamp !~ '^\d{4}-\d{2}-\d{2}';

SELECT COUNT(*) FROM rides_fact;

--Quick post-clean sanity check
SELECT
    COUNT(*) AS total_rows,
    COUNT(*) FILTER (WHERE distance_km IS NULL)      AS null_distance,
    COUNT(*) FILTER (WHERE final_fare IS NULL)        AS null_fare,
    COUNT(*) FILTER (WHERE surge_multiplier IS NULL)  AS null_surge,
    COUNT(*) FILTER (WHERE driver_eta_min IS NULL)    AS null_eta,
    COUNT(*) FILTER (WHERE request_timestamp IS NULL) AS null_timestamp
FROM rides_fact;

--Step 7: Deciding what to do with these remaining nulls
-- we have null in distance_km and driver_eta_min -- this will be replaced by median 
-- we have final_fare & surge_multiplier & request_timestamp -- we will drop this rows because this are core dependent metric for our op insight ,it can change that 

--Step 7 query — apply this logic
-- Impute distance_km using median per zone_type
UPDATE rides_fact r
SET distance_km = sub.med_distance
FROM (
    SELECT zone_type, PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY distance_km) AS med_distance
    FROM rides_fact
    WHERE distance_km IS NOT NULL
    GROUP BY zone_type
) sub
WHERE r.zone_type = sub.zone_type AND r.distance_km IS NULL;

-- Impute driver_eta_min using median per zone_type
UPDATE rides_fact r
SET driver_eta_min = sub.med_eta
FROM (
    SELECT zone_type, PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY driver_eta_min) AS med_eta
    FROM rides_fact
    WHERE driver_eta_min IS NOT NULL
    GROUP BY zone_type
) sub
WHERE r.zone_type = sub.zone_type AND r.driver_eta_min IS NULL;

-- Drop rows where core metrics are unusable
DELETE FROM rides_fact
WHERE final_fare IS NULL 
   OR surge_multiplier IS NULL 
   OR request_timestamp IS NULL;

SELECT COUNT(*) FROM rides_fact;


-----------------------------------------------------------------------------------------------------------------------------
--Step 8: Analysis queries — the actual insights for your dashboard
--8a. Average surge multiplier and revenue by zone type — the headline finding
SELECT
    zone_type,
    ROUND(AVG(surge_multiplier), 2) AS avg_surge,
    ROUND(AVG(final_fare), 0) AS avg_fare,
    COUNT(*) AS total_rides
FROM rides_fact
GROUP BY zone_type
ORDER BY avg_surge DESC;

--8b. Surge multiplier by hour of day (for the heatmap/line chart)
SELECT
    EXTRACT(HOUR FROM request_timestamp) AS hour_of_day,
    zone_type,
    ROUND(AVG(surge_multiplier), 2) AS avg_surge
FROM rides_fact
GROUP BY hour_of_day, zone_type
ORDER BY zone_type, hour_of_day;

--8c. Weekday vs weekend DSR trend
SELECT
    EXTRACT(HOUR FROM request_timestamp) AS hour_of_day,
    CASE WHEN EXTRACT(DOW FROM request_timestamp) IN (0,6) THEN 'Weekend' ELSE 'Weekday' END AS day_type,
    ROUND(AVG(dsr), 2) AS avg_dsr
FROM rides_fact
GROUP BY hour_of_day, day_type
ORDER BY day_type, hour_of_day;
--8d.Avg surge multiplier by city 
--Gives a geographic comparison across your 6 cities — a natural 4th tile next to the zone/hour breakdown.
SELECT
    city,
    ROUND(AVG(surge_multiplier), 2) AS avg_surge,
    COUNT(*) AS total_rides
FROM rides_fact
GROUP BY city
ORDER BY avg_surge DESC;

--Step 8 continued — Page 2: Revenue & rider impact
--8e. Cancellation rate by surge multiplier band — the "churn cliff"
SELECT
    CASE
        WHEN surge_multiplier < 1.1 THEN '1.0x'
        WHEN surge_multiplier < 1.3 THEN '1.1-1.3x'
        WHEN surge_multiplier < 1.5 THEN '1.3-1.5x'
        WHEN surge_multiplier < 1.8 THEN '1.5-1.8x'
        ELSE '1.8x+'
    END AS surge_band,
    COUNT(*) AS total_rides,
    ROUND(100.0 * COUNT(*) FILTER (WHERE ride_status != 'Completed') / COUNT(*), 1) AS cancel_rate_pct
FROM rides_fact
GROUP BY surge_band
ORDER BY MIN(surge_multiplier);

--8f. Revenue lift — actual surge revenue vs a flat-fare counterfactual
SELECT
    zone_type,
    ROUND(SUM(final_fare), 0) AS actual_revenue,
    ROUND(SUM(final_fare / surge_multiplier), 0) AS flat_fare_revenue,
    ROUND(100.0 * (SUM(final_fare) - SUM(final_fare / surge_multiplier)) / SUM(final_fare / surge_multiplier), 1) AS pct_lift
FROM rides_fact
WHERE ride_status = 'Completed'
GROUP BY zone_type
ORDER BY pct_lift DESC;
--8g. Repeat-cancellation riders — the churn-risk cohort
SELECT
    rider_id,
    COUNT(*) FILTER (WHERE ride_status = 'Cancelled_By_Rider' AND cancel_reason = 'High_Surge_Fare') AS surge_cancels
FROM rides_fact
GROUP BY rider_id
HAVING COUNT(*) FILTER (WHERE ride_status = 'Cancelled_By_Rider' AND cancel_reason = 'High_Surge_Fare') >= 2
ORDER BY surge_cancels DESC;

--Run this to get the actual total count and business-relevant summary stats:
SELECT
    COUNT(*) AS at_risk_riders,
    ROUND(100.0 * COUNT(*) / (SELECT COUNT(DISTINCT rider_id) FROM rides_fact), 2) AS pct_of_all_riders
FROM (
    SELECT rider_id
    FROM rides_fact
    WHERE ride_status = 'Cancelled_By_Rider' AND cancel_reason = 'High_Surge_Fare'
    GROUP BY rider_id
    HAVING COUNT(*) >= 2
) sub;

--8h. Cancellation reason breakdown
SELECT
    cancel_reason,
    COUNT(*) AS total_cancellations
FROM rides_fact
WHERE ride_status IN ('Cancelled_By_Rider', 'No_Driver_Found')
GROUP BY cancel_reason
ORDER BY total_cancellations DESC;
--Step 8 — Page 3: 
--Driver supply response (final set of queries)
--8i. Does driver supply actually respond to surge? (zone-level correlation)
SELECT
    r.zone_type,
    ROUND(AVG(r.surge_multiplier), 2) AS avg_surge,
    ROUND(AVG(s.drivers_online), 0) AS avg_drivers_online
FROM rides_fact r
JOIN driver_supply_snapshot s
    ON r.zone_id = s.zone_id
    AND DATE_TRUNC('hour', r.request_timestamp) = DATE_TRUNC('hour', s.snapshot_time)
GROUP BY r.zone_type
ORDER BY avg_surge DESC;

--8j. Final recommendation table — the "what should we cap" output
SELECT
    zone_type,
    ROUND(AVG(surge_multiplier), 2) AS current_avg_surge,
    ROUND(100.0 * COUNT(*) FILTER (WHERE ride_status != 'Completed') / COUNT(*), 1) AS cancel_rate_pct,
    ROUND(SUM(final_fare) - SUM(final_fare / surge_multiplier), 0) AS revenue_from_surge
FROM rides_fact
WHERE ride_status = 'Completed' OR ride_status IS NOT NULL
GROUP BY zone_type
ORDER BY cancel_rate_pct DESC;

--8k. Current surge vs recommended cap, by zone type
SELECT
    zone_type,
    ROUND(AVG(surge_multiplier), 2) AS current_avg_surge
FROM rides_fact
GROUP BY zone_type
ORDER BY current_avg_surge DESC;