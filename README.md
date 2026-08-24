# MissionImpactDW

A data warehouse, ETL pipeline, governance layer, and predictive analytics stack for a fictional nonprofit ("Mission Impact"). Built end-to-end in SQL Server, Python, and Power BI.

The point: demonstrate the full lifecycle of an analytics platform — landing raw data from multiple source systems, transforming it into a governed warehouse, exposing it through documented reporting views, checking it for quality on every load, and using it to power both a dashboard and a predictive model. All version-controlled and re-runnable.

---

## What this project demonstrates

| Area | Where it lives |
|---|---|
| Warehouse architecture | `sql/01`–`sql/04` — staging, dimensions, facts, date dim |
| ETL pipeline (Python) | `etl/load_staging.py` — CSV to `stg.*` with own-transaction logging |
| Idempotent transforms | `sql/06`, `sql/07` — MERGE upserts, unique indexes on business keys |
| Dimensional modeling | Star schema, surrogate keys, Unknown members for orphan resolution |
| Data quality framework | `sql/08` — 13 checks across 6 DQ dimensions, results logged to `ops.data_quality_result` |
| Governed reporting layer | `sql/09`–`sql/11` — documented views, single-source-of-truth metrics |
| Raw/clean view pattern | `sql/11` — donations exposed both ways with reconciliation check |
| Anomaly handling | Outlier donations filtered from business views but preserved in an audit view |
| Predictive analytics | `sql/13`, `sql/14`, `etl/train_and_score_risk_model.py` — features in SQL, predictions in a fact table |
| Model comparison + evaluation | Logistic regression vs. gradient boosting, held-out AUC as selection metric |
| Power BI semantic model | `powerbi/mission_impact_dashboard.pbix` — explicit measures, hidden internals, business-friendly names |
| BI dashboard | 3 pages: Executive Overview, Data Quality, Student Risk |

---

## Architecture

```
Source data (CSV)                        Simulated source systems
  ├── student_dropout_raw.csv              Kaggle: real academic data
  ├── donors.csv, donations.csv            Faker: synthetic Development
  ├── employees.csv, staff_hours.csv       Faker: synthetic HR
  └── course_lookup (inline in SQL)        Static reference

        │
        ▼

STAGING  (stg schema)                    Landing zone
  - NVARCHAR everywhere                    Types loose on purpose
  - Truncate-and-reload per run            Not history; safe to re-run
  - Every row stamped with load_batch_id   Full lineage

        │  MERGE upserts (idempotent)
        ▼

WAREHOUSE  (dw schema)                   Star schema
  - Dim: student, donor, employee,         Every dim has an Unknown
         department, program, date         member (key = -1) so orphan
  - Fact: student_term (unpivoted),        rows land there instead of
          student_outcome, donation,       failing the load
          staff_hours, student_risk_score
  - PERSISTED computed columns             approval_rate, is_dropout
  - Unique indexes on business keys        Enforce grain + idempotency

        │  CREATE OR ALTER VIEW
        ▼

REPORTING  (rpt schema)                  Governed semantic layer
  - Every KPI defined once                 Single source of truth
  - Header block = data dictionary         Documented inline
  - Raw + Clean pairs where needed         Donations before/after
                                           outlier filter, both
                                           exposed with reconciliation
        │
        ├──▶ Power BI (Import mode)      Executive Overview
        │                                Data Quality
        │                                Student Risk
        │
        └──▶ Predictive model            Two-view design:
                                         features (all scorable) and
                                         training (subset with target)

OPERATIONS  (ops schema)                 Runs alongside everything
  - etl_run_log                            Every step timed & logged
  - data_quality_result                    13 checks, PASS/FAIL history
```

---

## Key design decisions

**Staging is NVARCHAR everywhere, not typed.** Source files lie. A typed staging column throws a conversion error that tells you nothing about which row broke. NVARCHAR staging accepts bad data, a data quality check reports it clearly, and the warehouse layer casts on the way out with `TRY_CONVERT` so one bad row doesn't fail the load.

**Every dimension has an "Unknown" member at key -1.** When a donation arrives with a `donor_id` that isn't in the donor extract, three options exist: drop the row (revenue silently wrong), fail the load (one bad row blocks everything), or route it to Unknown (money stays in totals, orphan is visible to auditing). Third option wins.

