/* =============================================================================
   03_analytics.sql  -  Star schema for Power BI
   Run as VC_ADMIN. Tables (not views) so Power BI Import and DirectQuery both
   hit pre-joined, clustered data instead of re-running staging logic.

   Grain:
     FACT_VISIT   one row per visit request (completed, cancelled or no-show)
     FACT_SURVEY  one row per post-visit survey
   Conformed dimensions: DIM_DATE, DIM_MEMBER, DIM_EMPLOYER, DIM_PROVIDER, DIM_SERVICE_LINE

   In production these would be dbt models or Dynamic Tables with a target lag;
   plain CTAS keeps the demo easy to run and re-run.
   ============================================================================= */
USE ROLE VC_ADMIN;
USE WAREHOUSE VC_ELT_WH;
USE SCHEMA VIRTUAL_CARE_DEMO.ANALYTICS;

-- ---------------------------------------------------------------- DIM_DATE
CREATE OR REPLACE TABLE DIM_DATE AS
WITH d AS (
  SELECT DATEADD(day, SEQ4(), '2024-01-01'::DATE) AS date_day
  FROM TABLE(GENERATOR(ROWCOUNT => 1461))          -- 2024-01-01 .. 2027-12-31
)
SELECT
  date_day,
  YEAR(date_day)                                   AS year,
  QUARTER(date_day)                                AS quarter,
  'Q' || QUARTER(date_day) || ' ' || YEAR(date_day) AS year_quarter,
  MONTH(date_day)                                  AS month_num,
  MONTHNAME(date_day)                              AS month_short,
  DATE_TRUNC(month, date_day)                      AS month_start,
  TO_CHAR(date_day, 'YYYY-MM')                     AS year_month,
  DAYOFWEEKISO(date_day)                           AS day_of_week_num,
  DAYNAME(date_day)                                AS day_name,
  IFF(DAYOFWEEKISO(date_day) >= 6, TRUE, FALSE)    AS is_weekend,
  IFF(MONTH(date_day) IN (12, 1, 2), 'Winter',
    IFF(MONTH(date_day) IN (3, 4, 5), 'Spring',
    IFF(MONTH(date_day) IN (6, 7, 8), 'Summer', 'Fall'))) AS season
FROM d;

-- ---------------------------------------------------------------- DIM_EMPLOYER
CREATE OR REPLACE TABLE DIM_EMPLOYER AS
SELECT employer_id, employer_name, industry, region AS employer_region, hq_state,
       contract_start_date, eligible_lives, pricing_model
FROM VIRTUAL_CARE_DEMO.STAGING.STG_EMPLOYERS;

-- ---------------------------------------------------------------- DIM_MEMBER
-- Holds synthetic PII so the masking policies in 04_governance.sql have something
-- to protect. The Power BI model deliberately does NOT import the PII columns.
CREATE OR REPLACE TABLE DIM_MEMBER AS
SELECT
  member_id,
  first_name,
  last_name,
  date_of_birth,
  email,
  phone,
  DATEDIFF(year, date_of_birth, CURRENT_DATE())                    AS age,
  CASE
    WHEN DATEDIFF(year, date_of_birth, CURRENT_DATE()) < 26 THEN '18-25'
    WHEN DATEDIFF(year, date_of_birth, CURRENT_DATE()) < 36 THEN '26-35'
    WHEN DATEDIFF(year, date_of_birth, CURRENT_DATE()) < 46 THEN '36-45'
    WHEN DATEDIFF(year, date_of_birth, CURRENT_DATE()) < 56 THEN '46-55'
    WHEN DATEDIFF(year, date_of_birth, CURRENT_DATE()) < 66 THEN '56-65'
    ELSE '66+' END                                                 AS age_band,
  COALESCE(gender, 'Unknown')                                      AS gender,
  state                                                            AS member_state,
  region                                                           AS member_region,
  employer_id,
  plan_type,
  enrollment_date,
  dq_bad_email,
  dq_missing_gender
FROM VIRTUAL_CARE_DEMO.STAGING.STG_MEMBERS;

-- ---------------------------------------------------------------- DIM_PROVIDER
-- Includes an "Unknown" member so orphaned visits still join (no silent row loss).
CREATE OR REPLACE TABLE DIM_PROVIDER AS
SELECT provider_id, provider_name, specialty, primary_service_line_id, license_state,
       region AS provider_region, start_date, employment_type
FROM VIRTUAL_CARE_DEMO.STAGING.STG_PROVIDERS
UNION ALL
SELECT 'P-UNKNOWN', 'Unknown provider', 'Unknown', NULL, NULL, 'Unknown', NULL, 'Unknown';

-- ---------------------------------------------------------------- DIM_SERVICE_LINE
CREATE OR REPLACE TABLE DIM_SERVICE_LINE AS
SELECT service_line_id, service_line_name, service_category, list_price, target_duration_min
FROM VIRTUAL_CARE_DEMO.STAGING.STG_SERVICE_LINES;

