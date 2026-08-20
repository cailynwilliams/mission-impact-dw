/*==============================================================
  MissionImpactDW - Transform: stg -> dw (Dimensions)
  Purpose: Populate conformed dimensions from staging.
  Notes:   Idempotent via MERGE - re-running updates existing
           rows rather than duplicating them. This is the
           upsert pattern: safe to re-run after every reload.

  Run AFTER load_staging.py has populated the stg.* tables.
  Run BEFORE 07_transform_facts.sql (facts need these keys).
==============================================================*/

USE MissionImpactDW;
GO

/*--------------------------------------------------------------
  dw.dim_donor
  MERGE on the business key (donor_id). New donors get
  inserted; donors that already exist get their attributes
  refreshed (SCD Type 1 - overwrite, no history kept).
--------------------------------------------------------------*/
MERGE dw.dim_donor AS tgt
USING (
    SELECT
        donor_id,
        donor_name,
        donor_type,
        region,
        TRY_CONVERT(DATE, donor_since) AS donor_since_date
    FROM stg.donor_raw
    WHERE donor_id IS NOT NULL
) AS src
ON tgt.donor_id = src.donor_id
WHEN MATCHED THEN
    UPDATE SET
        donor_name        = src.donor_name,
        donor_type         = src.donor_type,
        region             = src.region,
        donor_since_date   = src.donor_since_date,
        dw_updated_at_utc  = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET THEN
    INSERT (donor_id, donor_name, donor_type, region, donor_since_date)
    VALUES (src.donor_id, src.donor_name, src.donor_type, src.region, src.donor_since_date);
GO


/*--------------------------------------------------------------
  dw.dim_department
  Derived from distinct, non-null departments in the employee
  extract. No business key collision risk - department names
  ARE the key here.
--------------------------------------------------------------*/
MERGE dw.dim_department AS tgt
USING (
    SELECT DISTINCT department AS department_name
    FROM stg.employee_raw
    WHERE department IS NOT NULL AND LTRIM(RTRIM(department)) <> ''
) AS src
ON tgt.department_name = src.department_name
WHEN NOT MATCHED BY TARGET THEN
    INSERT (department_name)
    VALUES (src.department_name);
GO


/*--------------------------------------------------------------
  dw.dim_employee
  MERGE on employee_id. Null/blank department in the source
  resolves to the Unknown department (-1) rather than being
  left as a broken reference - see the Unknown-member note in
  02_create_dimensions.sql for why.
--------------------------------------------------------------*/
MERGE dw.dim_employee AS tgt
USING (
    SELECT
        e.employee_id,
        e.employee_name,
        ISNULL(d.department_key, -1) AS department_key,
        e.job_title,
        TRY_CONVERT(DATE, e.hire_date) AS hire_date,
        TRY_CONVERT(DATE, e.termination_date) AS termination_date,
        e.employment_status,
        TRY_CAST(e.is_full_time AS BIT) AS is_full_time
    FROM stg.employee_raw e
    LEFT JOIN dw.dim_department d
        ON d.department_name = e.department
    WHERE e.employee_id IS NOT NULL
) AS src
ON tgt.employee_id = src.employee_id
WHEN MATCHED THEN
    UPDATE SET
        employee_name      = src.employee_name,
        department_key     = src.department_key,
        job_title           = src.job_title,
        hire_date            = src.hire_date,
        termination_date     = src.termination_date,
        employment_status    = src.employment_status,
        is_full_time          = src.is_full_time,
        dw_updated_at_utc     = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET THEN
    INSERT (employee_id, employee_name, department_key, job_title,
            hire_date, termination_date, employment_status, is_full_time)
    VALUES (src.employee_id, src.employee_name, src.department_key, src.job_title,
            src.hire_date, src.termination_date, src.employment_status, src.is_full_time);
GO


/*--------------------------------------------------------------
  dw.dim_program
  Derived from distinct "course" values in the student extract.
  program_name is the business key - each distinct course
  string from the source becomes one program row.
--------------------------------------------------------------*/
MERGE dw.dim_program AS tgt
USING (
    SELECT DISTINCT course AS program_name
    FROM stg.student_raw
    WHERE course IS NOT NULL AND LTRIM(RTRIM(course)) <> ''
) AS src
ON tgt.program_name = src.program_name
WHEN NOT MATCHED BY TARGET THEN
    INSERT (program_name, program_area)
    VALUES (src.program_name, NULL);
