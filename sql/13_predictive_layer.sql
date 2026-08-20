/*==============================================================
  MissionImpactDW - Predictive Layer: Features + Score Table
  Purpose: Feature engineering as governed SQL views, plus a
           fact table for the model to write predictions into.

  Notes: Idempotent via CREATE OR ALTER for views; the score
         table uses IF NOT EXISTS.
==============================================================*/

USE MissionImpactDW;
GO


/*==============================================================
  rpt.vw_student_risk_features
  --------------------------------------------------------------
  GRAIN: one row per student.
  PURPOSE: Feature set for the dropout risk classifier.
           Combines demographics, first-term performance, and
           macro indicators.

  FEATURE NOTES:
    - Uses ONLY term 1 performance
    - is_dropout comes from fact_student_outcome
      and is joined here so this view is trainable as-is.
==============================================================*/
CREATE OR ALTER VIEW rpt.vw_student_risk_features AS
SELECT
    s.student_key,
    s.student_id,

    -- Demographics
    ISNULL(s.age_at_enrollment, 20)                     AS age_at_enrollment,
    CASE WHEN s.gender = 'Male' THEN 1 ELSE 0 END       AS is_male,
    ISNULL(s.is_international, 0)                        AS is_international,
    ISNULL(s.is_displaced, 0)                             AS is_displaced,
    ISNULL(s.is_scholarship_holder, 0)                     AS is_scholarship_holder,
    ISNULL(s.is_debtor, 0)                                  AS is_debtor,
    ISNULL(s.tuition_fees_up_to_date, 1)                     AS tuition_fees_up_to_date,
    CASE WHEN s.attendance_type = 'Daytime' THEN 1 ELSE 0 END AS is_daytime_attendance,

    -- Term 1 performance 
    ISNULL(t1.units_enrolled, 0)         AS sem1_units_enrolled,
    ISNULL(t1.units_approved, 0)          AS sem1_units_approved,
    ISNULL(t1.units_grade, 0)               AS sem1_units_grade,
    ISNULL(t1.approval_rate, 0)              AS sem1_approval_rate,
    ISNULL(t1.units_without_evals, 0)          AS sem1_units_without_evals,

    -- Macro indicators 
    ISNULL(o.unemployment_rate, 0)  AS unemployment_rate,
    ISNULL(o.inflation_rate, 0)      AS inflation_rate,
    ISNULL(o.gdp, 0)                  AS gdp,

    -- Target: 1 if the student dropped out, 0 otherwise.
    -- Present here for TRAINING; the scoring pipeline reads the
    -- same view and ignores this column.
    o.is_dropout
FROM dw.dim_student s
LEFT JOIN dw.fact_student_outcome o
    ON o.student_key = s.student_key
LEFT JOIN dw.fact_student_term t1
    ON t1.student_key = s.student_key AND t1.term_number = 1
WHERE s.student_key <> -1
  AND o.is_dropout IS NOT NULL;  -- students without a resolved outcome can't train the model
GO


/*==============================================================
  dw.fact_student_risk_score
  --------------------------------------------------------------
  GRAIN: one row per student per model_run_id.
  PURPOSE: Persistent store of model predictions. Each scoring
           run stamps its own run id, so predictions from
           different model versions can be compared.
==============================================================*/
IF OBJECT_ID('dw.fact_student_risk_score','U') IS NULL
BEGIN
    CREATE TABLE dw.fact_student_risk_score (
        risk_score_key      BIGINT IDENTITY(1,1) NOT NULL,
        student_key         INT              NOT NULL,
        model_run_id        UNIQUEIDENTIFIER NOT NULL,
        model_version       VARCHAR(50)      NOT NULL,
        model_algorithm     VARCHAR(50)      NOT NULL,
        scored_at_utc       DATETIME2(0)     NOT NULL
            CONSTRAINT DF_fact_student_risk_score_scored DEFAULT SYSUTCDATETIME(),
        predicted_probability DECIMAL(6,4)   NOT NULL,   -- probability of dropout
        predicted_class     TINYINT          NOT NULL,   -- 1 = predicted dropout
        risk_tier           VARCHAR(20)      NOT NULL,   -- Low / Medium / High
        CONSTRAINT PK_fact_student_risk_score
            PRIMARY KEY CLUSTERED (risk_score_key),
        CONSTRAINT FK_fact_student_risk_score_student
            FOREIGN KEY (student_key) REFERENCES dw.dim_student (student_key),
        CONSTRAINT CK_fact_student_risk_score_probability
            CHECK (predicted_probability BETWEEN 0 AND 1),
        CONSTRAINT CK_fact_student_risk_score_class
            CHECK (predicted_class IN (0, 1)),
        CONSTRAINT CK_fact_student_risk_score_tier
            CHECK (risk_tier IN ('Low', 'Medium', 'High'))
    );

    -- Enforces one score per student per model run 
    CREATE UNIQUE INDEX UX_fact_student_risk_score_grain
        ON dw.fact_student_risk_score (student_key, model_run_id);

    -- Common query
    CREATE INDEX IX_fact_student_risk_score_scored_at
        ON dw.fact_student_risk_score (scored_at_utc DESC)
        INCLUDE (student_key, predicted_probability, risk_tier);
END
GO


/*==============================================================
  rpt.vw_student_risk_latest
  --------------------------------------------------------------
  GRAIN: one row per student, from the most recent scoring run.
  PURPOSE: The consumption layer for the risk model 
==============================================================*/
CREATE OR ALTER VIEW rpt.vw_student_risk_latest AS
WITH latest_run AS (
    SELECT TOP 1 model_run_id, scored_at_utc, model_version
    FROM dw.fact_student_risk_score
    ORDER BY scored_at_utc DESC
)
SELECT
    s.student_id,
    p.program_name,
    r.predicted_probability     AS dropout_probability,
    r.risk_tier,
    r.predicted_class            AS predicted_dropout,
    o.is_dropout                   AS actual_dropout,   -- null for still-enrolled
    o.outcome_status                AS actual_outcome,
    lr.scored_at_utc                 AS score_generated_at,
    lr.model_version
FROM dw.fact_student_risk_score r
JOIN latest_run lr             ON lr.model_run_id = r.model_run_id
JOIN dw.dim_student s           ON s.student_key = r.student_key
LEFT JOIN dw.fact_student_outcome o ON o.student_key = r.student_key
LEFT JOIN dw.dim_program p       ON p.program_key = o.program_key;
GO


PRINT 'Predictive layer objects created.';
GO

-- Confirm the feature view returns rows and target distribution
SELECT
    COUNT(*)                                   AS total_students,
    SUM(is_dropout)                              AS dropouts,
    CAST(100.0 * SUM(is_dropout) / COUNT(*)
         AS DECIMAL(5,2))                        AS dropout_rate_pct
FROM rpt.vw_student_risk_features;
GO
