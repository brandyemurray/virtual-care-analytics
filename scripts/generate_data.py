"""
Synthetic data generator for the Cascade Virtual Care analytics demo.

Everything here is fake. Names, emails, phone numbers and clinical details are
randomly generated and do not describe any real person, employer or company.

A handful of data-quality problems are planted on purpose (duplicate visits,
orphaned provider keys, negative durations, bad emails) so the Snowflake data
quality checks and the Power BI "Data Quality" page have something to find.

Usage:
    python scripts/generate_data.py            # writes CSVs to ./data
    python scripts/generate_data.py --seed 7   # different but reproducible run
"""
import argparse
import csv
import random
from datetime import date, datetime, timedelta
from pathlib import Path

FIRST = ["Avery", "Jordan", "Riley", "Morgan", "Casey", "Taylor", "Quinn", "Reese", "Jamie", "Rowan",
         "Elena", "Marcus", "Priya", "Diego", "Hannah", "Omar", "Grace", "Leo", "Nina", "Theo",
         "Isla", "Mateo", "Sofia", "Ethan", "Maya", "Noah", "Aria", "Lucas", "Zoe", "Caleb"]
LAST = ["Alder", "Brooks", "Castillo", "Dunn", "Ellis", "Foster", "Garza", "Hayes", "Ibarra", "Jensen",
        "Kim", "Lowe", "Mendez", "Nash", "Ortiz", "Patel", "Quigley", "Reyes", "Shah", "Tran",
        "Underwood", "Vance", "Walsh", "Xu", "Young", "Zimmer"]
STATES = {"West": ["CA", "WA", "OR", "CO", "AZ", "MT", "UT"],
          "Central": ["TX", "IL", "MN", "MO", "OH", "MI"],
          "East": ["NY", "NJ", "PA", "MA", "FL", "GA", "NC", "VA"]}
INDUSTRIES = ["Manufacturing", "Retail", "Financial Services", "Technology", "Public Sector",
              "Education", "Hospitality", "Logistics"]
PLAN_TYPES = ["PPO", "HMO", "HDHP", "Medicare Advantage"]

SERVICE_LINES = [
    # id, name, category, base_cost, avg_duration_min, share
    (1, "General Medical", "Urgent & Primary", 79.0, 14, 0.42),
    (2, "Mental Health - Therapy", "Behavioral Health", 129.0, 50, 0.16),
    (3, "Mental Health - Psychiatry", "Behavioral Health", 249.0, 30, 0.06),
    (4, "Dermatology", "Specialty", 95.0, 12, 0.09),
    (5, "Nutrition", "Wellness", 69.0, 30, 0.07),
    (6, "Chronic Care - Diabetes", "Chronic Condition", 110.0, 25, 0.11),
    (7, "Chronic Care - Hypertension", "Chronic Condition", 105.0, 20, 0.09),
]
SPECIALTY_FOR_LINE = {1: "Family Medicine", 2: "Licensed Therapist", 3: "Psychiatry",
                      4: "Dermatology", 5: "Registered Dietitian", 6: "Endocrinology", 7: "Internal Medicine"}
DIAG = {1: ["Upper respiratory infection", "Sinusitis", "UTI", "Allergic rhinitis", "Pink eye", "Flu-like illness"],
        2: ["Anxiety", "Depression", "Stress / adjustment", "Grief"],
        3: ["Medication management - depression", "Medication management - ADHD", "Medication management - anxiety"],
        4: ["Acne", "Eczema", "Rash", "Psoriasis"],
        5: ["Weight management", "Prediabetes coaching", "Heart-healthy diet"],
        6: ["Type 2 diabetes follow-up", "A1c review"],
        7: ["Blood pressure follow-up", "Medication adjustment - BP"]}
CHANNELS = [("Video", 0.62), ("Phone", 0.23), ("App Messaging", 0.15)]

START = date(2025, 1, 1)
END = date(2026, 10, 31)


def wchoice(pairs):
    items, weights = zip(*pairs)
    return random.choices(items, weights=weights, k=1)[0]


def rand_date(a, b):
    return a + timedelta(days=random.randint(0, (b - a).days))