**`MERGE` for idempotent upserts.** Every transform is safe to re-run. Match on the business key — update if exists, insert if not. Combined with unique indexes on business keys in fact tables, a partial failure recovers by simply re-running.

**Own-transaction logging.** The ETL log sits on a separate connection from the data load. If the data transaction rolls back, the log entry explaining *why* survives. Learned this after the first cut logged failures on the same transaction — rollbacks silently erased the audit trail. Fixed the pattern once and reused it in the ML pipeline too.

**Raw and Clean views in parallel.** `rpt.vw_donations_by_fiscal_year` shows everything, outliers included. `rpt.vw_donations_by_fiscal_year_clean` filters out anomalies flagged by data quality (donations over $100k). Business dashboards point to Clean. Diagnostic queries and audits point to Raw. A reconciliation query verifies `raw = clean + excluded` — if it doesn't, the filter is out of sync with the audit view and the governance is broken.

**Features engineered in SQL, not in a notebook.** The predictive model's features live in `rpt.vw_student_risk_features`. Version-controlled, reusable, defined once. Same reason business logic pushes upstream to SQL views rather than living in DAX measures — SQL is testable, reviewable, and doesn't require opening a `.pbix` to inspect.

**Feature view and training view are separate.** `vw_student_risk_features` returns every scorable student, no target column — this is what the scoring pipeline uses. `vw_student_risk_training` is a strict subset (students with resolved Dropout/Graduate outcomes) with the target attached — this is what training uses. Separating them means currently-enrolled students, who are the whole point of an early-warning model, actually get scored.

**Predictions land in a fact table, not a pickle.** `dw.fact_student_risk_score` is a first-class fact. Every scoring run stamps a UUID, so multiple model versions can coexist. Downstream reports join predictions to the rest of the warehouse using standard star-schema mechanics. Model performance is auditable via SQL — "what did the model predict for this student on this date, and what actually happened" is one query.

---

## Data quality

13 automated checks run after every load, covering the standard six dimensions (Completeness, Uniqueness, Validity, Consistency, Accuracy via range checks, Timeliness). Results log to `ops.data_quality_result` and surface in a Power BI dashboard page.

Deliberate messiness is injected during synthetic data generation so the checks have real problems to catch:
- ~44 donations with `donor_id` that don't exist in the donor extract (orphan FK)
- ~25 exact duplicate donations (uniqueness)
- ~21 donors with null email (completeness — informational, nulls are legitimate here)
- ~5 employees with null department (completeness — routes to Unknown dept)
- ~12 donations with outlier amounts $1M–$10M (validity)

Current pass rate: 11 of 13. The two failures are the outlier and duplicate checks, catching exactly what they're supposed to catch. A check that never fails isn't checking anything.

---

## Predictive model

**Task:** binary classification — predict whether a student will drop out based only on first-term performance and demographics.

**Why only first-term features?** Using both terms would be data leakage. By the time you have second-term data, the outcome is basically already known. The point of an early-warning model is to warn early.

**Approach:** train logistic regression and gradient boosting on a 75/25 stratified split of `rpt.vw_student_risk_training` (3,630 students with resolved outcomes). Pick whichever wins on test AUC. In practice both models come out near-tied — a signal that the relationship is mostly linear.

**Results (test set, 25% holdout):**

| Model | AUC | F1 | Precision | Recall |
|---|---|---|---|---|
| Logistic regression | 0.936 | 0.872 | 0.889 | 0.856 |
| Gradient boosting | 0.937 | 0.869 | 0.881 | 0.856 |

**Full-dataset confusion matrix (against 3,630 students with known outcomes):**

| | Predicted graduate | Predicted dropout |
|---|---|---|
| **Actually graduated** | 2,560 (TN) | 443 (FP) |
| **Actually dropped out** | 214 (FN) | 1,207 (TP) |

**Read:** the model catches 85% of actual dropouts (recall). When it flags a student it's right 73% of the time (precision). For an early-warning system the recall matters more than the precision — a false positive means a program staff member has an extra conversation, but a false negative means someone at risk doesn't get help. Overall accuracy 85% versus the "always predict graduate" baseline of 61% on this training subset.

Scoring runs against `rpt.vw_student_risk_features`, which includes all 4,424 eligible students (both resolved-outcome and currently-enrolled). Every scoring run writes to `dw.fact_student_risk_score` with a UUID, so historical predictions are queryable.

---

## Repo layout

