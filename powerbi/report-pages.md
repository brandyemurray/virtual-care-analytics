# Report pages

Five pages, each answering one question for one audience. Canvas 16:9, theme `virtual-care-theme.json` (View → Themes → Browse for themes).

Every page shares a header strip: page title on the left, the `[Data Through]` measure in a card on the right, and slicers for **Year-Month** (`DIM_DATE[YEAR_MONTH]`, between), **Region** (`DIM_MEMBER[MEMBER_REGION]`) and **Service Line**. Sync the slicers across pages (View → Sync slicers).

---

## 1. Executive Overview: "How is virtual care performing?"
*Audience: VP of Clinical Operations, executive leadership*

| Visual | Fields |
|---|---|
| 6 KPI cards (new card visual, with reference label vs. PY) | Completed Visits, Unique Members, Avg Wait (min), First Contact Resolution %, NPS, Visit Revenue |
| Line chart | X `DIM_DATE[MONTH_START]`; Y Completed Visits and Completed Visits PY |
| Clustered bar | Y `DIM_SERVICE_LINE[SERVICE_LINE_NAME]`; X Completed Visits; tooltip Service Line Mix % |
| Donut | Legend `FACT_VISIT[CHANNEL]`; Values Completed Visits |
| Map (or filled map) | Location `DIM_MEMBER[MEMBER_STATE]`; Size Completed Visits |

**Story to tell:** volume is growing year over year, General Medical drives volume but Behavioral Health drives revenue, and most care is delivered by video.

## 2. Access & Wait Times: "Are members seen quickly?"
*Audience: Operations managers, staffing*

| Visual | Fields |
|---|---|
| Gauge | Value Avg Wait (min); Target Wait Target (min) |
| KPI card | Seen Within Target % |
| Line chart | X `MONTH_START`; Y Avg Wait (min) and Avg Wait Rolling 3M; constant line at 15 |
| Matrix heatmap | Rows `DIM_DATE[DAY_NAME]`; Columns `FACT_VISIT[REQUEST_HOUR]`; Values Avg Wait (min); conditional background color |
| Bar | Service line by No-Show Rate and Cancellation Rate |

Apply conditional formatting to the line color using `[Wait Status Color]` (fx → Field value).

**Story to tell:** waits spike in winter for General Medical (respiratory season), and the heatmap shows which hours need more provider coverage.

## 3. Clinical Quality & Outcomes: "Is the care effective?"
*Audience: Chief Medical Officer, quality team*

| Visual | Fields |
|---|---|
| 4 KPI cards | First Contact Resolution %, ER Avoidance %, Referral Rate, Prescription Rate |
| Matrix | Rows Service Line → Diagnosis Category (drill); Values Completed Visits, FCR %, Referral Rate, Prescription Rate |
| Scatter | Details `DIM_PROVIDER[PROVIDER_NAME]`; X Completed Visits; Y First Contact Resolution %; Legend `SPECIALTY` |
| Decomposition tree | Analyze ER Avoidance %; explain by Service Line, Channel, Age Band, Plan Type |

## 4. Employer Utilization: "Are employer customers getting value?"
*Audience: Account management, customer success*

| Visual | Fields |
|---|---|
| Table | `DIM_EMPLOYER[EMPLOYER_NAME]`, INDUSTRY, Eligible Lives, Completed Visits, Visits per 1K Lives (Annualized), NPS, Visit Revenue; data bars on utilization |
| Bar | Industry by Visits per 1K Lives (Annualized) |
| Line | Monthly Completed Visits for the employer selected in the table |
| Drillthrough page (optional) | Employer detail, drill through on `EMPLOYER_NAME` |

**Story to tell:** utilization per 1,000 lives is the renewal conversation; low-utilization employers are the engagement-campaign list.

## 5. Data Quality: "Can we trust these numbers?"
*Audience: Data engineering, data governance council*

| Visual | Fields |
|---|---|
| KPI card | DQ Pass Rate |
| Table | `DQ_SCORECARD`: ENTITY, DIMENSION, CHECK_NAME, FAILED_ROWS, TOTAL_ROWS, HANDLING, DQ Status (icon conditional formatting) |
| Bar | DIMENSION by DQ Failed Rows |
| Text box | "Checks run in Snowflake via Data Metric Functions; results in SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS. Bad rows are flagged and handled, never silently dropped." |

**Story to tell:** governance isn't a separate project; it shows up in the report as trust.

---

## Polish checklist
- Turn off visual-level "Show items with no data" unless needed; turn off auto date/time (File → Options → Data Load) since `DIM_DATE` is marked.
- Add alt text to each visual, and keep a tab order (View → Selection pane) for accessibility.
- Use **bookmarks** for an "About this report" overlay with definitions copied from the measure descriptions.
- Run **Performance analyzer** once and screenshot it for the repo: every visual under 500 ms on Import.
- Optionally enable Copilot / Q&A with synonyms on key fields (Modeling → Q&A setup), and compare the answers to Cortex Analyst on the same questions.
