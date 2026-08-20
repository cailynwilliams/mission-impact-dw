/*==============================================================
  MissionImpactDW - Reporting Layer (rpt schema)

  Purpose: Governed, documented views that expose the warehouse
           to analysts and Power BI. 

  Conventions:
    - Every view has a header block: purpose, grain, owner,
      metric definitions. 
    - Views JOIN through surrogate keys.
    - No view exposes raw warehouse audit columns
    - Views are the ONLY thing analysts and Power BI should
      query.

  Idempotent: uses CREATE OR ALTER (available SQL Server 2016+).
==============================================================*/

USE MissionImpactDW;
GO

/*==============================================================
  vw_student_summary
  --------------------------------------------------------------
  GRAIN: one row per student.
  OWNER: Data Infrastructure team.
  PURPOSE: The canonical student-level view for reporting.
           Combines demographics from dim_student with the
           final outcome and both terms' performance flattened
           back into one row.

  METRICS EXPOSED:
    outcome_status         - Dropout / Enrolled / Graduate
    is_dropout             - 1 if outcome_status = 'Dropout',
                             else 0. Defined ONCE here, so
                             every dropout-rate calculation
                             uses the same denominator.
    sem1_approval_rate     - units approved / units enrolled,
                             term 1. Null if enrolled = 0.
    sem2_approval_rate     - same, term 2.
    approval_rate_delta    - sem2 minus sem1. Negative =
                             performance dropped between
                             terms. Key feature for the risk
                             model.
==============================================================*/
CREATE OR ALTER VIEW rpt.vw_student_summary AS
SELECT
    s.student_id,
    s.gender,
    s.age_at_enrollment,
    s.marital_status,
    s.nationality,
    s.is_international,
    s.is_scholarship_holder,
    s.is_debtor,
    s.tuition_fees_up_to_date,
    s.attendance_type,
    p.program_name,
    o.outcome_status,
    o.is_dropout,
    t1.units_enrolled     AS sem1_units_enrolled,
    t1.units_approved      AS sem1_units_approved,
    t1.units_grade           AS sem1_units_grade,
    t1.approval_rate          AS sem1_approval_rate,
    t2.units_enrolled            AS sem2_units_enrolled,
    t2.units_approved             AS sem2_units_approved,
    t2.units_grade                  AS sem2_units_grade,
    t2.approval_rate                 AS sem2_approval_rate,
    (t2.approval_rate - t1.approval_rate) AS approval_rate_delta,
    o.unemployment_rate,
    o.inflation_rate,
    o.gdp
FROM dw.dim_student s
LEFT JOIN dw.fact_student_outcome o ON o.student_key = s.student_key
LEFT JOIN dw.dim_program p ON p.program_key = o.program_key
LEFT JOIN dw.fact_student_term t1
    ON t1.student_key = s.student_key AND t1.term_number = 1
LEFT JOIN dw.fact_student_term t2
    ON t2.student_key = s.student_key AND t2.term_number = 2
WHERE s.student_key <> -1;
GO


/*==============================================================
  vw_dropout_rate_by_program
  --------------------------------------------------------------
  GRAIN: one row per program.
  METRIC:
    dropout_rate = students marked 'Dropout' / total students,
                    per program. Excludes Unknown program.
    Denominator: only students with a resolved outcome.

  The kind of thing that would normally get computed slightly
  differently by three different people in three different
  reports. Defined once, here.
==============================================================*/
CREATE OR ALTER VIEW rpt.vw_dropout_rate_by_program AS
SELECT
    p.program_name,
    COUNT(*)                                    AS total_students,
    SUM(o.is_dropout)                             AS dropout_count,
    CAST(100.0 * SUM(o.is_dropout) / COUNT(*)
         AS DECIMAL(5,2))                        AS dropout_rate_pct
FROM dw.fact_student_outcome o
JOIN dw.dim_program p ON p.program_key = o.program_key
WHERE p.program_key <> -1
GROUP BY p.program_name;
GO


/*==============================================================
  vw_donations_by_fiscal_year
  --------------------------------------------------------------
  GRAIN: one row per fiscal year.
  METRICS: total dollars raised, number of gifts, unique donor
           count, average gift size.
  Fiscal year comes from dim_date (defined once there - the
  point of a conformed dimension).
==============================================================*/
CREATE OR ALTER VIEW rpt.vw_donations_by_fiscal_year AS
SELECT
    d.fiscal_year,
    COUNT(*)                             AS gift_count,
    COUNT(DISTINCT f.donor_key)            AS unique_donor_count,
    SUM(f.amount)                          AS total_raised,
    CAST(AVG(f.amount) AS DECIMAL(12,2))    AS avg_gift_size,
    SUM(CASE WHEN f.donor_key = -1 THEN f.amount ELSE 0 END) AS raised_from_unknown_donors
