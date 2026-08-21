"""
train_and_score_risk_model.py

Trains a dropout risk classifier on rpt.vw_student_risk_training
and writes predictions for every student in rpt.vw_student_risk_features
to dw.fact_student_risk_score.

Runs like an ETL job - logs every step to ops.etl_run_log, stamps
runs with a UUID, safe to re-run.

Run:
    python train_and_score_risk_model.py
"""

import sys
import uuid
from datetime import datetime, timezone

import numpy as np
import pandas as pd
from sklearn.model_selection import train_test_split
from sklearn.linear_model import LogisticRegression
from sklearn.ensemble import GradientBoostingClassifier
from sklearn.preprocessing import StandardScaler
from sklearn.metrics import (roc_auc_score, precision_score, recall_score,
                              f1_score, accuracy_score, confusion_matrix)

from db_config import get_connection

PIPELINE_NAME = "train_and_score_risk_model"
MODEL_VERSION = "v2"
RANDOM_STATE = 42
HIGH_RISK_THRESHOLD = 0.60
MEDIUM_RISK_THRESHOLD = 0.30
TARGET_COLUMN = "is_dropout"
KEY_COLUMNS = ["student_key", "student_id"]


def log_step(log_cur, batch_id, step_name, target_object, started_at,
             status, rows_read=None, rows_written=None, error_message=None):
    # Own connection so a rollback doesn't wipe the log entry.
    log_cur.execute(
        """
        INSERT INTO ops.etl_run_log
            (load_batch_id, pipeline_name, step_name, target_object,
             started_at_utc, ended_at_utc, rows_read, rows_written,
             run_status, error_message)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        batch_id, PIPELINE_NAME, step_name, target_object,
        started_at, datetime.now(timezone.utc), rows_read, rows_written,
        status, error_message,
    )
    log_cur.connection.commit()


def risk_tier(prob: float) -> str:
    if prob >= HIGH_RISK_THRESHOLD:
        return "High"
    if prob >= MEDIUM_RISK_THRESHOLD:
        return "Medium"
    return "Low"


def load_view(cur, view_name: str) -> pd.DataFrame:
    cur.execute(f"SELECT * FROM {view_name}")
    cols = [c[0] for c in cur.description]
    rows = cur.fetchall()
    return pd.DataFrame.from_records(rows, columns=cols)


def train_and_evaluate(training_df: pd.DataFrame):
    feature_cols = [c for c in training_df.columns
                     if c not in KEY_COLUMNS + [TARGET_COLUMN]]

    X = training_df[feature_cols].astype(float).values
    y = training_df[TARGET_COLUMN].astype(int).values

    X_train, X_test, y_train, y_test = train_test_split(
        X, y, test_size=0.25, stratify=y, random_state=RANDOM_STATE
    )

    results = {}

    # Logreg needs scaling to converge properly.
    scaler = StandardScaler().fit(X_train)
    X_train_s = scaler.transform(X_train)
    X_test_s = scaler.transform(X_test)

    lr = LogisticRegression(max_iter=1000, random_state=RANDOM_STATE)
    lr.fit(X_train_s, y_train)
    lr_prob = lr.predict_proba(X_test_s)[:, 1]
    lr_pred = (lr_prob >= 0.5).astype(int)
    results["logistic_regression"] = {
        "model": lr,
        "scaler": scaler,
        "metrics": _score(y_test, lr_pred, lr_prob),
    }

    gb = GradientBoostingClassifier(
        n_estimators=200, max_depth=3, random_state=RANDOM_STATE
    )
    gb.fit(X_train, y_train)
    gb_prob = gb.predict_proba(X_test)[:, 1]
    gb_pred = (gb_prob >= 0.5).astype(int)
    results["gradient_boosting"] = {
        "model": gb,
        "scaler": None,
        "metrics": _score(y_test, gb_pred, gb_prob),
    }

    _report(results)

    winner_name = max(results, key=lambda k: results[k]["metrics"]["auc"])
    return winner_name, results[winner_name], feature_cols


def _score(y_true, y_pred, y_prob) -> dict:
    return {
        "accuracy":  accuracy_score(y_true, y_pred),
        "precision": precision_score(y_true, y_pred, zero_division=0),
        "recall":    recall_score(y_true, y_pred, zero_division=0),
        "f1":        f1_score(y_true, y_pred, zero_division=0),
        "auc":       roc_auc_score(y_true, y_prob),
        "confusion": confusion_matrix(y_true, y_pred).tolist(),
    }


def _report(results: dict):
    print("\n--- Model comparison (test set) ---")
    print(f"{'model':<22} {'AUC':>7} {'F1':>7} {'Precision':>10} {'Recall':>8}")
    for name, r in results.items():
        m = r["metrics"]
        print(f"{name:<22} {m['auc']:>7.3f} {m['f1']:>7.3f} "
              f"{m['precision']:>10.3f} {m['recall']:>8.3f}")


def score_all_students(winner: dict, feature_cols: list, scoring_df: pd.DataFrame):
    X_all = scoring_df[feature_cols].astype(float).values
    if winner["scaler"] is not None:
        X_all = winner["scaler"].transform(X_all)
    probs = winner["model"].predict_proba(X_all)[:, 1]

    return pd.DataFrame({
        "student_key": scoring_df["student_key"].values,
        "predicted_probability": probs,
        "predicted_class": (probs >= 0.5).astype(int),
        "risk_tier": [risk_tier(p) for p in probs],
    })


def write_scores(cur, batch_id, winner_name, scores_df):
    rows = [
        (int(r.student_key), batch_id, MODEL_VERSION, winner_name,
         float(r.predicted_probability), int(r.predicted_class), r.risk_tier)
        for r in scores_df.itertuples()
    ]
    # fast_executemany off - type inference issues on mixed columns.
    cur.fast_executemany = False
    cur.executemany(
        """
        INSERT INTO dw.fact_student_risk_score
            (student_key, model_run_id, model_version, model_algorithm,
             predicted_probability, predicted_class, risk_tier)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
        rows,
    )
    return len(rows)