```
mission-impact-dw/
├── sql/                        Numbered scripts, run in order
│   ├── 01_create_staging.sql
│   ├── 02_create_dimensions.sql
│   ├── 03_create_facts.sql
│   ├── 04_populate_dim_date.sql
│   ├── 05_alter_student_raw.sql
│   ├── 06_transform_dimensions.sql
│   ├── 07_transform_facts.sql
│   ├── 08_data_quality_checks.sql
│   ├── 09_create_reporting_views.sql
│   ├── 10_add_date_view.sql
│   ├── 11_add_cleaned_donations_view.sql
│   ├── 12_add_course_lookup.sql
│   ├── 13_predictive_layer.sql
│   └── 14_split_features_training_views.sql
├── etl/                        Python pipelines
│   ├── db_config.py             Shared DB connection helper
│   ├── generate_synthetic_data.py   Seeded Faker generator
│   ├── load_staging.py          CSV to stg.*
│   └── train_and_score_risk_model.py    Feature view to predictions
├── powerbi/
│   └── mission_impact_dashboard.pbix    3 pages
├── data/
│   └── raw/                    Ignored by git — regenerable
└── README.md
```

---

## Running from scratch

Assumes SQL Server (Developer Edition or higher), Python 3.11+, and the Kaggle "Predict Students' Dropout and Academic Success" dataset.

```bash
# 1. Create DB and load schemas (SSMS: run in order)
#    sql/01 through sql/14

# 2. Generate synthetic data (donors, donations, employees, staff hours)
python etl/generate_synthetic_data.py

# 3. Drop the Kaggle CSV in place as data/raw/student_dropout_raw.csv

# 4. Load everything into staging
python etl/load_staging.py

# 5. Run transforms (SSMS: 06, 07 in order)

# 6. Data quality (SSMS: 08)

# 7. Reporting + predictive views (SSMS: 09, 10, 11, 12, 13, 14)

# 8. Train & score the model
python etl/train_and_score_risk_model.py

# 9. Open powerbi/mission_impact_dashboard.pbix, refresh
```

Every step is idempotent. Every step logs to `ops.etl_run_log`.

---

## What's synthetic and what's real

- **Real:** the Kaggle student dropout dataset (~4,400 rows, from UCI).
- **Synthetic:** all donors, donations, employees, staff hours (generated by Faker with a fixed seed, so anyone can reproduce the exact same data).
- **Illustrative:** program names. The Kaggle source ships anonymized numeric course codes (1–17) with no published mapping. Names in `dw.dim_program` are plausible college-access-nonprofit program names, not real ones. The mapping lives in `sql/12_add_course_lookup.sql`.

---

## Known gaps / roadmap

Things I'd address next if this were a real system:

- **Role-based access control** — least-privilege model (read-only analyst role, ETL service account, admin). Currently everything runs as the DBA. The design would be one role per schema (`stg`/`dw`/`rpt`/`ops`), granting via `GRANT SELECT ON SCHEMA::rpt TO analyst_role`. Not built out here because on a single-user portfolio DB it's theater.
- **Query performance case study** — scoped out because at 2,500 donation rows the optimizer is efficient enough that meaningful before/after comparisons don't exist. In production I'd inflate to millions of rows and demonstrate indexing strategy, SARGable rewrites, and execution plan analysis.
- **Slowly Changing Dimensions (SCD Type 2)** — currently all dimensions are Type 1 (overwrite). Type 2 with effective dates would matter for donor giving-tier history, employee role changes, etc.
- **Real orchestration** — pipeline is currently a series of manually-run Python scripts. Production would need real scheduling (SQL Server Agent, Airflow, or Azure Data Factory), a proper dependency graph, and alerting.
- **Model retraining schedule** — the risk model trains once and scores once. Production would need a retraining cadence, drift monitoring on the feature distributions, and comparison of new-vs-current model performance before swapping in a new version.
- **Real source of student IDs** — the Kaggle dataset has no student ID column, so `student_id` is generated at load time (`STU00001`, `STU00002`, ...) based on row order. Stable only because the source file doesn't change. In production this gap would be closed by a data governance conversation with the source team.

---

## Stack

- **Database:** SQL Server 2022 Developer Edition
- **Language:** T-SQL, Python 3.14
- **Python libraries:** pandas, faker, pyodbc, scikit-learn
- **BI:** Power BI Desktop
- **Version control:** Git
