/*==============================================================
  MissionImpactDW - Patch: add student_id to stg.student_raw
  Purpose: The Kaggle source has no natural student key. This
           adds a column for a generated one (STU00001, ...),
           populated by the ETL loader going forward.
  Notes:   Idempotent - checks for the column before adding it.
==============================================================*/

USE MissionImpactDW;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('stg.student_raw')
      AND name = 'student_id'
)
BEGIN
    ALTER TABLE stg.student_raw ADD student_id NVARCHAR(20) NULL;
END
GO

PRINT 'stg.student_raw patched with student_id column.';
GO
