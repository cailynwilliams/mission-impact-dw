/*==============================================================
  MissionImpactDW - Patch: expose dim_date to reporting layer
  Purpose: Power BIneeds a proper date table marked in its 
           semantic model. Adding rpt.vw_date lets Power BI connect
           to it via the governed layer. 

  Notes:   Idempotent via CREATE OR ALTER.
==============================================================*/

USE MissionImpactDW;
GO

CREATE OR ALTER VIEW rpt.vw_date AS
SELECT
    date_key,
    full_date,
    day_of_month,
    day_name,
    day_of_week,
    is_weekend,
    week_of_year,
    month_number,
    month_name,
    quarter_number,
    calendar_year,
    fiscal_year,
    fiscal_quarter
FROM dw.dim_date
WHERE date_key <> -1;
GO

PRINT 'rpt.vw_date created.';
GO
