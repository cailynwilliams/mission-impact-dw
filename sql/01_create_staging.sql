/*==============================================================
  MissionImpactDW - Staging Layer
  Purpose: Raw landing tables. Mirror source shape exactly.
           Wide, permissive types, no constraints.
  Notes:   Idempotent - safe to re-run.
==============================================================*/

USE MissionImpactDW;
GO

/*--------------------------------------------------------------
  Operations schema - ETL logging and data quality results
--------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'ops')
    EXEC('CREATE SCHEMA ops');
GO


/*--------------------------------------------------------------
  stg.student_raw
  Source: Kaggle - Predict Students' Dropout and Academic Success
  Grain:  one row per student (as delivered)
--------------------------------------------------------------*/
DROP TABLE IF EXISTS stg.student_raw;
GO

CREATE TABLE stg.student_raw (
    marital_status                  NVARCHAR(50)   NULL,
    application_mode                NVARCHAR(50)   NULL,
    application_order               NVARCHAR(50)   NULL,
    course                          NVARCHAR(100)  NULL,
    attendance_type                 NVARCHAR(50)   NULL,
    previous_qualification          NVARCHAR(100)  NULL,
    previous_qualification_grade    NVARCHAR(50)   NULL,
    nationality                     NVARCHAR(100)  NULL,
    mothers_qualification           NVARCHAR(100)  NULL,
    fathers_qualification           NVARCHAR(100)  NULL,
    mothers_occupation              NVARCHAR(100)  NULL,
    fathers_occupation              NVARCHAR(100)  NULL,
    admission_grade                 NVARCHAR(50)   NULL,
    displaced                       NVARCHAR(10)   NULL,
    educational_special_needs       NVARCHAR(10)   NULL,
    debtor                          NVARCHAR(10)   NULL,
    tuition_fees_up_to_date         NVARCHAR(10)   NULL,
    gender                          NVARCHAR(10)   NULL,
    scholarship_holder              NVARCHAR(10)   NULL,
    age_at_enrollment               NVARCHAR(50)   NULL,
    international                   NVARCHAR(10)   NULL,

    sem1_units_credited             NVARCHAR(50)   NULL,
    sem1_units_enrolled             NVARCHAR(50)   NULL,
    sem1_units_evaluations          NVARCHAR(50)   NULL,
    sem1_units_approved             NVARCHAR(50)   NULL,
    sem1_units_grade                NVARCHAR(50)   NULL,
    sem1_units_without_evaluations  NVARCHAR(50)   NULL,

    sem2_units_credited             NVARCHAR(50)   NULL,
    sem2_units_enrolled             NVARCHAR(50)   NULL,
    sem2_units_evaluations          NVARCHAR(50)   NULL,
    sem2_units_approved             NVARCHAR(50)   NULL,
    sem2_units_grade                NVARCHAR(50)   NULL,
    sem2_units_without_evaluations  NVARCHAR(50)   NULL,

    unemployment_rate               NVARCHAR(50)   NULL,
    inflation_rate                  NVARCHAR(50)   NULL,
    gdp                             NVARCHAR(50)   NULL,

    target                          NVARCHAR(50)   NULL,

    src_file_name                   NVARCHAR(260)  NULL,
    load_batch_id                   UNIQUEIDENTIFIER NULL,
    loaded_at_utc                   DATETIME2(0)   NOT NULL
        CONSTRAINT DF_stg_student_raw_loaded DEFAULT SYSUTCDATETIME()
);
GO


/*--------------------------------------------------------------
  stg.donation_raw
--------------------------------------------------------------*/
DROP TABLE IF EXISTS stg.donation_raw;
GO

CREATE TABLE stg.donation_raw (
    donation_id         NVARCHAR(50)   NULL,
    donor_id            NVARCHAR(50)   NULL,
    donation_date       NVARCHAR(50)   NULL,
    amount              NVARCHAR(50)   NULL,
    campaign            NVARCHAR(100)  NULL,
    payment_method      NVARCHAR(50)   NULL,
    is_recurring        NVARCHAR(10)   NULL,
    src_file_name       NVARCHAR(260)  NULL,
    load_batch_id       UNIQUEIDENTIFIER NULL,
    loaded_at_utc       DATETIME2(0)   NOT NULL
        CONSTRAINT DF_stg_donation_raw_loaded DEFAULT SYSUTCDATETIME()
);
GO


/*--------------------------------------------------------------
  stg.donor_raw
--------------------------------------------------------------*/
DROP TABLE IF EXISTS stg.donor_raw;
GO

CREATE TABLE stg.donor_raw (
    donor_id            NVARCHAR(50)   NULL,
    donor_name          NVARCHAR(200)  NULL,
    donor_since         NVARCHAR(50)   NULL,
    donor_type          NVARCHAR(50)   NULL,
    region              NVARCHAR(50)   NULL,
    email               NVARCHAR(200)  NULL,
    src_file_name       NVARCHAR(260)  NULL,
    load_batch_id       UNIQUEIDENTIFIER NULL,
    loaded_at_utc       DATETIME2(0)   NOT NULL
        CONSTRAINT DF_stg_donor_raw_loaded DEFAULT SYSUTCDATETIME()
);
GO


/*--------------------------------------------------------------
  stg.employee_raw
--------------------------------------------------------------*/
DROP TABLE IF EXISTS stg.employee_raw;
GO

CREATE TABLE stg.employee_raw (
    employee_id         NVARCHAR(50)   NULL,
    employee_name       NVARCHAR(200)  NULL,
    department          NVARCHAR(100)  NULL,
    job_title           NVARCHAR(100)  NULL,
    hire_date           NVARCHAR(50)   NULL,
    termination_date    NVARCHAR(50)   NULL,
    employment_status   NVARCHAR(50)   NULL,
    is_full_time        NVARCHAR(10)   NULL,
    src_file_name       NVARCHAR(260)  NULL,
    load_batch_id       UNIQUEIDENTIFIER NULL,
    loaded_at_utc       DATETIME2(0)   NOT NULL
        CONSTRAINT DF_stg_employee_raw_loaded DEFAULT SYSUTCDATETIME()
);
GO


/*--------------------------------------------------------------
  stg.staff_hours_raw
--------------------------------------------------------------*/
DROP TABLE IF EXISTS stg.staff_hours_raw;
GO

CREATE TABLE stg.staff_hours_raw (
    employee_id         NVARCHAR(50)   NULL,
    week_ending_date    NVARCHAR(50)   NULL,
    hours_logged        NVARCHAR(50)   NULL,
    program_area        NVARCHAR(100)  NULL,
    src_file_name       NVARCHAR(260)  NULL,
    load_batch_id       UNIQUEIDENTIFIER NULL,
    loaded_at_utc       DATETIME2(0)   NOT NULL
        CONSTRAINT DF_stg_staff_hours_raw_loaded DEFAULT SYSUTCDATETIME()
);
GO

PRINT 'Staging layer created.';
GO