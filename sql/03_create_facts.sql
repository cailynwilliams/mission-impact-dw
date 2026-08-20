/*==============================================================
  MissionImpactDW - Fact Tables + Operations Tables
  Purpose: Transactional/measurement tables and the ETL/data
           quality logging infrastructure.
  Notes:   Idempotent. Run AFTER 02_create_dimensions.sql.
==============================================================*/

USE MissionImpactDW;
GO

/*--------------------------------------------------------------
  dw.fact_student_term
  GRAIN: one row per student per academic semester.

  Delivers one flat row per student with separate
  1st-sem and 2nd-sem columns. 
--------------------------------------------------------------*/
IF OBJECT_ID('dw.fact_student_term','U') IS NULL
BEGIN
    CREATE TABLE dw.fact_student_term (
        student_term_key        BIGINT IDENTITY(1,1) NOT NULL,
        student_key             INT           NOT NULL,
        program_key             INT           NOT NULL,
        term_number             TINYINT       NOT NULL,   -- 1 or 2
        -- Measures
        units_credited          SMALLINT      NULL,
        units_enrolled          SMALLINT      NULL,
        units_evaluations       SMALLINT      NULL,
        units_approved          SMALLINT      NULL,
        units_grade             DECIMAL(6,3)  NULL,
        units_without_evals     SMALLINT      NULL,
        -- Derived measure: pass rate for the term
        approval_rate           AS (CASE WHEN units_enrolled > 0
                                         THEN CAST(units_approved AS DECIMAL(9,4))
                                              / units_enrolled
                                         ELSE NULL END) PERSISTED,
        -- Audit
        load_batch_id           UNIQUEIDENTIFIER NULL,
        dw_created_at_utc       DATETIME2(0)  NOT NULL
            CONSTRAINT DF_fact_student_term_created DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_fact_student_term PRIMARY KEY CLUSTERED (student_term_key),
        CONSTRAINT FK_fact_student_term_student
            FOREIGN KEY (student_key) REFERENCES dw.dim_student (student_key),
        CONSTRAINT FK_fact_student_term_program
            FOREIGN KEY (program_key) REFERENCES dw.dim_program (program_key),
        CONSTRAINT CK_fact_student_term_term
            CHECK (term_number IN (1,2))
    );

    -- One row per student per term. Enforces the stated grain.
    CREATE UNIQUE INDEX UX_fact_student_term_grain
        ON dw.fact_student_term (student_key, term_number);

    CREATE INDEX IX_fact_student_term_program
        ON dw.fact_student_term (program_key)
        INCLUDE (units_enrolled, units_approved, units_grade);
END
GO


/*--------------------------------------------------------------
  dw.fact_student_outcome
  GRAIN: one row per student.

  Holds the final academic outcome. 
--------------------------------------------------------------*/
IF OBJECT_ID('dw.fact_student_outcome','U') IS NULL
BEGIN
    CREATE TABLE dw.fact_student_outcome (
        student_outcome_key   INT IDENTITY(1,1) NOT NULL,
        student_key           INT           NOT NULL,
        program_key           INT           NOT NULL,
        outcome_status        VARCHAR(20)   NOT NULL,  -- Dropout / Enrolled / Graduate
        is_dropout            AS (CASE WHEN outcome_status = 'Dropout'
                                       THEN 1 ELSE 0 END) PERSISTED,
        unemployment_rate     DECIMAL(6,2)  NULL,
        inflation_rate        DECIMAL(6,2)  NULL,
        gdp                   DECIMAL(8,2)  NULL,
        load_batch_id         UNIQUEIDENTIFIER NULL,
        dw_created_at_utc     DATETIME2(0)  NOT NULL
            CONSTRAINT DF_fact_student_outcome_created DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_fact_student_outcome PRIMARY KEY CLUSTERED (student_outcome_key),
        CONSTRAINT FK_fact_student_outcome_student
            FOREIGN KEY (student_key) REFERENCES dw.dim_student (student_key),
        CONSTRAINT FK_fact_student_outcome_program
            FOREIGN KEY (program_key) REFERENCES dw.dim_program (program_key),
        CONSTRAINT CK_fact_student_outcome_status
            CHECK (outcome_status IN ('Dropout','Enrolled','Graduate'))
    );

    CREATE UNIQUE INDEX UX_fact_student_outcome_grain
        ON dw.fact_student_outcome (student_key);
END
GO


/*--------------------------------------------------------------
  dw.fact_donation
  GRAIN: one row per donation transaction.
--------------------------------------------------------------*/
IF OBJECT_ID('dw.fact_donation','U') IS NULL
BEGIN
    CREATE TABLE dw.fact_donation (
        donation_key      BIGINT IDENTITY(1,1) NOT NULL,
        donation_id       VARCHAR(50)   NOT NULL,   -- business key
        donor_key         INT           NOT NULL,
        date_key          INT           NOT NULL,
        campaign          VARCHAR(100)  NULL,
        payment_method    VARCHAR(50)   NULL,
        is_recurring      BIT           NULL,
        amount            DECIMAL(12,2) NOT NULL,
        load_batch_id     UNIQUEIDENTIFIER NULL,
        dw_created_at_utc DATETIME2(0)  NOT NULL
            CONSTRAINT DF_fact_donation_created DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_fact_donation PRIMARY KEY CLUSTERED (donation_key),
        CONSTRAINT FK_fact_donation_donor
            FOREIGN KEY (donor_key) REFERENCES dw.dim_donor (donor_key),
        CONSTRAINT FK_fact_donation_date
            FOREIGN KEY (date_key) REFERENCES dw.dim_date (date_key)
    );

    -- Enforces idempotency: a re-run cannot duplicate a donation.
    CREATE UNIQUE INDEX UX_fact_donation_donation_id
        ON dw.fact_donation (donation_id);

    CREATE INDEX IX_fact_donation_donor_date
        ON dw.fact_donation (donor_key, date_key)
        INCLUDE (amount);
