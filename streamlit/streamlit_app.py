"""Cascade Virtual Care: operations app.

Runs two ways from the same file:
  * Streamlit in Snowflake: reads the governed ANALYTICS tables and uses Cortex Analyst
    over SEMANTIC.VIRTUAL_CARE_SV for the "Ask the data" tab. Masking and row access
    policies apply to the app's owner role, so the app only ever sees masked PII.
  * Anywhere else (local, Streamlit Community Cloud): reads a local, pre-masked copy of
    the same tables from ./data (built by build_local_data.py) with DuckDB.

All data is synthetic.
"""
import json
from datetime import date
from pathlib import Path

import altair as alt
import pandas as pd
import streamlit as st

st.set_page_config(page_title="Cascade Virtual Care", page_icon="🩺", layout="wide")

# ---------------------------------------------------------------- connection
try:
    from snowflake.snowpark.context import get_active_session
    SESSION = get_active_session()
except Exception:
    SESSION = None
IN_SNOWFLAKE = SESSION is not None

DB = "VIRTUAL_CARE_DEMO"
SEMANTIC_VIEW = f"{DB}.SEMANTIC.VIRTUAL_CARE_SV"
TABLES = ["fact_visit", "fact_survey", "dim_member", "dim_provider", "dim_service_line",
          "dim_employer", "dq_scorecard", "region_entitlements"]
if IN_SNOWFLAKE:
    T = {t: f"{DB}.{'GOVERNANCE' if t == 'region_entitlements' else 'ANALYTICS'}.{t.upper()}" for t in TABLES}
else:
    T = {t: t for t in TABLES}


@st.cache_resource
def duck():
    import duckdb
    con = duckdb.connect()
    data = Path(__file__).resolve().parent / "data"
    for t in TABLES:
        con.execute(f"CREATE VIEW {t} AS SELECT * FROM read_parquet('{(data / f'{t}.parquet').as_posix()}')")
    return con


@st.cache_data(ttl=600, show_spinner=False)
def run(sql: str) -> pd.DataFrame:
    """Run portable SQL (works in Snowflake and DuckDB). Columns come back upper case."""
    sql = sql.format(**T)
    df = SESSION.sql(sql).to_pandas() if IN_SNOWFLAKE else duck().execute(sql).df()
    df.columns = [c.upper() for c in df.columns]
    for c in df.columns:  # show midnight timestamps as plain dates
        if pd.api.types.is_datetime64_any_dtype(df[c]) and (df[c].dropna().dt.normalize() == df[c].dropna()).all():
            df[c] = df[c].dt.date
    return df


def sql_str(v: str) -> str:
    return "'" + str(v).replace("'", "''") + "'"


# ---------------------------------------------------------------- style
TEAL, CORAL, GRAY, INK, MUTED = "#00809A", "#D9534F", "#9CA3AF", "#1F2937", "#6B7280"
st.markdown(f"""
<style>
  .block-container {{ padding-top: 1.6rem; max-width: 1280px; }}
  h1, h2, h3 {{ color: #173F49; letter-spacing: -0.01em; }}
  [data-testid="stMetric"] {{ background: #FFFFFF; border: 1px solid #DCEAE7; border-left: 4px solid {CORAL};
                              border-radius: 10px; padding: 12px 16px; }}
  [data-testid="stMetricLabel"] p {{ color: {MUTED}; font-weight: 600; }}
  .note {{ color: {MUTED}; font-size: 0.92rem; }}
  [data-baseweb="tag"] {{ background-color: {TEAL} !important; }}
  .pill {{ display:inline-block; background:#DCEAE7; color:#173F49; border-radius:999px; padding:2px 10px;
           font-size:0.8rem; font-weight:600; margin-left:6px; }}
</style>
""", unsafe_allow_html=True)


def show_chart(chart):
    try:
        st.altair_chart(chart, use_container_width=True)
    except TypeError:
        st.altair_chart(chart)


def base(chart):
    return chart.configure_view(strokeWidth=0).configure_axis(
        labelColor=MUTED, titleColor=MUTED, gridColor="#E5E7EB", domainColor="#E5E7EB", labelFontSize=12
    ).configure_title(anchor="start", color=INK, fontSize=15, fontWeight="bold")