FROM dw.fact_donation f
JOIN dw.dim_date d ON d.date_key = f.date_key
WHERE d.date_key <> -1
GROUP BY d.fiscal_year;
GO


/*==============================================================
  vw_donor_giving_summary
  --------------------------------------------------------------
  GRAIN: one row per donor.
  Includes derived flags useful for donor-lifecycle reporting.
==============================================================*/
CREATE OR ALTER VIEW rpt.vw_donor_giving_summary AS
SELECT
    d.donor_id,
    d.donor_name,
    d.donor_type,
    d.region,
    d.donor_since_date,
    COUNT(f.donation_key)                            AS lifetime_gift_count,
    ISNULL(SUM(f.amount), 0)                          AS lifetime_giving,
    MIN(dt.full_date)                                  AS first_gift_date,
    MAX(dt.full_date)                                  AS most_recent_gift_date,
    DATEDIFF(DAY, MAX(dt.full_date), SYSUTCDATETIME()) AS days_since_last_gift,
    CASE WHEN MAX(dt.full_date) IS NULL THEN 'never_gave'
         WHEN DATEDIFF(DAY, MAX(dt.full_date), SYSUTCDATETIME()) <= 365 THEN 'active'
         WHEN DATEDIFF(DAY, MAX(dt.full_date), SYSUTCDATETIME()) <= 730 THEN 'lapsing'
         ELSE 'lapsed' END                              AS lifecycle_stage
FROM dw.dim_donor d
LEFT JOIN dw.fact_donation f ON f.donor_key = d.donor_key
LEFT JOIN dw.dim_date dt ON dt.date_key = f.date_key
WHERE d.donor_key <> -1
GROUP BY d.donor_id, d.donor_name, d.donor_type, d.region, d.donor_since_date;
GO


/*==============================================================
  vw_staff_hours_by_department
  --------------------------------------------------------------
  GRAIN: one row per department per fiscal year.
  Useful for HR reporting and departmental workload analysis.
==============================================================*/
CREATE OR ALTER VIEW rpt.vw_staff_hours_by_department AS
SELECT
    dept.department_name,
    dt.fiscal_year,
    COUNT(DISTINCT e.employee_key)     AS active_employee_count,
    SUM(f.hours_logged)                  AS total_hours,
    CAST(AVG(f.hours_logged) AS DECIMAL(6,2)) AS avg_weekly_hours_per_log
FROM dw.fact_staff_hours f
JOIN dw.dim_employee e     ON e.employee_key = f.employee_key
JOIN dw.dim_department dept ON dept.department_key = e.department_key
JOIN dw.dim_date dt          ON dt.date_key = f.date_key
WHERE dept.department_key <> -1
GROUP BY dept.department_name, dt.fiscal_year;
GO


/*==============================================================
  vw_data_quality_latest
  --------------------------------------------------------------
  GRAIN: one row per check, latest batch only.
  Exposes the DQ log to reporting so a dashboard can show
  "current warehouse health" without hitting ops.* directly.
==============================================================*/
CREATE OR ALTER VIEW rpt.vw_data_quality_latest AS
SELECT
    check_name,
    check_category,
    target_object,
    severity,
    expected_value,
    actual_value,
    failed_row_count,
    CASE WHEN check_passed = 1 THEN 'PASS' ELSE 'FAIL' END AS result,
    checked_at_utc
FROM ops.data_quality_result
WHERE load_batch_id = (
    SELECT TOP 1 load_batch_id
    FROM ops.data_quality_result
    ORDER BY checked_at_utc DESC
);
GO


PRINT 'Reporting views created.';
GO


SELECT
    v.name AS view_name,
    (SELECT COUNT(*) FROM sys.dm_sql_referenced_entities('rpt.' + v.name, 'OBJECT')) AS refs
FROM sys.views v
JOIN sys.schemas s ON s.schema_id = v.schema_id
WHERE s.name = 'rpt'
ORDER BY v.name;
GO


SELECT TOP 3 * FROM rpt.vw_student_summary;
SELECT * FROM rpt.vw_dropout_rate_by_program ORDER BY dropout_rate_pct DESC;
SELECT * FROM rpt.vw_donations_by_fiscal_year ORDER BY fiscal_year;
SELECT TOP 5 * FROM rpt.vw_donor_giving_summary ORDER BY lifetime_giving DESC;
SELECT * FROM rpt.vw_staff_hours_by_department ORDER BY fiscal_year, department_name;
SELECT * FROM rpt.vw_data_quality_latest;
GO
