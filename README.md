# MissionImpactDW

A data platform for a fictional nonprofit called Mission Impact. It pulls student, donor, and staff data into one governed warehouse, checks that data automatically for quality problems, and reports on it through Power BI. A dropout risk model sits on top as one thing the platform can do once the data underneath it is trustworthy.

Built in SQL Server, Python, and Power BI. Everything's version controlled and can be rebuilt from scratch by running the scripts in order.

---

## What's in here

| Area | Where |
|---|---|
| Warehouse architecture | `sql/00`–`sql/04`: database setup, staging, dimensions, facts, date dimension |
| ETL pipeline | `etl/load_staging.py`: loads CSVs into `stg.*` |
| Idempotent transforms | `sql/06`, `sql/07`: MERGE upserts, unique indexes on business keys |
| Dimensional modeling | Star schema, surrogate keys, Unknown members for orphaned rows |
| Data quality checks | `sql/08`: 13 checks, logged to `ops.data_quality_result` |
| Reporting views | `sql/09`–`sql/11`: one definition per metric |
| Predictive model | `sql/13`, `sql/14`, `etl/train_and_score_risk_model.py` |
| Power BI dashboard | `powerbi/mission_impact_dashboard.pbix`: 3 pages |

---

## Architecture

```
Source data (CSV)
  ├── student_dropout_raw.csv     Kaggle: real academic data
  ├── donors.csv, donations.csv   Faker: synthetic Development data
  ├── employees.csv, staff_hours.csv   Faker: synthetic HR data
  └── course_lookup (inline SQL) Static reference table

        │
        ▼

STAGING (stg)
  NVARCHAR everywhere, truncate and reload each run, every row stamped
  with a load_batch_id

        │  MERGE
        ▼

WAREHOUSE (dw)
  Star schema. Dimensions for student, donor, employee, department,
  program, date. Facts for student_term (unpivoted), student_outcome,
  donation, staff_hours, student_risk_score. Every dimension has an
  Unknown member at key -1.

        │  views
        ▼

REPORTING (rpt)
  Governed views, one definition per metric. Raw and clean pairs where
  it matters (donations).

        ├──▶ Power BI: Executive Overview, Data Quality, Student Risk
        └──▶ Predictive model: features view + training view

OPERATIONS (ops)
  etl_run_log and data_quality_result run alongside everything else.
```

---

## Design decisions

**Staging columns are NVARCHAR, not typed.** Source files have bad values in them. A typed column throws a conversion error on the first bad row and doesn't tell you which row it was. NVARCHAR takes it in as-is, a data quality check flags what's wrong, and the warehouse casts types on the way out with `TRY_CONVERT`.

**Dimensions have an Unknown member at key -1.** A donation with a `donor_id` that doesn't exist points at Unknown instead of getting dropped or failing the whole load. The dollar amount still shows up in totals, and anyone checking for orphaned rows can find it.

**Transforms use MERGE.** Match on the business key, update if it exists, insert if it doesn't. Every script can run twice without duplicating anything.

**The ETL log runs on its own connection, separate from the data load.** This came from an actual failure. The first version logged failures on the same transaction as the load, so when something failed and rolled back, it took the log entry explaining the failure down with it too. Moved logging to its own connection so that can't happen again.

**Donations have a raw view and a clean view.** Raw includes everything. Clean filters out anything the outlier check flagged. Dashboards use clean, audits use raw, and a reconciliation query checks that raw total equals clean total plus what got excluded.

**Model features are a SQL view.** Same reason business logic goes in SQL views instead of DAX. One definition, reused by training and scoring, readable without opening Python or Power BI.

**Feature view and training view are two different views.** Features covers every student who can be scored. Training is a smaller set, only students with a resolved outcome, with the target column attached. These used to be one view, which meant currently enrolled students had no outcome yet and got left out entirely. That didn't make sense for a model whose whole job is flagging risk before the outcome happens, since those are exactly the students it needs to score. I split the views once I noticed the problem, and retrained the model on the corrected data.

**Predictions go into a fact table.** `dw.fact_student_risk_score` gets a new row per student per scoring run, tagged with a UUID. Old and new model versions sit side by side, and you can look up what the model said about any student on any date.

---

## Data quality

13 checks, covering completeness, uniqueness, validity, consistency, timeliness, and range checks. Results go to `ops.data_quality_result` and show up on a dashboard page.

