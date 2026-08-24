# MissionImpactDW

A data warehouse, ETL pipeline, governance layer, and predictive analytics stack for a fictional nonprofit ("Mission Impact"). Built in SQL Server, Python, and Power BI.

This project models a full analytics platform: raw data comes in from a few source systems, gets transformed into a warehouse, gets exposed through documented views, gets checked for quality on every load, and powers both a dashboard and a predictive model. Everything is version controlled and can be rebuilt from scratch by running the scripts in order.

---

## What this project demonstrates

| Area | Where it lives |
|---|---|
| Warehouse architecture | `sql/01`–`sql/04`: staging, dimensions, facts, date dimension |
| ETL pipeline (Python) | `etl/load_staging.py`: loads CSVs into `stg.*`, logs on its own connection |
| Idempotent transforms | `sql/06`, `sql/07`: MERGE upserts, unique indexes on business keys |
| Dimensional modeling | Star schema, surrogate keys, Unknown members for orphaned rows |
| Data quality framework | `sql/08`: 13 checks across 6 categories, logged to `ops.data_quality_result` |
| Governed reporting layer | `sql/09`–`sql/11`: documented views, one definition per metric |
| Raw/clean view pattern | `sql/11`: donations exposed two ways, with a reconciliation check |
| Anomaly handling | Outlier donations excluded from reporting views, kept in an audit view |
| Predictive analytics | `sql/13`, `sql/14`, `etl/train_and_score_risk_model.py`: features in SQL, predictions in a fact table |
| Model comparison | Logistic regression vs. gradient boosting, selected by test AUC |
| Power BI semantic model | `powerbi/mission_impact_dashboard.pbix`: explicit measures, hidden internal fields |
| BI dashboard | 3 pages: Executive Overview, Data Quality, Student Risk |

---

## Architecture

```
Source data (CSV)                        Source systems
  ├── student_dropout_raw.csv              Kaggle: real academic data
  ├── donors.csv, donations.csv            Faker: synthetic Development data
  ├── employees.csv, staff_hours.csv       Faker: synthetic HR data
  └── course_lookup (inline in SQL)        Static reference table

        │
        ▼

STAGING  (stg schema)                    Landing zone
  - NVARCHAR everywhere                    types are loose on purpose
  - Truncate and reload per run             not history, safe to rerun
  - Every row stamped with load_batch_id    full lineage

        │  MERGE upserts (idempotent)
        ▼

WAREHOUSE  (dw schema)                   Star schema
  - Dim: student, donor, employee,          every dim has an Unknown
         department, program, date          member (key = -1) for
  - Fact: student_term (unpivoted),         orphaned foreign keys
          student_outcome, donation,
          staff_hours, student_risk_score
  - PERSISTED computed columns              approval_rate, is_dropout
  - Unique indexes on business keys         enforce grain and idempotency

        │  CREATE OR ALTER VIEW
        ▼

REPORTING  (rpt schema)                  Governed semantic layer
  - Every KPI defined once                  single source of truth
  - Header block = data dictionary          documented inline
  - Raw + Clean pairs where needed          donations before and after
                                            outlier filter, both exposed,
                                            with a reconciliation check
        │
        ├──▶ Power BI (Import mode)      Executive Overview
        │                                Data Quality
        │                                Student Risk
        │
        └──▶ Predictive model            two-view design:
                                         features (all scorable students)
                                         and training (subset with target)

OPERATIONS  (ops schema)                 runs alongside everything
  - etl_run_log                            every step timed and logged
  - data_quality_result                    13 checks, pass/fail history
```

---

## Key design decisions

**Staging columns are NVARCHAR, not typed.** Source files often contain bad values. A typed staging column fails on the first bad row and tells you nothing about which row it was. NVARCHAR staging accepts the data as-is, a data quality check reports what's wrong, and the warehouse layer converts types on the way out using `TRY_CONVERT`, so one bad row doesn't fail the whole load.

**Every dimension has an Unknown member at key -1.** If a donation references a `donor_id` that doesn't exist in the donor table, there are three options: drop the row, fail the load, or point the row at Unknown. This project uses Unknown. The dollar amount stays in the totals, and the orphaned row is visible to anyone checking for it.