-- ---------------------------------------------------------------- FACT_VISIT
CREATE OR REPLACE TABLE FACT_VISIT CLUSTER BY (request_date) AS
SELECT
  v.visit_id,
  v.member_id,
  IFF(v.dq_orphan_provider = 1, 'P-UNKNOWN', v.provider_id)       AS provider_id,
  v.service_line_id,
  m.employer_id,
  m.member_region,                       -- denormalized for the row access policy
  v.requested_at::DATE                   AS request_date,
  HOUR(v.requested_at)                   AS request_hour,
  v.requested_at,
  v.started_at,
  v.ended_at,
  v.channel,
  v.diagnosis_category,
  v.visit_status,
  IFF(v.visit_status = 'Completed', 1, 0)                         AS is_completed,
  v.wait_minutes,
  IFF(v.duration_minutes < 0, NULL, v.duration_minutes)           AS duration_minutes,
  IFF(v.resolved_first_contact, 1, 0)    AS resolved_first_contact,
  IFF(v.referral_flag, 1, 0)             AS referral_flag,
  IFF(v.prescription_flag, 1, 0)         AS prescription_flag,
  IFF(v.er_followup_7d, 1, 0)            AS er_followup_7d,
  v.visit_cost,
  v.dq_duplicate_in_source,
  v.dq_orphan_provider,
  v.dq_negative_duration,
  v.dq_completed_without_start
FROM VIRTUAL_CARE_DEMO.STAGING.STG_VISITS v
LEFT JOIN DIM_MEMBER m ON m.member_id = v.member_id;

-- ---------------------------------------------------------------- FACT_SURVEY
CREATE OR REPLACE TABLE FACT_SURVEY AS
SELECT
  s.survey_id,
  s.visit_id,
  f.member_id,
  f.member_region,
  f.employer_id,
  f.service_line_id,
  f.provider_id,
  f.channel,
  s.survey_date,
  s.nps_score,
  s.csat_score,
  CASE WHEN s.nps_score >= 9 THEN 'Promoter'
       WHEN s.nps_score >= 7 THEN 'Passive'
       ELSE 'Detractor' END              AS nps_bucket,
  s.comment
FROM VIRTUAL_CARE_DEMO.STAGING.STG_SURVEYS s
JOIN FACT_VISIT f ON f.visit_id = s.visit_id;

-- ---------------------------------------------------------------- Constraints (informational)
-- Snowflake does not enforce these, but Power BI and Cortex Analyst read them,
-- and they document the model for the next engineer.
ALTER TABLE DIM_DATE         ADD CONSTRAINT pk_dim_date     PRIMARY KEY (date_day);
ALTER TABLE DIM_EMPLOYER     ADD CONSTRAINT pk_dim_employer PRIMARY KEY (employer_id);
ALTER TABLE DIM_MEMBER       ADD CONSTRAINT pk_dim_member   PRIMARY KEY (member_id);
ALTER TABLE DIM_PROVIDER     ADD CONSTRAINT pk_dim_provider PRIMARY KEY (provider_id);
ALTER TABLE DIM_SERVICE_LINE ADD CONSTRAINT pk_dim_sl       PRIMARY KEY (service_line_id);
ALTER TABLE FACT_VISIT       ADD CONSTRAINT pk_fact_visit   PRIMARY KEY (visit_id);
ALTER TABLE FACT_SURVEY      ADD CONSTRAINT pk_fact_survey  PRIMARY KEY (survey_id);
ALTER TABLE FACT_VISIT ADD CONSTRAINT fk_visit_member   FOREIGN KEY (member_id)       REFERENCES DIM_MEMBER (member_id);
ALTER TABLE FACT_VISIT ADD CONSTRAINT fk_visit_provider FOREIGN KEY (provider_id)     REFERENCES DIM_PROVIDER (provider_id);
ALTER TABLE FACT_VISIT ADD CONSTRAINT fk_visit_sl       FOREIGN KEY (service_line_id) REFERENCES DIM_SERVICE_LINE (service_line_id);
ALTER TABLE FACT_VISIT ADD CONSTRAINT fk_visit_employer FOREIGN KEY (employer_id)     REFERENCES DIM_EMPLOYER (employer_id);
ALTER TABLE FACT_VISIT ADD CONSTRAINT fk_visit_date     FOREIGN KEY (request_date)    REFERENCES DIM_DATE (date_day);

-- ---------------------------------------------------------------- Documentation in the catalog
COMMENT ON TABLE FACT_VISIT  IS 'One row per virtual visit request. Grain: visit_id. Source: STG_VISITS (deduplicated).';
COMMENT ON TABLE FACT_SURVEY IS 'One row per post-visit survey. NPS 0-10, CSAT 1-5.';
COMMENT ON COLUMN FACT_VISIT.wait_minutes IS 'Minutes from request to provider join. Completed visits only.';
COMMENT ON COLUMN FACT_VISIT.resolved_first_contact IS '1 if the issue was resolved without referral or repeat visit.';
COMMENT ON COLUMN FACT_VISIT.er_followup_7d IS '1 if the member went to an ER within 7 days of the visit (avoidance KPI).';

-- Re-grant SELECT on the freshly replaced tables (CREATE OR REPLACE drops grants;
-- the FUTURE grant from 00_setup.sql covers new tables).
GRANT SELECT ON ALL TABLES IN SCHEMA VIRTUAL_CARE_DEMO.ANALYTICS TO ROLE VC_BI_READER;

SELECT visit_status, COUNT(*) visits, ROUND(AVG(wait_minutes),1) avg_wait
FROM FACT_VISIT GROUP BY 1 ORDER BY 2 DESC;
