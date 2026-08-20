/*==============================================================
  MissionImpactDW - Patch: reporting-cleaned donations view
  Purpose: rpt.vw_donations_by_fiscal_year is the RAW view.
           It exposes everything including outliers, so anomaly
           detection queries and data quality reporting can see
           the full picture.

           This adds a CLEAN version that excludes flagged
           outliers, so business dashboards report on trusted
           donations only. .

           A separate diagnostic view surfaces WHAT got
           excluded and WHY, so nothing is hidden from
           governance. Users can always audit the filter.

  Notes:   Idempotent via CREATE OR ALTER.
==============================================================*/

USE MissionImpactDW;
GO

/*--------------------------------------------------------------
  rpt.vw_donations_by_fiscal_year_clean
  Same shape as vw_donations_by_fiscal_year, but excludes
  donations flagged by the amount-outlier data quality check
--------------------------------------------------------------*/
CREATE OR ALTER VIEW rpt.vw_donations_by_fiscal_year_clean AS
SELECT
    d.fiscal_year,
    COUNT(*)                                             AS gift_count,
    COUNT(DISTINCT f.donor_key)                            AS unique_donor_count,
    SUM(f.amount)                                          AS total_raised,
    CAST(AVG(f.amount) AS DECIMAL(12,2))                    AS avg_gift_size,
    SUM(CASE WHEN f.donor_key = -1 THEN f.amount ELSE 0 END) AS raised_from_unknown_donors
FROM dw.fact_donation f
JOIN dw.dim_date d ON d.date_key = f.date_key
WHERE d.date_key <> -1
  AND f.amount <= 100000  -- outlier threshold, matches DQ check
GROUP BY d.fiscal_year;
GO

CREATE OR ALTER VIEW rpt.vw_donation_exclusions AS
SELECT
    f.donation_id,
    d.donor_name,
    dt.full_date AS donation_date,
    f.amount,
    f.campaign,
    'amount_over_100k' AS exclusion_reason
FROM dw.fact_donation f
LEFT JOIN dw.dim_donor d ON d.donor_key = f.donor_key
LEFT JOIN dw.dim_date dt ON dt.date_key = f.date_key
WHERE f.amount > 100000;
GO


PRINT 'Cleaned donations view and exclusions view created.';
GO

SELECT
    (SELECT SUM(total_raised) FROM rpt.vw_donations_by_fiscal_year)       AS raw_total,
    (SELECT SUM(total_raised) FROM rpt.vw_donations_by_fiscal_year_clean) AS clean_total,
    (SELECT SUM(amount)       FROM rpt.vw_donation_exclusions)             AS excluded_total,
    (SELECT SUM(total_raised) FROM rpt.vw_donations_by_fiscal_year)
     - (SELECT SUM(total_raised) FROM rpt.vw_donations_by_fiscal_year_clean)
     - (SELECT SUM(amount) FROM rpt.vw_donation_exclusions)                AS reconciliation_delta;
GO