END
GO


/*--------------------------------------------------------------
  dw.fact_staff_hours
  GRAIN: one row per employee per week.
--------------------------------------------------------------*/
IF OBJECT_ID('dw.fact_staff_hours','U') IS NULL
BEGIN
    CREATE TABLE dw.fact_staff_hours (
        staff_hours_key   BIGINT IDENTITY(1,1) NOT NULL,
        employee_key      INT           NOT NULL,
        date_key          INT           NOT NULL,   -- week ending date
        program_area      VARCHAR(100)  NULL,
        hours_logged      DECIMAL(6,2)  NULL,
        load_batch_id     UNIQUEIDENTIFIER NULL,
        dw_created_at_utc DATETIME2(0)  NOT NULL
            CONSTRAINT DF_fact_staff_hours_created DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_fact_staff_hours PRIMARY KEY CLUSTERED (staff_hours_key),
        CONSTRAINT FK_fact_staff_hours_employee
            FOREIGN KEY (employee_key) REFERENCES dw.dim_employee (employee_key),
        CONSTRAINT FK_fact_staff_hours_date
            FOREIGN KEY (date_key) REFERENCES dw.dim_date (date_key)
    );

    CREATE UNIQUE INDEX UX_fact_staff_hours_grain
        ON dw.fact_staff_hours (employee_key, date_key);
END
GO


/*==============================================================
  OPERATIONS LAYER
  ETL run logging and data quality results. 
==============================================================*/

/*--------------------------------------------------------------
  ops.etl_run_log
  GRAIN: one row per pipeline step per run.
--------------------------------------------------------------*/
IF OBJECT_ID('ops.etl_run_log','U') IS NULL
BEGIN
    CREATE TABLE ops.etl_run_log (
        run_log_key       BIGINT IDENTITY(1,1) NOT NULL,
        load_batch_id     UNIQUEIDENTIFIER NOT NULL,
        pipeline_name     VARCHAR(100)  NOT NULL,
        step_name         VARCHAR(100)  NOT NULL,
        target_object     VARCHAR(200)  NULL,
        started_at_utc    DATETIME2(0)  NOT NULL,
        ended_at_utc      DATETIME2(0)  NULL,
        duration_seconds  AS (DATEDIFF(SECOND, started_at_utc, ended_at_utc)),
        rows_read         BIGINT        NULL,
        rows_written      BIGINT        NULL,
        rows_rejected     BIGINT        NULL,
        run_status        VARCHAR(20)   NOT NULL,   -- Started / Succeeded / Failed
        error_message     NVARCHAR(2000) NULL,
        CONSTRAINT PK_etl_run_log PRIMARY KEY CLUSTERED (run_log_key),
        CONSTRAINT CK_etl_run_log_status
            CHECK (run_status IN ('Started','Succeeded','Failed','Warning'))
    );

    CREATE INDEX IX_etl_run_log_batch ON ops.etl_run_log (load_batch_id);
END
GO


/*--------------------------------------------------------------
  ops.data_quality_result
  GRAIN: one row per data quality check per run.

  Severity determines behavior: 'Error' fails the pipeline,
  'Warning' logs and continues.
--------------------------------------------------------------*/
IF OBJECT_ID('ops.data_quality_result','U') IS NULL
BEGIN
    CREATE TABLE ops.data_quality_result (
        dq_result_key     BIGINT IDENTITY(1,1) NOT NULL,
        load_batch_id     UNIQUEIDENTIFIER NOT NULL,
        check_name        VARCHAR(150)  NOT NULL,
        check_category    VARCHAR(50)   NOT NULL,  -- Completeness/Uniqueness/Validity/etc.
        target_object     VARCHAR(200)  NULL,
        severity          VARCHAR(20)   NOT NULL,  -- Error / Warning / Info
        expected_value    VARCHAR(100)  NULL,
        actual_value      VARCHAR(100)  NULL,
        failed_row_count  BIGINT        NULL,
        check_passed      BIT           NOT NULL,
        checked_at_utc    DATETIME2(0)  NOT NULL
            CONSTRAINT DF_dq_result_checked DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_data_quality_result PRIMARY KEY CLUSTERED (dq_result_key),
        CONSTRAINT CK_dq_result_severity
            CHECK (severity IN ('Error','Warning','Info'))
    );

    CREATE INDEX IX_dq_result_batch ON ops.data_quality_result (load_batch_id);
END
GO

PRINT 'Fact tables and operations layer created.';
GO