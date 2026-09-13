-- =========================================================
-- MARGIN LEAKAGE ANALYTICS — SCHEMA
-- =========================================================
-- Two-layer design:
--   staging.*  -> raw structure, loose types, mirrors the CSVs
--   clean.*    -> typed, deduped, normalized — analysis queries hit this layer
CREATE SCHEMA IF NOT EXISTS staging;
CREATE SCHEMA IF NOT EXISTS clean;

-- ---------------------------------------------------------
-- A. STAGING LAYER
-- ---------------------------------------------------------
DROP TABLE IF EXISTS staging.employees_raw;
CREATE TABLE staging.employees_raw (
    employee_id          TEXT,
    employee_name        TEXT,
    seniority_level      TEXT,
    practice_area        TEXT,
    standard_bill_rate   TEXT,      -- loose on purpose: some rows have "$" and trailing spaces
    hire_date            TEXT
);
SELECT * FROM staging.employees_raw ;

DROP TABLE IF EXISTS staging.projects_raw;
CREATE TABLE staging.projects_raw (
    project_id           TEXT,
    client_name          TEXT,
    practice_area        TEXT,
    start_date           TEXT,
    planned_end_date     TEXT,
    actual_end_date      TEXT,      -- has NULLs (in-progress projects) — kept as TEXT to distinguish blank vs bad
    budgeted_hours       TEXT,
    budgeted_cost        TEXT,
    status               TEXT
);
SELECT * FROM staging.projects_raw;

DROP TABLE IF EXISTS staging.timesheets_raw;
CREATE TABLE staging.timesheets_raw (
    entry_id             TEXT,
    employee_id          TEXT,
    project_id           TEXT,
    work_date            TEXT,
    hours_logged         TEXT,
    billable             TEXT
);

SELECT * FROM staging.timesheets_raw;

-- Quick sanity check row counts after load
SELECT 'employees_raw' AS table_name, COUNT(*) FROM staging.employees_raw
UNION ALL
SELECT 'projects_raw', COUNT(*) FROM staging.projects_raw
UNION ALL
SELECT 'timesheets_raw', COUNT(*) FROM staging.timesheets_raw;

-- --------------------------------------------------------
-- B. CLEAN LAYER
-- --------------------------------------------------------

DROP TABLE IF EXISTS clean.employees CASCADE;
CREATE TABLE clean.employees (
    employee_id         VARCHAR(10) PRIMARY KEY,
    employee_name       VARCHAR(100) NOT NULL,
    seniority_level     VARCHAR(30) NOT NULL,
    practice_area       VARCHAR(50) NOT NULL,
    standard_bill_rate  NUMERIC(8,2) NOT NULL,
    hire_date           DATE NOT NULL
);
SELECT * FROM clean.employees ;

DROP TABLE IF EXISTS clean.projects CASCADE;
CREATE TABLE clean.projects (
    project_id          VARCHAR(10) PRIMARY KEY,
    client_name         VARCHAR(150) NOT NULL,
    practice_area       VARCHAR(50) NOT NULL,
    start_date          DATE NOT NULL,
    planned_end_date    DATE NOT NULL,
    actual_end_date     DATE,                        -- NULL = still in progress (legitimate)
    budgeted_hours      NUMERIC(10,1) NOT NULL,
    budgeted_cost       NUMERIC(12,2) NOT NULL,
    status              VARCHAR(20) NOT NULL,
    has_date_anomaly    BOOLEAN DEFAULT FALSE        -- flags the actual_end < start_date case instead of silently fixing it
);

DROP TABLE IF EXISTS clean.timesheets CASCADE;
CREATE TABLE clean.timesheets (
    entry_id            INTEGER PRIMARY KEY,
    employee_id         VARCHAR(10) NOT NULL REFERENCES clean.employees(employee_id),
    project_id          VARCHAR(10) NOT NULL REFERENCES clean.projects(project_id),
    work_date           DATE NOT NULL,
    hours_logged        NUMERIC(4,1) NOT NULL,
    billable            BOOLEAN NOT NULL,
    is_flagged_hours    BOOLEAN DEFAULT FALSE       -- flags negative/zero/absurd hours instead of deleting them
);


