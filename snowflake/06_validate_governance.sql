/* =============================================================================
   06_validate_governance.sql  -  Prove the controls work (good demo moment)
   Your own user has every role, and Snowflake turns on secondary roles by
   default, which would let VC_ADMIN leak into every test. USE SECONDARY ROLES
   NONE makes each test see only the role you switched to.
   ============================================================================= */
USE WAREHOUSE VC_BI_WH;
USE SECONDARY ROLES NONE;

-- 1. PHI reader: full names, emails, birth dates
USE ROLE VC_ADMIN;
SELECT member_id, first_name, last_name, email, phone, date_of_birth, member_region
FROM VIRTUAL_CARE_DEMO.ANALYTICS.DIM_MEMBER LIMIT 5;

-- 2. West analyst: PII masked AND only West rows
USE ROLE VC_WEST_ANALYST;
SELECT member_id, first_name, email, phone, date_of_birth, member_region
FROM VIRTUAL_CARE_DEMO.ANALYTICS.DIM_MEMBER LIMIT 5;
SELECT member_region, COUNT(*) AS visits
FROM VIRTUAL_CARE_DEMO.ANALYTICS.FACT_VISIT GROUP BY 1;          -- West only

-- 3. Power BI service role: PII masked, every region
USE ROLE VC_PBI_SERVICE;
SELECT member_region, COUNT(*) AS visits
FROM VIRTUAL_CARE_DEMO.ANALYTICS.FACT_VISIT GROUP BY 1 ORDER BY 1;  -- all three regions
SELECT email FROM VIRTUAL_CARE_DEMO.ANALYTICS.DIM_MEMBER LIMIT 3;  -- *****@example.com

-- 4. Plain BI reader with no region entitlement: zero rows (deny by default)
USE ROLE VC_BI_READER;
SELECT COUNT(*) AS visible_visits FROM VIRTUAL_CARE_DEMO.ANALYTICS.FACT_VISIT;  -- 0

-- 5. Data quality results
USE ROLE VC_ADMIN;
SELECT * FROM VIRTUAL_CARE_DEMO.ANALYTICS.DQ_SCORECARD;
-- DMF history (populates a few minutes after the first change on each table)
SELECT measurement_time, table_name, metric_name, argument_names, value
FROM SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS
WHERE table_database = 'VIRTUAL_CARE_DEMO'
ORDER BY measurement_time DESC;

-- 6. Catalog: where is PII, and what protects it?
SELECT * FROM TABLE(VIRTUAL_CARE_DEMO.INFORMATION_SCHEMA.POLICY_REFERENCES(
  REF_ENTITY_NAME => 'VIRTUAL_CARE_DEMO.ANALYTICS.DIM_MEMBER', REF_ENTITY_DOMAIN => 'table'));

USE SECONDARY ROLES ALL;
