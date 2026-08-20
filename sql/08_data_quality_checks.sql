/*==============================================================
  MissionImpactDW - Data Quality Checks
  Purpose: A battery of standard checks run after every load,
           logged to ops.data_quality_result so results are
           queryable history, not just console output.

  Categories covered (the standard six, from the survival
  guide): Completeness, Uniqueness, Validity, Consistency,
  Accuracy (proxy via range checks), Timeliness.

  Severity convention:
    'Error'   - would fail a real pipeline; data is wrong or
                unusable if this check fails.
    'Warning' - worth knowing about, doesn't block the load.
                Most of the checks below are Warning, because
                the Unknown-member pattern already keeps orphan
                rows from breaking anything - these checks are
                about VISIBILITY, not blocking.

  Run AFTER 07_transform_facts.sql.
==============================================================*/

USE MissionImpactDW;
GO

DECLARE @batch_id UNIQUEIDENTIFIER = NEWID();

/*--------------------------------------------------------------
  CHECK 1 - Completeness: row count reconciliation
  Staging row count should equal warehouse row count for each
  source. A mismatch means rows were silently dropped somewhere
  in the transform - the cheapest, highest-value check there is.
--------------------------------------------------------------*/
INSERT INTO ops.data_quality_result
    (load_batch_id, check_name, check_category, target_object,
     severity, expected_value, actual_value, failed_row_count, check_passed)
SELECT
    @batch_id,
    'row_count_reconciliation_student',
    'Completeness',
    'stg.student_raw -> dw.dim_student',
    'Error',
    CAST((SELECT COUNT(*) FROM stg.student_raw) AS VARCHAR(20)),
    CAST((SELECT COUNT(*) FROM dw.dim_student WHERE student_key <> -1) AS VARCHAR(20)),
    ABS((SELECT COUNT(*) FROM stg.student_raw)
        - (SELECT COUNT(*) FROM dw.dim_student WHERE student_key <> -1)),
    CASE WHEN (SELECT COUNT(*) FROM stg.student_raw)
            = (SELECT COUNT(*) FROM dw.dim_student WHERE student_key <> -1)
         THEN 1 ELSE 0 END;

INSERT INTO ops.data_quality_result
    (load_batch_id, check_name, check_category, target_object,
     severity, expected_value, actual_value, failed_row_count, check_passed)
SELECT
    @batch_id,
    'row_count_reconciliation_donor',
    'Completeness',
    'stg.donor_raw -> dw.dim_donor',
    'Error',
    CAST((SELECT COUNT(*) FROM stg.donor_raw) AS VARCHAR(20)),
    CAST((SELECT COUNT(*) FROM dw.dim_donor WHERE donor_key <> -1) AS VARCHAR(20)),
    ABS((SELECT COUNT(*) FROM stg.donor_raw)
        - (SELECT COUNT(*) FROM dw.dim_donor WHERE donor_key <> -1)),
    CASE WHEN (SELECT COUNT(*) FROM stg.donor_raw)
            = (SELECT COUNT(*) FROM dw.dim_donor WHERE donor_key <> -1)
         THEN 1 ELSE 0 END;

INSERT INTO ops.data_quality_result
    (load_batch_id, check_name, check_category, target_object,
     severity, expected_value, actual_value, failed_row_count, check_passed)
SELECT
    @batch_id,
    'row_count_reconciliation_employee',
    'Completeness',
    'stg.employee_raw -> dw.dim_employee',
    'Error',
    CAST((SELECT COUNT(*) FROM stg.employee_raw) AS VARCHAR(20)),
    CAST((SELECT COUNT(*) FROM dw.dim_employee WHERE employee_key <> -1) AS VARCHAR(20)),
    ABS((SELECT COUNT(*) FROM stg.employee_raw)
        - (SELECT COUNT(*) FROM dw.dim_employee WHERE employee_key <> -1)),
    CASE WHEN (SELECT COUNT(*) FROM stg.employee_raw)
            = (SELECT COUNT(*) FROM dw.dim_employee WHERE employee_key <> -1)
         THEN 1 ELSE 0 END;

-- fact_donation is EXPECTED to be smaller than stg.donation_raw, because
-- we deliberately dedupe exact-duplicate donation_ids during the merge.
-- So this check's "expected" isn't equality - it's stg_count minus the
-- known duplicate count. Encoding that here (rather than just comparing
-- for equality) is what makes this check meaningful instead of a false
-- alarm every single run.
INSERT INTO ops.data_quality_result
    (load_batch_id, check_name, check_category, target_object,
     severity, expected_value, actual_value, failed_row_count, check_passed)
