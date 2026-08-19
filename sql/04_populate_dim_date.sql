/*==============================================================
  MissionImpactDW - Populate dim_date
  Purpose: Fills the date dimension for 2015-01-01 .. 2030-12-31.
  Notes:   Idempotent. Inserts only dates not already present.

  Fiscal year assumption: FY runs July 1 - June 30, and is
  named for the ending calendar year (July 2025 = FY2026).
  This is the most common US nonprofit convention. If the
  organization uses a different one, this is the single place
  it changes - which is the point of a conformed dimension.
==============================================================*/

USE MissionImpactDW;
GO

DECLARE @start_date DATE = '2015-01-01';
DECLARE @end_date   DATE = '2030-12-31';

;WITH n AS (
    -- Tally table: generates a row per day without a loop.
    SELECT TOP (DATEDIFF(DAY, @start_date, @end_date) + 1)
           ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS offset_days
    FROM sys.all_objects a
    CROSS JOIN sys.all_objects b
),
d AS (
    SELECT DATEADD(DAY, offset_days, @start_date) AS full_date
    FROM n
)
INSERT INTO dw.dim_date (
    date_key, full_date, day_of_month, day_name, day_of_week,
    is_weekend, week_of_year, month_number, month_name,
    quarter_number, calendar_year, fiscal_year, fiscal_quarter
)
SELECT
    CONVERT(INT, FORMAT(d.full_date, 'yyyyMMdd'))          AS date_key,
    d.full_date,
    DAY(d.full_date)                                        AS day_of_month,
    DATENAME(WEEKDAY, d.full_date)                          AS day_name,
    DATEPART(WEEKDAY, d.full_date)                          AS day_of_week,
    CASE WHEN DATEPART(WEEKDAY, d.full_date) IN (1,7)
         THEN 1 ELSE 0 END                                  AS is_weekend,
    DATEPART(WEEK, d.full_date)                             AS week_of_year,
    MONTH(d.full_date)                                      AS month_number,
    DATENAME(MONTH, d.full_date)                            AS month_name,
    DATEPART(QUARTER, d.full_date)                          AS quarter_number,
    YEAR(d.full_date)                                       AS calendar_year,
    CASE WHEN MONTH(d.full_date) >= 7
         THEN YEAR(d.full_date) + 1
         ELSE YEAR(d.full_date) END                         AS fiscal_year,
    CASE
        WHEN MONTH(d.full_date) BETWEEN 7  AND 9  THEN 1
        WHEN MONTH(d.full_date) BETWEEN 10 AND 12 THEN 2
        WHEN MONTH(d.full_date) BETWEEN 1  AND 3  THEN 3
        ELSE 4
    END                                                     AS fiscal_quarter
FROM d
WHERE NOT EXISTS (
    SELECT 1 FROM dw.dim_date dd
    WHERE dd.date_key = CONVERT(INT, FORMAT(d.full_date, 'yyyyMMdd'))
);
GO

-- Unknown member for facts with a missing or unparseable date
IF NOT EXISTS (SELECT 1 FROM dw.dim_date WHERE date_key = -1)
    INSERT INTO dw.dim_date (
        date_key, full_date, day_of_month, day_name, day_of_week,
        is_weekend, week_of_year, month_number, month_name,
        quarter_number, calendar_year, fiscal_year, fiscal_quarter
    )
    VALUES (-1, '1900-01-01', 1, 'Unknown', 1, 0, 1, 1, 'Unknown', 1, 1900, 1900, 1);
GO

SELECT
    COUNT(*)        AS total_rows,
    MIN(full_date)  AS earliest_date,
    MAX(full_date)  AS latest_date
FROM dw.dim_date
WHERE date_key <> -1;
GO