from pathlib import Path
import matplotlib.pyplot as plt
import pandas as pd

base_dir = Path("/content")
raw_path = base_dir / "01_raw" / "messy_orders.csv"
clean_path = base_dir / "03_cleaned" / "clean_orders.csv"
quarantine_path = base_dir / "03_cleaned" / "quarantine.csv"
img_path = base_dir / "03_cleaned" / "before_after.png"

raw_df = pd.read_csv(raw_path, dtype=str)
input_rows = len(raw_df)

df = raw_df.copy()
df["customer_name"] = df["customer_name"].str.strip().str.title()
df["status"] = df["status"].str.strip().str.title()

df["order_date_parsed"] = pd.to_datetime(
    df["order_date"].str.strip(), format="mixed", dayfirst=True, errors="coerce"
)
df["order_date"] = df["order_date_parsed"].dt.strftime("%Y-%m-%d")

cleaned_amt = (
    df["amount_inr"]
    .str.strip()
    .str.replace(",", "", regex=False)
    .replace({"N/A": pd.NA, "—": pd.NA, "-": pd.NA, "": pd.NA})
)
df["amount_inr"] = pd.to_numeric(cleaned_amt, errors="coerce")

# Deduplicate on business fields (keep first occurrence)
before_dedup = len(df)
dedup_df = df.drop_duplicates(
    subset=["order_id", "customer_name", "order_date", "amount_inr", "status"],
    keep="first",
).copy()
duplicates_removed = before_dedup - len(dedup_df)

# Flag anomalies for quarantine.csv (null amount, negative amount, or invalid date)
def flag_reason(r):
    reasons = []
    if pd.isna(r["order_date"]):
        reasons.append("invalid_date")
    if pd.isna(r["amount_inr"]):
        reasons.append("null_amount")
    elif r["amount_inr"] < 0:
        reasons.append("negative_amount")
    return "; ".join(reasons)

dedup_df["quarantine_reason"] = dedup_df.apply(flag_reason, axis=1)
quarantine_df = dedup_df[dedup_df["quarantine_reason"] != ""][
    ["order_id", "customer_name", "order_date", "amount_inr", "status", "quarantine_reason"]
].copy()

clean_df = dedup_df[["order_id", "customer_name", "order_date", "amount_inr", "status"]].copy()

clean_path.parent.mkdir(parents=True, exist_ok=True)
clean_df.to_csv(clean_path, index=False)
quarantine_df.to_csv(quarantine_path, index=False)

# Build a clean Before vs. After preview image (first 6 rows for readability)
preview_n = min(6, len(raw_df), len(clean_df))
before_rows = raw_df.iloc[:preview_n].fillna("").astype(str).values.tolist()
after_rows = clean_df.iloc[:preview_n].fillna("NaN").astype(str).values.tolist()
headers = ["ID", "Customer", "Date", "Amount", "Status"]

fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(13, 4.2))
fig.patch.set_facecolor("white")

for ax, title, rows, header_bg, row_bg in [
    (ax1, "BEFORE: Raw Input (Sample)", before_rows, "#991b1b", "#fef2f2"),
    (ax2, "AFTER: Cleaned Output (Sample)", after_rows, "#166534", "#f0fdf4"),
]:
    ax.axis("off")
    ax.set_title(title, fontsize=12, fontweight="bold", pad=10, color=header_bg)
    tbl = ax.table(
        cellText=rows,
        colLabels=headers,
        loc="center",
        cellLoc="left",
    )
    tbl.auto_set_font_size(False)
    tbl.set_fontsize(8.5)
    tbl.scale(1.0, 1.35)
    for (r, c), cell in tbl.get_celld().items():
        cell.set_edgecolor("#cbd5e1")
        if r == 0:
            cell.set_facecolor(header_bg)
            cell.set_text_props(color="white", fontweight="bold")
        else:
            cell.set_facecolor(row_bg)

plt.tight_layout()
plt.savefig(img_path, dpi=200, bbox_inches="tight")
plt.close()

print("=== VALIDATION SUMMARY ===")
print(f"Input rows:          {input_rows}")
print(f"Duplicates removed:  {duplicates_removed}")
print(f"Output rows:         {len(clean_df)}")
print(f"Quarantined rows:    {len(quarantine_df)}")
print(f"Null amounts (NaN):  {int(clean_df['amount_inr'].isna().sum())}")
print(f"Negative amounts:    {int((clean_df['amount_inr'] < 0).fillna(False).sum())}")
print(f"Invalid dates:       {int(dedup_df['order_date_parsed'].isna().sum())}")
print(f"Saved: {clean_path}, {quarantine_path}, {img_path}")
