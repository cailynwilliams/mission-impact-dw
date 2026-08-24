# MissionImpactDW

A data warehouse, ETL pipeline, governance layer, and predictive model for a fictional nonprofit called Mission Impact. Built in SQL Server, Python, and Power BI.

Raw data comes in from a few source systems, gets transformed into a warehouse, gets exposed through documented views, gets checked for quality on every load, and powers a dashboard and a dropout risk model. Everything's version controlled and can be rebuilt by running the scripts in order.

---

## What's in here

| Area | Where |
|---|---|
| Warehouse architecture | `sql/01`–`sql/04`: staging, dimensions, facts, date dimension |
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

## Why some of this is built the way it is

**Staging columns are NVARCHAR, not typed.** Source files have bad values in them. A typed column throws a conversion error on the first bad row and tells you nothing useful. NVARCHAR takes it in as-is, a data quality check flags what's wrong, and the warehouse casts types on the way out with `TRY_CONVERT`.

**Dimensions have an Unknown member at key -1.** A donation with a `donor_id` that doesn't exist gets pointed at Unknown instead of dropped or failing the whole load. The dollar amount still shows up in totals, and it's visible to anyone checking for orphaned rows.

**Transforms use MERGE.** Match on the business key, update if it exists, insert if it doesn't. Every script can run twice without duplicating anything.

**The ETL log runs on its own connection, separate from the data load.** Found this out the hard way. First version logged failures on the same transaction as the load, so a rollback wiped out the log entry explaining what went wrong. Moved logging to its own connection after that.

**Donations have a raw view and a clean view.** Raw includes everything. Clean filters out anything the outlier check flagged. Dashboards use clean, audits use raw, and a reconciliation query checks that raw total equals clean total plus what got excluded.

**Model features are a SQL view, not a notebook cell.** Same reason business logic goes in SQL views instead of DAX. It's one definition, reused by training and scoring, and anyone can read it without opening Python or Power BI.

**Feature view and training view are two different views.** Features covers every student who can be scored. Training is a subset, only students with a resolved outcome, with the target column attached. Originally these were one view, which meant currently enrolled students had no outcome yet and got excluded entirely. That's backwards for a model whose whole job is flagging risk before the outcome happens. Split them once I caught it.

**Predictions go into a fact table.** Not a pickle file, not a CSV. `dw.fact_student_risk_score` gets a new row per student per scoring run, tagged with a UUID, so old and new model versions sit side by side and you can query what the model said about any student on any date.

---

## Data quality

13 checks, covering completeness, uniqueness, validity, consistency, timeliness, and range checks. Results go to `ops.data_quality_result` and show up on a dashboard page.

The synthetic data has real problems seeded into it on purpose:

- ~44 donations pointing at a `donor_id` that doesn't exist
- ~25 exact duplicate donations
- ~21 donors with no email
- ~5 employees with no department
- ~12 donations between $1M and $10M, way outside normal range

11 of 13 checks pass. The two that fail are the duplicate check and the outlier check, and they're supposed to fail, since that's exactly what they're built to catch.

---

## Predictive model

Binary classification. Predicts whether a student drops out, using only first-term grades and demographics.

Only first term, because using second-term data would leak the answer. By the time second-term grades exist, you already basically know the outcome.

Trained logistic regression and gradient boosting on a 75/25 split of `rpt.vw_student_risk_training` (3,630 students with a known outcome), kept whichever scored higher on test AUC. They came out almost even, which says the relationship here is mostly linear.

**Test set results:**

| Model | AUC | F1 | Precision | Recall |
|---|---|---|---|---|
| Logistic regression | 0.936 | 0.872 | 0.889 | 0.856 |
| Gradient boosting | 0.937 | 0.869 | 0.881 | 0.856 |

**Confusion matrix, full training population:**

| | Predicted graduate | Predicted dropout |
|---|---|---|
| Actually graduated | 2,560 | 443 |
| Actually dropped out | 214 | 1,207 |

Catches 85% of actual dropouts. When it flags someone, it's right about 73% of the time. Recall matters more here than precision. A false positive is one extra conversation with a staff member. A false negative is a student who needed help and didn't get flagged.

Scoring runs against all 4,424 eligible students, including students still enrolled, and writes to `dw.fact_student_risk_score` with a UUID for the run.

---

## Repo layout

```
mission-impact-dw/
├── sql/
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
# run sql/01 through sql/14 in order in SSMS, then:

python etl/generate_synthetic_data.py
# drop the Kaggle CSV at data/raw/student_dropout_raw.csv
python etl/load_staging.py
# run sql/06-14 in SSMS
python etl/train_and_score_risk_model.py
# open powerbi/mission_impact_dashboard.pbix and refresh
```

Everything's idempotent. Everything logs to `ops.etl_run_log`.

---

## What's real and what's not

Real: the Kaggle student dropout dataset, ~4,400 rows, originally from UCI.

Synthetic: donors, donations, employees, staff hours, generated with Faker on a fixed seed so it's reproducible.

Made up: program names. The Kaggle codes are anonymized numbers (1–17) with no published mapping, so the names in `dw.dim_program` are placeholders, not real programs. Mapping's in `sql/12_add_course_lookup.sql`.

---

## What I'd do with more time

- Role-based access control: separate roles for analyst (read-only), ETL service account, admin. Currently everything runs as the DBA. Didn't build this out since it doesn't mean much on a single-user database.
- A real performance tuning case study. At 2,500 rows the optimizer's already fast, so there's nothing to show. Would need millions of rows to make indexing and query rewrites actually matter.
- SCD Type 2 on dimensions that currently overwrite in place. Would matter for donor giving-tier history or employee role changes over time.
- Real orchestration instead of running scripts by hand, through something like SQL Server Agent, Airflow, or Azure Data Factory, with scheduling and alerting.
- A retraining schedule for the model, plus drift monitoring on the features.
- A real student ID from the source system. Right now it's generated at load time based on row order, which only works because the source file doesn't change.

---

## Stack

SQL Server 2022 Developer Edition, T-SQL, Python 3.14 (pandas, faker, pyodbc, scikit-learn), Power BI Desktop, Git.
