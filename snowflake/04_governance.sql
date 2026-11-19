/* =============================================================================
   04_governance.sql  -  Cataloging, access controls and data quality
   Run as VC_ADMIN (Enterprise edition required; trial accounts default to it).

   1. Catalog:        object tags for domain, owner and PII type, plus comments
   2. Access:         tag-based masking for PII, row access policy by region
   3. Data quality:   Data Metric Functions (system + custom) and a DQ scorecard
                      view that Power BI reads for the "Data Quality" page
   ============================================================================= */
USE ROLE VC_ADMIN;
USE WAREHOUSE VC_ELT_WH;
USE SCHEMA VIRTUAL_CARE_DEMO.GOVERNANCE;

-- ============================================================================
-- 1. CATALOG  -  tags make the data discoverable and drive policy
-- ============================================================================
CREATE TAG IF NOT EXISTS DATA_DOMAIN  ALLOWED_VALUES 'Clinical Operations', 'Member', 'Provider', 'Commercial'
  COMMENT = 'Business domain that owns the object';
CREATE TAG IF NOT EXISTS DATA_OWNER   COMMENT = 'Accountable data owner (team or person)';
CREATE TAG IF NOT EXISTS PII_TYPE     ALLOWED_VALUES 'NAME', 'EMAIL', 'PHONE', 'DOB'
  COMMENT = 'Kind of personal data in a column; drives masking';

ALTER SCHEMA VIRTUAL_CARE_DEMO.ANALYTICS SET TAG DATA_OWNER = 'Analytics Engineering';
ALTER TABLE VIRTUAL_CARE_DEMO.ANALYTICS.FACT_VISIT   SET TAG DATA_DOMAIN = 'Clinical Operations';
ALTER TABLE VIRTUAL_CARE_DEMO.ANALYTICS.FACT_SURVEY  SET TAG DATA_DOMAIN = 'Clinical Operations';
ALTER TABLE VIRTUAL_CARE_DEMO.ANALYTICS.DIM_MEMBER   SET TAG DATA_DOMAIN = 'Member';
ALTER TABLE VIRTUAL_CARE_DEMO.ANALYTICS.DIM_PROVIDER SET TAG DATA_DOMAIN = 'Provider';
ALTER TABLE VIRTUAL_CARE_DEMO.ANALYTICS.DIM_EMPLOYER SET TAG DATA_DOMAIN = 'Commercial';

-- Optional: let Snowflake find sensitive columns itself and propose tags
-- CALL SYSTEM$CLASSIFY('VIRTUAL_CARE_DEMO.RAW.MEMBERS', NULL);

-- ============================================================================
-- 2a. MASKING  -  one policy per data type, attached to the PII_TYPE tag.
--     Tag a new column and it is masked automatically; no per-column policy work.
-- ============================================================================
CREATE OR REPLACE MASKING POLICY MASK_PII_STRING AS (val STRING) RETURNS STRING ->
  CASE
    WHEN IS_ROLE_IN_SESSION('VC_PHI_READER') THEN val
    WHEN SYSTEM$GET_TAG_ON_CURRENT_COLUMN('VIRTUAL_CARE_DEMO.GOVERNANCE.PII_TYPE') = 'EMAIL'
      THEN REGEXP_REPLACE(val, '^[^@]+', '*****')            -- keep the domain for analysis
    WHEN SYSTEM$GET_TAG_ON_CURRENT_COLUMN('VIRTUAL_CARE_DEMO.GOVERNANCE.PII_TYPE') = 'PHONE'
      THEN '***-***-' || RIGHT(val, 4)
    ELSE '*** MASKED ***'
  END
  COMMENT = 'Unmasked only for VC_PHI_READER';

CREATE OR REPLACE MASKING POLICY MASK_PII_DATE AS (val DATE) RETURNS DATE ->
  CASE
    WHEN IS_ROLE_IN_SESSION('VC_PHI_READER') THEN val
    ELSE DATE_FROM_PARTS(YEAR(val), 1, 1)                    -- birth year only
  END
  COMMENT = 'Generalizes dates of birth to Jan 1 for non-PHI roles';

ALTER TAG PII_TYPE SET MASKING POLICY MASK_PII_STRING, MASKING POLICY MASK_PII_DATE;

