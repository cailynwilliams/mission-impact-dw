"""
generate_synthetic_data.py

MissionImpactDW - Synthetic Data Generator
--------------------------------------------------------------
Generates CSVs for the three departments the Kaggle dataset does
NOT cover: Development (donors/donations), HR (employees), and
staff hours. Output lands in data/raw/ and matches the shape of
the stg.* staging tables exactly, so loading later is a
straight column-for-column copy.

Deliberate messiness is injected on purpose (see MESSY CONFIG
below) - it gives the data quality checks something real to
catch, instead of validating against data that's already clean.

Run:
    python generate_synthetic_data.py

Output:
    data/raw/donors.csv
    data/raw/donations.csv
    data/raw/employees.csv
    data/raw/staff_hours.csv
"""

import random
import uuid
from datetime import date, timedelta
from pathlib import Path

import pandas as pd
from faker import Faker

# ----------------------------------------------------------------
# Config
# ----------------------------------------------------------------
SEED = 42                      # reproducible runs
N_DONORS = 400
N_DONATIONS = 2500
N_EMPLOYEES = 60
WEEKS_OF_STAFF_HOURS = 104     # 2 years of weekly logs

OUTPUT_DIR = Path(__file__).resolve().parent.parent / "data" / "raw"

# MESSY CONFIG - deliberate data quality problems.
# Each is a *rate*, not a count, so it scales if you change N above.
PCT_DONATIONS_ORPHAN_DONOR = 0.015    # donor_id that doesn't exist in donors.csv
PCT_DONATIONS_DUPLICATE    = 0.01     # exact duplicate donation rows
PCT_EMPLOYEES_NULL_DEPT    = 0.05     # blank department
PCT_DONORS_NULL_EMAIL      = 0.08     # missing email
PCT_DONATIONS_BAD_AMOUNT   = 0.004    # absurd outlier amount (typo simulation)

random.seed(SEED)
fake = Faker()
Faker.seed(SEED)


# ----------------------------------------------------------------
# Reference lists - keep these realistic for a college-access nonprofit
# ----------------------------------------------------------------
DEPARTMENTS = ["Programs", "Development", "HR", "Finance", "IT", "Executive"]
JOB_TITLES = {
    "Programs":    ["Program Manager", "Program Coordinator", "Tutor", "Advisor",
                     "Director of Programs"],
    "Development": ["Development Officer", "Grants Manager", "Development Coordinator",
                     "Director of Development"],
    "HR":          ["HR Generalist", "HR Manager", "Recruiter"],
    "Finance":     ["Staff Accountant", "Finance Manager", "Controller"],
    "IT":          ["Data Analyst", "IT Support Specialist", "Systems Administrator"],
    "Executive":   ["Executive Director", "Chief Operating Officer"],
}
DONOR_TYPES = ["individual", "individual", "individual", "corporate", "foundation"]
CAMPAIGNS = ["Spring Appeal", "Year-End Giving", "Gala 2025", "Gala 2026",
             "Monthly Giving", "Corporate Match", "Alumni Fund"]
PAYMENT_METHODS = ["credit_card", "ach", "check", "paypal", "stock_transfer"]
REGIONS = ["MA", "NY", "CT", "RI", "NH", "National"]
PROGRAM_AREAS = ["College Access", "College Persistence", "Career Readiness",
                  "Alumni Support"]


# ----------------------------------------------------------------
# Generators
# ----------------------------------------------------------------
def generate_donors(n: int) -> pd.DataFrame:
    rows = []
    for i in range(1, n + 1):
        donor_id = f"DON{1000 + i}"
        since = fake.date_between(start_date="-10y", end_date="-30d")
        email = fake.email()
        if random.random() < PCT_DONORS_NULL_EMAIL:
            email = None
        rows.append({
            "donor_id": donor_id,
            "donor_name": fake.name() if random.random() > 0.15 else fake.company(),
            "donor_since": since.isoformat(),
            "donor_type": random.choice(DONOR_TYPES),
            "region": random.choice(REGIONS),
            "email": email,
        })
    return pd.DataFrame(rows)


def generate_donations(n: int, donor_ids: list[str]) -> pd.DataFrame:
    rows = []
    for i in range(1, n + 1):
        donation_id = f"D{100000 + i}"

        # Orphan FK injection: reference a donor_id that was never generated
        if random.random() < PCT_DONATIONS_ORPHAN_DONOR:
            donor_id = f"DON{9000 + random.randint(1, 999)}"  # guaranteed not in donors.csv
        else:
            donor_id = random.choice(donor_ids)

        donation_date = fake.date_between(start_date="-2y", end_date="today")

        # Amount: mostly modest, occasionally a real major gift, rarely a typo outlier
        if random.random() < PCT_DONATIONS_BAD_AMOUNT:
            amount = round(random.uniform(1_000_000, 9_999_999), 2)   # obvious typo/outlier
        elif random.random() < 0.03:
            amount = round(random.uniform(5000, 25000), 2)            # major gift
        else:
            amount = round(random.uniform(10, 500), 2)                # typical gift

        rows.append({
            "donation_id": donation_id,
            "donor_id": donor_id,
            "donation_date": donation_date.isoformat(),
            "amount": amount,
            "campaign": random.choice(CAMPAIGNS),
            "payment_method": random.choice(PAYMENT_METHODS),
            "is_recurring": random.random() < 0.2,
        })

    df = pd.DataFrame(rows)

    # Duplicate injection: pick some real rows and re-append them verbatim
    n_dupes = int(len(df) * PCT_DONATIONS_DUPLICATE)
    if n_dupes > 0:
        dupes = df.sample(n=n_dupes, random_state=SEED).copy()
        df = pd.concat([df, dupes], ignore_index=True)

    return df.sample(frac=1, random_state=SEED).reset_index(drop=True)  # shuffle


