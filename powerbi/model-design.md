# Power BI semantic model design

The model is a star schema over `VIRTUAL_CARE_DEMO.ANALYTICS`. Snowflake does the heavy lifting (cleansing, deduplication, governance); Power BI holds business logic that belongs to reporting (measures, time intelligence, formatting).

## Connection

**Get Data → Snowflake**

| Setting | Value |
|---|---|
| Server | `<account_identifier>.snowflakecomputing.com` (Snowsight → your name → Account → copy the account URL) |
| Warehouse | `VC_BI_WH` |
| Role (Advanced options) | `VC_PBI_SERVICE` |
| Sign-in | **Key pair**, user `PBI_SVC`, upload `pbi_rsa_key.p8` |
| Data connectivity mode | **Import** (see storage mode below) |

Snowflake is phasing out password-only sign-in, so the demo uses a key-pair service user. In a production tenant the preferred option is **Microsoft Entra ID SSO**, which passes each viewer's identity to Snowflake so the row access and masking policies apply per person. Note that Entra SSO only works with DirectQuery.

The generated Power Query uses the newer ADBC driver:

```powerquery
let
    Source = Snowflake.Databases("xy12345.us-east-1.snowflakecomputing.com", "VC_BI_WH",
                                 [Role = "VC_PBI_SERVICE", Implementation = "2.0"]),
    DB = Source{[Name = "VIRTUAL_CARE_DEMO", Kind = "Database"]}[Data],
    Schema = DB{[Name = "ANALYTICS", Kind = "Schema"]}[Data],
    FACT_VISIT = Schema{[Name = "FACT_VISIT", Kind = "Table"]}[Data]
in
    FACT_VISIT
```

## Tables to load

| Table | Storage | Notes |
|---|---|---|
| `FACT_VISIT` | Import | Drop `REQUESTED_AT`, `STARTED_AT`, `ENDED_AT` (high-cardinality timestamps bloat the model; the date and hour columns cover reporting) and the `DQ_*` flags |
| `FACT_SURVEY` | Import | Drop `COMMENT` unless you build a text page |
| `DIM_DATE` | Import | **Mark as date table** on `DATE_DAY`; sort `MONTH_SHORT` by `MONTH_NUM`, `DAY_NAME` by `DAY_OF_WEEK_NUM` |
| `DIM_MEMBER` | Import | **Do not load** `FIRST_NAME`, `LAST_NAME`, `EMAIL`, `PHONE`, `DATE_OF_BIRTH`. A report never needs them, and leaving them out is the strongest PII control there is |
| `DIM_PROVIDER` | Import | |
| `DIM_SERVICE_LINE` | Import | |
| `DIM_EMPLOYER` | Import | |
| `DQ_SCORECARD` | Import | Disconnected table for the Data Quality page |

**Why Import:** about 45K visits fits easily in memory, gives the fastest visuals, and keeps warehouse credits near zero (one refresh, not a query per click). For larger facts the pattern is a **composite model**: dimensions in Dual mode, the fact in DirectQuery or an aggregation table in Import. The decision is made per table, not per report.

## Relationships (all single direction, many-to-one)

```
FACT_VISIT[REQUEST_DATE]     → DIM_DATE[DATE_DAY]
FACT_VISIT[MEMBER_ID]        → DIM_MEMBER[MEMBER_ID]
FACT_VISIT[PROVIDER_ID]      → DIM_PROVIDER[PROVIDER_ID]
FACT_VISIT[SERVICE_LINE_ID]  → DIM_SERVICE_LINE[SERVICE_LINE_ID]
FACT_VISIT[EMPLOYER_ID]      → DIM_EMPLOYER[EMPLOYER_ID]

FACT_SURVEY[SURVEY_DATE]     → DIM_DATE[DATE_DAY]
FACT_SURVEY[MEMBER_ID]       → DIM_MEMBER[MEMBER_ID]
FACT_SURVEY[PROVIDER_ID]     → DIM_PROVIDER[PROVIDER_ID]
FACT_SURVEY[SERVICE_LINE_ID] → DIM_SERVICE_LINE[SERVICE_LINE_ID]
FACT_SURVEY[EMPLOYER_ID]     → DIM_EMPLOYER[EMPLOYER_ID]
```

Power BI may auto-detect some of these from the Snowflake key constraints. Check that none are bidirectional and that there is no direct `FACT_VISIT` ↔ `FACT_SURVEY` relationship; the two facts share dimensions instead.

## Measures

Load them all at once from `measures.dax` (DAX query view → Run → Update model with changes). Then set formats and folders:

| Display folder | Measures | Format |
|---|---|---|
| Volume | Total Visits, Completed Visits, Unique Members, Completed Visits PY / PM / YTD | `#,0` |
| Volume | Visits per Member | `0.00` |
| Volume | Repeat Member %, Service Line Mix %, Completed Visits YoY % / MoM % | `0.0%` |
| Access | Avg Wait (min), Median Wait (min), Avg Visit Length (min), Avg Wait Rolling 3M, Wait Target (min) | `0.0` |
| Access | Seen Within Target %, No-Show Rate, Cancellation Rate | `0.0%` |
| Quality | First Contact Resolution %, Referral Rate, Prescription Rate, ER Avoidance % | `0.0%` |
| Financial | Visit Revenue, Revenue per Visit | `$#,0` |
| Financial | Visits per 1K Lives (Annualized), Eligible Lives | `#,0` |
| Experience | NPS | `0` |
| Experience | Avg CSAT | `0.00` |
| Experience | Survey Response Rate | `0.0%` |
| Data Quality | DQ Failed Rows | `#,0` |
| Data Quality | DQ Pass Rate | `0.00%` |

Hide the helper measures (`First Data Date`, `Last Data Date`, `Months in Period`, `Wait Status Color`) and all key columns (`*_ID` on facts) from report view.

## Security: two layers, and why both

1. **Snowflake (source of truth).** Masking and row access policies live with the data, so they apply in Power BI, Cortex Analyst, a notebook, or anywhere else. The Power BI service role is entitled to all regions here.
2. **Power BI RLS (presentation).** Because the Import model connects as one service identity, add Power BI roles if report viewers need regional filtering. Modeling → Manage roles → new role `West` with the DAX filter on `DIM_MEMBER`:

   ```
   [MEMBER_REGION] = "West"
   ```

   For a scalable version, load `GOVERNANCE.REGION_ENTITLEMENTS` mapped to user emails and filter on `USERPRINCIPALNAME()`, so Snowflake stays the single place entitlements are managed.

Alternatively, Entra SSO with DirectQuery removes the second layer entirely, because each viewer queries Snowflake as themselves. That trade-off (simplicity and governance vs. speed and cost) is a key architecture decision.

## Refresh

Publish to a workspace → semantic model settings → data source credentials (key pair) → schedule refresh daily after the ELT run. No gateway is needed for Snowflake as a cloud source.
