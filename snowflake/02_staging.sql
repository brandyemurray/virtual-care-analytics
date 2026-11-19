/* =============================================================================
   02_staging.sql  -  Type, clean, deduplicate and flag data quality issues
   Run as VC_ADMIN. Views only: STAGING always reflects the latest RAW load.
   Rule of thumb used here: never silently drop a bad row. Keep it, flag it,
   and let ANALYTICS decide (and let the DQ dashboard show it).
   ============================================================================= */
USE ROLE VC_ADMIN;
USE WAREHOUSE VC_ELT_WH;
USE SCHEMA VIRTUAL_CARE_DEMO.STAGING;

CREATE OR REPLACE VIEW STG_EMPLOYERS AS
SELECT
  employer_id,
  employer_name,
  industry,
  region,
  hq_state,
  TRY_TO_DATE(contract_start_date)    AS contract_start_date,
  TRY_TO_NUMBER(eligible_lives)       AS eligible_lives,
  pricing_model
FROM VIRTUAL_CARE_DEMO.RAW.EMPLOYERS
QUALIFY ROW_NUMBER() OVER (PARTITION BY employer_id ORDER BY _loaded_at DESC) = 1;

CREATE OR REPLACE VIEW STG_MEMBERS AS
SELECT
  member_id,
  first_name,
  last_name,
  TRY_TO_DATE(date_of_birth)                                  AS date_of_birth,
  NULLIF(gender, '')                                          AS gender,
  LOWER(email)                                                AS email,
  phone,
  state,
  region,
  employer_id,
  plan_type,
  TRY_TO_DATE(enrollment_date)                                AS enrollment_date,
  -- DQ flags
  IFF(REGEXP_LIKE(LOWER(email), '^[a-z0-9._%+-]+@[a-z0-9.-]+\\.[a-z]{2,}$'), 0, 1) AS dq_bad_email,
  IFF(NULLIF(gender, '') IS NULL, 1, 0)                       AS dq_missing_gender
FROM VIRTUAL_CARE_DEMO.RAW.MEMBERS
QUALIFY ROW_NUMBER() OVER (PARTITION BY member_id ORDER BY _loaded_at DESC) = 1;

CREATE OR REPLACE VIEW STG_SERVICE_LINES AS
SELECT
  TRY_TO_NUMBER(service_line_id)          AS service_line_id,
  service_line_name,
  service_category,
  TRY_TO_DECIMAL(list_price, 10, 2)       AS list_price,
  TRY_TO_NUMBER(target_duration_min)      AS target_duration_min
FROM VIRTUAL_CARE_DEMO.RAW.SERVICE_LINES;

CREATE OR REPLACE VIEW STG_PROVIDERS AS
SELECT
  provider_id,
  provider_name,
  specialty,
  TRY_TO_NUMBER(primary_service_line_id)  AS primary_service_line_id,
  license_state,
  region,
  TRY_TO_DATE(start_date)                 AS start_date,
  employment_type
FROM VIRTUAL_CARE_DEMO.RAW.PROVIDERS
QUALIFY ROW_NUMBER() OVER (PARTITION BY provider_id ORDER BY _loaded_at DESC) = 1;

CREATE OR REPLACE VIEW STG_VISITS AS
WITH typed AS (
  SELECT
    visit_id,
    member_id,
    provider_id,
    TRY_TO_NUMBER(service_line_id)            AS service_line_id,
    channel,
    diagnosis_category,
    TRY_TO_TIMESTAMP_NTZ(requested_at)        AS requested_at,
    TRY_TO_TIMESTAMP_NTZ(started_at)          AS started_at,
    TRY_TO_TIMESTAMP_NTZ(ended_at)            AS ended_at,
    TRY_TO_NUMBER(wait_minutes)               AS wait_minutes,
    TRY_TO_NUMBER(duration_minutes)           AS duration_minutes,
    visit_status,
    TRY_TO_BOOLEAN(resolved_first_contact)    AS resolved_first_contact,
    TRY_TO_BOOLEAN(referral_flag)             AS referral_flag,
    TRY_TO_BOOLEAN(prescription_flag)         AS prescription_flag,
    TRY_TO_BOOLEAN(er_followup_7d)            AS er_followup_7d,
    TRY_TO_DECIMAL(visit_cost, 10, 2)         AS visit_cost,
    -- exact duplicates arrive from the source; count them so DQ can report them
    COUNT(*) OVER (PARTITION BY visit_id)     AS dup_count,
    ROW_NUMBER() OVER (PARTITION BY visit_id ORDER BY _loaded_at DESC) AS rn
  FROM VIRTUAL_CARE_DEMO.RAW.VISITS
)
SELECT
  t.* EXCLUDE (rn, dup_count),
  IFF(t.dup_count > 1, 1, 0)                                          AS dq_duplicate_in_source,
  IFF(p.provider_id IS NULL, 1, 0)                                    AS dq_orphan_provider,
  IFF(t.duration_minutes < 0, 1, 0)                                   AS dq_negative_duration,
  IFF(t.visit_status = 'Completed' AND t.started_at IS NULL, 1, 0)    AS dq_completed_without_start
FROM typed t
LEFT JOIN STG_PROVIDERS p ON p.provider_id = t.provider_id
WHERE t.rn = 1;   -- deduplicate: one row per visit_id

CREATE OR REPLACE VIEW STG_SURVEYS AS
SELECT
  survey_id,
  visit_id,
  TRY_TO_DATE(survey_date)       AS survey_date,
  TRY_TO_NUMBER(nps_score)       AS nps_score,
  TRY_TO_NUMBER(csat_score)      AS csat_score,
  NULLIF(comment, '')            AS comment
FROM VIRTUAL_CARE_DEMO.RAW.SURVEYS
QUALIFY ROW_NUMBER() OVER (PARTITION BY survey_id ORDER BY survey_date) = 1;
