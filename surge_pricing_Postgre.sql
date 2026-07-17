
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
    final_fare            TEXT,
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

-- =============================================================================
-- STEP 5: PROFILE THE RAW DATA
-- =============================================================================
SELECT COUNT(*) FROM stg_rides_raw;
SELECT * FROM stg_rides_raw LIMIT 10;

SELECT
    COUNT(*) FILTER (WHERE distance_km IS NULL OR distance_km = '')       AS null_distance,
    COUNT(*) FILTER (WHERE driver_eta_min IS NULL OR driver_eta_min = '') AS null_eta,
    COUNT(*) FILTER (WHERE weather_flag IS NULL OR weather_flag = '')     AS null_weather,
    COUNT(*) FILTER (WHERE payment_mode IS NULL OR payment_mode = '')     AS null_payment,
    COUNT(*) FILTER (WHERE vehicle_type IS NULL OR vehicle_type = '')     AS null_vehicle
FROM stg_rides_raw;

SELECT ride_id, COUNT(*)
FROM stg_rides_raw
GROUP BY ride_id
HAVING COUNT(*) > 1;

SELECT DISTINCT surge_multiplier
FROM stg_rides_raw
WHERE surge_multiplier !~ '^\d+(\.\d+)?$'
LIMIT 20;

SELECT MIN(distance_km::NUMERIC), MAX(distance_km::NUMERIC)
FROM stg_rides_raw
WHERE distance_km ~ '^\d+(\.\d+)?$';

-- =============================================================================
-- STEP 6: BUILD THE CLEAN rides_fact TABLE
-- =============================================================================

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

-- 6b. CLEANING + INSERT — FORMAT VALIDATION ONLY (no range filtering here).
-- Range/outlier filtering now happens separately in Step 6c using IQR bounds,
-- so genuine outlier values (e.g. 400-900km trips, Rs.35k-90k fares) are
-- inserted as real numbers first, then statistically detected and nulled.
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
    CASE WHEN distance_km ~ '^\d+(\.\d+)?$' AND distance_km::NUMERIC > 0
         THEN distance_km::NUMERIC END,
    duration_min::NUMERIC,
    CASE WHEN drivers_online_zone ~ '^\d+$' THEN drivers_online_zone::INT END,
    open_requests_zone::INT,
    dsr::NUMERIC,
    CASE WHEN surge_multiplier ~ '^\d+(\.\d+)?$' THEN surge_multiplier::NUMERIC END,
    base_fare::NUMERIC,
    CASE WHEN final_fare ~ '^\d+(\.\d+)?$' THEN final_fare::NUMERIC END,
    CASE WHEN driver_eta_min ~ '^\d+(\.\d+)?$' THEN driver_eta_min::NUMERIC END,
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

SELECT COUNT(*) FROM rides_fact;

-- =============================================================================
-- STEP 6c: IQR-BASED OUTLIER DETECTION (CTE + window/ordered-set functions)
-- Applied to: distance_km, final_fare, driver_eta_min
-- Method: Q1 = 25th percentile, Q3 = 75th percentile, IQR = Q3 - Q1.
-- Any value below (Q1 - 1.5*IQR) or above (Q3 + 1.5*IQR) is a statistical
-- outlier — this 1.5x multiplier is the standard convention (same rule
-- used to draw the "whiskers" on a box plot).
-- =============================================================================

-- --- distance_km ---
WITH bounds AS (
    SELECT
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY distance_km) AS q1,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY distance_km) AS q3
    FROM rides_fact
    WHERE distance_km IS NOT NULL
)
SELECT q1, q3, (q3 - q1) AS iqr,
       q1 - 1.5 * (q3 - q1) AS lower_bound,
       q3 + 1.5 * (q3 - q1) AS upper_bound
FROM bounds;
-- Inspect the printed lower_bound / upper_bound above, then apply the UPDATE:

WITH bounds AS (
    SELECT
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY distance_km) AS q1,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY distance_km) AS q3
    FROM rides_fact
    WHERE distance_km IS NOT NULL
)
UPDATE rides_fact r
SET distance_km = NULL
FROM bounds b
WHERE r.distance_km < (b.q1 - 1.5 * (b.q3 - b.q1))
   OR r.distance_km > (b.q3 + 1.5 * (b.q3 - b.q1));

-- --- final_fare ---
WITH bounds AS (
    SELECT
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY final_fare) AS q1,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY final_fare) AS q3
    FROM rides_fact
    WHERE final_fare IS NOT NULL
)
SELECT q1, q3, (q3 - q1) AS iqr,
       q1 - 1.5 * (q3 - q1) AS lower_bound,
       q3 + 1.5 * (q3 - q1) AS upper_bound
FROM bounds;

WITH bounds AS (
    SELECT
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY final_fare) AS q1,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY final_fare) AS q3
    FROM rides_fact
    WHERE final_fare IS NOT NULL
)
UPDATE rides_fact r
SET final_fare = NULL
FROM bounds b
WHERE r.final_fare < (b.q1 - 1.5 * (b.q3 - b.q1))
   OR r.final_fare > (b.q3 + 1.5 * (b.q3 - b.q1));