-- Tag the PII columns in both the RAW landing table and the ANALYTICS dimension
ALTER TABLE VIRTUAL_CARE_DEMO.ANALYTICS.DIM_MEMBER MODIFY
  COLUMN first_name    SET TAG PII_TYPE = 'NAME',
  COLUMN last_name     SET TAG PII_TYPE = 'NAME',
  COLUMN email         SET TAG PII_TYPE = 'EMAIL',
  COLUMN phone         SET TAG PII_TYPE = 'PHONE',
  COLUMN date_of_birth SET TAG PII_TYPE = 'DOB';

ALTER TABLE VIRTUAL_CARE_DEMO.RAW.MEMBERS MODIFY
  COLUMN first_name    SET TAG PII_TYPE = 'NAME',
  COLUMN last_name     SET TAG PII_TYPE = 'NAME',
  COLUMN email         SET TAG PII_TYPE = 'EMAIL',
  COLUMN phone         SET TAG PII_TYPE = 'PHONE';
  -- RAW.date_of_birth is STRING, so the STRING policy masks it fully there
ALTER TABLE VIRTUAL_CARE_DEMO.RAW.MEMBERS MODIFY COLUMN date_of_birth SET TAG PII_TYPE = 'DOB';

-- ============================================================================
-- 2b. ROW ACCESS  -  region entitlements live in a table, not in the policy.
--     Adding a regional analyst is an INSERT, not a policy change.
-- ============================================================================
USE ROLE ACCOUNTADMIN;
CREATE ROLE IF NOT EXISTS VC_REGION_ALL;
CREATE ROLE IF NOT EXISTS VC_REGION_WEST;
CREATE ROLE IF NOT EXISTS VC_REGION_CENTRAL;
CREATE ROLE IF NOT EXISTS VC_REGION_EAST;
GRANT ROLE VC_REGION_ALL, VC_REGION_WEST, VC_REGION_CENTRAL, VC_REGION_EAST TO ROLE VC_ADMIN;
-- The Power BI model sees every region: its service role = BI reader + all-region entitlement
CREATE ROLE IF NOT EXISTS VC_PBI_SERVICE;
GRANT ROLE VC_BI_READER  TO ROLE VC_PBI_SERVICE;
GRANT ROLE VC_REGION_ALL TO ROLE VC_PBI_SERVICE;
GRANT ROLE VC_PBI_SERVICE TO ROLE VC_ADMIN;
GRANT ROLE VC_PBI_SERVICE TO USER PBI_SVC;
ALTER USER PBI_SVC SET DEFAULT_ROLE = VC_PBI_SERVICE;

-- A demo persona: an analyst who should only ever see the West
CREATE ROLE IF NOT EXISTS VC_WEST_ANALYST;
GRANT ROLE VC_ANALYST     TO ROLE VC_WEST_ANALYST;
GRANT ROLE VC_REGION_WEST TO ROLE VC_WEST_ANALYST;
GRANT ROLE VC_WEST_ANALYST TO ROLE VC_ADMIN;
SET me = CURRENT_USER();
GRANT ROLE VC_WEST_ANALYST TO USER IDENTIFIER($me);

USE ROLE VC_ADMIN;
USE SCHEMA VIRTUAL_CARE_DEMO.GOVERNANCE;

CREATE OR REPLACE TABLE REGION_ENTITLEMENTS (role_name STRING, region STRING);
INSERT INTO REGION_ENTITLEMENTS VALUES
  ('VC_REGION_ALL', 'ALL'),
  ('VC_REGION_WEST', 'West'),
  ('VC_REGION_CENTRAL', 'Central'),
  ('VC_REGION_EAST', 'East');

CREATE OR REPLACE ROW ACCESS POLICY REGION_RAP AS (row_region STRING) RETURNS BOOLEAN ->
  IS_ROLE_IN_SESSION('VC_ENGINEER')
  OR EXISTS (
    SELECT 1 FROM VIRTUAL_CARE_DEMO.GOVERNANCE.REGION_ENTITLEMENTS e
    WHERE IS_ROLE_IN_SESSION(e.role_name)
      AND (e.region = 'ALL' OR e.region = row_region)
  )
  COMMENT = 'Rows visible when the session holds a role entitled to the member region';

ALTER TABLE VIRTUAL_CARE_DEMO.ANALYTICS.FACT_VISIT  ADD ROW ACCESS POLICY REGION_RAP ON (member_region);
ALTER TABLE VIRTUAL_CARE_DEMO.ANALYTICS.FACT_SURVEY ADD ROW ACCESS POLICY REGION_RAP ON (member_region);
ALTER TABLE VIRTUAL_CARE_DEMO.ANALYTICS.DIM_MEMBER  ADD ROW ACCESS POLICY REGION_RAP ON (member_region);