# ---------------------------------------------------------------- header + filters
bounds = run("SELECT MIN(request_date) AS lo, MAX(request_date) AS hi FROM {fact_visit}")
LO, HI = pd.to_datetime(bounds.LO[0]).date(), pd.to_datetime(bounds.HI[0]).date()
regions = run("SELECT DISTINCT member_region AS r FROM {fact_visit} WHERE member_region IS NOT NULL ORDER BY 1").R.tolist()
lines = run("SELECT service_line_name AS s FROM {dim_service_line} ORDER BY 1").S.tolist()

left, right = st.columns([3, 2])
with left:
    st.title("Cascade Virtual Care")
    where_from = "governed Snowflake tables" if IN_SNOWFLAKE else "a masked copy of the Snowflake tables"
    st.markdown(f"<p class='note'>Operations app on {where_from}. All data is synthetic."
                f"<span class='pill'>{'Running in Snowflake' if IN_SNOWFLAKE else 'Public preview'}</span></p>",
                unsafe_allow_html=True)

with st.sidebar:
    st.header("Filters")
    picked = st.date_input("Visit dates", value=(LO, HI), min_value=LO, max_value=HI)
    start, end = (picked if isinstance(picked, (list, tuple)) and len(picked) == 2 else (LO, HI))
    sel_regions = st.multiselect("Member region", regions, default=regions)
    sel_lines = st.multiselect("Service line", lines, default=lines)
    st.caption("Filters apply to the Overview tab.")


def visit_filter(alias="f", date_col="request_date", s=start, e=end):
    parts = [f"{alias}.{date_col} BETWEEN {sql_str(s)} AND {sql_str(e)}"]
    if sel_regions and len(sel_regions) < len(regions):
        parts.append(f"{alias}.member_region IN ({', '.join(sql_str(r) for r in sel_regions)})")
    if sel_lines and len(sel_lines) < len(lines):
        parts.append(f"sl.service_line_name IN ({', '.join(sql_str(x) for x in sel_lines)})")
    if not sel_regions or not sel_lines:
        parts.append("1 = 0")
    return " AND ".join(parts)


def kpis(s, e):
    k = run(f"""
        SELECT SUM(f.is_completed) AS completed,
               COUNT(DISTINCT CASE WHEN f.is_completed = 1 THEN f.member_id END) AS members,
               AVG(f.wait_minutes) AS avg_wait,
               SUM(f.resolved_first_contact) * 1.0 / NULLIF(SUM(f.is_completed), 0) AS fcr,
               SUM(f.visit_cost) AS revenue
        FROM {{fact_visit}} f JOIN {{dim_service_line}} sl ON sl.service_line_id = f.service_line_id
        WHERE {visit_filter(s=s, e=e)}""")
    n = run(f"""
        SELECT (SUM(CASE WHEN f.nps_score >= 9 THEN 1 ELSE 0 END) - SUM(CASE WHEN f.nps_score <= 6 THEN 1 ELSE 0 END))
               * 100.0 / NULLIF(COUNT(*), 0) AS nps
        FROM {{fact_survey}} f JOIN {{dim_service_line}} sl ON sl.service_line_id = f.service_line_id
        WHERE {visit_filter(date_col='survey_date', s=s, e=e)}""")
    out = k.iloc[0].to_dict()
    out["NPS"] = n.NPS[0]
    return out


def shift_year(d):
    try:
        return d.replace(year=d.year - 1)
    except ValueError:
        return d.replace(year=d.year - 1, day=28)


tab_over, tab_ask, tab_dq, tab_gov = st.tabs(["Overview", "Ask the data", "Data quality", "Governance"])

