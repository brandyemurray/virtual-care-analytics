# Architecture

```mermaid
flowchart LR
    subgraph SRC["Source extracts (synthetic)"]
        CSV["6 CSV files<br/>members, employers, providers,<br/>service lines, visits, surveys"]
    end

    subgraph SF["Snowflake · VIRTUAL_CARE_DEMO"]
        STG_L["@RAW.LANDING<br/>internal stage"]
        RAW["RAW<br/>all-text tables + file lineage"]
        STG["STAGING<br/>typed · deduplicated · DQ-flagged views"]
        AN["ANALYTICS<br/>star schema: 2 facts, 5 dims<br/>+ DQ_SCORECARD"]
        SEM["SEMANTIC<br/>VIRTUAL_CARE_SV"]
        GOV["GOVERNANCE<br/>tags · masking · row access ·<br/>entitlements · data metric functions"]
    end

    subgraph BI["Power BI"]
        PBI["Import semantic model<br/>measures.dax · RLS optional"]
        RPT["Report: 5 pages"]
    end

    CORTEX["Cortex Analyst /<br/>Snowflake Intelligence"]

    CSV --> STG_L --> RAW --> STG --> AN
    AN --> SEM --> CORTEX
    AN -- "key-pair service user<br/>VC_PBI_SERVICE · VC_BI_WH" --> PBI --> RPT
    GOV -. "policies applied to" .-> RAW
    GOV -. "policies applied to" .-> AN
```

## Design decisions

| Decision | Why |
|---|---|
| RAW stores everything as text | A bad value never fails a load; it's flagged in STAGING instead, so nothing is lost silently |
| STAGING is views, ANALYTICS is tables | Staging always reflects the latest load; BI reads pre-built tables for speed and predictable cost |
| Flag, don't drop | Duplicates are deduplicated, orphan keys map to `P-UNKNOWN`, impossible values become NULL, and every case is counted in `DQ_SCORECARD` |
| Tag-based masking | Policy follows the classification. Tag a column and it's protected; no per-column policy sprawl |
| Entitlements in a table | Row access changes are data changes (INSERT), reviewable and auditable, not code changes |
| Deny by default | A role with no region entitlement sees zero rows |
| PII never imported to Power BI | The strongest control is not moving the data at all |
| Separate ELT and BI warehouses + resource monitor | Workload isolation and cost visibility per consumer |
| Key-pair service user | Snowflake is retiring password-only sign-in; Entra SSO is the per-user alternative |
| One KPI definition in two places (semantic view + DAX) | Called out explicitly so the team decides early where metric definitions are owned |

## Role hierarchy

```mermaid
flowchart TB
    SYSADMIN --> VC_ADMIN
    VC_ADMIN --> VC_ENGINEER
    VC_ADMIN --> VC_PHI_READER
    VC_ADMIN --> VC_PBI_SERVICE
    VC_ADMIN --> VC_WEST_ANALYST
    VC_ENGINEER --> VC_ANALYST
    VC_PHI_READER --> VC_ANALYST
    VC_ANALYST --> VC_BI_READER
    VC_PBI_SERVICE --> VC_BI_READER
    VC_PBI_SERVICE --> VC_REGION_ALL
    VC_WEST_ANALYST --> VC_ANALYST
    VC_WEST_ANALYST --> VC_REGION_WEST
```

`VC_PHI_READER` sees unmasked PII. Region roles (`VC_REGION_*`) carry row entitlements only; they grant no object access on their own.