-- =========================================================
-- C.1 CLEAN: EMPLOYEES
-- =========================================================
-- Two problems to fix here: (1) exact duplicate rows, (2) messy text/rate formatting.

-- --- Step 1: understand the duplicate problem first ---
SELECT employee_id, COUNT(*)
FROM staging.employees_raw
GROUP BY employee_id
HAVING COUNT(*) > 1;

-- --- Step 2: the cleaning query ---
WITH deduped AS (
    SELECT
        employee_id,
        employee_name,
        seniority_level,
        practice_area,
        standard_bill_rate,
        hire_date,
        ROW_NUMBER() OVER ( PARTITION BY employee_id ORDER BY employee_id) AS rn
    FROM staging.employees_raw
),
normalized AS (
    SELECT
        employee_id,
        TRIM(employee_name)   AS employee_name,
        TRIM(seniority_level) AS seniority_level,
        INITCAP(TRIM(REGEXP_REPLACE(practice_area, '\s+', ' ', 'g'))) AS practice_area,
        CAST(REGEXP_REPLACE(standard_bill_rate, '[^0-9.]', '', 'g') AS NUMERIC(8,2)) AS standard_bill_rate,
        CAST(hire_date AS DATE) AS hire_date
    FROM deduped
    WHERE rn = 1   -- this is the line that actually removes the duplicates
)
INSERT INTO clean.employees
SELECT * FROM normalized;

SELECT * FROM clean.employees;

-- --- Step 3: verify ---
SELECT COUNT(*) AS clean_employee_count FROM clean.employees;
SELECT COUNT(DISTINCT employee_id) AS distinct_staging_ids FROM staging.employees_raw;     -- Result: 20 in both


-- =========================================================
-- C.2 CLEAN: PROJECTS
-- =========================================================

-- --- Step 1: the cleaning query ---
WITH normalized AS (
    SELECT
        project_id,
        INITCAP(TRIM(client_name))                                     AS client_name,
        INITCAP(TRIM(REGEXP_REPLACE(practice_area, '\s+', ' ', 'g')))  AS practice_area,
        CAST(start_date AS DATE)                  AS start_date,
        CAST(planned_end_date AS DATE)            AS planned_end_date,
        CAST(NULLIF(actual_end_date, '') AS DATE) AS actual_end_date,
        CAST(budgeted_hours AS NUMERIC(10,1))     AS budgeted_hours,
        CAST(budgeted_cost AS NUMERIC(12,2))      AS budgeted_cost,
        TRIM(status) AS status
    FROM staging.projects_raw
)
INSERT INTO clean.projects
SELECT
    project_id,
    client_name,
    practice_area,
    start_date,
    planned_end_date,
    actual_end_date,
    budgeted_hours,
    budgeted_cost,
    status,
	CASE
        WHEN actual_end_date IS NOT NULL AND actual_end_date < start_date THEN TRUE
        ELSE FALSE
    END AS has_date_anomaly
FROM normalized;

SELECT * FROM clean.projects;

-- --- step 2: Verify: which project(s) got flagged? ---
SELECT project_id, client_name, start_date, actual_end_date, has_date_anomaly
FROM clean.projects
WHERE has_date_anomaly = TRUE;     -- result: PRJ005


-- =========================================================
-- C.3 CLEAN: TIMESHEETS
-- =========================================================
-- Two problems here:
-- 1. "Duplicate" entries - same employee, same project, same date, same hours, but a DIFFERENT entry_id (simulates someone
--    accidentally logging the same day's hours twice). Unlike the employee duplicates, these are NOT identical rows, so a naive
--    SELECT DISTINCT won't catch them — we have to define what "duplicate" means in business terms (same person + project + date
--    + hours = the same piece of work logged twice).
-- 2. Invalid hour values - negative hours, 0 hours, or absurd values like 27 hours in a single day.