def generate_employees(n: int) -> pd.DataFrame:
    rows = []
    for i in range(1, n + 1):
        employee_id = f"EMP{1000 + i}"
        department = random.choice(DEPARTMENTS)
        title = random.choice(JOB_TITLES[department])
        hire_date = fake.date_between(start_date="-8y", end_date="-30d")

        is_terminated = random.random() < 0.12
        termination_date = None
        status = "active"
        if is_terminated:
            termination_date = fake.date_between(start_date=hire_date, end_date="today")
            status = "terminated"

        dept_out = department
        if random.random() < PCT_EMPLOYEES_NULL_DEPT:
            dept_out = None   # missing department - data quality target

        rows.append({
            "employee_id": employee_id,
            "employee_name": fake.name(),
            "department": dept_out,
            "job_title": title,
            "hire_date": hire_date.isoformat(),
            "termination_date": termination_date.isoformat() if termination_date else None,
            "employment_status": status,
            "is_full_time": random.random() < 0.85,
        })
    return pd.DataFrame(rows)


def generate_staff_hours(employees_df: pd.DataFrame, weeks: int) -> pd.DataFrame:
    rows = []
    today = date.today()
    # Anchor to the most recent Friday so "week ending" dates look realistic
    last_friday = today - timedelta(days=(today.weekday() - 4) % 7)

    for _, emp in employees_df.iterrows():
        hire = date.fromisoformat(emp["hire_date"])
        term_raw = emp["termination_date"]
        term = (date.fromisoformat(term_raw)
                if pd.notna(term_raw) and term_raw not in (None, "")
                else None)

        for w in range(weeks):
            week_ending = last_friday - timedelta(weeks=w)

            # Only log hours while the employee was actually employed
            if week_ending < hire:
                continue
            if term and week_ending > term:
                continue

            base_hours = 40 if emp["is_full_time"] else 20
            hours = round(random.uniform(base_hours - 4, base_hours + 2), 1)

            rows.append({
                "employee_id": emp["employee_id"],
                "week_ending_date": week_ending.isoformat(),
                "hours_logged": hours,
                "program_area": (random.choice(PROGRAM_AREAS)
                                  if emp["department"] == "Programs" else None),
            })
    return pd.DataFrame(rows)


# ----------------------------------------------------------------
# Main
# ----------------------------------------------------------------
def main():
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    print("Generating donors...")
    donors = generate_donors(N_DONORS)
    donors.to_csv(OUTPUT_DIR / "donors.csv", index=False)
    print(f"  -> {len(donors)} rows -> {OUTPUT_DIR / 'donors.csv'}")

    print("Generating donations...")
    donations = generate_donations(N_DONATIONS, donors["donor_id"].tolist())
    donations.to_csv(OUTPUT_DIR / "donations.csv", index=False)
    print(f"  -> {len(donations)} rows -> {OUTPUT_DIR / 'donations.csv'}")

    print("Generating employees...")
    employees = generate_employees(N_EMPLOYEES)
    employees.to_csv(OUTPUT_DIR / "employees.csv", index=False)
    print(f"  -> {len(employees)} rows -> {OUTPUT_DIR / 'employees.csv'}")

    print("Generating staff hours...")
    staff_hours = generate_staff_hours(employees, WEEKS_OF_STAFF_HOURS)
    staff_hours.to_csv(OUTPUT_DIR / "staff_hours.csv", index=False)
    print(f"  -> {len(staff_hours)} rows -> {OUTPUT_DIR / 'staff_hours.csv'}")

    # Quick self-report of the messiness actually injected, for the README/DQ writeup
    orphan_count = (~donations["donor_id"].isin(donors["donor_id"])).sum()
    dupe_count = donations.duplicated(subset=["donation_id"]).sum()
    null_email_count = donors["email"].isna().sum()
    null_dept_count = employees["department"].isna().sum()
    outlier_count = (donations["amount"] > 100_000).sum()

    print("\n--- Injected data quality issues (for your DQ checks to catch) ---")
    print(f"  Orphaned donor_id in donations: {orphan_count}")
    print(f"  Duplicate donation_id rows:     {dupe_count}")
    print(f"  Null donor emails:              {null_email_count}")
    print(f"  Null employee departments:      {null_dept_count}")
    print(f"  Outlier donation amounts:       {outlier_count}")
    print("\nDone.")


if __name__ == "__main__":
    main()