-- --- driver_eta_min ---
-- Also enforce a hard logical floor: ETA can never be negative, regardless
-- of what the statistical bound says (a real-world constraint, not derived
-- from the distribution).
WITH bounds AS (
    SELECT
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY driver_eta_min) AS q1,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY driver_eta_min) AS q3
    FROM rides_fact
    WHERE driver_eta_min IS NOT NULL
)
SELECT q1, q3, (q3 - q1) AS iqr,
       GREATEST(0, q1 - 1.5 * (q3 - q1)) AS lower_bound,
       q3 + 1.5 * (q3 - q1) AS upper_bound
FROM bounds;

WITH bounds AS (
    SELECT
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY driver_eta_min) AS q1,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY driver_eta_min) AS q3
    FROM rides_fact
    WHERE driver_eta_min IS NOT NULL
)
UPDATE rides_fact r
SET driver_eta_min = NULL
FROM bounds b
WHERE r.driver_eta_min < 0
   OR r.driver_eta_min < (b.q1 - 1.5 * (b.q3 - b.q1))
   OR r.driver_eta_min > (b.q3 + 1.5 * (b.q3 - b.q1));

-- =============================================================================
-- STEP 6d: Zero-distance sensor-fault check (kept separate from IQR, since a
-- value of exactly 0 is a logical impossibility, not a statistical outlier —
-- every real ride covers some distance).
-- =============================================================================
UPDATE rides_fact
SET distance_km = NULL
WHERE distance_km = 0;

SELECT COUNT(*) FROM rides_fact;

-- Post-outlier-removal sanity check
SELECT
    COUNT(*) AS total_rows,
    COUNT(*) FILTER (WHERE distance_km IS NULL)      AS null_distance,
    COUNT(*) FILTER (WHERE final_fare IS NULL)        AS null_fare,
    COUNT(*) FILTER (WHERE surge_multiplier IS NULL)  AS null_surge,
    COUNT(*) FILTER (WHERE driver_eta_min IS NULL)    AS null_eta,
    COUNT(*) FILTER (WHERE request_timestamp IS NULL) AS null_timestamp
FROM rides_fact;

-- =============================================================================
-- STEP 7: HANDLE REMAINING NULLS (from both missing data AND nulled outliers)
--   - distance_km, driver_eta_min  -> impute with zone_type median (recoverable)
--   - final_fare, surge_multiplier, request_timestamp -> drop row (core metrics,
--     not safely imputable — imputing would fabricate the exact thing we're
--     trying to measure)
-- =============================================================================

UPDATE rides_fact r
SET distance_km = sub.med_distance
FROM (
    SELECT zone_type, PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY distance_km) AS med_distance
    FROM rides_fact
    WHERE distance_km IS NOT NULL
    GROUP BY zone_type
) sub
WHERE r.zone_type = sub.zone_type AND r.distance_km IS NULL;

UPDATE rides_fact r
SET driver_eta_min = sub.med_eta
FROM (
    SELECT zone_type, PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY driver_eta_min) AS med_eta
    FROM rides_fact
    WHERE driver_eta_min IS NOT NULL
    GROUP BY zone_type
) sub
WHERE r.zone_type = sub.zone_type AND r.driver_eta_min IS NULL;

DELETE FROM rides_fact
WHERE final_fare IS NULL
   OR surge_multiplier IS NULL
   OR request_timestamp IS NULL;

SELECT COUNT(*) FROM rides_fact;

-- =============================================================================
-- STEP 8: ANALYSIS QUERIES
-- =============================================================================

-- 8a. Average surge multiplier and revenue by zone type
SELECT
    zone_type,
    ROUND(AVG(surge_multiplier), 2) AS avg_surge,
    ROUND(AVG(final_fare), 0) AS avg_fare,
    COUNT(*) AS total_rides
FROM rides_fact
GROUP BY zone_type
ORDER BY avg_surge DESC;

-- 8b. Surge multiplier by hour of day
SELECT
    EXTRACT(HOUR FROM request_timestamp) AS hour_of_day,
    zone_type,
    ROUND(AVG(surge_multiplier), 2) AS avg_surge
FROM rides_fact
GROUP BY hour_of_day, zone_type
ORDER BY zone_type, hour_of_day;

-- 8c. Weekday vs weekend DSR trend
SELECT
    EXTRACT(HOUR FROM request_timestamp) AS hour_of_day,
    CASE WHEN EXTRACT(DOW FROM request_timestamp) IN (0,6) THEN 'Weekend' ELSE 'Weekday' END AS day_type,
    ROUND(AVG(dsr), 2) AS avg_dsr
FROM rides_fact
GROUP BY hour_of_day, day_type
ORDER BY day_type, hour_of_day;

-- 8d. Avg surge multiplier by city
SELECT
    city,
    ROUND(AVG(surge_multiplier), 2) AS avg_surge,
    COUNT(*) AS total_rides
FROM rides_fact
GROUP BY city
ORDER BY avg_surge DESC;

