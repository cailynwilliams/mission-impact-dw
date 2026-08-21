/*==============================================================
  MissionImpactDW - Refactor: split feature view from training view

  Purpose: split vw_student_risk_features into two views:

             rpt.vw_student_risk_features
               - one row per eligible student
               - NO target column
               - includes currently enrolled students
               - used by the scoring pipeline

             rpt.vw_student_risk_training
               - subset of the above (students with resolved outcome)
               - INCLUDES target column (is_dropout)
               - used only during model training

  Notes: Idempotent via CREATE OR ALTER.
==============================================================*/

USE MissionImpactDW;
GO


/*--------------------------------------------------------------
  rpt.vw_student_risk_features
  --------------------------------------------------------------
  GRAIN: one row per eligible student.
  PURPOSE: Features for the scoring pipeline. Every student
           who has at least a first-term record is eligible,
           regardless of whether their outcome is resolved.
--------------------------------------------------------------*/
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
    ISNULL(o.gdp, 0)                  AS gdp
FROM dw.dim_student s
LEFT JOIN dw.fact_student_outcome o
    ON o.student_key = s.student_key
LEFT JOIN dw.fact_student_term t1
    ON t1.student_key = s.student_key AND t1.term_number = 1
WHERE s.student_key <> -1
  AND t1.student_key IS NOT NULL;   -- must have term 1 data to be scorable
GO


/*--------------------------------------------------------------
  rpt.vw_student_risk_training
  --------------------------------------------------------------
  GRAIN: one row per student with a resolved outcome.
  PURPOSE: Training set. 
--------------------------------------------------------------*/
CREATE OR ALTER VIEW rpt.vw_student_risk_training AS
SELECT
    f.*,
    o.is_dropout
FROM rpt.vw_student_risk_features f
JOIN dw.fact_student_outcome o
    ON o.student_key = f.student_key
WHERE o.is_dropout IS NOT NULL
  AND o.outcome_status IN ('Dropout', 'Graduate');   -- exclude still-enrolled
GO


PRINT 'Feature/training view split complete.';
GO

-- Sanity check: features should include everyone eligible;
-- training should be a strict subset with the target attached.
SELECT
    (SELECT COUNT(*) FROM rpt.vw_student_risk_features)                          AS features_total,
    (SELECT COUNT(*) FROM rpt.vw_student_risk_training)                           AS training_total,
    (SELECT COUNT(*) FROM rpt.vw_student_risk_features)
     - (SELECT COUNT(*) FROM rpt.vw_student_risk_training)                        AS enrolled_not_in_training;
GO