SELECT
    @batch_id,
    'row_count_reconciliation_donation',
    'Completeness',
    'stg.donation_raw -> dw.fact_donation',
    'Error',
    CAST(((SELECT COUNT(*) FROM stg.donation_raw)
          - (SELECT COUNT(*) - COUNT(DISTINCT donation_id) FROM stg.donation_raw)) AS VARCHAR(20)),
    CAST((SELECT COUNT(*) FROM dw.fact_donation) AS VARCHAR(20)),
    ABS(((SELECT COUNT(*) FROM stg.donation_raw)
         - (SELECT COUNT(*) - COUNT(DISTINCT donation_id) FROM stg.donation_raw))
        - (SELECT COUNT(*) FROM dw.fact_donation)),
    CASE WHEN ((SELECT COUNT(*) FROM stg.donation_raw)
               - (SELECT COUNT(*) - COUNT(DISTINCT donation_id) FROM stg.donation_raw))
             = (SELECT COUNT(*) FROM dw.fact_donation)
         THEN 1 ELSE 0 END;


/*--------------------------------------------------------------
  CHECK 2 - Completeness: required fields not null
--------------------------------------------------------------*/
INSERT INTO ops.data_quality_result
    (load_batch_id, check_name, check_category, target_object,
     severity, expected_value, actual_value, failed_row_count, check_passed)
SELECT
    @batch_id, 'null_check_donation_amount', 'Completeness', 'dw.fact_donation.amount',
    'Error', '0 nulls', CAST(COUNT(*) AS VARCHAR(20)), COUNT(*),
    CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END
FROM dw.fact_donation WHERE amount IS NULL;

INSERT INTO ops.data_quality_result
    (load_batch_id, check_name, check_category, target_object,
     severity, expected_value, actual_value, failed_row_count, check_passed)
SELECT
    @batch_id, 'null_check_donor_email', 'Completeness', 'dw.dim_donor.email',
    'Warning',
    '0 nulls (informational - nulls are legitimate here)',
    CAST(COUNT(*) AS VARCHAR(20)), COUNT(*), 1  -- informational, always "passes"
FROM stg.donor_raw WHERE email IS NULL OR LTRIM(RTRIM(email)) = '';


/*--------------------------------------------------------------
  CHECK 3 - Uniqueness: duplicate business keys
--------------------------------------------------------------*/
INSERT INTO ops.data_quality_result
    (load_batch_id, check_name, check_category, target_object,
     severity, expected_value, actual_value, failed_row_count, check_passed)
SELECT
    @batch_id, 'duplicate_donation_id_source', 'Uniqueness', 'stg.donation_raw',
    'Warning', '0 duplicates',
    CAST(COUNT(*) - COUNT(DISTINCT donation_id) AS VARCHAR(20)),
    COUNT(*) - COUNT(DISTINCT donation_id),
    CASE WHEN COUNT(*) = COUNT(DISTINCT donation_id) THEN 1 ELSE 0 END
FROM stg.donation_raw;


/*--------------------------------------------------------------
  CHECK 4 - Consistency: referential integrity (orphaned facts)
  Rows resolved to the Unknown member (-1). Not blocking - by
  design, per the Unknown-member pattern - but worth counting
  and watching. A spike run-over-run would indicate an upstream
  source problem worth investigating.
--------------------------------------------------------------*/
INSERT INTO ops.data_quality_result
    (load_batch_id, check_name, check_category, target_object,
     severity, expected_value, actual_value, failed_row_count, check_passed)
SELECT
    @batch_id, 'orphaned_donation_donor_fk', 'Consistency', 'dw.fact_donation.donor_key',
    'Warning', '0 orphans (informational)',
    CAST(COUNT(*) AS VARCHAR(20)), COUNT(*), 1
FROM dw.fact_donation WHERE donor_key = -1;

INSERT INTO ops.data_quality_result
    (load_batch_id, check_name, check_category, target_object,
     severity, expected_value, actual_value, failed_row_count, check_passed)
SELECT
    @batch_id, 'orphaned_staff_hours_employee_fk', 'Consistency', 'dw.fact_staff_hours.employee_key',
    'Warning', '0 orphans (informational)',
    CAST(COUNT(*) AS VARCHAR(20)), COUNT(*), 1
