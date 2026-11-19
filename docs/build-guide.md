# Build guide: zero to working demo

About 2–3 hours end to end. Windows is required for Power BI Desktop.

## Step 1. Get the accounts (15 min)

**Snowflake trial**
1. Sign up at signup.snowflake.com (no credit card needed).
2. Choose **Enterprise** edition (masking, row access and data metric functions need it), plus a cloud and region near you. These can't be changed later.
3. You get 30 days or $400 of credits, whichever runs out first. The scripts use X-Small warehouses that suspend after 60 seconds and a resource monitor capped at 20 credits, so the whole build costs a few dollars.

**Power BI**
1. Install **Power BI Desktop** from the Microsoft Store (free, no license needed to build).
2. Optional: to publish and share, sign in to app.powerbi.com with a work or school account and start the 60-day Pro trial.

## Step 2. Generate the data (2 min)

The CSVs are already in `data/`. To regenerate or make a bigger set:

```bash
python scripts/generate_data.py                 # default: 6,000 members, ~45K visits
python scripts/generate_data.py --visits 200000 # bigger fact for a DirectQuery test
```

## Step 3. Build Snowflake (30 min)

In Snowsight, open a SQL worksheet for each file and run them in order (Run All, Ctrl+Shift+Enter):

| # | Script | Run as | What you should see |
|---|---|---|---|
| 1 | `snowflake/00_setup.sql` | ACCOUNTADMIN | Roles, two warehouses, database with 5 schemas, `PBI_SVC` user |
| 2 | Upload the six CSVs from `data/` to `RAW.LANDING` (Snowsight: Catalog → Database Explorer → VIRTUAL_CARE_DEMO → RAW → Stages → LANDING → **+ Files**). The stage is created at the end of `00_setup.sql` | | Six files listed in the stage |
| 3 | `snowflake/01_raw_load.sql` | VC_ADMIN | Row counts: 24 / 6,000 / 7 / 106 / 45,040 / ~15,000 |
| 4 | `snowflake/02_staging.sql` | VC_ADMIN | Six views |
| 5 | `snowflake/03_analytics.sql` | VC_ADMIN | Star schema; final query shows ~39.7K completed visits |
| 6 | `snowflake/04_governance.sql` | VC_ADMIN, switches to ACCOUNTADMIN for roles | Tags, policies, DMFs, `DQ_SCORECARD` |
| 7 | `snowflake/05_semantic_view.sql` | VC_ADMIN | Semantic view and a sample query |
| 8 | `snowflake/06_validate_governance.sql` | Various | Masked vs. unmasked, West-only vs. all regions |

To start over, run `99_teardown.sql`, then begin again at step 1. Scripts 03 and 04 are not safe to rerun on their own (replacing a table removes its policies).

**Key pair for Power BI** (Git Bash or WSL on your laptop):

```bash
openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -out pbi_rsa_key.p8 -nocrypt
openssl rsa -in pbi_rsa_key.p8 -pubout -out pbi_rsa_key.pub
```

Paste the contents of `pbi_rsa_key.pub` (without the BEGIN/END lines) into:

```sql
USE ROLE ACCOUNTADMIN;
ALTER USER PBI_SVC SET RSA_PUBLIC_KEY = 'MIIBIjANBgkqh...';
```

Keep `pbi_rsa_key.p8` out of the repo (`.gitignore` already blocks `*.p8`).

## Step 4. Build Power BI (60–90 min)

1. **Get Data → Snowflake.** Server = your account URL without `https://`, Warehouse `VC_BI_WH`, Advanced → Role `VC_PBI_SERVICE`. Choose **Import**. Sign in with **Key pair**: user `PBI_SVC`, upload the `.p8`.
2. Select the eight objects in `ANALYTICS` (see `powerbi/model-design.md`), click **Transform Data**, and remove the PII and timestamp columns listed there.
3. **Close & Apply.** In Model view, check the relationships against the design doc. Mark `DIM_DATE` as the date table.
4. **DAX query view →** paste `powerbi/measures.dax` → **Run** → **Update model with changes.** Set formats and display folders.
5. **View → Themes → Browse** → `powerbi/virtual-care-theme.json`.
6. Build the five pages in `powerbi/report-pages.md`. Start with Executive Overview; it's the one you'll show first.
7. **File → Save as → Power BI project (.pbip).** This saves the model and report as text files (TMDL and JSON) you can commit to Git and diff, which is the modern source-control pattern. Put the project in `powerbi/pbip/`. Also keep a `.pbix` copy for easy sharing.
8. **Publish** to My workspace (or a trial workspace), then set the semantic model's data source credentials to key pair and schedule a daily refresh.

## Step 5. Try conversational AI (10 min, optional)

Snowsight → **AI & ML → Cortex Analyst** → choose `SEMANTIC.VIRTUAL_CARE_SV` and ask the questions in `docs/demo-script.md`. Trial accounts limit Cortex usage to a small daily allowance, which is plenty for a few questions.

## Step 6. Commit and push

```bash
git add .
git commit -m "Add Power BI project"
git push
```

Take a few screenshots of each report page and the governance tests and put them in `docs/screenshots/`. The README links to them, and they're what people will actually look at.
