/* =============================================================================
   07_streamlit_app.sql  -  Role and schema for the Streamlit in Snowflake app
   Run as ACCOUNTADMIN after 00-06.

   A Streamlit in Snowflake app runs with its OWNER's role. Giving it a dedicated
   least-privilege role means the app sees exactly what a masked, all-region
   analyst sees: PII masked by the tag policies, rows filtered by REGION_RAP.
   ============================================================================= */
USE ROLE ACCOUNTADMIN;

CREATE ROLE IF NOT EXISTS VC_APP_OWNER COMMENT = 'Owns the Streamlit app; masked PII, all regions';
GRANT ROLE VC_BI_READER  TO ROLE VC_APP_OWNER;   -- read ANALYTICS
GRANT ROLE VC_REGION_ALL TO ROLE VC_APP_OWNER;   -- row access: every region
GRANT ROLE VC_APP_OWNER  TO ROLE VC_ADMIN;
SET me = CURRENT_USER();
GRANT ROLE VC_APP_OWNER  TO USER IDENTIFIER($me);

-- Cortex Analyst over the semantic view
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE VC_APP_OWNER;
GRANT USAGE ON SCHEMA VIRTUAL_CARE_DEMO.SEMANTIC TO ROLE VC_APP_OWNER;
GRANT SELECT ON SEMANTIC VIEW VIRTUAL_CARE_DEMO.SEMANTIC.VIRTUAL_CARE_SV TO ROLE VC_APP_OWNER;

-- Governance tab shows the entitlements table
GRANT USAGE ON SCHEMA VIRTUAL_CARE_DEMO.GOVERNANCE TO ROLE VC_APP_OWNER;
GRANT SELECT ON TABLE VIRTUAL_CARE_DEMO.GOVERNANCE.REGION_ENTITLEMENTS TO ROLE VC_APP_OWNER;

-- Where the app lives
USE ROLE VC_ADMIN;
CREATE SCHEMA IF NOT EXISTS VIRTUAL_CARE_DEMO.APP COMMENT = 'Streamlit apps';
GRANT USAGE ON SCHEMA VIRTUAL_CARE_DEMO.APP TO ROLE VC_APP_OWNER;
GRANT CREATE STREAMLIT, CREATE STAGE ON SCHEMA VIRTUAL_CARE_DEMO.APP TO ROLE VC_APP_OWNER;

-- Quick check: as the app role, PII is masked and all three regions are visible
USE ROLE VC_APP_OWNER;
USE SECONDARY ROLES NONE;
USE WAREHOUSE VC_BI_WH;
SELECT member_region, COUNT(*) AS visits FROM VIRTUAL_CARE_DEMO.ANALYTICS.FACT_VISIT GROUP BY 1 ORDER BY 1;
SELECT first_name, email FROM VIRTUAL_CARE_DEMO.ANALYTICS.DIM_MEMBER LIMIT 3;
USE SECONDARY ROLES ALL;
