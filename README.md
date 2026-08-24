# MissionImpactDW

A data warehouse, ETL pipeline, governance layer, and predictive analytics stack for a fictional nonprofit ("Mission Impact"). Built end to end in SQL Server, Python, and Power BI.

The idea was to build a small version of a real analytics platform: land raw data from a few different source systems, transform it into a proper warehouse, expose it through documented views, check it for quality on every load, and use it to power a dashboard and a predictive model. Everything here is version controlled and can be rerun from scratch.

---

## What this project demonstrates

| Area | Where it lives |
|---|---|
| Warehouse architecture | `sql/01`–`sql/04`, staging, dimensions, facts, date dim |
| ETL pipeline (Python) | `etl/load_staging.py`, CSV to `stg.*`, own-transaction logging |
| Idempotent transforms | `sql/06`, `sql/07`, MERGE upserts, unique indexes on business keys |
| Dimensional modeling | Star schema, surrogate keys, Unknown members for orphan resolution |
| Data quality framework | `sql/08`, 13 checks across 6 DQ dimensions, logged to `ops.data_quality_result` |
| Governed reporting layer | `sql/09`–`sql/11`, documented views, single source of truth for every metric |
| Raw/clean view pattern | `sql/11`, donations exposed both ways with a reconciliation check |
| Anomaly handling | Outlier donations filtered from business views, kept in an audit view |
| Predictive analytics | `sql/13`, `sql/14`, `etl/train_and_score_risk_model.py`, features in SQL, predictions in a fact table |
| Model comparison | Logistic regression vs. gradient boosting, picked by held-out AUC |
| Power BI semantic model | `powerbi/mission_impact_dashboard.pbix`, explicit measures, hidden internals, clean names |
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
  - NVARCHAR everywhere                    types loose on purpose
  - Truncate and reload per run            not history, safe to rerun
  - Every row stamped with load_batch_id   full lineage

        │  MERGE upserts (idempotent)
        ▼

WAREHOUSE  (dw schema)                   Star schema
  - Dim: student, donor, employee,         every dim has an Unknown
         department, program, date         member (key = -1) so orphan
  - Fact: student_term (unpivoted),        rows land there instead of
          student_outcome, donation,       failing the load
          staff_hours, student_risk_score
  - PERSISTED computed columns             approval_rate, is_dropout
  - Unique indexes on business keys        enforce grain and idempotency

        │  CREATE OR ALTER VIEW
        ▼

REPORTING  (rpt schema)                  Governed semantic layer
  - Every KPI defined once                 single source of truth
  - Header block = data dictionary         documented inline
  - Raw + Clean pairs where needed         donations before and after
                                           outlier filter, both exposed
                                           with a reconciliation check
        │
        ├──▶ Power BI (Import mode)      Executive Overview
        │                                Data Quality
        │                                Student Risk
        │
        └──▶ Predictive model            two-view design:
                                         features (all scorable) and
                                         training (subset with target)

OPERATIONS  (ops schema)                 runs alongside everything
  - etl_run_log                            every step timed and logged
  - data_quality_result                    13 checks, pass/fail history
