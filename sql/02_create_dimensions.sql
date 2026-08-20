/*==============================================================
  MissionImpactDW - Dimension Tables
  Purpose: Conformed dimensions for the warehouse layer.
  Notes:   Idempotent. Run AFTER 01_create_staging.sql and
           BEFORE 03_create_facts.sql (facts reference these).

  Conventions:
    - Surrogate key: <table>_key, INT IDENTITY, primary key.
    - Business key:  <table>_id, from the source system.
    - Every dimension carries an "Unknown" member with key -1
    - SCD Type 1 (overwrite) throughout. 
==============================================================*/

USE MissionImpactDW;
GO

/*--------------------------------------------------------------
  dw.dim_date
  Grain: one row per calendar day.
  Conformed across every fact table.
--------------------------------------------------------------*/
IF OBJECT_ID('dw.dim_date','U') IS NULL
BEGIN
    CREATE TABLE dw.dim_date (
        date_key         INT          NOT NULL,   -- YYYYMMDD
        full_date        DATE         NOT NULL,
        day_of_month     TINYINT      NOT NULL,
        day_name         VARCHAR(10)  NOT NULL,
        day_of_week      TINYINT      NOT NULL,
        is_weekend       BIT          NOT NULL,
        week_of_year     TINYINT      NOT NULL,
        month_number     TINYINT      NOT NULL,
        month_name       VARCHAR(10)  NOT NULL,
        quarter_number   TINYINT      NOT NULL,
        calendar_year    SMALLINT     NOT NULL,
        fiscal_year      SMALLINT     NOT NULL,   -- FY starts July 1
        fiscal_quarter   TINYINT      NOT NULL,
        CONSTRAINT PK_dim_date PRIMARY KEY CLUSTERED (date_key)
    );

    CREATE UNIQUE INDEX UX_dim_date_full_date ON dw.dim_date (full_date);
END
GO


/*--------------------------------------------------------------
  dw.dim_student
  Grain: one row per student.
--------------------------------------------------------------*/
IF OBJECT_ID('dw.dim_student','U') IS NULL
BEGIN
    CREATE TABLE dw.dim_student (
        student_key                 INT IDENTITY(1,1) NOT NULL,
        student_id                  VARCHAR(50)   NOT NULL,   -- business key
        gender                      VARCHAR(20)   NULL,
        age_at_enrollment           SMALLINT      NULL,
        marital_status              VARCHAR(50)   NULL,
        nationality                 VARCHAR(100)  NULL,
        is_international            BIT           NULL,
        is_displaced                BIT           NULL,
        has_special_needs           BIT           NULL,
        is_scholarship_holder       BIT           NULL,
        is_debtor                   BIT           NULL,
        tuition_fees_up_to_date     BIT           NULL,
        attendance_type             VARCHAR(20)   NULL,       -- daytime / evening
        application_mode            VARCHAR(100)  NULL,
        admission_grade             DECIMAL(6,2)  NULL,
        previous_qualification      VARCHAR(100)  NULL,
        previous_qual_grade         DECIMAL(6,2)  NULL,
        mothers_qualification       VARCHAR(100)  NULL,
        fathers_qualification       VARCHAR(100)  NULL,
        -- Audit
        dw_created_at_utc           DATETIME2(0)  NOT NULL
            CONSTRAINT DF_dim_student_created DEFAULT SYSUTCDATETIME(),
        dw_updated_at_utc           DATETIME2(0)  NOT NULL
            CONSTRAINT DF_dim_student_updated DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_dim_student PRIMARY KEY CLUSTERED (student_key)
    );

    CREATE UNIQUE INDEX UX_dim_student_student_id
        ON dw.dim_student (student_id);
END
GO


/*--------------------------------------------------------------
  dw.dim_program
  Grain: one row per academic program / course of study.
--------------------------------------------------------------*/
IF OBJECT_ID('dw.dim_program','U') IS NULL
BEGIN
    CREATE TABLE dw.dim_program (
        program_key       INT IDENTITY(1,1) NOT NULL,
        program_name      VARCHAR(150)  NOT NULL,
        program_area      VARCHAR(100)  NULL,
        dw_created_at_utc DATETIME2(0)  NOT NULL
            CONSTRAINT DF_dim_program_created DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_dim_program PRIMARY KEY CLUSTERED (program_key)
    );

    CREATE UNIQUE INDEX UX_dim_program_name ON dw.dim_program (program_name);
END
GO


