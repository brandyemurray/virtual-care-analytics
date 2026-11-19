/* =============================================================================
   99_teardown.sql  -  Remove everything so the build can be rerun from scratch
   (Scripts 03 and 04 are not idempotent on their own: replacing a table drops
   its tags and policies, and a policy attached to a tag cannot be replaced.)
   ============================================================================= */
USE ROLE ACCOUNTADMIN;
DROP DATABASE IF EXISTS VIRTUAL_CARE_DEMO;
DROP USER IF EXISTS PBI_SVC;
DROP ROLE IF EXISTS VC_WEST_ANALYST;
DROP ROLE IF EXISTS VC_PBI_SERVICE;
DROP ROLE IF EXISTS VC_REGION_ALL;
DROP ROLE IF EXISTS VC_REGION_WEST;
DROP ROLE IF EXISTS VC_REGION_CENTRAL;
DROP ROLE IF EXISTS VC_REGION_EAST;
DROP ROLE IF EXISTS VC_BI_READER;
DROP ROLE IF EXISTS VC_ANALYST;
DROP ROLE IF EXISTS VC_PHI_READER;
DROP ROLE IF EXISTS VC_ENGINEER;
DROP ROLE IF EXISTS VC_ADMIN;
DROP WAREHOUSE IF EXISTS VC_ELT_WH;
DROP WAREHOUSE IF EXISTS VC_BI_WH;
DROP RESOURCE MONITOR IF EXISTS VC_DEMO_MONITOR;
