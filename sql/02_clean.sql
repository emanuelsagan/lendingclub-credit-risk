USE credit_risk;
GO
SET LANGUAGE us_english;   -- so SQL Server understands 'Dec', 'Jan', etc.
GO

DROP TABLE IF EXISTS loans_clean;   -- safety: drops the old version if it already exists
GO

SELECT
    -- identification and outcome
    TRY_CAST(id AS BIGINT)                                         AS id,
    loan_status,
    CASE WHEN loan_status = 'Charged Off' THEN 1 ELSE 0 END        AS is_default,
    TRY_CONVERT(date, '01 ' + REPLACE(NULLIF(issue_d,''), '-', ' '), 106) AS issue_date,

    -- loan terms
    TRY_CAST(NULLIF(loan_amnt,'')   AS DECIMAL(12,2))              AS loan_amnt,
    TRY_CAST(NULLIF(funded_amnt,'') AS DECIMAL(12,2))              AS funded_amnt,
    TRY_CAST(LEFT(LTRIM(term), 2)   AS INT)                        AS term_months,
    TRY_CAST(NULLIF(int_rate,'')    AS DECIMAL(6,2))               AS int_rate,
    TRY_CAST(NULLIF(installment,'') AS DECIMAL(10,2))              AS installment,
    grade,
    sub_grade,

    -- borrower
    emp_length,
    home_ownership,
    TRY_CAST(NULLIF(annual_inc,'')  AS DECIMAL(14,2))              AS annual_inc,
    verification_status,
    purpose,
    addr_state,
    application_type,

    -- credit history
    TRY_CAST(NULLIF(dti,'')              AS DECIMAL(8,2))          AS dti,
    TRY_CAST(NULLIF(delinq_2yrs,'')      AS DECIMAL(6,0))          AS delinq_2yrs,
    TRY_CONVERT(date, '01 ' + REPLACE(NULLIF(earliest_cr_line,''), '-', ' '), 106) AS earliest_cr_date,
    TRY_CAST(NULLIF(fico_range_low,'')   AS DECIMAL(6,1))          AS fico_low,
    TRY_CAST(NULLIF(fico_range_high,'')  AS DECIMAL(6,1))          AS fico_high,
    TRY_CAST(NULLIF(inq_last_6mths,'')   AS DECIMAL(6,0))          AS inq_last_6mths,
    TRY_CAST(NULLIF(open_acc,'')         AS DECIMAL(6,0))          AS open_acc,
    TRY_CAST(NULLIF(pub_rec,'')          AS DECIMAL(6,0))          AS pub_rec,
    TRY_CAST(NULLIF(revol_bal,'')        AS DECIMAL(14,2))         AS revol_bal,
    TRY_CAST(NULLIF(revol_util,'')       AS DECIMAL(8,2))          AS revol_util,
    TRY_CAST(NULLIF(total_acc,'')        AS DECIMAL(6,0))          AS total_acc,
    TRY_CAST(NULLIF(mort_acc,'')         AS DECIMAL(6,0))          AS mort_acc,
    TRY_CAST(NULLIF(pub_rec_bankruptcies,'') AS DECIMAL(6,0))      AS pub_rec_bankruptcies,

    -- repayment (for loss analysis only, NOT for the model)
    TRY_CAST(NULLIF(total_pymnt,'')    AS DECIMAL(14,2))           AS total_pymnt,
    TRY_CAST(NULLIF(total_rec_prncp,'') AS DECIMAL(14,2))          AS total_rec_prncp,
    TRY_CAST(NULLIF(total_rec_int,'')   AS DECIMAL(14,2))          AS total_rec_int,
    TRY_CAST(NULLIF(recoveries,'')      AS DECIMAL(14,2))          AS recoveries,
    TRY_CONVERT(date, '01 ' + REPLACE(NULLIF(last_pymnt_d,''), '-', ' '), 106) AS last_pymnt_date
INTO loans_clean
FROM loans_raw
WHERE loan_status IN ('Fully Paid', 'Charged Off');
GO

-- quick look at the first rows
SELECT TOP 10 * FROM loans_clean

-- check recoveries on charged-off loans
SELECT TOP 100 id, loan_status, loan_amnt, recoveries
FROM loans_clean
WHERE loan_status = 'Charged off';

USE credit_risk;

-- sanity checks
SELECT COUNT(*) FROM loans_clean;                                        -- approx. 1.3 million
SELECT loan_status, COUNT(*) AS n FROM loans_clean GROUP BY loan_status; -- 2 statuses
SELECT COUNT(*) FROM loans_clean WHERE issue_date IS NULL;               -- expected: 0
SELECT COUNT(*) FROM loans_clean WHERE loan_amnt IS NULL;                -- expected: 0 or very few