/*--------------------------------------------------------------
  dw.dim_donor
  Grain: one row per donor.
--------------------------------------------------------------*/
IF OBJECT_ID('dw.dim_donor','U') IS NULL
BEGIN
    CREATE TABLE dw.dim_donor (
        donor_key           INT IDENTITY(1,1) NOT NULL,
        donor_id            VARCHAR(50)   NOT NULL,   -- business key
        donor_name          VARCHAR(200)  NULL,
        donor_type          VARCHAR(50)   NULL,       -- individual / corporate / foundation
        region              VARCHAR(50)   NULL,
        donor_since_date    DATE          NULL,
        dw_created_at_utc   DATETIME2(0)  NOT NULL
            CONSTRAINT DF_dim_donor_created DEFAULT SYSUTCDATETIME(),
        dw_updated_at_utc   DATETIME2(0)  NOT NULL
            CONSTRAINT DF_dim_donor_updated DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_dim_donor PRIMARY KEY CLUSTERED (donor_key)
    );

    CREATE UNIQUE INDEX UX_dim_donor_donor_id ON dw.dim_donor (donor_id);
END
GO


/*--------------------------------------------------------------
  dw.dim_department
  Grain: one row per organizational department.
--------------------------------------------------------------*/
IF OBJECT_ID('dw.dim_department','U') IS NULL
BEGIN
    CREATE TABLE dw.dim_department (
        department_key    INT IDENTITY(1,1) NOT NULL,
        department_name   VARCHAR(100)  NOT NULL,
        dw_created_at_utc DATETIME2(0)  NOT NULL
            CONSTRAINT DF_dim_department_created DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_dim_department PRIMARY KEY CLUSTERED (department_key)
    );

    CREATE UNIQUE INDEX UX_dim_department_name
        ON dw.dim_department (department_name);
END
GO


/*--------------------------------------------------------------
  dw.dim_employee
  Grain: one row per employee.
--------------------------------------------------------------*/
IF OBJECT_ID('dw.dim_employee','U') IS NULL
BEGIN
    CREATE TABLE dw.dim_employee (
        employee_key       INT IDENTITY(1,1) NOT NULL,
        employee_id        VARCHAR(50)   NOT NULL,   -- business key
        employee_name      VARCHAR(200)  NULL,
        department_key     INT           NULL,
        job_title          VARCHAR(100)  NULL,
        hire_date          DATE          NULL,
        termination_date   DATE          NULL,
        employment_status  VARCHAR(50)   NULL,
        is_full_time       BIT           NULL,
        dw_created_at_utc  DATETIME2(0)  NOT NULL
            CONSTRAINT DF_dim_employee_created DEFAULT SYSUTCDATETIME(),
        dw_updated_at_utc  DATETIME2(0)  NOT NULL
            CONSTRAINT DF_dim_employee_updated DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_dim_employee PRIMARY KEY CLUSTERED (employee_key),
        CONSTRAINT FK_dim_employee_department
            FOREIGN KEY (department_key) REFERENCES dw.dim_department (department_key)
    );

    CREATE UNIQUE INDEX UX_dim_employee_employee_id
        ON dw.dim_employee (employee_id);
END
GO


/*==============================================================
  Every dimension gets a key = -1 "Unknown" row.
==============================================================*/

SET IDENTITY_INSERT dw.dim_student ON;
IF NOT EXISTS (SELECT 1 FROM dw.dim_student WHERE student_key = -1)
    INSERT INTO dw.dim_student (student_key, student_id, gender)
    VALUES (-1, 'UNKNOWN', 'Unknown');
SET IDENTITY_INSERT dw.dim_student OFF;
GO

SET IDENTITY_INSERT dw.dim_program ON;
IF NOT EXISTS (SELECT 1 FROM dw.dim_program WHERE program_key = -1)
    INSERT INTO dw.dim_program (program_key, program_name, program_area)
    VALUES (-1, 'Unknown', 'Unknown');
SET IDENTITY_INSERT dw.dim_program OFF;
GO

SET IDENTITY_INSERT dw.dim_donor ON;
IF NOT EXISTS (SELECT 1 FROM dw.dim_donor WHERE donor_key = -1)
    INSERT INTO dw.dim_donor (donor_key, donor_id, donor_name, donor_type)
    VALUES (-1, 'UNKNOWN', 'Unknown Donor', 'Unknown');
SET IDENTITY_INSERT dw.dim_donor OFF;
GO

SET IDENTITY_INSERT dw.dim_department ON;
IF NOT EXISTS (SELECT 1 FROM dw.dim_department WHERE department_key = -1)
    INSERT INTO dw.dim_department (department_key, department_name)
    VALUES (-1, 'Unknown');
SET IDENTITY_INSERT dw.dim_department OFF;
GO

SET IDENTITY_INSERT dw.dim_employee ON;
IF NOT EXISTS (SELECT 1 FROM dw.dim_employee WHERE employee_key = -1)
    INSERT INTO dw.dim_employee (employee_key, employee_id, employee_name, department_key)
    VALUES (-1, 'UNKNOWN', 'Unknown Employee', -1);
SET IDENTITY_INSERT dw.dim_employee OFF;
GO

PRINT 'Dimension tables created.';
GO