WITH flagged_dupes AS (
    SELECT
        entry_id,
        employee_id,
        project_id,
        work_date,
        hours_logged,
        billable,
        ROW_NUMBER() OVER (
            PARTITION BY employee_id, project_id, work_date, hours_logged, billable
            ORDER BY entry_id) AS rn
    FROM staging.timesheets_raw
),
deduped AS (
    SELECT * FROM flagged_dupes WHERE rn = 1
)
INSERT INTO clean.timesheets
SELECT
    CAST(entry_id AS INTEGER),
    employee_id,
    project_id,
    CAST(work_date AS DATE),
    CAST(hours_logged AS NUMERIC(4,1)),
    CAST(billable AS BOOLEAN),
    CASE
        WHEN CAST(hours_logged AS NUMERIC(4,1)) <= 0
          OR CAST(hours_logged AS NUMERIC(4,1)) > 16 THEN TRUE
        ELSE FALSE
    END AS is_flagged_hours
FROM deduped;

SELECT * FROM clean.timesheets;

-- --- Verify: how many duplicates were removed, how many hours flagged? ---
SELECT COUNT(*) AS raw_row_count FROM staging.timesheets_raw;      -- result : 3413
SELECT COUNT(*) AS clean_row_count FROM clean.timesheets;          -- result : 3379
                                                                   -- difference (34) = number of duplicate rows removed

SELECT COUNT(*) AS flagged_hour_rows 
FROM clean.timesheets WHERE is_flagged_hours = TRUE;               -- result : 49


-- =========================================================
-- UTILIZATION & BENCH COST 
-- =========================================================
-- employee x month grid, LEFT JOIN to catch fully-benched employees, utilization rate and bench cost 
-- per employee per month. Saving it as a VIEW just means we can reuse its result in the 
-- next step without repeating the whole query.
 
CREATE VIEW clean.utilization AS
WITH months AS (
    SELECT generate_series(
        DATE_TRUNC('month', (SELECT MAX(work_date) - INTERVAL '6 months' FROM clean.timesheets)),
        DATE_TRUNC('month', (SELECT MAX(work_date) FROM clean.timesheets)),
        '1 month'
    )::DATE AS month
),
employee_month_grid AS (
    SELECT e.employee_id, m.month
    FROM clean.employees e
    CROSS JOIN months m
),
monthly_hours AS (
    SELECT
        ts.employee_id,
        DATE_TRUNC('month', ts.work_date)::DATE AS month,
        SUM(ts.hours_logged) FILTER (WHERE ts.billable = TRUE AND ts.is_flagged_hours = FALSE) AS billable_hours
    FROM clean.timesheets ts
    GROUP BY ts.employee_id, DATE_TRUNC('month', ts.work_date)
)
SELECT
    g.employee_id,
    e.employee_name,
    e.practice_area,
    e.standard_bill_rate,
    g.month,
    COALESCE(mh.billable_hours, 0) AS billable_hours,
    LEAST(ROUND(COALESCE(mh.billable_hours, 0) / 160.0 * 100, 1), 100) AS utilization_rate_pct,
    ROUND(GREATEST(160 - COALESCE(mh.billable_hours, 0), 0) * e.standard_bill_rate, 2) AS bench_cost
FROM employee_month_grid g
JOIN clean.employees e ON e.employee_id = g.employee_id
LEFT JOIN monthly_hours mh ON mh.employee_id = g.employee_id AND mh.month = g.month;
 
-- --- Check the output ---
SELECT * FROM clean.utilization ORDER BY employee_id, month;

DROP VIEW clean.utilization;
 

-- =========================================================
-- PROJECT PROFITABILITY 
-- =========================================================
-- Same idea as before, simplified: for each project, add up the actual billable hours/cost logged against it, 
-- compare to budget, and flag anything more than 20% over budget hours as a scope-creep risk.