# ---------------------------------------------------------------- overview
with tab_over:
    cur = kpis(start, end)
    ps, pe = shift_year(start), shift_year(end)
    prev = kpis(ps, pe) if ps >= LO else None

    def delta(key, fmt, invert=False):
        if not prev or not prev.get(key) or pd.isna(prev.get(key)) or pd.isna(cur.get(key)):
            return None
        d = (cur[key] - prev[key]) / prev[key]
        return f"{d:+.0%} vs. prior year"

    c = st.columns(6)
    c[0].metric("Completed visits", f"{(cur['COMPLETED'] or 0):,.0f}", delta("COMPLETED", ""))
    c[1].metric("Unique members", f"{(cur['MEMBERS'] or 0):,.0f}", delta("MEMBERS", ""))
    c[2].metric("Avg wait (min)", "–" if pd.isna(cur["AVG_WAIT"]) else f"{cur['AVG_WAIT']:.1f}",
                delta("AVG_WAIT", "", True), delta_color="inverse")
    c[3].metric("First-contact resolution", "–" if pd.isna(cur["FCR"]) else f"{cur['FCR']:.1%}")
    c[4].metric("NPS", "–" if pd.isna(cur["NPS"]) else f"{cur['NPS']:.0f}")
    c[5].metric("Visit revenue", f"${(cur['REVENUE'] or 0) / 1e6:,.2f}M", delta("REVENUE", ""))
    if prev is None:
        st.caption("Year-over-year change appears when the date range starts in 2026, so a full prior year exists to compare against.")

    monthly = run(f"""
        SELECT DATE_TRUNC('month', f.request_date) AS month, SUM(f.is_completed) AS visits
        FROM {{fact_visit}} f JOIN {{dim_service_line}} sl ON sl.service_line_id = f.service_line_id
        WHERE {visit_filter(s=LO, e=HI)}
        GROUP BY 1 ORDER BY 1""")
    monthly["MONTH"] = pd.to_datetime(monthly.MONTH)
    py = monthly.assign(MONTH=monthly.MONTH + pd.DateOffset(years=1))
    py = py[py.MONTH <= monthly.MONTH.max()]
    trend = pd.concat([monthly.assign(SERIES="Completed visits"), py.assign(SERIES="Prior year")])
    trend = trend[(trend.MONTH >= pd.Timestamp(start).replace(day=1)) & (trend.MONTH <= pd.Timestamp(end))]

    g1, g2 = st.columns([3, 2])
    with g1:
        line = alt.Chart(trend, title="Completed visits vs. prior year").mark_line(strokeWidth=2.5).encode(
            x=alt.X("MONTH:T", title=None, axis=alt.Axis(format="%b %Y", grid=False)),
            y=alt.Y("VISITS:Q", title=None),
            color=alt.Color("SERIES:N", scale=alt.Scale(domain=["Completed visits", "Prior year"], range=[TEAL, GRAY]),
                            legend=alt.Legend(title=None, orient="top")),
            strokeDash=alt.StrokeDash("SERIES:N", scale=alt.Scale(domain=["Completed visits", "Prior year"],
                                                                   range=[[1, 0], [5, 4]]), legend=None),
            tooltip=[alt.Tooltip("MONTH:T", format="%B %Y", title="Month"), alt.Tooltip("SERIES:N", title="Series"),
                     alt.Tooltip("VISITS:Q", format=",", title="Visits")])
        show_chart(base(line.properties(height=300)))
    with g2:
        by_line = run(f"""
            SELECT sl.service_line_name AS service_line, SUM(f.is_completed) AS visits, AVG(f.wait_minutes) AS avg_wait
            FROM {{fact_visit}} f JOIN {{dim_service_line}} sl ON sl.service_line_id = f.service_line_id
            WHERE {visit_filter()} GROUP BY 1""")
        bars = alt.Chart(by_line, title="Visits by service line").mark_bar(color=TEAL, cornerRadiusEnd=3).encode(
            x=alt.X("VISITS:Q", title=None, axis=alt.Axis(format="~s")),
            y=alt.Y("SERVICE_LINE:N", title=None, sort="-x"),
            tooltip=[alt.Tooltip("SERVICE_LINE:N", title="Service line"), alt.Tooltip("VISITS:Q", format=",", title="Visits")])
        labels = bars.mark_text(align="left", dx=4, color=INK, fontSize=11).encode(text=alt.Text("VISITS:Q", format=","))
        show_chart(base((bars + labels).properties(height=300)))

    g3, g4, g5 = st.columns(3)
    with g3:
        wait = by_line.dropna(subset=["AVG_WAIT"])
        wb = alt.Chart(wait, title="Average wait vs. 15-minute target").mark_bar(color=TEAL, cornerRadiusEnd=3).encode(
            x=alt.X("AVG_WAIT:Q", title="Minutes", scale=alt.Scale(domain=[0, 20])),
            y=alt.Y("SERVICE_LINE:N", title=None, sort="x"),
            tooltip=[alt.Tooltip("SERVICE_LINE:N", title="Service line"), alt.Tooltip("AVG_WAIT:Q", format=".1f", title="Avg wait")])
        rule = alt.Chart(pd.DataFrame({"t": [15]})).mark_rule(color=INK, strokeDash=[4, 3]).encode(x="t:Q")
        show_chart(base((wb + rule).properties(height=260)))
    with g4:
        ch = run(f"""
            SELECT f.channel, SUM(f.is_completed) AS visits
            FROM {{fact_visit}} f JOIN {{dim_service_line}} sl ON sl.service_line_id = f.service_line_id
            WHERE {visit_filter()} GROUP BY 1""")
        ch["SHARE"] = ch.VISITS / ch.VISITS.sum() if ch.VISITS.sum() else 0
        cb = alt.Chart(ch, title="Visits by channel").mark_bar(color=TEAL, cornerRadiusEnd=3).encode(
            x=alt.X("SHARE:Q", title=None, axis=alt.Axis(format="%")),
            y=alt.Y("CHANNEL:N", title=None, sort="-x"),
            tooltip=[alt.Tooltip("CHANNEL:N", title="Channel"), alt.Tooltip("VISITS:Q", format=",", title="Visits"),
                     alt.Tooltip("SHARE:Q", format=".1%", title="Share")])
        cl = cb.mark_text(align="left", dx=4, color=INK, fontSize=11).encode(text=alt.Text("SHARE:Q", format=".0%"))
        show_chart(base((cb + cl).properties(height=260)))
    with g5:
        stt = run(f"""
            SELECT m.member_state AS state, SUM(f.is_completed) AS visits
            FROM {{fact_visit}} f JOIN {{dim_service_line}} sl ON sl.service_line_id = f.service_line_id
            JOIN {{dim_member}} m ON m.member_id = f.member_id
            WHERE {visit_filter()} GROUP BY 1 ORDER BY 2 DESC LIMIT 8""")
        sb = alt.Chart(stt, title="Top member states").mark_bar(color=TEAL, cornerRadiusEnd=3).encode(
            x=alt.X("VISITS:Q", title=None, axis=alt.Axis(format="~s")),
            y=alt.Y("STATE:N", title=None, sort="-x"),
            tooltip=[alt.Tooltip("STATE:N", title="State"), alt.Tooltip("VISITS:Q", format=",", title="Visits")])
        show_chart(base(sb.properties(height=260)))

