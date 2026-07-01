-- Data Quality Checks : Checking for nulls, duplicates
SELECT COUNT(*) FROM public.onboarding_events;
--1. Nulls
SELECT *
FROM public.onboarding_events
WHERE "USER_ID" IS NULL
   OR "EVENT_TYPE" IS NULL
   OR "EVENT_AT" IS NULL;

--2. Checking distinct event types
SELECT DISTINCT "EVENT_TYPE"
FROM public.onboarding_events
ORDER BY "EVENT_TYPE";

--3. Duplicates 
SELECT "USER_ID", "EVENT_TYPE", "EVENT_AT", COUNT(*) 
FROM public.onboarding_events
GROUP BY "USER_ID", "EVENT_TYPE", "EVENT_AT"
HAVING COUNT(*) > 1;

-- Data is clean, changes required are:
-- 1. changing EVENT_AT to timestamp from text| 2. Fixing typo 'started_onboading' column to 'started_onboarding'
--------------------------------------------------------------------------------------------------------------------------------
-- Part 1: Drop-off (Count of users by each event type):

 WITH events_clean AS(
 SELECT
    "USER_ID" AS user_id,
    CASE
      WHEN "EVENT_TYPE" IN ('started_onboading','started_onboarding') THEN 'started_onboarding'
      ELSE "EVENT_TYPE"
    END AS event_type,
    "EVENT_AT"::timestamp AS event_time
  FROM public.onboarding_events
),
drop_off_count_cte AS(
SELECT event_type, COUNT(DISTINCT user_id) AS count_of_users, 
CASE WHEN event_type = 'started_onboarding' THEN 1
	 WHEN event_type ='accepted_terms_of_service' THEN 2
	 WHEN event_type ='passed_kyc' THEN 3
	 WHEN event_type ='started_application' THEN 4
	 WHEN event_type ='submitted_application' THEN 5
	 WHEN event_type ='confirmed_advance' THEN 6
	 WHEN event_type = 'opted_for_instant_transfer' THEN 7
END AS step_order
FROM events_clean
GROUP BY 1),

prev_count_cte AS(
	SELECT step_order, event_type, count_of_users, 
	LAG(count_of_users) OVER (ORDER BY step_order) AS prev_count_of_users
	FROM drop_off_count_cte
)

SELECT step_order, event_type, count_of_users, (prev_count_of_users - count_of_users) AS drop_count,
ROUND( 
100.0 * (prev_count_of_users - count_of_users)/NULLIF(prev_count_of_users, 0),
2) AS drop_off_rate,
ROUND(
  100.0 * count_of_users / NULLIF(prev_count_of_users, 0),
  2
) AS conversion_rate
FROM prev_count_cte
ORDER BY 1 
;
----------------------------------------------------------------------------------------------------------------

--Part 2: How long does it take users to move through each step


WITH events_clean AS (
SELECT "USER_ID" AS user_id,
CASE
      WHEN "EVENT_TYPE" IN ('started_onboading','started_onboarding') THEN 'started_onboarding'
      ELSE "EVENT_TYPE"
	      END AS event_type,
    "EVENT_AT"::timestamp AS event_time
  FROM public.onboarding_events),
  
-- 1) How many times each user hit each event
 number_of_hits AS(
 SELECT
    user_id,
    event_type,
    COUNT(*) AS hits
  FROM events_clean
  GROUP BY user_id, event_type
  HAVING COUNT(*)>1),
  --Since no data is returned, each user only goes through each step once in this dataset
  
step_order AS (
SELECT user_id, event_type,event_time, 
CASE WHEN event_type = 'started_onboarding' THEN 1
	 WHEN event_type ='accepted_terms_of_service' THEN 2
	 WHEN event_type ='passed_kyc' THEN 3
	 WHEN event_type ='started_application' THEN 4
	 WHEN event_type ='submitted_application' THEN 5
	 WHEN event_type ='confirmed_advance' THEN 6
	 WHEN event_type = 'opted_for_instant_transfer' THEN 7
END AS step_order
	 FROM events_clean),

-- Step to step time differences by each user:
time_difference AS (
  SELECT
    step_order,
    user_id,
    event_type,
    event_time,
    LEAD(event_time) OVER (PARTITION BY user_id ORDER BY step_order) AS next_event_time,
    LEAD(step_order) OVER (PARTITION BY user_id ORDER BY step_order) AS next_step_order 
  FROM step_order
),

deltas AS (
  SELECT
    CONCAT(event_type, ' - ', 
     CASE next_step_order
      WHEN 2 THEN 'accepted_terms_of_service'
      WHEN 3 THEN 'passed_kyc'
      WHEN 4 THEN 'started_application'
      WHEN 5 THEN 'submitted_application'
      WHEN 6 THEN 'confirmed_advance'
      WHEN 7 THEN 'opted_for_instant_transfer'
    END) AS step_pair,
    EXTRACT(EPOCH FROM (next_event_time - event_time)) AS seconds,  
    step_order
  FROM time_difference
  WHERE next_step_order = step_order + 1                -- consecutive only
    AND next_event_time IS NOT NULL
    AND (next_event_time - event_time) >= INTERVAL '0'  -- dropping negatives
)

SELECT
  step_pair,
  ROUND(PERCENTILE_DISC(0.5) WITHIN GROUP (ORDER BY seconds),2) AS p50_seconds,
  ROUND(PERCENTILE_DISC(0.9) WITHIN GROUP (ORDER BY seconds)/60.0,2) AS p90_minutes,
  ROUND(AVG(seconds) / 3600.0, 2)                      AS avg_hours,
  ROUND(MIN(seconds),2)                                AS fastest_seconds,
  ROUND(MAX(seconds)/3600.0,2)                         AS slowest_hours,
  COUNT(*)                                             AS n_users
FROM deltas
GROUP BY step_pair
ORDER BY MIN(step_order);

-----------------------------------------------------------------------------------------