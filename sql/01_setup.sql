/* ============================================================
   01_setup.sql
   Creates the database and loads the LendingClub accepted-loans
   file into loans_raw (all columns as text).

   Requires: C:\data\accepted.csv (Kaggle, not included in repo)
   Requires: SQL Server 2017+ (BULK INSERT ... FORMAT = 'CSV')
   ============================================================ */

/* ---------- 1. DATABASE ---------- */
IF DB_ID('credit_risk') IS NULL
    CREATE DATABASE credit_risk;
GO

USE credit_risk;
GO

/* ---------- 2. READ THE HEADER ROW ---------- */
-- The whole first line is loaded into a single column (the field
-- terminator 0x0b never appears in the file), so we can build
-- loans_raw from the real column names.
DROP TABLE IF EXISTS header_stage;
CREATE TABLE header_stage (line NVARCHAR(MAX) NULL);

BULK INSERT header_stage
FROM 'C:\data\accepted.csv'
WITH (
    FIRSTROW        = 1,
    LASTROW         = 1,
    ROWTERMINATOR   = '0x0a',
    FIELDTERMINATOR = '0x0b',
    CODEPAGE        = '65001'
);
GO

/* ---------- 3. CREATE loans_raw FROM THE HEADER ---------- */
-- Variables and EXEC must stay in the same batch (no GO in between).
DROP TABLE IF EXISTS loans_raw;

DECLARE @h NVARCHAR(MAX) = (
    SELECT TOP 1
        REPLACE(REPLACE(REPLACE(line, CHAR(13), ''), NCHAR(65279), ''), '"', '')  -- CR, BOM, quotes
    FROM header_stage
);

DECLARE @sql NVARCHAR(MAX) =
    'CREATE TABLE loans_raw ([' + REPLACE(@h, ',', '] NVARCHAR(500) NULL, [') + '] NVARCHAR(500) NULL);';

-- columns with long free text
SET @sql = REPLACE(@sql, '[desc] NVARCHAR(500)',      '[desc] NVARCHAR(MAX)');
SET @sql = REPLACE(@sql, '[url] NVARCHAR(500)',       '[url] NVARCHAR(MAX)');
SET @sql = REPLACE(@sql, '[emp_title] NVARCHAR(500)', '[emp_title] NVARCHAR(MAX)');
SET @sql = REPLACE(@sql, '[title] NVARCHAR(500)',     '[title] NVARCHAR(MAX)');

EXEC sp_executesql @sql;
GO

/* ---------- 4. LOAD THE DATA ---------- */
BULK INSERT loans_raw
FROM 'C:\data\accepted.csv'
WITH (
    FORMAT          = 'CSV',
    FIRSTROW        = 2,
    FIELDQUOTE      = '"',
    FIELDTERMINATOR = ',',
    ROWTERMINATOR   = '0x0a',
    CODEPAGE        = '65001',
    TABLOCK
);
GO

/* ---------- 5. CLEAN UP AND CHECK ---------- */
DROP TABLE IF EXISTS header_stage;
GO

SELECT COUNT(*) AS n_rows_loaded FROM loans_raw;

-- Expected: ~2.26 mln rows. The Kaggle file ends with summary lines
-- that are not loans; they are removed later by the loan_status
-- filter in 02_clean.sql.
SELECT loan_status, COUNT(*) AS n
FROM loans_raw
GROUP BY loan_status
ORDER BY n DESC;