FROM dw.fact_staff_hours WHERE employee_key = -1;


/*--------------------------------------------------------------
  CHECK 5 - Validity/Accuracy: range and outlier checks
--------------------------------------------------------------*/
INSERT INTO ops.data_quality_result
    (load_batch_id, check_name, check_category, target_object,
     severity, expected_value, actual_value, failed_row_count, check_passed)
SELECT
    @batch_id, 'donation_amount_outliers', 'Validity', 'dw.fact_donation.amount',
    'Warning', '< $100,000',
    CAST(COUNT(*) AS VARCHAR(20)), COUNT(*),
    CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END
FROM dw.fact_donation WHERE amount > 100000;

INSERT INTO ops.data_quality_result
    (load_batch_id, check_name, check_category, target_object,
     severity, expected_value, actual_value, failed_row_count, check_passed)
SELECT
    @batch_id, 'student_age_range_check', 'Validity', 'dw.dim_student.age_at_enrollment',
    'Warning', 'between 15 and 80',
    CAST(COUNT(*) AS VARCHAR(20)), COUNT(*),
    CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END
FROM dw.dim_student
WHERE age_at_enrollment IS NOT NULL
  AND (age_at_enrollment < 15 OR age_at_enrollment > 80);

INSERT INTO ops.data_quality_result
    (load_batch_id, check_name, check_category, target_object,
     severity, expected_value, actual_value, failed_row_count, check_passed)
SELECT
    @batch_id, 'staff_hours_range_check', 'Validity', 'dw.fact_staff_hours.hours_logged',
    'Warning', 'between 0 and 80 (two-week-equivalent guard)',
    CAST(COUNT(*) AS VARCHAR(20)), COUNT(*),
    CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END
FROM dw.fact_staff_hours
WHERE hours_logged IS NOT NULL
  AND (hours_logged < 0 OR hours_logged > 80);


/*--------------------------------------------------------------
  CHECK 6 - Timeliness: staging freshness
  Flags if the most recent staging load is older than expected.
  Threshold set generously (7 days) since this is a manually-run
  portfolio pipeline, not a nightly production job - in
  production this would be tightened to match the real SLA.
--------------------------------------------------------------*/
INSERT INTO ops.data_quality_result
    (load_batch_id, check_name, check_category, target_object,
     severity, expected_value, actual_value, failed_row_count, check_passed)
SELECT
    @batch_id, 'staging_freshness_student', 'Timeliness', 'stg.student_raw',
    'Warning', 'loaded within 7 days',
    CAST(DATEDIFF(HOUR, MAX(loaded_at_utc), SYSUTCDATETIME()) AS VARCHAR(20)) + ' hours ago',
    0,
    CASE WHEN DATEDIFF(DAY, MAX(loaded_at_utc), SYSUTCDATETIME()) <= 7 THEN 1 ELSE 0 END
FROM stg.student_raw;

GO


/*==============================================================
  SUMMARY - what you'd actually screenshot for a README or show
  in an interview. One row per check, pass/fail, plain English.
==============================================================*/
SELECT
    check_name,
    check_category,
    severity,
    expected_value,
    actual_value,
    failed_row_count,
    CASE WHEN check_passed = 1 THEN 'PASS' ELSE 'FAIL' END AS result
FROM ops.data_quality_result
WHERE load_batch_id = (SELECT TOP 1 load_batch_id FROM ops.data_quality_result ORDER BY checked_at_utc DESC)
ORDER BY
    CASE severity WHEN 'Error' THEN 1 WHEN 'Warning' THEN 2 ELSE 3 END,
    check_name;
GO

-- Overall pass rate - a single number for a dashboard tile
SELECT
    COUNT(*) AS total_checks,
    SUM(CASE WHEN check_passed = 1 THEN 1 ELSE 0 END) AS checks_passed,
    SUM(CASE WHEN check_passed = 0 AND severity = 'Error' THEN 1 ELSE 0 END) AS hard_failures,
    CAST(100.0 * SUM(CASE WHEN check_passed = 1 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,1)) AS pct_passed
FROM ops.data_quality_result
WHERE load_batch_id = (SELECT TOP 1 load_batch_id FROM ops.data_quality_result ORDER BY checked_at_utc DESC);
GO