**MERGE handles all transforms.** Every transform matches on a business key, updates if the row exists, inserts if it doesn't. Combined with unique indexes on business keys in the fact tables, this makes every script safe to rerun. A failed load can be fixed by just running the script again.

**The ETL log uses a separate database connection from the data load.** If the data load fails and rolls back, the log entry explaining the failure needs to survive that rollback. An earlier version logged on the same connection, so a rollback also erased the log entry describing what went wrong. Fixed by moving logging to its own connection, used the same approach in the ML pipeline.

**Donations are exposed as both a raw view and a clean view.** `rpt.vw_donations_by_fiscal_year` includes everything, outliers included. `rpt.vw_donations_by_fiscal_year_clean` excludes anything flagged by the data quality check (donations over $100k). Dashboards use the clean view. Audits use the raw view. A reconciliation query checks that `raw total = clean total + excluded total` on every run, so if the filter and the audit view ever get out of sync, it shows up immediately.

**Model features are defined in SQL, not in a notebook.** `rpt.vw_student_risk_features` holds the feature logic. It's version controlled and reused by both training and scoring, the same reasoning behind putting business logic in SQL views instead of DAX measures. SQL can be reviewed and tested without opening Power BI or a notebook.

**Feature view and training view are separate.** `vw_student_risk_features` returns every student eligible for scoring, with no target column. `vw_student_risk_training` is a subset: students with a resolved outcome (Dropout or Graduate), with the target column included. This split matters because an early-warning model needs to score students who are still enrolled. A single combined view that required a known outcome would exclude exactly the students the model is meant to help.

**Predictions are written to a fact table, not saved to a file.** `dw.fact_student_risk_score` treats each prediction as a row like any other fact in the warehouse. Every scoring run gets a UUID, so multiple model versions can exist side by side. Checking what the model predicted for a given student, and what actually happened, is a single SQL query.

---

## Data quality

13 automated checks run after every load, covering completeness, uniqueness, validity, consistency, timeliness, and accuracy (via range checks). Results are logged to `ops.data_quality_result` and shown on a dashboard page.

The synthetic data generator seeds known problems on purpose, so these checks have something real to catch:

- ~44 donations reference a `donor_id` that doesn't exist in the donor table (orphan foreign key)
- ~25 exact duplicate donations (uniqueness)
- ~21 donors with no email on file (completeness — informational, nulls are expected here)
- ~5 employees with no department listed (completeness — routed to Unknown department)
- ~12 donations with amounts between $1M and $10M (validity — outliers)

Current pass rate: 11 of 13. The two failing checks are the duplicate check and the outlier check, and they're supposed to fail, since they're catching problems that were deliberately introduced.

---

## Predictive model

**Task:** binary classification. Predict whether a student will drop out, using only first-term performance and demographics.

**Why only first-term data:** using second-term data would leak the outcome. By the time second-term grades exist, the result is basically already known. An early-warning model has to rely only on information available before the outcome happens.

**Approach:** train logistic regression and gradient boosting on a 75/25 stratified split of `rpt.vw_student_risk_training` (3,630 students with a resolved outcome). Keep whichever model scores higher on test AUC. The two models scored nearly identically, which suggests the relationship between the features and the outcome is close to linear.

**Results (test set, 25% holdout):**

| Model | AUC | F1 | Precision | Recall |
|---|---|---|---|---|
| Logistic regression | 0.936 | 0.872 | 0.889 | 0.856 |
| Gradient boosting | 0.937 | 0.869 | 0.881 | 0.856 |

**Confusion matrix (3,630 students with a known outcome):**

| | Predicted graduate | Predicted dropout |
|---|---|---|
| **Actually graduated** | 2,560 (TN) | 443 (FP) |
| **Actually dropped out** | 214 (FN) | 1,207 (TP) |

The model correctly identifies 85% of actual dropouts (recall). When it flags a student as at-risk, it's correct 73% of the time (precision). Recall matters more than precision for this use case: a false positive costs one extra conversation with a staff member, a false negative means a student who needed help wasn't flagged. Overall accuracy is 85%, compared to 61% if you predicted every student would graduate.