# ---------------------------------------------------------------- ask the data
EXAMPLES = [
    "What is the average wait time by service line?",
    "Which 5 employers had the most completed visits in 2026?",
    "Show completed visits by month for Mental Health - Therapy",
    "What is the first contact resolution rate by channel?",
]


def ask_analyst(messages):
    """Call Cortex Analyst. Works on both Streamlit in Snowflake runtimes:
    the warehouse runtime (via the private _snowflake module) and the container
    runtime (via REST with the container's session OAuth token)."""
    body = {"messages": messages, "semantic_view": SEMANTIC_VIEW}
    try:
        import _snowflake  # warehouse runtime only
        resp = _snowflake.send_snow_api_request("POST", "/api/v2/cortex/analyst/message", {}, {}, body, None, 50000)
        content = json.loads(resp["content"])
        if resp["status"] >= 400:
            raise RuntimeError(content.get("message", str(content)))
        return content
    except ImportError:
        pass

    import os
    import requests
    token_path = "/snowflake/session/token"
    if not os.path.exists(token_path):
        raise RuntimeError("No Snowflake session token found, so Cortex Analyst can't be reached from here.")
    token = open(token_path).read().strip()
    host = os.getenv("SNOWFLAKE_HOST")
    if not host:
        acct = run("SELECT LOWER(CURRENT_ORGANIZATION_NAME() || '-' || CURRENT_ACCOUNT_NAME()) AS a").A[0]
        host = f"{acct}.snowflakecomputing.com"
    r = requests.post(
        f"https://{host}/api/v2/cortex/analyst/message",
        json=body,
        headers={"Authorization": f"Bearer {token}",
                 "X-Snowflake-Authorization-Token-Type": "OAUTH",
                 "Content-Type": "application/json", "Accept": "application/json"},
        timeout=60)
    content = r.json() if r.content else {}
    if r.status_code >= 400:
        raise RuntimeError(f"{r.status_code}: {content.get('message', r.text[:300])}")
    return content


