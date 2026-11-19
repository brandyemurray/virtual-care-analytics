/* =============================================================================
   00_setup.sql  -  Account objects, roles, warehouse, database, schemas
   Run as ACCOUNTADMIN in a Snowflake trial (Enterprise edition is required for
   masking / row access policies and data metric functions in 04_governance.sql).
   ============================================================================= */
USE ROLE ACCOUNTADMIN;

-- ---------------------------------------------------------------------------
-- Warehouses: separate ELT from BI so Power BI load is isolated and costed.
-- ---------------------------------------------------------------------------
CREATE WAREHOUSE IF NOT EXISTS VC_ELT_WH
  WAREHOUSE_SIZE = 'XSMALL' AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE
  COMMENT = 'Loads and transforms for the virtual care demo';

CREATE WAREHOUSE IF NOT EXISTS VC_BI_WH
  WAREHOUSE_SIZE = 'XSMALL' AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE
  COMMENT = 'Power BI and analyst queries for the virtual care demo';

-- Protect trial credits: cap spend at 20 credits per month across both warehouses.
CREATE RESOURCE MONITOR IF NOT EXISTS VC_DEMO_MONITOR
  WITH CREDIT_QUOTA = 20 FREQUENCY = MONTHLY START_TIMESTAMP = IMMEDIATELY
  TRIGGERS ON 80 PERCENT DO NOTIFY
           ON 100 PERCENT DO SUSPEND;
ALTER WAREHOUSE VC_ELT_WH SET RESOURCE_MONITOR = VC_DEMO_MONITOR;
ALTER WAREHOUSE VC_BI_WH  SET RESOURCE_MONITOR = VC_DEMO_MONITOR;

-- ---------------------------------------------------------------------------
-- Role hierarchy (functional roles roll up to VC_ADMIN, which rolls up to SYSADMIN)
--
--   SYSADMIN
--     └─ VC_ADMIN            owns the database and all objects
--          ├─ VC_ENGINEER    builds RAW / STAGING / ANALYTICS
--          ├─ VC_PHI_READER  analysts cleared to see unmasked member PII
--          └─ VC_ANALYST     reads ANALYTICS + SEMANTIC, PII masked
--               └─ VC_BI_READER  Power BI service identity, PII masked, region filtered
-- ---------------------------------------------------------------------------
CREATE ROLE IF NOT EXISTS VC_ADMIN;
CREATE ROLE IF NOT EXISTS VC_ENGINEER;
CREATE ROLE IF NOT EXISTS VC_ANALYST;
CREATE ROLE IF NOT EXISTS VC_PHI_READER;
CREATE ROLE IF NOT EXISTS VC_BI_READER;

GRANT ROLE VC_BI_READER  TO ROLE VC_ANALYST;
GRANT ROLE VC_ANALYST    TO ROLE VC_PHI_READER;
GRANT ROLE VC_ANALYST    TO ROLE VC_ENGINEER;
GRANT ROLE VC_PHI_READER TO ROLE VC_ADMIN;
GRANT ROLE VC_ENGINEER   TO ROLE VC_ADMIN;
GRANT ROLE VC_ADMIN      TO ROLE SYSADMIN;

-- Let you test every role yourself
SET me = CURRENT_USER();
GRANT ROLE VC_ADMIN     TO USER IDENTIFIER($me);
GRANT ROLE VC_ANALYST   TO USER IDENTIFIER($me);
GRANT ROLE VC_BI_READER TO USER IDENTIFIER($me);

GRANT USAGE, OPERATE ON WAREHOUSE VC_ELT_WH TO ROLE VC_ENGINEER;
GRANT USAGE ON WAREHOUSE VC_BI_WH TO ROLE VC_BI_READER;
GRANT CREATE DATABASE ON ACCOUNT TO ROLE VC_ADMIN;

-- Governance objects need these account-level privileges
GRANT APPLY MASKING POLICY ON ACCOUNT TO ROLE VC_ADMIN;
GRANT APPLY ROW ACCESS POLICY ON ACCOUNT TO ROLE VC_ADMIN;
GRANT APPLY TAG ON ACCOUNT TO ROLE VC_ADMIN;
GRANT EXECUTE DATA METRIC FUNCTION ON ACCOUNT TO ROLE VC_ADMIN;
GRANT DATABASE ROLE SNOWFLAKE.DATA_METRIC_USER TO ROLE VC_ADMIN;
GRANT APPLICATION ROLE SNOWFLAKE.DATA_QUALITY_MONITORING_VIEWER TO ROLE VC_ADMIN;  -- read DMF results
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE VC_ANALYST;

