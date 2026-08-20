"""
load_staging.py

MissionImpactDW - Staging Load
--------------------------------------------------------------
Loads all four raw sources into their stg.* landing tables:
    data/raw/student_dropout_raw.csv  -> stg.student_raw
    data/raw/donors.csv               -> stg.donor_raw
    data/raw/donations.csv            -> stg.donation_raw
    data/raw/employees.csv            -> stg.employee_raw
    data/raw/staff_hours.csv          -> stg.staff_hours_raw

Design:
    - Idempotent: each table is truncated before reload, so
      re-running this script never duplicates staging data.
      (Staging is a landing zone, not history - re-truncating
      it is safe and correct. The warehouse layer, loaded
      later, is where idempotency needs the merge/upsert
      pattern instead, because that layer IS the history.)
    - Every run gets a single load_batch_id (a GUID) stamped
      onto every row it inserts, across all five tables. That
      batch id ties the data back to its ops.etl_run_log entry,
      so any row in the warehouse can be traced to the exact
      run that loaded it. This is what "lineage" means in
      practice, not just in the vocabulary sheet.
    - Every step is timed and logged to ops.etl_run_log,
      success or failure, so a run you didn't watch live is
      still fully auditable afterward.
    - Column renaming for the Kaggle file happens here, not in
      SQL - the staging table stores the target shape, and this
      script is the one place responsible for getting the
      messy real-world source into that shape.

Run:
    python load_staging.py
"""

import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

import pandas as pd
import pyodbc

from db_config import get_connection

DATA_DIR = Path(__file__).resolve().parent.parent / "data" / "raw"
PIPELINE_NAME = "load_staging"

# ----------------------------------------------------------------
# Kaggle source column -> stg.student_raw column
# ----------------------------------------------------------------
STUDENT_COLUMN_MAP = {
    "Marital status": "marital_status",
    "Application mode": "application_mode",
    "Application order": "application_order",
    "Course": "course",
    "Daytime/evening attendance": "attendance_type",
    "Previous qualification": "previous_qualification",
    "Nacionality": "nationality",
    "Mother's qualification": "mothers_qualification",
    "Father's qualification": "fathers_qualification",
    "Mother's occupation": "mothers_occupation",
    "Father's occupation": "fathers_occupation",
    "Displaced": "displaced",
    "Educational special needs": "educational_special_needs",
    "Debtor": "debtor",
    "Tuition fees up to date": "tuition_fees_up_to_date",
    "Gender": "gender",
    "Scholarship holder": "scholarship_holder",
    "Age at enrollment": "age_at_enrollment",
    "International": "international",
    "Curricular units 1st sem (credited)": "sem1_units_credited",
    "Curricular units 1st sem (enrolled)": "sem1_units_enrolled",
    "Curricular units 1st sem (evaluations)": "sem1_units_evaluations",
    "Curricular units 1st sem (approved)": "sem1_units_approved",
    "Curricular units 1st sem (grade)": "sem1_units_grade",
    "Curricular units 1st sem (without evaluations)": "sem1_units_without_evaluations",
    "Curricular units 2nd sem (credited)": "sem2_units_credited",
    "Curricular units 2nd sem (enrolled)": "sem2_units_enrolled",
    "Curricular units 2nd sem (evaluations)": "sem2_units_evaluations",
    "Curricular units 2nd sem (approved)": "sem2_units_approved",
    "Curricular units 2nd sem (grade)": "sem2_units_grade",
    "Curricular units 2nd sem (without evaluations)": "sem2_units_without_evaluations",
    "Unemployment rate": "unemployment_rate",
    "Inflation rate": "inflation_rate",
    "GDP": "gdp",
    "Target": "target",
}
# Columns stg.student_raw expects that this Kaggle mirror doesn't provide.
# Loaded as NULL rather than dropped from the table - keeps the staging
# schema stable even if a future source DOES provide them.
STUDENT_MISSING_SOURCE_COLS = ["previous_qualification_grade", "admission_grade"]


