/* =============================================================================
   05_semantic_view.sql  -  Conversational AI foundation (Cortex Analyst)
   Run as VC_ADMIN.

   A semantic view is the governed business layer that Cortex Analyst (and a
   Snowflake Intelligence agent) uses to turn questions like
   "What was average wait time for dermatology in the West last quarter?" into SQL.
   It inherits the masking and row access policies on the underlying tables,
   so a West analyst asking a question still only gets West answers.

   The same metric definitions appear as DAX in powerbi/measures.dax. Keeping the
   two in step is the "one definition of a KPI" decision to make early.
   ============================================================================= */
USE ROLE VC_ADMIN;
USE WAREHOUSE VC_ELT_WH;
USE SCHEMA VIRTUAL_CARE_DEMO.SEMANTIC;

CREATE OR REPLACE SEMANTIC VIEW VIRTUAL_CARE_SV
  TABLES (
    visits AS VIRTUAL_CARE_DEMO.ANALYTICS.FACT_VISIT
      PRIMARY KEY (visit_id)
      WITH SYNONYMS = ('appointments', 'consults', 'encounters')
      COMMENT = 'One row per virtual visit request',
    surveys AS VIRTUAL_CARE_DEMO.ANALYTICS.FACT_SURVEY
      PRIMARY KEY (survey_id)
      COMMENT = 'Post-visit NPS and CSAT surveys',
    members AS VIRTUAL_CARE_DEMO.ANALYTICS.DIM_MEMBER
      PRIMARY KEY (member_id)
      WITH SYNONYMS = ('patients', 'users')
      COMMENT = 'Enrolled members (PII masked by policy)',
    providers AS VIRTUAL_CARE_DEMO.ANALYTICS.DIM_PROVIDER
      PRIMARY KEY (provider_id)
      WITH SYNONYMS = ('clinicians', 'doctors'),
    service_lines AS VIRTUAL_CARE_DEMO.ANALYTICS.DIM_SERVICE_LINE
      PRIMARY KEY (service_line_id)
      WITH SYNONYMS = ('specialty', 'program'),
    employers AS VIRTUAL_CARE_DEMO.ANALYTICS.DIM_EMPLOYER
      PRIMARY KEY (employer_id)
      WITH SYNONYMS = ('clients', 'accounts', 'groups')
  )
  RELATIONSHIPS (
    visits_to_members       AS visits (member_id)       REFERENCES members,
    visits_to_providers     AS visits (provider_id)     REFERENCES providers,
    visits_to_service_lines AS visits (service_line_id) REFERENCES service_lines,
    visits_to_employers     AS visits (employer_id)     REFERENCES employers,
    surveys_to_visits       AS surveys (visit_id)       REFERENCES visits
  )
  FACTS (
    visits.wait_minutes     AS wait_minutes     COMMENT = 'Minutes from request to provider join',
    visits.duration_minutes AS duration_minutes,
    visits.visit_cost       AS visit_cost,
    surveys.nps_score       AS nps_score
  )
  DIMENSIONS (
    visits.request_date       AS request_date      WITH SYNONYMS = ('visit date', 'date'),
    visits.request_month      AS DATE_TRUNC('month', request_date),
    visits.channel            AS channel           WITH SYNONYMS = ('modality'),
    visits.visit_status       AS visit_status,
    visits.diagnosis_category AS diagnosis_category WITH SYNONYMS = ('reason for visit', 'condition'),
    visits.member_region      AS member_region     WITH SYNONYMS = ('region'),
    members.age_band          AS age_band,
    members.plan_type         AS plan_type,
    members.member_state      AS member_state      WITH SYNONYMS = ('state'),
    providers.provider_name   AS provider_name,
    providers.specialty       AS specialty,
    service_lines.service_line_name AS service_line_name WITH SYNONYMS = ('service line'),
    service_lines.service_category  AS service_category,
    employers.employer_name   AS employer_name     WITH SYNONYMS = ('client name', 'employer'),
    employers.industry        AS industry
  )
  METRICS (
    visits.total_visits          AS COUNT(visit_id)                   COMMENT = 'All visit requests',
    visits.completed_visits      AS SUM(is_completed),
    visits.avg_wait_minutes      AS AVG(wait_minutes)                 WITH SYNONYMS = ('average wait', 'time to provider'),
    visits.first_contact_resolution_rate
                                 AS SUM(resolved_first_contact) / NULLIF(SUM(is_completed), 0)
                                 WITH SYNONYMS = ('FCR', 'resolution rate'),
    visits.er_avoidance_rate     AS 1 - SUM(er_followup_7d) / NULLIF(SUM(is_completed), 0),
    visits.no_show_rate          AS COUNT_IF(visit_status = 'No-Show') / NULLIF(COUNT(visit_id), 0),
    visits.total_visit_cost      AS SUM(visit_cost)                   WITH SYNONYMS = ('revenue', 'spend'),
    visits.unique_members        AS COUNT(DISTINCT member_id)         WITH SYNONYMS = ('utilizers'),
    surveys.nps                  AS (COUNT_IF(nps_score >= 9) - COUNT_IF(nps_score <= 6)) * 100
                                    / NULLIF(COUNT(survey_id), 0)
                                 WITH SYNONYMS = ('net promoter score')
  )
  COMMENT = 'Virtual care operations: access, quality, experience and utilization';

GRANT SELECT ON SEMANTIC VIEW VIRTUAL_CARE_SV TO ROLE VC_ANALYST;

-- Query it directly with SQL (same definitions Cortex Analyst will use):
SELECT * FROM SEMANTIC_VIEW(
  VIRTUAL_CARE_SV
  DIMENSIONS service_lines.service_line_name, visits.member_region
  METRICS visits.total_visits, visits.avg_wait_minutes, visits.first_contact_resolution_rate
)
ORDER BY total_visits DESC;

-- Next step for the conversational AI conversation: in Snowsight go to
-- AI & ML > Cortex Analyst, pick SEMANTIC.VIRTUAL_CARE_SV, and ask questions; or add
-- it as a tool on a Snowflake Intelligence agent. Sample questions are in docs/demo-script.md.
