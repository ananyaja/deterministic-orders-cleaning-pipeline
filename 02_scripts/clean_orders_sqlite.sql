-- clean_orders_sqlite.sql
%%sql
-- 1. Create and load raw table (in sqlite3 CLI: .mode csv / .import --skip 1 messy_orders.csv raw_orders)
DROP TABLE IF EXISTS raw_orders;
CREATE TABLE raw_orders (
    order_id TEXT,
    customer_name TEXT,
    order_date TEXT,
    amount_inr TEXT,
    status TEXT
);

-- 2. Stage cleaned text, normalize mixed date formats to YYYY-MM-DD, and parse numeric amounts
DROP TABLE IF EXISTS staged_orders;
CREATE TABLE staged_orders AS
WITH trimmed AS (
    SELECT
        TRIM(order_id) AS order_id,
        TRIM(customer_name) AS raw_name,
        TRIM(order_date) AS raw_date,
        TRIM(amount_inr) AS raw_amt,
        TRIM(status) AS raw_status
    FROM raw_orders
),
formatted AS (
    SELECT
        order_id,
        -- Title-case customer_name (handles single or two-word names cleanly)
        CASE
            WHEN INSTR(raw_name, ' ') > 0 THEN
                UPPER(SUBSTR(raw_name, 1, 1)) ||
                LOWER(SUBSTR(raw_name, 2, INSTR(raw_name, ' ') - 2)) || ' ' ||
                UPPER(SUBSTR(raw_name, INSTR(raw_name, ' ') + 1, 1)) ||
                LOWER(SUBSTR(raw_name, INSTR(raw_name, ' ') + 2))
            ELSE
                UPPER(SUBSTR(raw_name, 1, 1)) || LOWER(SUBSTR(raw_name, 2))
        END AS customer_name,
        -- Normalize supported date formats to ISO YYYY-MM-DD
        CASE
            -- Already YYYY-MM-DD (e.g., 2026-03-06)
            WHEN raw_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'
                THEN raw_date
            -- YYYY/MM/DD (e.g., 2026/03/05) -> YYYY-MM-DD
            WHEN raw_date GLOB '[0-9][0-9][0-9][0-9]/[0-9][0-9]/[0-9][0-9]'
                THEN REPLACE(raw_date, '/', '-')
            -- YYYY.MM.DD (e.g., 2026.03.08) -> YYYY-MM-DD
            WHEN raw_date GLOB '[0-9][0-9][0-9][0-9].[0-9][0-9].[0-9][0-9]'
                THEN REPLACE(raw_date, '.', '-')
            -- DD/MM/YYYY (e.g., 07/03/2026) -> YYYY-MM-DD
            WHEN raw_date GLOB '[0-9][0-9]/[0-9][0-9]/[0-9][0-9][0-9][0-9]'
                THEN SUBSTR(raw_date, 7, 4) || '-' || SUBSTR(raw_date, 4, 2) || '-' || SUBSTR(raw_date, 1, 2)
            -- DD-MM-YYYY (e.g., 09-03-2026) -> YYYY-MM-DD
            WHEN raw_date GLOB '[0-9][0-9]-[0-9][0-9]-[0-9][0-9][0-9][0-9]'
                THEN SUBSTR(raw_date, 7, 4) || '-' || SUBSTR(raw_date, 4, 2) || '-' || SUBSTR(raw_date, 1, 2)
            -- DD-Mon-YYYY (e.g., 05-Mar-2026) -> YYYY-MM-DD
            WHEN raw_date GLOB '[0-9][0-9]-[A-Za-z][A-Za-z][A-Za-z]-[0-9][0-9][0-9][0-9]' THEN
                SUBSTR(raw_date, 8, 4) || '-' ||
                CASE LOWER(SUBSTR(raw_date, 4, 3))
                    WHEN 'jan' THEN '01' WHEN 'feb' THEN '02' WHEN 'mar' THEN '03'
                    WHEN 'apr' THEN '04' WHEN 'may' THEN '05' WHEN 'jun' THEN '06'
                    WHEN 'jul' THEN '07' WHEN 'aug' THEN '08' WHEN 'sep' THEN '09'
                    WHEN 'oct' THEN '10' WHEN 'nov' THEN '11' WHEN 'dec' THEN '12'
                    ELSE NULL
                END || '-' || SUBSTR(raw_date, 1, 2)
            ELSE NULL
        END AS order_date,
        -- Convert non-numeric tokens to NULL, otherwise cast numeric text to REAL
        CASE
            WHEN raw_amt IN ('', 'N/A', 'n/a', '—', '-') THEN NULL
            ELSE CAST(REPLACE(raw_amt, ',', '') AS REAL)
        END AS amount_inr,
        UPPER(SUBSTR(raw_status, 1, 1)) || LOWER(SUBSTR(raw_status, 2)) AS status
    FROM trimmed
)
SELECT * FROM formatted;

-- 3. Deduplicate deterministically while preserving row-level auditability
DROP TABLE IF EXISTS deduped_orders;
CREATE TABLE deduped_orders AS
SELECT
    order_id,
    customer_name,
    order_date,
    amount_inr,
    status,
    ROW_NUMBER() OVER (
        PARTITION BY order_id, customer_name, order_date, amount_inr, status
        ORDER BY order_id
    ) AS rn
FROM staged_orders;

-- 4. Clean dataset output (run in sqlite3 CLI to export CSV)
-- .headers on
-- .mode csv
-- .output clean_orders_sqlite.csv
SELECT order_id, customer_name, order_date, amount_inr, status
FROM deduped_orders
WHERE rn = 1;
-- .output stdout

-- 5. Validation Summary
SELECT
    (SELECT COUNT(*) FROM raw_orders) AS input_rows,
    (SELECT COUNT(*) FROM deduped_orders WHERE rn > 1) AS duplicates_removed,
    (SELECT COUNT(*) FROM deduped_orders WHERE rn = 1) AS output_rows,
    (SELECT COUNT(*) FROM deduped_orders WHERE rn = 1 AND amount_inr IS NULL) AS null_amounts,
    (SELECT COUNT(*) FROM deduped_orders WHERE rn = 1 AND amount_inr < 0) AS negative_amounts,
    (SELECT COUNT(*) FROM staged_orders WHERE order_date IS NULL) AS invalid_dates;