CREATE VIEW clean.project_profitability AS
WITH actuals AS (
    -- Add up each project's real billable hours and their dollar cost
    -- (hours × the employee's rate who logged them). Only billable,
    -- non-flagged hours count — same rule as the utilization query.
    SELECT
        ts.project_id,
        SUM(ts.hours_logged) AS actual_hours,
        SUM(ts.hours_logged * e.standard_bill_rate) AS actual_cost
    FROM clean.timesheets ts
    JOIN clean.employees e ON e.employee_id = ts.employee_id
    WHERE ts.is_flagged_hours = FALSE
      AND ts.billable = TRUE
    GROUP BY ts.project_id
)
SELECT
    p.project_id,
    p.client_name,
    p.status,
    p.budgeted_hours,
    COALESCE(a.actual_hours, 0) AS actual_hours,

    -- Hours variance %: how far over/under budget the project ran
    ROUND(
        (COALESCE(a.actual_hours, 0) - p.budgeted_hours) / p.budgeted_hours * 100
    , 1) AS hours_variance_pct,

    p.budgeted_cost,
    COALESCE(a.actual_cost, 0) AS actual_cost,

    -- Gross margin %: (revenue - cost) / revenue, the standard margin formula
    ROUND(
        (p.budgeted_cost - COALESCE(a.actual_cost, 0)) / p.budgeted_cost * 100
    , 1) AS gross_margin_pct,

    -- Cost overage: the dollar amount actual cost exceeded the budget.
    -- GREATEST(x, 0) just means "never go below zero" — if the project
    -- came in under budget, there's no overage to report.
    ROUND(GREATEST(COALESCE(a.actual_cost, 0) - p.budgeted_cost, 0), 2) AS cost_overage,

    -- Simple threshold flag instead of a trend line: >20% over budget hours gets flagged("a common PS benchmark for
    -- when a project needs PM attention"), not a statistical model.
    CASE
        WHEN (COALESCE(a.actual_hours, 0) - p.budgeted_hours) / p.budgeted_hours * 100 > 20
            THEN 'Over Budget - Review Needed'
        ELSE 'On Track'
    END AS budget_flag
FROM clean.projects p
LEFT JOIN actuals a ON a.project_id = p.project_id;

-- --- Check the output ---
SELECT * FROM clean.project_profitability ORDER BY gross_margin_pct;

-- =========================================================
-- MARGIN LEAKAGE (the headline metric)
-- =========================================================
-- it add up the two leakage sources we already calculated, and add them together.

WITH bench AS (
    SELECT SUM(bench_cost) AS total_bench_cost_leakage
    FROM clean.utilization
),
scope_creep AS (
    SELECT SUM(cost_overage) AS total_scope_creep_leakage
    FROM clean.project_profitability
)
SELECT
    bench.total_bench_cost_leakage,
    scope_creep.total_scope_creep_leakage,
    bench.total_bench_cost_leakage + scope_creep.total_scope_creep_leakage AS total_margin_leakage
FROM bench, scope_creep;


-- =========================================================
-- MARGIN LEAKAGE WATERFALL (data shape for the Page 3 visual)
-- =========================================================
-- Power BI's waterfall chart needs data in a simple two-column shape: one "Category" column (the step label)
-- and one "Value" column (how much that step adds or subtracts). It then plots a running total
-- automatically - starting revenue, minus each leakage source, ending at what's actually left.

-- sort_order exists purely so the bars appear in a logical left-to-right sequence (Revenue first, then each leakage source) 
-- Power BI doesn't know the "right" order on its own, since these are just category labels to it, not a specific step in time.
 
CREATE VIEW clean.margin_leakage_waterfall AS
SELECT '1. Budgeted Revenue' AS category, 1 AS sort_order,
       (SELECT SUM(budgeted_cost) FROM clean.project_profitability) AS value
UNION ALL
SELECT '2. Bench Cost Leakage', 2,
       -1 * (SELECT SUM(bench_cost) FROM clean.utilization)
UNION ALL
SELECT '3. Scope Creep Leakage', 3,
       -1 * (SELECT SUM(cost_overage) FROM clean.project_profitability);
 
-- --- Check the output ---
SELECT * FROM clean.margin_leakage_waterfall ORDER BY sort_order;
 