def render_answer(content_items, key):
    for item in content_items:
        if item["type"] == "text":
            st.markdown(item["text"])
        elif item["type"] == "suggestions":
            st.markdown("Did you mean:")
            for s_ in item.get("suggestions", []):
                st.markdown(f"- {s_}")
        elif item["type"] == "sql":
            with st.expander("SQL that Cortex Analyst wrote", expanded=False):
                st.code(item["statement"], language="sql")
            try:
                df = SESSION.sql(item["statement"]).to_pandas()
                st.dataframe(df, hide_index=True)
                num = df.select_dtypes("number").columns.tolist()
                cat = [c for c in df.columns if c not in num]
                if len(df) > 1 and num and cat:
                    ch_ = alt.Chart(df).mark_bar(color=TEAL, cornerRadiusEnd=3).encode(
                        x=alt.X(f"{num[0]}:Q"), y=alt.Y(f"{cat[0]}:N", sort="-x"))
                    show_chart(base(ch_.properties(height=min(40 * len(df), 360))))
            except Exception as e:  # show the error rather than fail the whole app
                st.error(f"The query did not run: {e}")


with tab_ask:
    st.subheader("Ask the data in plain English")
    st.markdown("<p class='note'>Cortex Analyst turns your question into SQL against the governed semantic view "
                "<code>SEMANTIC.VIRTUAL_CARE_SV</code>. It runs under this app's role, so masking and row access "
                "still apply, and every answer shows the SQL behind it.</p>", unsafe_allow_html=True)
    if not IN_SNOWFLAKE:
        st.info("The live chat runs inside Snowflake, where Cortex Analyst is available. "
                "In this public preview, here are the kinds of questions it answers:")
        for q_ in EXAMPLES:
            st.markdown(f"- {q_}")
    else:
        if "chat" not in st.session_state:
            st.session_state.chat = []
        cols = st.columns(len(EXAMPLES))
        clicked = None
        for i, q_ in enumerate(EXAMPLES):
            if cols[i].button(q_, key=f"ex{i}"):
                clicked = q_
        for i, msg in enumerate(st.session_state.chat):
            with st.chat_message("user" if msg["role"] == "user" else "assistant"):
                if msg["role"] == "user":
                    st.markdown(msg["content"][0]["text"])
                else:
                    render_answer(msg["content"], key=i)
        question = st.chat_input("Ask about visits, waits, quality, members or employers") or clicked
        if question:
            st.session_state.chat.append({"role": "user", "content": [{"type": "text", "text": question}]})
            with st.chat_message("user"):
                st.markdown(question)
            with st.chat_message("assistant"):
                with st.spinner("Asking Cortex Analyst..."):
                    try:
                        ans = ask_analyst(st.session_state.chat)
                        st.session_state.chat.append(ans["message"])
                        render_answer(ans["message"]["content"], key=len(st.session_state.chat))
                    except Exception as e:
                        st.session_state.chat.pop()
                        st.error(f"Cortex Analyst could not answer: {e}")
        if st.session_state.chat and st.button("Clear conversation"):
            st.session_state.chat = []
            st.rerun()