-- ============================================================================
-- 3. DATA QUALITY  -  Data Metric Functions run on change; results land in
--    SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS
-- ============================================================================
CREATE OR REPLACE DATA METRIC FUNCTION INVALID_EMAIL_COUNT(arg_t TABLE(arg_c STRING))
  RETURNS NUMBER AS
  $$ SELECT COUNT_IF(arg_c IS NOT NULL
                     AND NOT REGEXP_LIKE(LOWER(arg_c), '^[a-z0-9._%+-]+@[a-z0-9.-]+\\.[a-z]{2,}$'))
     FROM arg_t $$;

CREATE OR REPLACE DATA METRIC FUNCTION NEGATIVE_VALUE_COUNT(arg_t TABLE(arg_c NUMBER))
  RETURNS NUMBER AS
  $$ SELECT COUNT_IF(arg_c < 0) FROM arg_t $$;

ALTER TABLE VIRTUAL_CARE_DEMO.RAW.VISITS  SET DATA_METRIC_SCHEDULE = 'TRIGGER_ON_CHANGES';
ALTER TABLE VIRTUAL_CARE_DEMO.RAW.MEMBERS SET DATA_METRIC_SCHEDULE = 'TRIGGER_ON_CHANGES';
ALTER TABLE VIRTUAL_CARE_DEMO.ANALYTICS.FACT_VISIT SET DATA_METRIC_SCHEDULE = 'TRIGGER_ON_CHANGES';

ALTER TABLE VIRTUAL_CARE_DEMO.RAW.VISITS  ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.DUPLICATE_COUNT ON (visit_id);
ALTER TABLE VIRTUAL_CARE_DEMO.RAW.VISITS  ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_COUNT      ON (member_id);
ALTER TABLE VIRTUAL_CARE_DEMO.RAW.MEMBERS ADD DATA METRIC FUNCTION INVALID_EMAIL_COUNT            ON (email);
ALTER TABLE VIRTUAL_CARE_DEMO.ANALYTICS.FACT_VISIT ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.ROW_COUNT ON ();
ALTER TABLE VIRTUAL_CARE_DEMO.ANALYTICS.FACT_VISIT ADD DATA METRIC FUNCTION NEGATIVE_VALUE_COUNT ON (wait_minutes);

-- Scorecard view: the same checks, computed on demand, shaped for Power BI.
-- (DMF results are the system of record; this view gives the report a stable, simple feed.)
CREATE OR REPLACE VIEW VIRTUAL_CARE_DEMO.ANALYTICS.DQ_SCORECARD AS
WITH raw_visits AS (SELECT COUNT(*) n, COUNT(DISTINCT visit_id) d FROM VIRTUAL_CARE_DEMO.RAW.VISITS),
     stg AS (SELECT * FROM VIRTUAL_CARE_DEMO.STAGING.STG_VISITS),
     mem AS (SELECT * FROM VIRTUAL_CARE_DEMO.STAGING.STG_MEMBERS)
SELECT 'Visits' AS entity, 'Uniqueness' AS dimension, 'Duplicate visit rows in source' AS check_name,
       (SELECT n - d FROM raw_visits) AS failed_rows, (SELECT n FROM raw_visits) AS total_rows,
       'Deduplicated in STAGING' AS handling
UNION ALL
SELECT 'Visits', 'Referential integrity', 'Visit references unknown provider',
       (SELECT SUM(dq_orphan_provider) FROM stg), (SELECT COUNT(*) FROM stg), 'Mapped to P-UNKNOWN'
UNION ALL
SELECT 'Visits', 'Validity', 'Negative visit duration',
       (SELECT SUM(dq_negative_duration) FROM stg), (SELECT COUNT(*) FROM stg), 'Set to NULL in ANALYTICS'
UNION ALL
SELECT 'Visits', 'Completeness', 'Completed visit missing start time',
       (SELECT SUM(dq_completed_without_start) FROM stg), (SELECT COUNT(*) FROM stg), 'Flagged'
UNION ALL
SELECT 'Members', 'Validity', 'Malformed email address',
       (SELECT SUM(dq_bad_email) FROM mem), (SELECT COUNT(*) FROM mem), 'Flagged for source fix'
UNION ALL
SELECT 'Members', 'Completeness', 'Missing gender',
       (SELECT SUM(dq_missing_gender) FROM mem), (SELECT COUNT(*) FROM mem), 'Shown as Unknown';

GRANT SELECT ON VIEW VIRTUAL_CARE_DEMO.ANALYTICS.DQ_SCORECARD TO ROLE VC_BI_READER;
