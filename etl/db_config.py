"""
db_config.py

MissionImpactDW - shared connection helper.

Uses Windows Authentication by default (matches how you connect
in SSMS), so no username/password lives in this repo. If you
ever move to a server that needs SQL auth, set DB_USER / DB_PASS
as environment variables and this will pick them up automatically
- never hardcode credentials here or in any committed file.
"""

import os
import pyodbc

DB_SERVER = os.environ.get("MI_DB_SERVER", "localhost")
DB_NAME = os.environ.get("MI_DB_NAME", "MissionImpactDW")
DB_DRIVER = "{ODBC Driver 18 for SQL Server}"


def get_connection() -> pyodbc.Connection:
    """Return a live connection to MissionImpactDW."""
    user = os.environ.get("MI_DB_USER")
    pwd = os.environ.get("MI_DB_PASS")

    if user and pwd:
        conn_str = (
            f"DRIVER={DB_DRIVER};SERVER={DB_SERVER};DATABASE={DB_NAME};"
            f"UID={user};PWD={pwd};TrustServerCertificate=yes;"
        )
    else:
        conn_str = (
            f"DRIVER={DB_DRIVER};SERVER={DB_SERVER};DATABASE={DB_NAME};"
            f"Trusted_Connection=yes;TrustServerCertificate=yes;"
        )

    conn = pyodbc.connect(conn_str)
    conn.autocommit = False
    return conn
