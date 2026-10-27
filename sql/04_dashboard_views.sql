/* ============================================================
   04_dashboard_views.sql
   Small aggregate views that feed the Power BI dashboard.
   Source: loans_complete (36-month loans issued 2012-2015).
   Power BI imports only these views, not the 589k loan rows.
   ============================================================ */
USE credit_risk;
GO

-- Page 1: risk and return by grade
CREATE OR ALTER VIEW v_grade_summary AS
SELECT
	grade,
	COUNT(*) AS n_of_loans,
	AVG(CAST(is_default AS FLOAT)) * 100 as default_rate,
	AVG(CAST(int_rate AS FLOAT)) AS avg_int_rate,
	SUM(funded_amnt) AS total_funded,
	SUM(total_pymnt) AS total_received,
	CAST(SUM(total_pymnt) - SUM(funded_amnt) AS FLOAT)
        / SUM(funded_amnt) * 100                      AS net_return_pct
FROM loans_complete
GROUP BY grade;
GO
-- Page 2a: grade x issue year (complete vintages, repricing)
CREATE OR ALTER VIEW v_vintage_grade AS
SELECT
    grade,
    YEAR(issue_date)                                  AS issue_year,
    COUNT(*)                                          AS n_of_loans,
    AVG(CAST(is_default AS FLOAT)) * 100              AS default_rate_pct,
    AVG(CAST(int_rate AS FLOAT))                      AS avg_int_rate,
    CAST(SUM(total_pymnt) - SUM(funded_amnt) AS FLOAT)
        / SUM(funded_amnt) * 100                   AS net_return_pct
FROM loans_complete
GROUP BY grade, YEAR(issue_date);
GO

-- Page 2b: censoring check (36-month loans from 2012, ALL vintages incl. 2016-2018)
CREATE OR ALTER VIEW v_censoring AS
SELECT
    YEAR(issue_date)                                  AS issue_year,
    loan_status,
    COUNT(*)                                          AS n_of_loans,
	ROUND(AVG(CAST(DATEDIFF(month, issue_date, last_pymnt_date) AS FLOAT)), 1)
                                                   AS avg_months_to_last_payment,                   
    CAST(SUM(total_pymnt) - SUM(funded_amnt) AS FLOAT)
        / SUM(funded_amnt) * 100                      AS net_return_pct
FROM loans_clean
WHERE term_months = 36
  AND issue_date >= '2012-01-01'
GROUP BY YEAR(issue_date), loan_status;
GO
-- Page 2c: portfolio mix by issue year (complete vintages)
CREATE OR ALTER VIEW v_portfolio_year AS
SELECT
    YEAR(issue_date)                                                      AS issue_year,
    COUNT(*)                                                              AS n_of_loans,
    AVG(CAST(int_rate AS FLOAT))                                          AS avg_int_rate,
    AVG(CASE WHEN grade IN ('A','B') THEN 1.0 ELSE 0 END) * 100           AS pct_grade_AB,
    AVG(CASE WHEN grade IN ('D','E','F','G') THEN 1.0 ELSE 0 END) * 100   AS pct_grade_D_G,                                        
    AVG(CAST(fico_low AS FLOAT))                                          AS avg_fico_low,
    AVG(CAST(loan_amnt AS FLOAT))                                         AS avg_loan_amnt,
    CAST(SUM(total_pymnt) - SUM(funded_amnt) AS FLOAT)
        / SUM(funded_amnt) * 100                                          AS net_return_pct
FROM loans_complete
GROUP BY YEAR(issue_date);
GO

-- Page 3: default rate and interest rate by grade x DTI band

CREATE OR ALTER VIEW v_dti_grade AS
WITH banded AS (
    SELECT
        grade,
        is_default,
        int_rate,
        CASE
            WHEN dti IS NULL OR dti < 0 THEN 'unknown'
            WHEN dti < 10 THEN '1. 0-10'
            WHEN dti < 20 THEN '2. 10-20'
            WHEN dti < 30 THEN '3. 20-30'
            WHEN dti < 40 THEN '4. 30-40'
            ELSE               '5. 40+'
        END AS dti_band
    FROM loans_complete
)
SELECT
    grade,
    dti_band,
    COUNT(*)                                AS n_of_loans,
    AVG(CAST(is_default AS FLOAT)) * 100    AS default_rate_pct,
    AVG(CAST(int_rate AS FLOAT))            AS avg_int_rate
FROM banded
WHERE dti_band <> 'unknown'
GROUP BY grade, dti_band;
GO

SELECT * FROM v_grade_summary ORDER BY grade;                          -- A: 5.45 / 7.21 / 7.29
SELECT * FROM v_vintage_grade WHERE grade = 'A' ORDER BY issue_year;   -- 2013: 4.56 / 7.70 / 8.44
SELECT * FROM v_portfolio_year ORDER BY issue_year;                    -- 2013: 13.37 / 57.1 / 18.3 / 11.05
SELECT * FROM v_dti_grade WHERE grade = 'A' AND dti_band = '1. 0-10';  -- 4.27
SELECT * FROM v_censoring ORDER BY issue_year, loan_status;            -- 2012 Fully Paid: ok. 27.3

-- Page 3: DTI 0-10 vs 30-40 within grade (is DTI priced?)
CREATE OR ALTER VIEW v_dti_pricing AS
WITH by_band AS (
    SELECT
        grade,
        AVG(CASE WHEN dti >= 0  AND dti < 10 THEN CAST(int_rate AS FLOAT) END)   AS int_0_10,
        AVG(CASE WHEN dti >= 30 AND dti < 40 THEN CAST(int_rate AS FLOAT) END)   AS int_30_40,
        AVG(CASE WHEN dti >= 0  AND dti < 10 THEN CAST(is_default AS FLOAT) END) AS def_0_10,
        AVG(CASE WHEN dti >= 30 AND dti < 40 THEN CAST(is_default AS FLOAT) END) AS def_30_40
    FROM loans_complete
    GROUP BY grade
)
SELECT
    grade,
    int_30_40 - int_0_10          AS int_rate_change_pp,
    (def_30_40 - def_0_10) * 100  AS default_rate_change_pp
FROM by_band;
GO

SELECT * FROM v_dti_pricing ORDER BY grade;   -- A: 0.33 / 3.38 ; E: -0.53 / 11.08

-- Page 6: base numbers for the scenario analysis (what-if)
CREATE OR ALTER VIEW v_scenario_base AS
SELECT
    grade,
    COUNT(*)                                                    AS n_of_loans,
    SUM(funded_amnt)                                            AS total_funded,
    CAST(SUM(CASE WHEN is_default = 1 THEN funded_amnt END) AS FLOAT)
        / SUM(funded_amnt)                                      AS default_share,
    CAST(SUM(CASE WHEN is_default = 0 THEN total_pymnt - funded_amnt END) AS FLOAT)
        / SUM(CASE WHEN is_default = 0 THEN funded_amnt END)    AS ret_paid,
    CAST(SUM(CASE WHEN is_default = 1 THEN total_pymnt - funded_amnt END) AS FLOAT)
        / SUM(CASE WHEN is_default = 1 THEN funded_amnt END)    AS ret_default
FROM loans_complete
GROUP BY grade;
GO

SELECT * FROM v_scenario_base ORDER BY grade;
-- check: A -> ret_paid ~ 0.0966, ret_default ~ -0.3576