def write(path, header, rows):
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(header)
        w.writerows(rows)
    print(f"  {path.name:<28} {len(rows):>7,} rows")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--members", type=int, default=6000)
    ap.add_argument("--visits", type=int, default=45000)
    ap.add_argument("--out", default=str(Path(__file__).resolve().parent.parent / "data"))
    args = ap.parse_args()
    random.seed(args.seed)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    print(f"Writing synthetic data to {out}")

    # ---- employers -------------------------------------------------------
    prefixes = ["Summit", "Bluewater", "Ironwood", "Prairie", "Harbor", "Granite", "Juniper", "Northstar",
                "Redtail", "Silverline", "Timber", "Clearview", "Evergreen", "Lakeside", "Pinecrest",
                "Ridgeway", "Sagebrush", "Copper", "Meadow", "Cobalt", "Falcon", "Willow", "Aspen", "Beacon"]
    suffixes = ["Manufacturing", "Logistics", "Financial", "Retail Group", "Health Partners", "Schools",
                "Systems", "Hospitality", "Foods", "County"]
    employers = []
    for i, p in enumerate(prefixes, start=1):
        region = random.choice(list(STATES))
        employers.append([
            f"E{i:03d}", f"{p} {random.choice(suffixes)}", random.choice(INDUSTRIES), region,
            random.choice(STATES[region]), rand_date(date(2019, 1, 1), date(2025, 6, 1)).isoformat(),
            random.choice([1500, 3000, 5000, 8000, 12000]),  # eligible lives
            random.choice(["PEPM", "Per Visit", "Hybrid"]),
        ])
    write(out / "employers.csv",
          ["employer_id", "employer_name", "industry", "region", "hq_state", "contract_start_date",
           "eligible_lives", "pricing_model"], employers)

    # ---- members (contains synthetic PII on purpose, for masking demos) --
    members = []
    for i in range(1, args.members + 1):
        emp = random.choice(employers)
        region = emp[3] if random.random() < 0.8 else random.choice(list(STATES))
        fn, ln = random.choice(FIRST), random.choice(LAST)
        dob = rand_date(date(1946, 1, 1), date(2006, 12, 31))
        email = f"{fn.lower()}.{ln.lower()}{i}@example.com"
        if random.random() < 0.004:  # planted DQ: malformed email
            email = email.replace("@", "")
        members.append([
            f"M{i:06d}", fn, ln, dob.isoformat(), random.choice(["F", "M", "X"]) if random.random() > 0.02 else "",
            email, f"555-{random.randint(100, 999)}-{random.randint(1000, 9999)}",
            random.choice(STATES[region]), region, emp[0],
            "Medicare Advantage" if dob.year < 1960 and random.random() < 0.6 else random.choice(PLAN_TYPES[:3]),
            rand_date(date(2023, 1, 1), date(2026, 6, 30)).isoformat(),
        ])
    write(out / "members.csv",
          ["member_id", "first_name", "last_name", "date_of_birth", "gender", "email", "phone",
           "state", "region", "employer_id", "plan_type", "enrollment_date"], members)

    # ---- service lines ---------------------------------------------------
    write(out / "service_lines.csv",
          ["service_line_id", "service_line_name", "service_category", "list_price", "target_duration_min"],
          [[s[0], s[1], s[2], s[3], s[4]] for s in SERVICE_LINES])

    # ---- providers -------------------------------------------------------
    providers, by_line = [], {}
    pid = 0
    for sl in SERVICE_LINES:
        n = max(4, int(110 * sl[5]))
        for _ in range(n):
            pid += 1
            region = random.choice(list(STATES))
            row = [f"P{pid:04d}", f"Dr. {random.choice(FIRST)} {random.choice(LAST)}"
                   if sl[0] not in (2, 5) else f"{random.choice(FIRST)} {random.choice(LAST)}",
                   SPECIALTY_FOR_LINE[sl[0]], sl[0], random.choice(STATES[region]), region,
                   rand_date(date(2016, 1, 1), date(2026, 3, 1)).isoformat(),
                   random.choice(["Employed", "Contracted"])]
            providers.append(row)
            by_line.setdefault(sl[0], []).append(row)
    write(out / "providers.csv",
          ["provider_id", "provider_name", "specialty", "primary_service_line_id", "license_state",
           "region", "start_date", "employment_type"], providers)

    # ---- visits ----------------------------------------------------------
    visits, surveys = [], []
    sl_weights = [(s, s[5]) for s in SERVICE_LINES]
    member_ids = [m[0] for m in members]
    heavy_users = set(random.sample(member_ids, k=len(member_ids) // 8))
    total_days = (END - START).days
    for v in range(1, args.visits + 1):
        sl = wchoice(sl_weights)
        mid = random.choice(list(heavy_users)) if random.random() < 0.35 else random.choice(member_ids)
        # growth over time + winter respiratory bump for General Medical
        d = START + timedelta(days=int(total_days * (random.random() ** 0.8)))
        if sl[0] == 1 and d.month in (5, 6, 7, 8) and random.random() < 0.3:
            d = d.replace(month=random.choice([1, 2, 12]), day=min(d.day, 28))
            d = min(d, END)
        req = datetime.combine(d, datetime.min.time()) + timedelta(minutes=random.randint(6 * 60, 23 * 60))
        channel = wchoice(CHANNELS)
        scheduled = sl[0] in (2, 3, 5, 6, 7)
        wait = (random.randint(5, 30) if scheduled else
                max(1, int(random.gammavariate(2.2, 9 if d.month in (1, 2, 12) else 6))))
        status = wchoice([("Completed", 0.88), ("Cancelled", 0.07), ("No-Show", 0.05)])
        prov = random.choice(by_line[sl[0]])
        start = req + timedelta(minutes=wait) if status == "Completed" else None
        dur = max(3, int(random.gauss(sl[4], sl[4] * 0.25))) if status == "Completed" else None
        end = start + timedelta(minutes=dur) if start else None
        rx = status == "Completed" and random.random() < (0.55 if sl[0] in (1, 3, 4, 6, 7) else 0.05)
        referral = status == "Completed" and random.random() < (0.08 if sl[0] == 1 else 0.03)
        resolved = status == "Completed" and not referral and random.random() < 0.91
        followup_er = status == "Completed" and random.random() < 0.012
        cost = round(sl[3] * random.uniform(0.92, 1.08), 2) if status == "Completed" else 0.0
        provider_id = prov[0]
        # planted DQ issues
        if random.random() < 0.002:
            provider_id = "P9999"           # orphan key
        if dur and random.random() < 0.001:
            dur = -dur                       # impossible duration
        row = [f"V{v:07d}", mid, provider_id, sl[0], channel, random.choice(DIAG[sl[0]]),
               req.isoformat(sep=" "), start.isoformat(sep=" ") if start else "",
               end.isoformat(sep=" ") if end else "", wait if status == "Completed" else "",
               dur if dur is not None else "", status, int(resolved), int(referral), int(rx),
               int(followup_er), cost]
        visits.append(row)
        if status == "Completed" and random.random() < 0.38:
            base = 9 if wait < 15 else (8 if wait < 30 else 6)
            nps = max(0, min(10, int(random.gauss(base, 1.6))))
            surveys.append([f"S{len(surveys)+1:07d}", row[0], (end + timedelta(hours=random.randint(1, 48))).date().isoformat(),
                            nps, max(1, min(5, round(nps / 2))),
                            random.choice(["", "", "", "Quick and easy", "Provider was great", "Long wait",
                                           "Video kept freezing", "Got my prescription fast", "Felt heard"])])
    # planted DQ: exact duplicate rows
    for row in random.sample(visits, 40):
        visits.append(list(row))
    write(out / "visits.csv",
          ["visit_id", "member_id", "provider_id", "service_line_id", "channel", "diagnosis_category",
           "requested_at", "started_at", "ended_at", "wait_minutes", "duration_minutes", "visit_status",
           "resolved_first_contact", "referral_flag", "prescription_flag", "er_followup_7d", "visit_cost"],
          visits)
    write(out / "surveys.csv",
          ["survey_id", "visit_id", "survey_date", "nps_score", "csat_score", "comment"], surveys)
    print("Done.")


if __name__ == "__main__":
    main()