```

---

## Key design decisions

**Staging is NVARCHAR everywhere, not typed.** Source files lie. A typed staging column throws a conversion error that doesn't tell you which row broke it. NVARCHAR staging takes the bad data in, a data quality check reports it clearly, and the warehouse layer casts on the way out with `TRY_CONVERT` so one bad row doesn't fail the whole load.

**Every dimension has an "Unknown" member at key -1.** When a donation shows up with a `donor_id` that isn't in the donor extract, you've got three choices: drop the row and quietly lose money from the totals, fail the whole load over one bad row, or point it at Unknown. Unknown wins. The dollar amount still counts, and the orphan is visible to anyone checking.

**MERGE for idempotent upserts.** Every transform can rerun safely. Match on the business key, update if it exists, insert if it doesn't. Combined with unique indexes on business keys in the fact tables, a partial failure just gets fixed by rerunning the script.

**Logging happens on its own connection.** The ETL log is separate from the data load's transaction. If the data load rolls back, the log entry explaining why it failed sticks around. First version of this didn't work that way, a rollback wiped out its own log entry, which is a pretty bad way to lose the exact information you need to debug a failure. Fixed it once and used the same pattern in the ML pipeline.

**Raw and Clean views exist side by side.** `rpt.vw_donations_by_fiscal_year` shows everything including outliers. `rpt.vw_donations_by_fiscal_year_clean` filters out anything the data quality check flagged (donations over $100k). Dashboards point to Clean. Anyone auditing points to Raw. There's a reconciliation query that checks `raw = clean + excluded` every time, so if that filter ever drifts out of sync with the audit view, it shows up immediately instead of quietly breaking trust in the numbers.

**Model features live in SQL, not in a notebook.** `rpt.vw_student_risk_features` is where the feature engineering happens. It's version controlled, reusable, and defined once, same reasoning as pushing business logic into SQL views instead of DAX measures. SQL is testable and reviewable without opening Power BI or a notebook to check what's actually happening.

**Feature view and training view are two separate things.** `vw_student_risk_features` returns every student who can be scored, no target column attached. `vw_student_risk_training` is a smaller set, students with a resolved Dropout or Graduate outcome, with the target attached. Splitting these matters because the whole point of an early-warning model is scoring students who are still enrolled, and a single combined view that required a known outcome would make that impossible.

**Predictions get written to a fact table, not saved as a pickle file.** `dw.fact_student_risk_score` treats a prediction like any other measurement in the warehouse. Every scoring run gets its own UUID, so old and new model versions can sit side by side. Anyone can ask "what did the model say about this student, and what actually happened" with a plain SQL query instead of digging through a notebook.

---

## Data quality

13 automated checks run after every load, covering completeness, uniqueness, validity, consistency, timeliness, and accuracy via range checks. Results get logged to `ops.data_quality_result` and show up on a dashboard page.

The synthetic data generator deliberately seeds real problems so these checks have something to catch:
- ~44 donations reference a `donor_id` that doesn't exist in the donor file (orphan FK)
- ~25 exact duplicate donations (uniqueness)
- ~21 donors with no email on file (completeness, informational, nulls are expected here)
- ~5 employees with no department listed (completeness, routes to Unknown dept)
- ~12 donations with wildly out-of-range amounts, $1M to $10M (validity)

Current pass rate is 11 out of 13. The two failures are the duplicate check and the outlier check, catching exactly what they're supposed to catch. A check that never fails isn't really checking anything.

---

## Predictive model

**Task:** binary classification, predict whether a student will drop out using only first-term performance and demographics.

**Why only first-term data?** Using second-term data would leak the answer. By the time you have those numbers, you basically already know the outcome. An early-warning model only works if it warns you early.

**Approach:** train logistic regression and gradient boosting on a 75/25 stratified split of `rpt.vw_student_risk_training` (3,630 students with a resolved outcome). Keep whichever wins on test AUC. They came out almost tied, which suggests the underlying relationship is mostly linear.

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

The model catches 85% of actual dropouts. When it flags someone, it's right about 73% of the time. For this kind of early-warning use case, recall matters more than precision: a false positive just means a staff member has one extra check-in conversation, a false negative means someone who needed help didn't get flagged. Overall accuracy sits at 85%, compared to a 61% baseline if you just guessed "everyone graduates."

Scoring runs against `rpt.vw_student_risk_features`, which covers all 4,424 eligible students, including the ones still enrolled. Every run writes to `dw.fact_student_risk_score` with a UUID attached, so past predictions stay queryable.

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
├── etl/                        python pipelines
│   ├── db_config.py             shared DB connection helper
│   ├── generate_synthetic_data.py   seeded Faker generator
│   ├── load_staging.py          CSV to stg.*
│   └── train_and_score_risk_model.py    feature view to predictions
├── powerbi/
│   └── mission_impact_dashboard.pbix    3 pages
├── data/
│   └── raw/                    ignored by git, fully regenerable
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

# 8. Train and score the model
python etl/train_and_score_risk_model.py

# 9. Open powerbi/mission_impact_dashboard.pbix, refresh
```

Every step is idempotent. Every step logs to `ops.etl_run_log`.

---

## What's synthetic and what's real

- **Real:** the Kaggle student dropout dataset, about 4,400 rows, originally from UCI.
- **Synthetic:** donors, donations, employees, staff hours. Generated with Faker using a fixed seed, so the exact same data comes out every time you run the generator.
- **Made up but plausible:** program names. The Kaggle source ships anonymized numeric course codes (1 through 17) with no published mapping to actual programs. The names in `dw.dim_program` are plausible college-access-nonprofit program names, not real ones. The mapping is in `sql/12_add_course_lookup.sql`.

---

## Known gaps / what I'd do next

Stuff I'd tackle if this were running for real:

- **Role-based access control.** Least-privilege setup, a read-only analyst role, an ETL service account, an admin role. Right now everything runs as the DBA. The design would be one role per schema (`stg`/`dw`/`rpt`/`ops`), granted with something like `GRANT SELECT ON SCHEMA::rpt TO analyst_role`. Didn't build it out here since on a single-user portfolio database it wouldn't mean much.
- **A real query performance case study.** At 2,500 donation rows, the optimizer is already fast enough that a before/after comparison doesn't show anything interesting. I'd want millions of rows to actually demonstrate indexing strategy, rewriting non-SARGable predicates, and reading execution plans.
- **Slowly Changing Dimensions.** Everything here is Type 1, meaning updates just overwrite. Type 2 with effective dates would matter for things like donor giving-tier history or employee role changes over time.
- **Real orchestration.** Right now this is a stack of Python scripts you run manually in order. A real version needs scheduling, a dependency graph, and alerting, something like SQL Server Agent, Airflow, or Azure Data Factory.
- **A retraining schedule for the model.** It trains once and scores once right now. A real deployment needs a retraining cadence, drift monitoring on the features, and a way to compare a new model against the current one before swapping it in.
- **A real source for student IDs.** The Kaggle data has no student ID column at all, so `student_id` gets generated at load time based on row order (`STU00001`, `STU00002`, and so on). That's only stable because the source file never changes. In a real system this would need an actual conversation with whoever owns the source data.

---

## Stack

- **Database:** SQL Server 2022 Developer Edition
- **Language:** T-SQL, Python 3.14
- **Python libraries:** pandas, faker, pyodbc, scikit-learn
- **BI:** Power BI Desktop
- **Version control:** Git
