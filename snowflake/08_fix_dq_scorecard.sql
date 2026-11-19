/* =============================================================================
   08_fix_dq_scorecard.sql  -  Make the data quality scorecard role-proof
   Run as VC_ADMIN.

   Why: masking policies evaluate against the role RUNNING the query, even inside a
   view. The original scorecard re-checked emails live from STAGING, so for a masked
   role every email looked like "*****@example.com" and failed the format check
   (6,000 failures instead of 22). The flags are now read from DIM_MEMBER, where
   they were computed once at build time by a role that sees the real values.
   ============================================================================= */
USE ROLE VC_ADMIN;
USE WAREHOUSE VC_ELT_WH;

CREATE OR REPLACE VIEW VIRTUAL_CARE_DEMO.ANALYTICS.DQ_SCORECARD COPY GRANTS AS
WITH raw_visits AS (SELECT COUNT(*) n, COUNT(DISTINCT visit_id) d FROM VIRTUAL_CARE_DEMO.RAW.VISITS),
     stg AS (SELECT * FROM VIRTUAL_CARE_DEMO.STAGING.STG_VISITS),
     mem AS (SELECT dq_bad_email, dq_missing_gender FROM VIRTUAL_CARE_DEMO.ANALYTICS.DIM_MEMBER)
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

-- Check as the app role: malformed email should be 22, not 6,000
USE ROLE VC_APP_OWNER;
USE SECONDARY ROLES NONE;
USE WAREHOUSE VC_BI_WH;
SELECT check_name, failed_rows, total_rows FROM VIRTUAL_CARE_DEMO.ANALYTICS.DQ_SCORECARD;
USE SECONDARY ROLES ALL;