Scoring runs against `rpt.vw_student_risk_features`, which includes all 4,424 eligible students, including students still enrolled. Every scoring run writes to `dw.fact_student_risk_score` with a UUID, so past predictions stay queryable.

---

## Repo layout

```
mission-impact-dw/
├── sql/                        numbered scripts, run in order
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
│   ├── db_config.py             shared DB connection helper
│   ├── generate_synthetic_data.py   seeded Faker generator
│   ├── load_staging.py          loads CSVs into stg.*
│   └── train_and_score_risk_model.py    feature view to predictions
├── powerbi/
│   └── mission_impact_dashboard.pbix    3 pages
├── data/
│   └── raw/                    ignored by git, fully regenerable
└── README.md
```

---

## Running from scratch

Requires SQL Server (Developer Edition or higher), Python 3.11+, and the Kaggle "Predict Students' Dropout and Academic Success" dataset.

```bash
# 1. Create the database and run the schema scripts, in order (SSMS)
#    sql/01 through sql/14

# 2. Generate synthetic data (donors, donations, employees, staff hours)
python etl/generate_synthetic_data.py

# 3. Place the Kaggle CSV at data/raw/student_dropout_raw.csv

# 4. Load everything into staging
python etl/load_staging.py

# 5. Run the transform scripts (SSMS: 06, 07, in order)

# 6. Run the data quality checks (SSMS: 08)

# 7. Run the reporting and predictive view scripts (SSMS: 09, 10, 11, 12, 13, 14)

# 8. Train and score the model
python etl/train_and_score_risk_model.py

# 9. Open powerbi/mission_impact_dashboard.pbix and refresh
```

Every step is idempotent and logs to `ops.etl_run_log`.

---

## What's synthetic and what's real

- **Real:** the Kaggle student dropout dataset, about 4,400 rows, originally from UCI.
- **Synthetic:** donors, donations, employees, staff hours. Generated with Faker using a fixed seed, so the same data is produced every time the generator runs.
- **Fictional but plausible:** program names. The Kaggle source uses anonymized numeric course codes (1 through 17) with no published mapping to real programs. The names in `dw.dim_program` are placeholder names for a college-access nonprofit, not real programs. The mapping is defined in `sql/12_add_course_lookup.sql`.

---

## Known gaps / what I'd do next

Things that would need to change for a production system:

- **Role-based access control.** A least-privilege model with a read-only analyst role, an ETL service account, and an admin role. Everything currently runs as the database owner. The design would grant access per schema, for example `GRANT SELECT ON SCHEMA::rpt TO analyst_role`. Not built out here since it wouldn't demonstrate anything meaningful on a single-user database.
- **A real performance tuning case study.** At 2,500 donation rows, the query optimizer is already fast enough that a before/after comparison isn't meaningful. This would require a larger dataset, on the order of millions of rows, to actually show indexing strategy, query rewrites, and execution plan analysis.
- **Slowly Changing Dimensions.** All dimensions currently use Type 1 (overwrite on update). Type 2, with effective dates, would matter for tracking history like donor giving-tier changes or employee role changes.
- **Real orchestration.** The pipeline is currently a set of Python scripts run manually in sequence. A production version needs scheduling, dependency management, and alerting, for example through SQL Server Agent, Airflow, or Azure Data Factory.
- **A retraining schedule for the model.** The model currently trains once and scores once. A production version would need a retraining schedule, drift monitoring on the input features, and a comparison step before replacing the current model with a new one.
- **A real source for student IDs.** The Kaggle dataset has no student ID column. `student_id` is generated at load time based on row order (`STU00001`, `STU00002`, etc.). This is only stable because the source file doesn't change between runs. A production system would need an actual student ID from the source system.

---

## Stack

- **Database:** SQL Server 2022 Developer Edition
- **Language:** T-SQL, Python 3.14
- **Python libraries:** pandas, faker, pyodbc, scikit-learn
- **BI:** Power BI Desktop
- **Version control:** Git
