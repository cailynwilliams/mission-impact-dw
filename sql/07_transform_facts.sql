/*==============================================================
  MissionImpactDW - Transform: stg -> dw (Facts)
  Purpose: Populate fact tables from staging + dimensions.
  Notes:   Idempotent via MERGE, same pattern as dimensions.

==============================================================*/

USE MissionImpactDW;
GO

/*--------------------------------------------------------------
  dw.fact_student_term
  GRAIN: one row per student per semester.

--------------------------------------------------------------*/
MERGE dw.fact_student_term AS tgt
USING (
    SELECT
        s.student_key,
        1 AS term_number,
        TRY_CAST(r.sem1_units_credited AS SMALLINT)  AS units_credited,
        TRY_CAST(r.sem1_units_enrolled AS SMALLINT)  AS units_enrolled,
        TRY_CAST(r.sem1_units_evaluations AS SMALLINT) AS units_evaluations,
        TRY_CAST(r.sem1_units_approved AS SMALLINT)  AS units_approved,
        TRY_CAST(r.sem1_units_grade AS DECIMAL(6,3))  AS units_grade,
        TRY_CAST(r.sem1_units_without_evaluations AS SMALLINT) AS units_without_evals,
        ISNULL(p.program_key, -1) AS program_key
    FROM stg.student_raw r
    JOIN dw.dim_student s ON s.student_id = r.student_id
    LEFT JOIN dw.dim_program p ON p.program_name = r.course

    UNION ALL

    SELECT
        s.student_key,
        2 AS term_number,
        TRY_CAST(r.sem2_units_credited AS SMALLINT),
        TRY_CAST(r.sem2_units_enrolled AS SMALLINT),
        TRY_CAST(r.sem2_units_evaluations AS SMALLINT),
        TRY_CAST(r.sem2_units_approved AS SMALLINT),
        TRY_CAST(r.sem2_units_grade AS DECIMAL(6,3)),
        TRY_CAST(r.sem2_units_without_evaluations AS SMALLINT),
        ISNULL(p.program_key, -1)
    FROM stg.student_raw r
    JOIN dw.dim_student s ON s.student_id = r.student_id
    LEFT JOIN dw.dim_program p ON p.program_name = r.course
) AS src
ON  tgt.student_key = src.student_key
AND tgt.term_number = src.term_number
WHEN MATCHED THEN
    UPDATE SET
        units_credited      = src.units_credited,
        units_enrolled       = src.units_enrolled,
        units_evaluations     = src.units_evaluations,
        units_approved         = src.units_approved,
        units_grade              = src.units_grade,
        units_without_evals        = src.units_without_evals,
        program_key                  = src.program_key
WHEN NOT MATCHED BY TARGET THEN
    INSERT (student_key, program_key, term_number, units_credited, units_enrolled,
            units_evaluations, units_approved, units_grade, units_without_evals)
    VALUES (src.student_key, src.program_key, src.term_number, src.units_credited,
            src.units_enrolled, src.units_evaluations, src.units_approved,
            src.units_grade, src.units_without_evals);
GO


/*--------------------------------------------------------------
  dw.fact_student_outcome
  GRAIN: one row per student.
--------------------------------------------------------------*/
MERGE dw.fact_student_outcome AS tgt
USING (
    SELECT
        ds.student_key,
        ISNULL(dp.program_key, -1) AS program_key,
        r.target AS outcome_status,
        TRY_CAST(r.unemployment_rate AS DECIMAL(6,2)) AS unemployment_rate,
        TRY_CAST(r.inflation_rate AS DECIMAL(6,2))     AS inflation_rate,
        TRY_CAST(r.gdp AS DECIMAL(8,2))                 AS gdp
    FROM stg.student_raw r
    JOIN dw.dim_student ds ON ds.student_id = r.student_id
    LEFT JOIN dw.dim_program dp ON dp.program_name = r.course
    WHERE r.target IN ('Dropout','Enrolled','Graduate')   -- CK constraint guard
) AS src
ON tgt.student_key = src.student_key
WHEN MATCHED THEN
    UPDATE SET
        program_key         = src.program_key,
        outcome_status        = src.outcome_status,
        unemployment_rate      = src.unemployment_rate,
        inflation_rate            = src.inflation_rate,
        gdp                        = src.gdp
WHEN NOT MATCHED BY TARGET THEN
    INSERT (student_key, program_key, outcome_status, unemployment_rate, inflation_rate, gdp)
    VALUES (src.student_key, src.program_key, src.outcome_status,
            src.unemployment_rate, src.inflation_rate, src.gdp);
GO


