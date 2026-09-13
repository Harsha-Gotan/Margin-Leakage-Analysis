# 📊 Margin Leakage Analytics

A SQL-driven analytics project for a fictional consulting/professional services firm, identifying and quantifying where billable profit is being lost - through underutilized staff capacity and project scope creep - and combining both into a single actionable metric: **Margin Leakage**.

<br>

## Business Problem

Professional services firms bill by the hour, which means profitability depends on two things: keeping staff utilized (billable) and keeping projects within their budgeted scope. This project answers two questions leadership at any consulting, agency, or IT services firm would ask:

1. **How much profit are we losing to underutilized staff (bench time)?**
2. **How much profit are we losing to projects that ran over their budgeted hours?**

The **Margin Leakage** metric combines both into one number a firm's leadership can act on.

<br>

## 🗂️ Data Source

This project uses a **synthetic dataset** generated specifically for this analysis — no real company or client data is used. Three tables were created to simulate a consulting/professional services firm:

- **Employees** (20 staff records) - seniority level, practice area, standard bill rate
- **Projects** (18 fixed-fee client engagements) - budgeted hours/cost, timeline, status
- **Timesheets** (~2,800 entries) - daily logged hours per employee per project, spanning a 6-month reporting window

The data was intentionally generated with realistic messiness (duplicate rows, inconsistent text formatting, invalid values, a logical date inconsistency) to demonstrate a genuine data-cleaning workflow, and with a controlled budget-variance distribution across projects so the profitability analysis reflects a believable mix of on-budget, under-budget, and over-budget outcomes rather than random noise.

<br>

## 🛠️ Tech Stack

- **PostgreSQL** - data cleaning, transformation, and analysis (CTEs, window functions, views)
- **Power BI** - 3-page interactive dashboard with DAX measures
- **Python (pandas, Faker)** - synthetic dataset generation only (not part of the analysis itself)

<br>

## Methodology

### 1. Data Cleaning
Raw data (employee roster, project budgets, timesheets) is loaded into a `staging` schema, then cleaned into a `clean` schema:
- Deduplication using `ROW_NUMBER()` window functions (both exact-duplicate rows and business-key duplicates)
- Text normalization (casing, whitespace) and type casting from loosely-typed staging columns
- Logical validation — flagging (not silently correcting) data inconsistencies, e.g. a project's completion date preceding its start date

### 2. Utilization Analysis
For each employee, each month: billable hours, non-billable hours, utilization rate, and bench cost (the dollar value of unbilled capacity). Built with a full employee × month grid (`CROSS JOIN` + `LEFT JOIN`) so employees with zero logged hours are correctly captured as fully benched, rather than silently excluded from the report.

### 3. Project Profitability
For each project: actual vs. budgeted hours and cost, gross margin %, and a simple threshold flag (>20% over budgeted hours) for projects at scope-creep risk.

### 4. Margin Leakage Synthesis
Bench cost leakage (from utilization) + scope creep cost overage (from profitability) = Total Margin Leakage.

<br>

## 📈 Dashboard Walkthrough

### Page 1 — Utilization Overview

<img width="1375" height="772" alt="image" src="https://github.com/user-attachments/assets/900b479b-3a46-49ed-91b0-d401a70337f5" />

| Visual | What it shows & why |
|---|---|
| **KPI cards** (Firm Utilization %, Bench Cost, Billable Hours, Headcount, Avg Utilization Rate %) | The top-line numbers a manager checks first. Two utilization metrics are shown side by side deliberately - one dollar-weighted, one a simple average - so the gap between them itself becomes a talking point. |
| **Firm Utilization % trend line** | A single line over time answers "is this getting better or worse?" faster than any table. A month-over-month view was chosen over a single point-in-time number specifically to catch a declining trend early. |
| **Utilization by Employee (bar chart)** | Ranked bars make outliers - both top performers and fully-benched staff - visible in one glance, which a table of 20 rows wouldn't surface as quickly. |
| **Bench Cost by Employee (bar chart)** | Placed next to the utilization chart on purpose: the two rankings *don't* match, because a benched senior consultant costs more than a benched analyst at the same utilization %. The contrast is the insight. |
| **Utilization by Practice Area (donut)** | Answers "is one practice line systematically more overstaffed than others?" - a donut suits a small number of categories (5 practice areas) better than a bar chart would. |