# ---------------------------------------------------------------- data quality
DRILL = {
    "Duplicate visit rows in source": "SELECT visit_id, request_date, visit_status, member_region FROM {fact_visit} WHERE dq_duplicate_in_source = 1 ORDER BY visit_id",
    "Visit references unknown provider": "SELECT visit_id, request_date, provider_id, visit_status FROM {fact_visit} WHERE dq_orphan_provider = 1 ORDER BY visit_id",
    "Negative visit duration": "SELECT visit_id, request_date, visit_status, 'Negative in source, set to NULL' AS handling FROM {fact_visit} WHERE dq_negative_duration = 1 ORDER BY visit_id",
    "Completed visit missing start time": "SELECT visit_id, request_date, visit_status FROM {fact_visit} WHERE dq_completed_without_start = 1",
    "Malformed email address": "SELECT member_id, email AS email_as_this_role_sees_it, member_state FROM {dim_member} WHERE dq_bad_email = 1 ORDER BY member_id",
    "Missing gender": "SELECT member_id, gender, member_state FROM {dim_member} WHERE dq_missing_gender = 1 ORDER BY member_id",
}

with tab_dq:
    dq = run("SELECT * FROM {dq_scorecard}")
    failed, total = dq.FAILED_ROWS.sum(), dq.TOTAL_ROWS.sum()
    d1, d2, d3 = st.columns(3)
    d1.metric("Checks", f"{len(dq)}")
    d2.metric("Rows flagged and handled", f"{failed:,.0f}")
    d3.metric("Pass rate", f"{1 - failed / total:.2%}")
    st.markdown("<p class='note'>Every problem the source data arrives with is flagged and handled, never silently "
                "dropped, so report totals always reconcile back to the source.</p>", unsafe_allow_html=True)
    show = dq.rename(columns={"ENTITY": "Entity", "DIMENSION": "Dimension", "CHECK_NAME": "Check",
                              "FAILED_ROWS": "Failed rows", "TOTAL_ROWS": "Total rows", "HANDLING": "Handling"})
    st.dataframe(show, hide_index=True)
    pick = st.selectbox("Look at the flagged rows for", dq.CHECK_NAME.tolist())
    rows = run(DRILL[pick] + " LIMIT 200")
    st.caption(f"{len(rows):,} row{'s' if len(rows) != 1 else ''} shown (up to 200).")
    st.dataframe(rows, hide_index=True)

# ---------------------------------------------------------------- governance
with tab_gov:
    st.subheader("Governance travels with the data")
    role = run("SELECT CURRENT_ROLE() AS r").R[0] if IN_SNOWFLAKE else "Public preview (pre-masked copy)"
    st.markdown(f"<p class='note'>This app runs as <b>{role}</b>, a role that is not cleared for personal "
                "data. Snowflake masks those columns before the app ever sees them.</p>", unsafe_allow_html=True)
    sample = run("SELECT member_id, first_name, last_name, email, phone, date_of_birth, member_region "
                 "FROM {dim_member} ORDER BY member_id LIMIT 8")
    st.dataframe(sample, hide_index=True)

    st.markdown("#### Who can see which rows")
    st.markdown("<p class='note'>Row access comes from an entitlements table, so adding a regional analyst is an "
                "INSERT, not a policy change. A role with no entitlement sees nothing.</p>", unsafe_allow_html=True)
    ent = run("""
        SELECT e.role_name, e.region, COUNT(f.visit_id) AS visits_visible
        FROM {region_entitlements} e
        LEFT JOIN {fact_visit} f ON e.region = 'ALL' OR e.region = f.member_region
        GROUP BY 1, 2 ORDER BY 3 DESC""")
    ent = pd.concat([ent, pd.DataFrame([{"ROLE_NAME": "Any role with no entitlement", "REGION": "None",
                                         "VISITS_VISIBLE": 0}])], ignore_index=True)
    st.dataframe(ent.rename(columns={"ROLE_NAME": "Entitlement role", "REGION": "Region",
                                     "VISITS_VISIBLE": "Visits visible"}), hide_index=True)

    st.markdown("#### Policies in force")
    st.dataframe(pd.DataFrame([
        ("MASK_PII_STRING", "Masking", "Names, emails, phones", "Attached to the PII_TYPE tag"),
        ("MASK_PII_DATE", "Masking", "Date of birth", "Generalized to January 1 of the birth year"),
        ("REGION_RAP", "Row access", "Visits, surveys, members", "Rows filtered by the session's region entitlement"),
    ], columns=["Policy", "Type", "Protects", "How"]), hide_index=True)