GO


/*--------------------------------------------------------------
  dw.dim_student
  MERGE on student_id (generated during staging load - see
  05_alter_student_raw.sql and load_staging.py for why).

  Numeric-looking staging columns are NVARCHAR by design (staging
  never assumes clean types), so every cast here uses TRY_CONVERT/
  TRY_CAST rather than CONVERT/CAST: a value that fails to convert
  becomes NULL instead of failing the whole batch. That trade-off
  is deliberate - a handful of unparseable ages shouldn't block
  4,424 students from loading. In production, TRY_-failures like
  these are exactly what a data quality check should count and
  report, not silently swallow - see the DQ script we'll build
  next for how that gets surfaced.
--------------------------------------------------------------*/
MERGE dw.dim_student AS tgt
USING (
    SELECT
        student_id,
        gender,
        TRY_CAST(age_at_enrollment AS SMALLINT)      AS age_at_enrollment,
        marital_status,
        nationality,
        TRY_CAST(international AS BIT)                AS is_international,
        TRY_CAST(displaced AS BIT)                    AS is_displaced,
        TRY_CAST(educational_special_needs AS BIT)    AS has_special_needs,
        TRY_CAST(scholarship_holder AS BIT)           AS is_scholarship_holder,
        TRY_CAST(debtor AS BIT)                        AS is_debtor,
        TRY_CAST(tuition_fees_up_to_date AS BIT)      AS tuition_fees_up_to_date,
        attendance_type,
        application_mode,
        TRY_CAST(admission_grade AS DECIMAL(6,2))     AS admission_grade,
        previous_qualification,
        TRY_CAST(previous_qualification_grade AS DECIMAL(6,2)) AS previous_qual_grade,
        mothers_qualification,
        fathers_qualification
    FROM stg.student_raw
    WHERE student_id IS NOT NULL
) AS src
ON tgt.student_id = src.student_id
WHEN MATCHED THEN
    UPDATE SET
        gender                   = src.gender,
        age_at_enrollment        = src.age_at_enrollment,
        marital_status            = src.marital_status,
        nationality                = src.nationality,
        is_international            = src.is_international,
        is_displaced                 = src.is_displaced,
        has_special_needs             = src.has_special_needs,
        is_scholarship_holder          = src.is_scholarship_holder,
        is_debtor                       = src.is_debtor,
        tuition_fees_up_to_date          = src.tuition_fees_up_to_date,
        attendance_type                   = src.attendance_type,
        application_mode                   = src.application_mode,
        admission_grade                     = src.admission_grade,
        previous_qualification               = src.previous_qualification,
        previous_qual_grade                   = src.previous_qual_grade,
        mothers_qualification                  = src.mothers_qualification,
        fathers_qualification                   = src.fathers_qualification,
        dw_updated_at_utc                        = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET THEN
    INSERT (student_id, gender, age_at_enrollment, marital_status, nationality,
            is_international, is_displaced, has_special_needs, is_scholarship_holder,
            is_debtor, tuition_fees_up_to_date, attendance_type, application_mode,
            admission_grade, previous_qualification, previous_qual_grade,
            mothers_qualification, fathers_qualification)
    VALUES (src.student_id, src.gender, src.age_at_enrollment, src.marital_status,
            src.nationality, src.is_international, src.is_displaced, src.has_special_needs,
            src.is_scholarship_holder, src.is_debtor, src.tuition_fees_up_to_date,
            src.attendance_type, src.application_mode, src.admission_grade,
            src.previous_qualification, src.previous_qual_grade,
            src.mothers_qualification, src.fathers_qualification);
GO

PRINT 'Dimensions loaded from staging.';
GO

-- Quick sanity check
SELECT 'dim_donor' AS dim, COUNT(*) AS rows FROM dw.dim_donor WHERE donor_key <> -1
UNION ALL SELECT 'dim_department', COUNT(*) FROM dw.dim_department WHERE department_key <> -1
UNION ALL SELECT 'dim_employee', COUNT(*) FROM dw.dim_employee WHERE employee_key <> -1
UNION ALL SELECT 'dim_program', COUNT(*) FROM dw.dim_program WHERE program_key <> -1
UNION ALL SELECT 'dim_student', COUNT(*) FROM dw.dim_student WHERE student_key <> -1;
GO