-- 8e. Cancellation rate by surge band — CTE VERSION
-- The CASE-based banding logic is computed once in the CTE (banded_rides),
-- then the outer query just aggregates it. Cleaner and reusable versus
-- repeating the CASE block in every downstream query that needs the band.
WITH banded_rides AS (
    SELECT
        CASE
            WHEN surge_multiplier < 1.1 THEN '1.0x'
            WHEN surge_multiplier < 1.3 THEN '1.1-1.3x'
            WHEN surge_multiplier < 1.5 THEN '1.3-1.5x'
            WHEN surge_multiplier < 1.8 THEN '1.5-1.8x'
            ELSE '1.8x+'
        END AS surge_band,
        ride_status,
        surge_multiplier
    FROM rides_fact
)
SELECT
    surge_band,
    COUNT(*) AS total_rides,
    ROUND(100.0 * COUNT(*) FILTER (WHERE ride_status != 'Completed') / COUNT(*), 1) AS cancel_rate_pct
FROM banded_rides
GROUP BY surge_band
ORDER BY MIN(surge_multiplier);

-- 8f. Revenue lift — actual vs flat-fare counterfactual
SELECT
    zone_type,
    ROUND(SUM(final_fare), 0) AS actual_revenue,
    ROUND(SUM(final_fare / surge_multiplier), 0) AS flat_fare_revenue,
    ROUND(100.0 * (SUM(final_fare) - SUM(final_fare / surge_multiplier)) / SUM(final_fare / surge_multiplier), 1) AS pct_lift
FROM rides_fact
WHERE ride_status = 'Completed'
GROUP BY zone_type
ORDER BY pct_lift DESC;

-- 8g. Repeat-cancellation riders — churn-risk cohort
SELECT
    rider_id,
    COUNT(*) FILTER (WHERE ride_status = 'Cancelled_By_Rider' AND cancel_reason = 'High_Surge_Fare') AS surge_cancels
FROM rides_fact
GROUP BY rider_id
HAVING COUNT(*) FILTER (WHERE ride_status = 'Cancelled_By_Rider' AND cancel_reason = 'High_Surge_Fare') >= 2
ORDER BY surge_cancels DESC;

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

-- 8h. Cancellation reason breakdown
SELECT
    cancel_reason,
    COUNT(*) AS total_cancellations
FROM rides_fact
WHERE ride_status IN ('Cancelled_By_Rider', 'No_Driver_Found')
GROUP BY cancel_reason
ORDER BY total_cancellations DESC;

-- 8i. Does driver supply respond to surge?
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

-- 8j. Final recommendation table
SELECT
    zone_type,
    ROUND(AVG(surge_multiplier), 2) AS current_avg_surge,
    ROUND(100.0 * COUNT(*) FILTER (WHERE ride_status != 'Completed') / COUNT(*), 1) AS cancel_rate_pct,
    ROUND(SUM(final_fare) - SUM(final_fare / surge_multiplier), 0) AS revenue_from_surge
FROM rides_fact
WHERE ride_status = 'Completed' OR ride_status IS NOT NULL
GROUP BY zone_type
ORDER BY cancel_rate_pct DESC;

-- 8k. Current surge vs recommended cap, by zone type
SELECT
    zone_type,
    ROUND(AVG(surge_multiplier), 2) AS current_avg_surge
FROM rides_fact
GROUP BY zone_type
ORDER BY current_avg_surge DESC;

-- 8l. NEW — WINDOW FUNCTION QUERY
-- Per-ride surge multiplier alongside its zone's average, using OVER/PARTITION BY.
SELECT
    ride_id,
    rider_id,
    zone_type,
    surge_multiplier,
    ROUND(AVG(surge_multiplier) OVER (PARTITION BY zone_type), 2) AS zone_avg_surge,
    ROUND(surge_multiplier - AVG(surge_multiplier) OVER (PARTITION BY zone_type), 2) AS diff_from_zone_avg
FROM rides_fact
ORDER BY zone_type, diff_from_zone_avg DESC;

--=====================================================================
-- FOR RECOMMENDATION 
-- 8m. Cancellation rate and revenue, broken down by zone type AND surge band
-- The direct evidence behind the per-zone recommended caps
WITH banded_rides AS (
    SELECT
        zone_type,
        CASE
            WHEN surge_multiplier < 1.1 THEN '1.0x'
            WHEN surge_multiplier < 1.3 THEN '1.1-1.3x'
            WHEN surge_multiplier < 1.5 THEN '1.3-1.5x'
            WHEN surge_multiplier < 1.8 THEN '1.5-1.8x'
            WHEN surge_multiplier < 2.2 THEN '1.8-2.2x'
            ELSE '2.2x+'
        END AS surge_band,
        ride_status,
        surge_multiplier,
        final_fare
    FROM rides_fact
)
SELECT
    zone_type,
    surge_band,
    COUNT(*) AS total_rides,
    ROUND(100.0 * COUNT(*) FILTER (WHERE ride_status != 'Completed') / COUNT(*), 1) AS cancel_rate_pct,
    ROUND(SUM(final_fare) FILTER (WHERE ride_status = 'Completed'), 0) AS revenue_in_band
FROM banded_rides
GROUP BY zone_type, surge_band
ORDER BY zone_type, MIN(surge_multiplier);

