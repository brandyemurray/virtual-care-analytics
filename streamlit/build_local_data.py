"""Builds the local copy of the ANALYTICS layer used when the app runs outside Snowflake
(local testing and the public Streamlit Community Cloud version).

It mirrors snowflake/02_staging.sql and 03_analytics.sql, and applies the same masking
rules the Snowflake policies apply for a non-PHI role, so the public app never holds
unmasked personal data.

Usage (from the repo root):  python streamlit/build_local_data.py
"""
from pathlib import Path
import re
import pandas as pd

ROOT = Path(__file__).resolve().parent.parent
SRC, OUT = ROOT / "data", Path(__file__).resolve().parent / "data"
OUT.mkdir(exist_ok=True)

raw = {n: pd.read_csv(SRC / f"{n}.csv") for n in
       ["employers", "members", "providers", "service_lines", "visits", "surveys"]}

# ---- staging: dedupe, flag ------------------------------------------------
v = raw["visits"].copy()
v["dq_duplicate_in_source"] = v.duplicated("visit_id", keep=False).astype(int)
v = v.drop_duplicates("visit_id")
known = set(raw["providers"].provider_id)
v["dq_orphan_provider"] = (~v.provider_id.isin(known)).astype(int)
v["dq_negative_duration"] = (v.duration_minutes < 0).astype(int)
v["dq_completed_without_start"] = ((v.visit_status == "Completed") & v.started_at.isna()).astype(int)

m = raw["members"].copy()
email_ok = m.email.str.lower().str.match(r"^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$", na=False)
m["dq_bad_email"] = (~email_ok).astype(int)
m["dq_missing_gender"] = m.gender.isna().astype(int)

# ---- analytics: dimensions ------------------------------------------------
dob = pd.to_datetime(m.date_of_birth)
age = 2026 - dob.dt.year
bands = pd.cut(age, [0, 25, 35, 45, 55, 65, 200], labels=["18-25", "26-35", "36-45", "46-55", "56-65", "66+"])

def mask_email(e):  # same rule as MASK_PII_STRING for EMAIL
    return re.sub(r"^[^@]+", "*****", str(e))

dim_member = pd.DataFrame({
    "member_id": m.member_id,
    "first_name": "*** MASKED ***",
    "last_name": "*** MASKED ***",
    "date_of_birth": dob.dt.year.astype(str) + "-01-01",          # MASK_PII_DATE: year only
    "email": m.email.map(mask_email),
    "phone": "***-***-" + m.phone.str[-4:],
    "age": age, "age_band": bands.astype(str),
    "gender": m.gender.fillna("Unknown"),
    "member_state": m.state, "member_region": m.region,
    "employer_id": m.employer_id, "plan_type": m.plan_type,
    "dq_bad_email": m.dq_bad_email, "dq_missing_gender": m.dq_missing_gender,
})

dim_provider = raw["providers"].rename(columns={"region": "provider_region"})
dim_provider = pd.concat([dim_provider, pd.DataFrame([{
    "provider_id": "P-UNKNOWN", "provider_name": "Unknown provider", "specialty": "Unknown",
    "provider_region": "Unknown", "employment_type": "Unknown"}])], ignore_index=True)
dim_service_line = raw["service_lines"]
dim_employer = raw["employers"].rename(columns={"region": "employer_region"})

# ---- analytics: facts -----------------------------------------------------
req = pd.to_datetime(v.requested_at)
fact_visit = pd.DataFrame({
    "visit_id": v.visit_id, "member_id": v.member_id,
    "provider_id": v.provider_id.where(v.dq_orphan_provider == 0, "P-UNKNOWN"),
    "service_line_id": v.service_line_id,
}).merge(m[["member_id", "employer_id", "region"]].rename(columns={"region": "member_region"}),
         on="member_id", how="left")
fact_visit["request_date"] = req.dt.date.values
fact_visit["request_hour"] = req.dt.hour.values
for c in ["channel", "diagnosis_category", "visit_status", "wait_minutes", "resolved_first_contact",
          "referral_flag", "prescription_flag", "er_followup_7d", "visit_cost",
          "dq_duplicate_in_source", "dq_orphan_provider", "dq_negative_duration", "dq_completed_without_start"]:
    fact_visit[c] = v[c].values
fact_visit["is_completed"] = (fact_visit.visit_status == "Completed").astype(int)
fact_visit["duration_minutes"] = v.duration_minutes.where(v.duration_minutes >= 0).values
fact_visit["request_date"] = pd.to_datetime(fact_visit.request_date)

s = raw["surveys"].drop_duplicates("survey_id").merge(
    fact_visit[["visit_id", "member_id", "member_region", "employer_id", "service_line_id", "provider_id", "channel"]],
    on="visit_id")
s["survey_date"] = pd.to_datetime(s.survey_date)
s["nps_bucket"] = pd.cut(s.nps_score, [-1, 6, 8, 10], labels=["Detractor", "Passive", "Promoter"]).astype(str)
fact_survey = s

# ---- governance ------------------------------------------------------------
dq = pd.DataFrame([
    ("Visits", "Uniqueness", "Duplicate visit rows in source", len(raw["visits"]) - len(v), len(raw["visits"]), "Deduplicated in STAGING"),
    ("Visits", "Referential integrity", "Visit references unknown provider", int(v.dq_orphan_provider.sum()), len(v), "Mapped to P-UNKNOWN"),
    ("Visits", "Validity", "Negative visit duration", int(v.dq_negative_duration.sum()), len(v), "Set to NULL in ANALYTICS"),
    ("Visits", "Completeness", "Completed visit missing start time", int(v.dq_completed_without_start.sum()), len(v), "Flagged"),
    ("Members", "Validity", "Malformed email address", int(m.dq_bad_email.sum()), len(m), "Flagged for source fix"),
    ("Members", "Completeness", "Missing gender", int(m.dq_missing_gender.sum()), len(m), "Shown as Unknown"),
], columns=["entity", "dimension", "check_name", "failed_rows", "total_rows", "handling"])
ent = pd.DataFrame({"role_name": ["VC_REGION_ALL", "VC_REGION_WEST", "VC_REGION_CENTRAL", "VC_REGION_EAST"],
                    "region": ["ALL", "West", "Central", "East"]})

for name, df in {"fact_visit": fact_visit, "fact_survey": fact_survey, "dim_member": dim_member,
                 "dim_provider": dim_provider, "dim_service_line": dim_service_line,
                 "dim_employer": dim_employer, "dq_scorecard": dq, "region_entitlements": ent}.items():
    df.to_parquet(OUT / f"{name}.parquet", index=False)
    print(f"{name:<20}{len(df):>8,}")