### Page 2 — Project Profitability

<img width="1375" height="772" alt="image" src="https://github.com/user-attachments/assets/e5312b10-49c9-4f9a-980e-bad9fcbe82d4" />


| Visual | What it shows & why |
|---|---|
| **KPI cards** (Revenue, Actual Cost, Gross Margin %, Scope Creep Cost, Projects Over Budget) | Mirrors Page 1's format for consistency, now at the project level instead of the people level. |
| **Project Table** | The full detail view, sorted worst-margin-first — for when a KPI or chart raises a question and someone needs to click into specifics. |
| **Margin by Project (color-coded bar chart)** | Color (green/red) does the flagging instantly, so a viewer doesn't have to read every margin % to spot which projects need attention. |
| **Scope Creep vs. Margin (scatter plot)** | The one chart that visually *proves* the project's core thesis — as hours-over-budget increases, margin trends downward. A scatter is the right choice here because it shows the relationship between two numbers, not just a ranking. |


### Page 3 — Margin Leakage Summary

<img width="1377" height="772" alt="image" src="https://github.com/user-attachments/assets/5f5a2597-b9f2-442f-ae79-11a19feabdc9" />


| Visual | What it shows & why |
|---|---|
| **Waterfall chart** | The headline visual of the whole project. A waterfall is the only chart type that shows *both* the starting revenue *and* exactly how much each leakage source subtracts from it, step by step, ending at what's actually realized — a single bar or KPI card couldn't tell that story. |

<br>

## 💡 Insights & Recommendations

**Insight:** Firm-wide utilization sits at 34.1%, roughly half of the 65-75% healthy industry benchmark, with 5 of 20 employees (25%) logging zero billable work over the period.
**➡️ Recommendation:** This is a staffing-to-pipeline mismatch, not an individual performance issue. Leadership should either grow the sales pipeline to match current headcount, or right-size the bench through project rotation, before considering headcount reduction.

**Insight:** Bench cost ($2.31M) dwarfs scope creep cost ($30K) by roughly 75-to-1 - idle capacity is a far bigger profit drain than budget overruns in this dataset.
**➡️ Recommendation:** Prioritize utilization/staffing fixes over scope-management process improvements - the ROI on solving underutilization is dramatically higher here.

**Insight:** Dollar-weighted utilization (34.1%) is meaningfully lower than the simple average utilization (40%) across employees.
**➡️ Recommendation:** Senior, higher-rate staff are idle more than junior staff, proportionally. Since their idle time costs more per hour, staffing/rotation decisions should weight seniority, not just headcount, when addressing bench cost.

**Insight:** Only 1 of 18 projects breached the 20%-over-budget scope-creep threshold, but that single project accounts for the entire $30K overage.
**➡️ Recommendation:** Scope creep isn't a firm-wide process problem in this data - it's isolated. A targeted post-mortem on that one project (PRJ018) would likely explain the overage better than a firm-wide policy change.

<br>

## Key SQL / DAX Concepts Demonstrated

- CTEs and window functions (`ROW_NUMBER()`, `AVG() OVER()`)
- `CROSS JOIN` / `LEFT JOIN` for complete data grids (avoiding silent data loss)
- Views for reusable, modular analysis layers
- DAX: `SUMX`, `DIVIDE`, `CALCULATE`, context transition, custom number formatting

<br>

## Assumptions & Limitations

- `budgeted_cost` represents the client-billed contract value; actual delivery cost is calculated as logged hours × employee bill rate (a simplification — real firms often track a separate internal cost rate)
- Utilization is measured over a fixed 6-month reporting period, while project profitability is measured over each project's full lifetime - these are intentionally different time frames, consistent with how PS firms typically report each
- Scope-creep flagging uses a fixed >20% over-budget threshold rather than a statistical model, prioritizing interpretability