def main():
    batch_id = uuid.uuid4()
    print(f"Model run id: {batch_id}\n")

    conn = get_connection()
    cur = conn.cursor()

    log_conn = get_connection()
    log_conn.autocommit = True
    log_cur = log_conn.cursor()

    try:
        started = datetime.now(timezone.utc)
        print("Loading training set...")
        training_df = load_view(cur, "rpt.vw_student_risk_training")
        print(f"  Loaded {len(training_df)} rows for training.")
        log_step(log_cur, batch_id, "load_training", "rpt.vw_student_risk_training",
                  started, "Succeeded",
                  rows_read=len(training_df), rows_written=len(training_df))

        started = datetime.now(timezone.utc)
        print("Loading scoring set...")
        scoring_df = load_view(cur, "rpt.vw_student_risk_features")
        print(f"  Loaded {len(scoring_df)} rows for scoring.")
        log_step(log_cur, batch_id, "load_scoring", "rpt.vw_student_risk_features",
                  started, "Succeeded",
                  rows_read=len(scoring_df), rows_written=len(scoring_df))

        started = datetime.now(timezone.utc)
        print("\nTraining models...")
        winner_name, winner, feature_cols = train_and_evaluate(training_df)
        print(f"\nSelected: {winner_name} "
              f"(test AUC = {winner['metrics']['auc']:.3f})")
        log_step(log_cur, batch_id, "train_models", "in-memory",
                  started, "Succeeded",
                  error_message=f"selected {winner_name} AUC={winner['metrics']['auc']:.3f}")

        started = datetime.now(timezone.utc)
        print("\nScoring all eligible students...")
        scores = score_all_students(winner, feature_cols, scoring_df)
        tier_counts = scores["risk_tier"].value_counts().to_dict()
        print(f"  Risk tier distribution: {tier_counts}")
        log_step(log_cur, batch_id, "score_students", "in-memory",
                  started, "Succeeded", rows_written=len(scores))

        started = datetime.now(timezone.utc)
        print("\nWriting scores to warehouse...")
        rows_written = write_scores(cur, batch_id, winner_name, scores)
        conn.commit()
        log_step(log_cur, batch_id, "write_scores", "dw.fact_student_risk_score",
                  started, "Succeeded", rows_written=rows_written)
        print(f"  Wrote {rows_written} predictions.")

        print(f"\nDone. Model run id: {batch_id}")
        print("Query rpt.vw_student_risk_latest to see the results.")

    except Exception as e:
        conn.rollback()
        log_step(log_cur, batch_id, "pipeline_failure", None,
                  datetime.now(timezone.utc), "Failed",
                  error_message=str(e)[:2000])
        print(f"\nFAILED: {e}", file=sys.stderr)
        sys.exit(1)

    finally:
        cur.close()
        conn.close()
        log_cur.close()
        log_conn.close()


if __name__ == "__main__":
    main()