The synthetic data has real problems seeded into it on purpose:

- ~44 donations pointing at a `donor_id` that doesn't exist
- ~25 exact duplicate donations
- ~21 donors with no email
- ~5 employees with no department
- ~12 donations between $1M and $10M, way outside normal range

11 of 13 checks pass. The two that fail are the duplicate check and the outlier check. They're supposed to fail, since the problems they're catching were seeded into the data on purpose.

---

## Predictive model

Binary classification. Predicts whether a student drops out, using only first-term grades and demographics.

Only first term, because using second-term data would leak the answer. By the time second-term grades exist, you basically already know how it ends.

Trained logistic regression and gradient boosting on a 75/25 split of `rpt.vw_student_risk_training` (3,630 students with a known outcome), kept whichever scored higher on test AUC. They came out almost even, which says the relationship here is mostly linear.

**Test set results:**

| Model | AUC | F1 | Precision | Recall |
|---|---|---|---|---|
| Logistic regression | 0.936 | 0.872 | 0.889 | 0.856 |
| Gradient boosting | 0.937 | 0.869 | 0.881 | 0.856 |

**Confusion matrix, students with a known outcome (3,630):**

| | Predicted graduate | Predicted dropout |
|---|---|---|
| Actually graduated | 2,110 | 99 |
| Actually dropped out | 214 | 1,207 |

Catches 85% of actual dropouts. When it flags someone as at risk, it's right 92% of the time. Recall matters more here than precision: a false positive just costs one extra conversation with a staff member, a false negative means a student who needed help never got flagged.

An earlier version of this table was wrong. The view feeding it was treating currently-enrolled students as confirmed non-dropouts instead of leaving them out, so they were getting counted in the graduate column even though nobody actually knows their outcome yet. Once that got fixed and the matrix only counted students with a real, known outcome, the model's precision turned out to be better than what had first been reported.

Scoring runs against all 4,424 eligible students, including students still enrolled, and writes to `dw.fact_student_risk_score` with a UUID for the run.

---

## Repo layout

```
mission-impact-dw/
├── sql/
│   ├── 00_create_database.sql
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
├── etl/
│   ├── db_config.py
│   ├── generate_synthetic_data.py
│   ├── load_staging.py
│   └── train_and_score_risk_model.py
├── powerbi/
│   └── mission_impact_dashboard.pbix
├── data/raw/          (gitignored, regenerable)
└── README.md
```

---

## Running it

Needs SQL Server, Python 3.11+, and the Kaggle "Predict Students' Dropout and Academic Success" dataset.

```bash
# run sql/00 through sql/14 in order in SSMS, then:

python etl/generate_synthetic_data.py
# drop the Kaggle CSV at data/raw/student_dropout_raw.csv
python etl/load_staging.py
# run sql/06-14 in SSMS
python etl/train_and_score_risk_model.py
# open powerbi/mission_impact_dashboard.pbix and refresh
```

Everything's idempotent, and every step logs to `ops.etl_run_log`.

---

## What's real and what's not

Real: the Kaggle student dropout dataset, about 4,400 rows, originally from UCI.

Synthetic: donors, donations, employees, staff hours. Generated with Faker on a fixed seed, so it's the same data every time you run it.

Made up: program names. The Kaggle codes are anonymized numbers (1 through 17) with no published mapping, so the names in `dw.dim_program` are placeholders, not real programs. The mapping is in `sql/12_add_course_lookup.sql`.

---

## What I'd do with more time

- Role-based access control. Separate roles for analyst (read-only), ETL service account, admin. Everything currently runs as the DBA. Didn't build this out since it doesn't mean much on a single-user database.
- A real performance tuning case study. At 2,500 rows the optimizer's already fast enough that there's nothing to show. Would need millions of rows before indexing and query rewrites actually made a difference.
- SCD Type 2 on dimensions that currently just overwrite in place. Would matter for things like donor giving-tier history or employee role changes over time.
- Real orchestration instead of running scripts by hand. Something like SQL Server Agent, Airflow, or Azure Data Factory, with actual scheduling and alerting.
- A retraining schedule for the model, plus drift monitoring on the features.
- A real student ID from the source system. Right now it's generated at load time based on row order, which only holds up because the source file never changes.

---

## Stack

SQL Server 2022 Developer Edition, T-SQL, Python 3.14 (pandas, faker, pyodbc, scikit-learn), Power BI Desktop, Git.
