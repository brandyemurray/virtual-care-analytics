/* =============================================================================
   01_raw_load.sql  -  Land the CSVs in RAW exactly as received
   Run as VC_ADMIN.

   Getting the files into the stage, pick one:
     A) Snowsight: Data > Databases > VIRTUAL_CARE_DEMO > RAW > Stages > LANDING
        > "+ Files", drag in the six CSVs from /data.
     B) SnowSQL / Snowflake CLI from the repo root:
          snow stage copy data/ @VIRTUAL_CARE_DEMO.RAW.LANDING --recursive
        or
          PUT file://data/*.csv @VIRTUAL_CARE_DEMO.RAW.LANDING AUTO_COMPRESS=TRUE;
   ============================================================================= */
USE ROLE VC_ADMIN;
USE WAREHOUSE VC_ELT_WH;
USE SCHEMA VIRTUAL_CARE_DEMO.RAW;

CREATE FILE FORMAT IF NOT EXISTS CSV_HEADER
  TYPE = CSV
  PARSE_HEADER = FALSE
  SKIP_HEADER = 1
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  EMPTY_FIELD_AS_NULL = TRUE
  NULL_IF = ('', 'NULL')
  TRIM_SPACE = TRUE;

CREATE STAGE IF NOT EXISTS LANDING   -- already created by 00_setup.sql; kept so this script stands alone
  FILE_FORMAT = CSV_HEADER
  DIRECTORY = (ENABLE = TRUE)
  COMMENT = 'Drop zone for source extracts';
-- The stage made in 00_setup.sql has no file format yet; attach it so COPY skips headers
ALTER STAGE LANDING SET FILE_FORMAT = (FORMAT_NAME = 'CSV_HEADER');

-- RAW tables keep everything as text plus load lineage. Typing happens in STAGING,
-- so a bad value never fails the load; it gets flagged downstream instead.
CREATE OR REPLACE TABLE EMPLOYERS (
  employer_id STRING, employer_name STRING, industry STRING, region STRING, hq_state STRING,
  contract_start_date STRING, eligible_lives STRING, pricing_model STRING,
  _source_file STRING, _loaded_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP());

CREATE OR REPLACE TABLE MEMBERS (
  member_id STRING, first_name STRING, last_name STRING, date_of_birth STRING, gender STRING,
  email STRING, phone STRING, state STRING, region STRING, employer_id STRING, plan_type STRING,
  enrollment_date STRING,
  _source_file STRING, _loaded_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP());

CREATE OR REPLACE TABLE SERVICE_LINES (
  service_line_id STRING, service_line_name STRING, service_category STRING, list_price STRING,
  target_duration_min STRING,
  _source_file STRING, _loaded_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP());

CREATE OR REPLACE TABLE PROVIDERS (
  provider_id STRING, provider_name STRING, specialty STRING, primary_service_line_id STRING,
  license_state STRING, region STRING, start_date STRING, employment_type STRING,
  _source_file STRING, _loaded_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP());

CREATE OR REPLACE TABLE VISITS (
  visit_id STRING, member_id STRING, provider_id STRING, service_line_id STRING, channel STRING,
  diagnosis_category STRING, requested_at STRING, started_at STRING, ended_at STRING,
  wait_minutes STRING, duration_minutes STRING, visit_status STRING, resolved_first_contact STRING,
  referral_flag STRING, prescription_flag STRING, er_followup_7d STRING, visit_cost STRING,
  _source_file STRING, _loaded_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP());

CREATE OR REPLACE TABLE SURVEYS (
  survey_id STRING, visit_id STRING, survey_date STRING, nps_score STRING, csat_score STRING,
  comment STRING,
  _source_file STRING, _loaded_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP());

-- One COPY per table. METADATA$FILENAME gives row-level lineage back to the file.
COPY INTO EMPLOYERS FROM (SELECT t.$1,t.$2,t.$3,t.$4,t.$5,t.$6,t.$7,t.$8, METADATA$FILENAME, CURRENT_TIMESTAMP()
  FROM @LANDING t) PATTERN = '.*employers.*[.]csv.*' ON_ERROR = 'CONTINUE';
COPY INTO MEMBERS FROM (SELECT t.$1,t.$2,t.$3,t.$4,t.$5,t.$6,t.$7,t.$8,t.$9,t.$10,t.$11,t.$12, METADATA$FILENAME, CURRENT_TIMESTAMP()
  FROM @LANDING t) PATTERN = '.*members.*[.]csv.*' ON_ERROR = 'CONTINUE';
COPY INTO SERVICE_LINES FROM (SELECT t.$1,t.$2,t.$3,t.$4,t.$5, METADATA$FILENAME, CURRENT_TIMESTAMP()
  FROM @LANDING t) PATTERN = '.*service_lines.*[.]csv.*' ON_ERROR = 'CONTINUE';
COPY INTO PROVIDERS FROM (SELECT t.$1,t.$2,t.$3,t.$4,t.$5,t.$6,t.$7,t.$8, METADATA$FILENAME, CURRENT_TIMESTAMP()
  FROM @LANDING t) PATTERN = '.*providers.*[.]csv.*' ON_ERROR = 'CONTINUE';
COPY INTO VISITS FROM (SELECT t.$1,t.$2,t.$3,t.$4,t.$5,t.$6,t.$7,t.$8,t.$9,t.$10,t.$11,t.$12,t.$13,t.$14,t.$15,t.$16,t.$17,
  METADATA$FILENAME, CURRENT_TIMESTAMP()
  FROM @LANDING t) PATTERN = '.*visits.*[.]csv.*' ON_ERROR = 'CONTINUE';
COPY INTO SURVEYS FROM (SELECT t.$1,t.$2,t.$3,t.$4,t.$5,t.$6, METADATA$FILENAME, CURRENT_TIMESTAMP()
  FROM @LANDING t) PATTERN = '.*surveys.*[.]csv.*' ON_ERROR = 'CONTINUE';

-- Expect: 24 / 6,000 / 7 / 106 / 45,040 / ~15,000 with the default seed
SELECT 'EMPLOYERS' tbl, COUNT(*) n FROM EMPLOYERS UNION ALL
SELECT 'MEMBERS', COUNT(*) FROM MEMBERS UNION ALL
SELECT 'SERVICE_LINES', COUNT(*) FROM SERVICE_LINES UNION ALL
SELECT 'PROVIDERS', COUNT(*) FROM PROVIDERS UNION ALL
SELECT 'VISITS', COUNT(*) FROM VISITS UNION ALL
SELECT 'SURVEYS', COUNT(*) FROM SURVEYS;