-- ---------------------------------------------------------------------------
-- Database and medallion-style schemas
-- ---------------------------------------------------------------------------
USE ROLE VC_ADMIN;
CREATE DATABASE IF NOT EXISTS VIRTUAL_CARE_DEMO COMMENT = 'Synthetic telehealth data - no real PHI';

CREATE SCHEMA IF NOT EXISTS VIRTUAL_CARE_DEMO.RAW        WITH MANAGED ACCESS COMMENT = 'Landed as-is from source files';
CREATE SCHEMA IF NOT EXISTS VIRTUAL_CARE_DEMO.STAGING    WITH MANAGED ACCESS COMMENT = 'Typed, deduplicated, DQ-flagged views';
CREATE SCHEMA IF NOT EXISTS VIRTUAL_CARE_DEMO.ANALYTICS  WITH MANAGED ACCESS COMMENT = 'Star schema consumed by Power BI';
CREATE SCHEMA IF NOT EXISTS VIRTUAL_CARE_DEMO.GOVERNANCE WITH MANAGED ACCESS COMMENT = 'Tags, policies, entitlements, DQ results';
CREATE SCHEMA IF NOT EXISTS VIRTUAL_CARE_DEMO.SEMANTIC   WITH MANAGED ACCESS COMMENT = 'Semantic views for Cortex Analyst';

GRANT USAGE ON DATABASE VIRTUAL_CARE_DEMO TO ROLE VC_BI_READER;
GRANT USAGE, CREATE TABLE, CREATE VIEW, CREATE STAGE, CREATE FILE FORMAT
  ON SCHEMA VIRTUAL_CARE_DEMO.RAW TO ROLE VC_ENGINEER;
GRANT USAGE, CREATE VIEW ON SCHEMA VIRTUAL_CARE_DEMO.STAGING   TO ROLE VC_ENGINEER;
GRANT USAGE, CREATE TABLE, CREATE VIEW ON SCHEMA VIRTUAL_CARE_DEMO.ANALYTICS TO ROLE VC_ENGINEER;
GRANT USAGE ON SCHEMA VIRTUAL_CARE_DEMO.ANALYTICS TO ROLE VC_BI_READER;
GRANT USAGE ON SCHEMA VIRTUAL_CARE_DEMO.SEMANTIC  TO ROLE VC_ANALYST;

-- BI readers see only the ANALYTICS layer, never RAW or STAGING
GRANT SELECT ON ALL TABLES    IN SCHEMA VIRTUAL_CARE_DEMO.ANALYTICS TO ROLE VC_BI_READER;
GRANT SELECT ON FUTURE TABLES IN SCHEMA VIRTUAL_CARE_DEMO.ANALYTICS TO ROLE VC_BI_READER;
GRANT SELECT ON ALL VIEWS     IN SCHEMA VIRTUAL_CARE_DEMO.ANALYTICS TO ROLE VC_BI_READER;
GRANT SELECT ON FUTURE VIEWS  IN SCHEMA VIRTUAL_CARE_DEMO.ANALYTICS TO ROLE VC_BI_READER;

-- ---------------------------------------------------------------------------
-- Power BI service user (key-pair auth; Snowflake is retiring password-only sign-in)
--   1. On your laptop:  openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -out pbi_rsa_key.p8 -nocrypt
--                       openssl rsa -in pbi_rsa_key.p8 -pubout -out pbi_rsa_key.pub
--   2. Paste the body of pbi_rsa_key.pub (no header/footer lines) below and run.
--   3. In Power BI Desktop choose the "Key pair" sign-in and upload pbi_rsa_key.p8.
--   Never commit the .p8 file (it is in .gitignore).
-- ---------------------------------------------------------------------------
USE ROLE ACCOUNTADMIN;
CREATE USER IF NOT EXISTS PBI_SVC
  TYPE = SERVICE
  DEFAULT_ROLE = VC_BI_READER
  DEFAULT_WAREHOUSE = VC_BI_WH
  COMMENT = 'Power BI semantic model connection';
-- ALTER USER PBI_SVC SET RSA_PUBLIC_KEY = 'MIIBIjANBgkqh...';
GRANT ROLE VC_BI_READER TO USER PBI_SVC;

-- ---------------------------------------------------------------------------
-- Landing stage, created here so the CSVs can be uploaded before 01_raw_load.sql
-- ---------------------------------------------------------------------------
USE ROLE VC_ADMIN;
CREATE STAGE IF NOT EXISTS VIRTUAL_CARE_DEMO.RAW.LANDING
  DIRECTORY = (ENABLE = TRUE)
  COMMENT = 'Drop zone for source extracts';