/*--------------------------------------------------------------
  dw.fact_donation
  GRAIN: one row per donation transaction.

  Orphan handling 
--------------------------------------------------------------*/
MERGE dw.fact_donation AS tgt
USING (
    -- Deduplicate on donation_id before merging. The synthetic generator
    -- deliberately injects duplicate donation rows so the data
    -- quality checks have something real to catch.
    SELECT donation_id, donor_key, date_key, campaign, payment_method,
           is_recurring, amount
    FROM (
        SELECT
            r.donation_id,
            ISNULL(d.donor_key, -1) AS donor_key,
            ISNULL(dt.date_key, -1) AS date_key,
            r.campaign,
            r.payment_method,
            TRY_CAST(r.is_recurring AS BIT) AS is_recurring,
            TRY_CAST(r.amount AS DECIMAL(12,2)) AS amount,
            ROW_NUMBER() OVER (
                PARTITION BY r.donation_id
                ORDER BY (SELECT NULL)
            ) AS rn
        FROM stg.donation_raw r
        LEFT JOIN dw.dim_donor d ON d.donor_id = r.donor_id
        LEFT JOIN dw.dim_date dt ON dt.full_date = TRY_CONVERT(DATE, r.donation_date)
        WHERE r.donation_id IS NOT NULL
          AND TRY_CAST(r.amount AS DECIMAL(12,2)) IS NOT NULL
    ) deduped
    WHERE rn = 1
) AS src
ON tgt.donation_id = src.donation_id
WHEN MATCHED THEN
    UPDATE SET
        donor_key       = src.donor_key,
        date_key          = src.date_key,
        campaign            = src.campaign,
        payment_method        = src.payment_method,
        is_recurring            = src.is_recurring,
        amount                    = src.amount
WHEN NOT MATCHED BY TARGET THEN
    INSERT (donation_id, donor_key, date_key, campaign, payment_method, is_recurring, amount)
    VALUES (src.donation_id, src.donor_key, src.date_key, src.campaign,
            src.payment_method, src.is_recurring, src.amount);
GO


/*--------------------------------------------------------------
  dw.fact_staff_hours
  GRAIN: one row per employee per week.
--------------------------------------------------------------*/
MERGE dw.fact_staff_hours AS tgt
USING (
    SELECT
        ISNULL(e.employee_key, -1) AS employee_key,
        ISNULL(dt.date_key, -1)     AS date_key,
        r.program_area,
        TRY_CAST(r.hours_logged AS DECIMAL(6,2)) AS hours_logged
    FROM stg.staff_hours_raw r
    LEFT JOIN dw.dim_employee e ON e.employee_id = r.employee_id
    LEFT JOIN dw.dim_date dt ON dt.full_date = TRY_CONVERT(DATE, r.week_ending_date)
    WHERE r.employee_id IS NOT NULL
) AS src
ON  tgt.employee_key = src.employee_key
AND tgt.date_key = src.date_key
WHEN MATCHED THEN
    UPDATE SET
        program_area    = src.program_area,
        hours_logged      = src.hours_logged
WHEN NOT MATCHED BY TARGET THEN
    INSERT (employee_key, date_key, program_area, hours_logged)
    VALUES (src.employee_key, src.date_key, src.program_area, src.hours_logged);
GO

PRINT 'Facts loaded from staging.';
GO

-- Log the duplicate donationsdeliberately dropped during dedup so
-- there's an auditable record.
DECLARE @dupe_count INT;
SELECT @dupe_count = COUNT(*) - COUNT(DISTINCT donation_id)
FROM stg.donation_raw;

INSERT INTO ops.data_quality_result
    (load_batch_id, check_name, check_category, target_object,
     severity, expected_value, actual_value, failed_row_count, check_passed)
VALUES
    (NEWID(), 'duplicate_donation_id', 'Uniqueness', 'stg.donation_raw',
     'Warning', '0 duplicates', CAST(@dupe_count AS VARCHAR(20)), @dupe_count,
     CASE WHEN @dupe_count = 0 THEN 1 ELSE 0 END);
GO

-- Sanity check
SELECT 'fact_student_term' AS fact, COUNT(*) AS rows FROM dw.fact_student_term
UNION ALL SELECT 'fact_student_outcome', COUNT(*) FROM dw.fact_student_outcome
UNION ALL SELECT 'fact_donation', COUNT(*) FROM dw.fact_donation
UNION ALL SELECT 'fact_staff_hours', COUNT(*) FROM dw.fact_staff_hours;
GO

-- Orphan visibility: how many facts landed on the Unknown member?
SELECT 'donation rows on Unknown donor' AS check_name, COUNT(*) AS n
FROM dw.fact_donation WHERE donor_key = -1
UNION ALL
SELECT 'staff_hours rows on Unknown employee', COUNT(*)
FROM dw.fact_staff_hours WHERE employee_key = -1;
GO