def log_step(log_cur, batch_id, step_name, target_object, started_at,
             status, rows_read=None, rows_written=None, error_message=None):
    """Writes to ops.etl_run_log on its OWN connection/transaction.

    This is deliberate, not an oversight: if it shared the main data
    transaction, a rollback on failure would also erase the log row
    explaining the failure - exactly the moment you need it most.
    Logging is committed immediately and independently so the audit
    trail survives regardless of what happens to the data load.
    """
    log_cur.execute(
        """
        INSERT INTO ops.etl_run_log
            (load_batch_id, pipeline_name, step_name, target_object,
             started_at_utc, ended_at_utc, rows_read, rows_written, run_status, error_message)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        batch_id, PIPELINE_NAME, step_name, target_object,
        started_at, datetime.now(timezone.utc), rows_read, rows_written,
        status, error_message,
    )
    log_cur.connection.commit()


def load_table(cur, log_cur, batch_id, csv_path: Path, stg_table: str,
                column_map: dict | None = None, extra_null_cols=None):
    """Read a CSV, optionally rename columns, truncate the target
    staging table, and bulk-insert. Returns rows written."""
    step_started = datetime.now(timezone.utc)
    step_name = f"load_{stg_table}"

    try:
        df = pd.read_csv(csv_path, dtype=str)  # everything as text - stg is NVARCHAR
        rows_read = len(df)

        if column_map:
            df = df.rename(columns=column_map)

        if extra_null_cols:
            for col in extra_null_cols:
                df[col] = None

        df["src_file_name"] = csv_path.name
        df["load_batch_id"] = str(batch_id)

        # Truncate first - staging is a landing zone, not history.
        cur.execute(f"TRUNCATE TABLE {stg_table};")

        cols = list(df.columns)
        placeholders = ",".join("?" for _ in cols)
        col_list = ",".join(f"[{c}]" for c in cols)
        insert_sql = f"INSERT INTO {stg_table} ({col_list}) VALUES ({placeholders})"

        # NaN -> None so pyodbc sends real NULLs, not the string "nan".
        # Doing this with df.where(pd.notna(df), None) across a whole
        # DataFrame at once isn't fully reliable with mixed dtypes -
        # pandas' read_csv(dtype=str) still represents an empty/missing
        # cell as an actual float NaN, not the string "nan", regardless
        # of the column's intended dtype. A NaN slipping through as a
        # literal float parameter is exactly what caused the "not a
        # valid instance of data type float" error. Converting value by
        # value, explicitly, removes any ambiguity.
        import math

        def clean(v):
            if v is None:
                return None
            if isinstance(v, float) and math.isnan(v):
                return None
            return v

        raw_rows = df.values.tolist()
        data = [[clean(v) for v in row] for row in raw_rows]

        # fast_executemany infers each column's SQL type from the first
        # row of the batch, then reuses that inference for every row.
        # When a column's later rows don't match what the first row
        # implied (common with NVARCHAR columns that are numeric-looking
        # in some rows and not others, or a UNIQUEIDENTIFIER column mixed
        # with the rest of a batch), that mismatch surfaces as exactly
        # this kind of "numeric value out of range" error - it's a known
        # fast_executemany fragility, not a real data problem. Turning it
        # off falls back to row-by-row binding, which is slower but
        # infers each value's type individually and is far more reliable.
        # These tables are small (thousands of rows), so the speed cost
        # here is negligible.
        cur.fast_executemany = False
        cur.executemany(insert_sql, data)

        rows_written = len(data)
        log_step(log_cur, batch_id, step_name, stg_table, step_started,
                  "Succeeded", rows_read=rows_read, rows_written=rows_written)
        print(f"  [OK] {stg_table}: {rows_written} rows loaded")
        return rows_written

    except Exception as e:
        log_step(log_cur, batch_id, step_name, stg_table, step_started,
                  "Failed", error_message=str(e)[:2000])
        print(f"  [FAIL] {stg_table}: {e}")
        raise


def main():
    batch_id = uuid.uuid4()
    print(f"Load batch: {batch_id}\n")

    conn = get_connection()          # main data-loading transaction
    cur = conn.cursor()

    log_conn = get_connection()      # independent connection for ops logging
    log_conn.autocommit = True
    log_cur = log_conn.cursor()

    sources = [
        (DATA_DIR / "student_dropout_raw.csv", "stg.student_raw",
         STUDENT_COLUMN_MAP, STUDENT_MISSING_SOURCE_COLS),
        (DATA_DIR / "donors.csv", "stg.donor_raw", None, None),
        (DATA_DIR / "donations.csv", "stg.donation_raw", None, None),
        (DATA_DIR / "employees.csv", "stg.employee_raw", None, None),
        (DATA_DIR / "staff_hours.csv", "stg.staff_hours_raw", None, None),
    ]

    total_rows = 0
    try:
        for csv_path, stg_table, col_map, extra_nulls in sources:
            if not csv_path.exists():
                raise FileNotFoundError(
                    f"Expected source file not found: {csv_path}\n"
                    f"  -> Run generate_synthetic_data.py first, or check the "
                    f"Kaggle CSV was renamed/placed correctly."
                )
            total_rows += load_table(cur, log_cur, batch_id, csv_path, stg_table,
                                      col_map, extra_nulls)

        conn.commit()
        print(f"\nAll staging tables loaded successfully. Total rows: {total_rows}")
        print(f"Batch id: {batch_id}")

    except Exception:
        conn.rollback()
        print("\nLoad FAILED - transaction rolled back. No partial data left in staging.")
        print("See ops.etl_run_log for the failure detail (that log entry is NOT")
        print("rolled back - it lives on its own connection specifically so this")
        print("kind of failure is still fully diagnosable afterward.)")
        sys.exit(1)

    finally:
        cur.close()
        conn.close()
        log_cur.close()
        log_conn.close()


if __name__ == "__main__":
    main()
