/* ============================================================
   03_analysis.sql
   Credit risk analysis on LendingClub loans

   Tables / views:
   - loans_clean    : all loans with a final outcome (Fully Paid / Charged Off)
   - loans_complete : COMPLETE VINTAGES ONLY = 36-month loans issued 2012-2015
                      (nearly all finished by the end of the data, so no
                      right-censoring). ALL main results use this view.

   Conventions:
   - default rate  = share of loans with is_default = 1 (Charged Off)
   - net return    = (total_pymnt - funded_amnt) / funded_amnt, nominal,
                     computed as ratio of sums and cast to FLOAT
   - total_pymnt already includes recoveries (checked in 0.1)

   Section numbering matches the README:
   0 checks | 1 grade | 2 purpose | 3 DTI and income
   4 DTI within grade | 5 trends by issue year (censoring)
   6 why does return fall in 2013-2015? (LAG, CTEs) | 7 sub-grade check
   ============================================================ */
USE credit_risk;
GO

/* ---------- 0. DATA CHECKS ---------- */

-- 0.1 Does total_pymnt already include recoveries?
-- Result: yes, total_pymnt = principal + interest + recoveries
SELECT TOP 10
    id,
    total_pymnt,
    total_rec_prncp + total_rec_int                 AS prncp_plus_int,
    total_rec_prncp + total_rec_int + recoveries    AS prncp_int_recoveries,
    recoveries
FROM loans_clean
WHERE loan_status = 'Charged Off'
  AND recoveries > 0;

-- 0.2 DTI range and suspicious values
SELECT MIN(dti) AS min_dti, MAX(dti) AS max_dti
FROM loans_clean;

SELECT
    SUM(CASE WHEN dti < 0     THEN 1 ELSE 0 END) AS n_negative,
    SUM(CASE WHEN dti >= 100  THEN 1 ELSE 0 END) AS n_100_plus,
    SUM(CASE WHEN dti IS NULL THEN 1 ELSE 0 END) AS n_null,
    COUNT(*)                                     AS n_total
FROM loans_clean;
GO

-- 0.3 Analysis base: complete vintages (view used by sections 1-4)
CREATE OR ALTER VIEW loans_complete AS
SELECT *
FROM loans_clean
WHERE term_months = 36
  AND issue_date >= '2012-01-01'
  AND issue_date <  '2016-01-01';
GO

-- 0.4 How much of loans_clean is in the analysis base?
SELECT
    (SELECT COUNT(*) FROM loans_clean)    AS n_loans_clean,
    (SELECT COUNT(*) FROM loans_complete) AS n_loans_complete;


/* ---------- 1. RISK AND RETURN BY GRADE (complete vintages) ---------- */

-- 1.0 Overall default rate and return
SELECT
    COUNT(*)                                       AS n_of_loans,
    SUM(is_default)                                AS n_of_defaulted_loans,
    ROUND(AVG(CAST(is_default AS FLOAT)) * 100, 2) AS default_rate_pct,
    ROUND(CAST(SUM(total_pymnt) - SUM(funded_amnt) AS FLOAT)
          / SUM(funded_amnt) * 100, 2)             AS net_return_pct
FROM loans_complete;

-- 1a. Does grade separate risky from safe loans, and is the risk priced?
-- -> README Results 1, main table
SELECT
    grade,
    COUNT(*)                                       AS n_of_loans,
    SUM(is_default)                                AS n_of_defaulted_loans,
    ROUND(AVG(CAST(is_default AS FLOAT)) * 100, 2) AS default_rate_pct,
    ROUND(AVG(int_rate), 2)                        AS avg_int_rate,
    SUM(funded_amnt)                               AS total_funded,
    SUM(total_pymnt)                               AS total_received,
    ROUND(CAST(SUM(total_pymnt) - SUM(funded_amnt) AS FLOAT)
          / SUM(funded_amnt) * 100, 2)             AS net_return_pct
FROM loans_complete
GROUP BY grade
ORDER BY grade;

-- 1b. Net return split by outcome
-- Defaulted loans lose ~35-41%, fully paid loans earn more with risk.
-- -> README Results 1, "Net return by outcome"
SELECT
    grade,
    loan_status,
    COUNT(*)                                       AS n_of_loans,
    SUM(funded_amnt)                               AS total_funded,
    SUM(total_pymnt)                               AS total_received,
    ROUND(CAST(SUM(total_pymnt) - SUM(funded_amnt) AS FLOAT)
          / SUM(funded_amnt) * 100, 2)             AS net_return_pct
FROM loans_complete
GROUP BY grade, loan_status
ORDER BY grade, loan_status;

-- 1c. REFERENCE ONLY: same as 1a on ALL vintages and both terms
-- (right-censored, so return is biased downward; shows the size of the bias)
SELECT
    grade,
    COUNT(*)                                       AS n_of_loans,
    ROUND(AVG(CAST(is_default AS FLOAT)) * 100, 2) AS default_rate_pct,
    ROUND(AVG(int_rate), 2)                        AS avg_int_rate,
    ROUND(CAST(SUM(total_pymnt) - SUM(funded_amnt) AS FLOAT)
          / SUM(funded_amnt) * 100, 2)             AS net_return_pct
FROM loans_clean
GROUP BY grade
ORDER BY grade;


/* ---------- 2. RISK BY PURPOSE (complete vintages) ---------- */
SELECT
    purpose,
    COUNT(*)                                       AS n_of_loans,
    ROUND(AVG(CAST(is_default AS FLOAT)) * 100, 2) AS default_rate_pct,
    ROUND(AVG(int_rate), 2)                        AS avg_int_rate,
    ROUND(AVG(loan_amnt), 0)                       AS avg_loan_amnt
FROM loans_complete
GROUP BY purpose
ORDER BY default_rate_pct DESC;


/* ---------- 3. DTI AND INCOME (complete vintages) ---------- */

-- 3a. Risk by DTI band
-- 'unknown' = NULL or negative DTI (excluded from the README table)
WITH banded AS (
    SELECT
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
    dti_band,
    COUNT(*)                                       AS n_of_loans,
    ROUND(AVG(CAST(is_default AS FLOAT)) * 100, 2) AS default_rate_pct,
    ROUND(AVG(int_rate), 2)                        AS avg_int_rate
FROM banded
GROUP BY dti_band
ORDER BY dti_band;

-- 3b. Risk by income quartile
-- id is a tiebreaker so quartile membership is deterministic
WITH income_groups AS (
    SELECT
        is_default,
        int_rate,
        annual_inc,
        NTILE(4) OVER (ORDER BY annual_inc, id) AS income_quartile
    FROM loans_complete
    WHERE annual_inc IS NOT NULL
)
SELECT
    income_quartile,
    COUNT(*)                                       AS n_of_loans,
    ROUND(MIN(annual_inc), 0)                      AS min_income,
    ROUND(MAX(annual_inc), 0)                      AS max_income,
    ROUND(AVG(CAST(is_default AS FLOAT)) * 100, 2) AS default_rate_pct,
    ROUND(AVG(int_rate), 2)                        AS avg_int_rate
FROM income_groups
GROUP BY income_quartile
ORDER BY income_quartile;


/* ---------- 4. DTI WITHIN GRADE (complete vintages) ---------- */

-- 4a. Grade x DTI band: default rate and interest rate
-- Does DTI matter within a grade, and is it priced?
WITH banded AS (
    SELECT
        grade,
        is_default,
        int_rate,
        CASE
            WHEN dti IS NULL OR dti < 0 THEN 'unknown'
            WHEN dti < 10 THEN '0 to 10'
            WHEN dti < 20 THEN '10 to 20'
            WHEN dti < 30 THEN '20 to 30'
            WHEN dti < 40 THEN '30 to 40'
            ELSE               '40+'
        END AS dti_band
    FROM loans_complete
)
SELECT
    grade,
    dti_band,
    COUNT(*)                                       AS n_of_loans,
    ROUND(AVG(CAST(is_default AS FLOAT)) * 100, 2) AS default_rate_pct,
    ROUND(AVG(int_rate), 2)                        AS avg_int_rate
FROM banded
WHERE dti_band <> 'unknown'
GROUP BY grade, dti_band
ORDER BY grade, dti_band;

-- 4b. One row per grade: DTI 0-10 vs 30-40
-- When DTI goes from low to high inside a grade, how much does the
-- interest rate change compared with the default rate?
-- -> README Results 4 ("Interest rate vs. default rate")
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
    ROUND(int_0_10, 2)                      AS avg_int_rate_dti_0_10,
    ROUND(int_30_40, 2)                     AS avg_int_rate_dti_30_40,
    ROUND(int_30_40 - int_0_10, 2)          AS int_rate_change_pp,
    ROUND((def_30_40 - def_0_10) * 100, 2)  AS default_rate_change_pp
FROM by_band
ORDER BY grade;


/* ---------- 5. TRENDS BY ISSUE YEAR (censoring) ---------- */
-- Only finished loans are in loans_clean, so recent vintages are
-- right-censored (still-running loans are missing).
-- These queries intentionally use loans_clean to show where the data breaks.

-- 5a. REFERENCE ONLY: all loans, all vintages, both terms
SELECT
    YEAR(issue_date)                               AS issue_year,
    COUNT(*)                                       AS n_of_loans,
    SUM(is_default)                                AS n_of_defaulted_loans,
    ROUND(AVG(CAST(is_default AS FLOAT)) * 100, 2) AS default_rate_pct,
    ROUND(CAST(SUM(total_pymnt) - SUM(funded_amnt) AS FLOAT)
          / SUM(funded_amnt) * 100, 2)             AS net_return_pct
FROM loans_clean
GROUP BY YEAR(issue_date)
ORDER BY issue_year;

-- 5b. 36-month loans only, vintages from 2012
-- (2007-2011 vintages are small and noisy; 2016+ are right-censored)
-- -> README Results 5
SELECT
    YEAR(issue_date)                               AS issue_year,
    COUNT(*)                                       AS n_of_loans,
    ROUND(AVG(CAST(is_default AS FLOAT)) * 100, 2) AS default_rate_pct,
    ROUND(CAST(SUM(total_pymnt) - SUM(funded_amnt) AS FLOAT)
          / SUM(funded_amnt) * 100, 2)             AS net_return_pct
FROM loans_clean
WHERE term_months = 36
  AND issue_date >= '2012-01-01'
GROUP BY YEAR(issue_date)
ORDER BY issue_year;

-- 5c. Censoring check: time from issue to last payment, by outcome
-- (36-month loans, from 2012)
SELECT
    YEAR(issue_date)                               AS issue_year,
    loan_status,
    COUNT(*)                                       AS n_of_loans,
    ROUND(AVG(CAST(DATEDIFF(month, issue_date, last_pymnt_date) AS FLOAT)), 1)
                                                   AS avg_months_to_last_payment,
    ROUND(CAST(SUM(total_pymnt) - SUM(funded_amnt) AS FLOAT)
          / SUM(funded_amnt) * 100, 2)             AS net_return_pct
FROM loans_clean
WHERE term_months = 36
  AND issue_date >= '2012-01-01'
GROUP BY YEAR(issue_date), loan_status
ORDER BY issue_year, loan_status;

-- 5d. Is the end of the 2015 vintage still safe? Quarter by quarter.
-- A 36-month loan issued in Q4 2015 matures in Q4 2018, right at the data cut-off.
-- If avg months to last payment and default rate shift in late 2015,
-- shorten the complete-vintage window (e.g. to issue_date < '2015-07-01').
SELECT
    YEAR(issue_date)                               AS issue_year,
    DATEPART(quarter, issue_date)                  AS issue_quarter,
    COUNT(*)                                       AS n_of_loans,
    ROUND(AVG(CAST(is_default AS FLOAT)) * 100, 2) AS default_rate_pct,
    ROUND(AVG(CAST(DATEDIFF(month, issue_date, last_pymnt_date) AS FLOAT)), 1)
                                                   AS avg_months_to_last_payment,
    ROUND(CAST(SUM(total_pymnt) - SUM(funded_amnt) AS FLOAT)
          / SUM(funded_amnt) * 100, 2)             AS net_return_pct
FROM loans_clean
WHERE term_months = 36
  AND issue_date >= '2014-01-01'
  AND issue_date <  '2016-07-01'
GROUP BY YEAR(issue_date), DATEPART(quarter, issue_date)
ORDER BY issue_year, issue_quarter;


/* ---------- 6. WHY DOES RETURN FALL IN 2013-2015? (complete vintages) ---------- */

-- 6a. Year-over-year change by grade.
-- CTE aggregates per grade and year; LAG compares each year with the
-- previous one inside the same grade.
-- Note: grade G has 15-245 loans per year and grade F 103 in 2012, so their
-- year-to-year changes are noise.
WITH by_year AS (
    SELECT
        grade,
        YEAR(issue_date)                                AS issue_year,
        COUNT(*)                                        AS n_of_loans,
        AVG(CAST(is_default AS FLOAT)) * 100            AS default_rate_pct,
        CAST(SUM(total_pymnt) - SUM(funded_amnt) AS FLOAT)
            / SUM(funded_amnt) * 100                    AS net_return_pct
    FROM loans_complete
    GROUP BY grade, YEAR(issue_date)
)
SELECT
    grade,
    issue_year,
    n_of_loans,
    ROUND(default_rate_pct, 2)                          AS default_rate_pct,
    ROUND(default_rate_pct
          - LAG(default_rate_pct) OVER (PARTITION BY grade ORDER BY issue_year), 2)
                                                        AS default_rate_chg_pp,
    ROUND(net_return_pct, 2)                            AS net_return_pct,
    ROUND(net_return_pct
          - LAG(net_return_pct) OVER (PARTITION BY grade ORDER BY issue_year), 2)
                                                        AS net_return_chg_pp
FROM by_year
ORDER BY grade, issue_year;

-- 6b. Did the portfolio mix change? Pricing, grade mix, FICO and loan size
-- by issue year, with LAG on net return.
-- -> README Results 6, portfolio table
WITH by_year AS (
    SELECT
        YEAR(issue_date)                                AS issue_year,
        COUNT(*)                                        AS n_of_loans,
        AVG(CAST(int_rate AS FLOAT))                    AS avg_int_rate,
        AVG(CASE WHEN grade IN ('A','B') THEN 1.0 ELSE 0 END) * 100         AS pct_grade_AB,
        AVG(CASE WHEN grade IN ('D','E','F','G') THEN 1.0 ELSE 0 END) * 100 AS pct_grade_D_G,
        AVG(CAST(fico_low AS FLOAT))                    AS avg_fico_low,
        AVG(CAST(loan_amnt AS FLOAT))                   AS avg_loan_amnt,
        CAST(SUM(total_pymnt) - SUM(funded_amnt) AS FLOAT)
            / SUM(funded_amnt) * 100                    AS net_return_pct
    FROM loans_complete
    GROUP BY YEAR(issue_date)
)
SELECT
    issue_year,
    n_of_loans,
    ROUND(avg_int_rate, 2)                              AS avg_int_rate,
    ROUND(pct_grade_AB, 1)                              AS pct_grade_AB,
    ROUND(pct_grade_D_G, 1)                             AS pct_grade_D_G,
    ROUND(avg_fico_low, 0)                              AS avg_fico_low,
    ROUND(avg_loan_amnt, 0)                             AS avg_loan_amnt,
    ROUND(net_return_pct, 2)                            AS net_return_pct,
    ROUND(net_return_pct
          - LAG(net_return_pct) OVER (ORDER BY issue_year), 2) AS net_return_chg_pp
FROM by_year
ORDER BY issue_year;

-- 6c. Return split by outcome and year:
-- do paid loans earn less, or do defaulted loans lose more?
-- -> README Results 6, outcome table
SELECT
    YEAR(issue_date)                                    AS issue_year,
    loan_status,
    COUNT(*)                                            AS n_of_loans,
    ROUND(CAST(SUM(total_pymnt) - SUM(funded_amnt) AS FLOAT)
          / SUM(funded_amnt) * 100, 2)                  AS net_return_pct
FROM loans_complete
GROUP BY YEAR(issue_date), loan_status
ORDER BY issue_year, loan_status;

-- 6d. Did pricing change within grades? Average interest rate by grade and year.
-- -> README Results 6, grade table
SELECT
    grade,
    YEAR(issue_date)                                    AS issue_year,
    ROUND(AVG(CAST(int_rate AS FLOAT)), 2)              AS avg_int_rate
FROM loans_complete
GROUP BY grade, YEAR(issue_date)
ORDER BY grade, issue_year;


/* ---------- 7. SUB-GRADE CHECK: REPRICING OR MIX? (complete vintages) ---------- */

-- 7a. Same sub-grade, different year: did pricing change? 2013 vs 2015.
SELECT
    sub_grade,
    COUNT(CASE WHEN YEAR(issue_date) = 2013 THEN 1 END)                         AS n_2013,
    COUNT(CASE WHEN YEAR(issue_date) = 2015 THEN 1 END)                         AS n_2015,
    ROUND(AVG(CASE WHEN YEAR(issue_date) = 2013 THEN CAST(int_rate AS FLOAT) END), 2) AS rate_2013,
    ROUND(AVG(CASE WHEN YEAR(issue_date) = 2015 THEN CAST(int_rate AS FLOAT) END), 2) AS rate_2015,
    ROUND(AVG(CASE WHEN YEAR(issue_date) = 2013 THEN CAST(is_default AS FLOAT) END) * 100, 2) AS default_2013,
    ROUND(AVG(CASE WHEN YEAR(issue_date) = 2015 THEN CAST(is_default AS FLOAT) END) * 100, 2) AS default_2015
FROM loans_complete
GROUP BY sub_grade
ORDER BY sub_grade;

-- 7b. Split the 2013 -> 2015 change in a grade's average rate into
--   within_subgrade_chg: same sub-grade, different rate (repricing)
--   mix_chg:             different share of cheap vs expensive sub-grades
--   total_chg = within_subgrade_chg + mix_chg
-- Sub-grades missing in one of the years are dropped, so ignore grade G.
-- -> README Results 6, sub-grade table
WITH sg AS (
    SELECT
        grade, sub_grade, YEAR(issue_date) AS y,
        COUNT(*)                           AS n,
        AVG(CAST(int_rate AS FLOAT))       AS r
    FROM loans_complete
    WHERE YEAR(issue_date) IN (2013, 2015)
    GROUP BY grade, sub_grade, YEAR(issue_date)
),
w AS (
    SELECT *, n * 1.0 / SUM(n) OVER (PARTITION BY grade, y) AS wt   -- share within grade and year
    FROM sg
),
p AS (
    SELECT
        grade, sub_grade,
        MAX(CASE WHEN y = 2013 THEN wt END) AS w13,
        MAX(CASE WHEN y = 2015 THEN wt END) AS w15,
        MAX(CASE WHEN y = 2013 THEN r  END) AS r13,
        MAX(CASE WHEN y = 2015 THEN r  END) AS r15
    FROM w
    GROUP BY grade, sub_grade
)
SELECT
    grade,
    ROUND(SUM(w15 * r15) - SUM(w13 * r13), 2) AS total_chg_pp,
    ROUND(SUM(w15 * (r15 - r13)), 2)          AS within_subgrade_chg_pp,
    ROUND(SUM((w15 - w13) * r13), 2)          AS mix_chg_pp
FROM p
WHERE w13 IS NOT NULL AND w15 IS NOT NULL
GROUP BY grade
ORDER BY grade;

/* Dashboard: one row per issue year (complete vintages) */
SELECT
    YEAR(issue_date)                               AS issue_year,
    COUNT(*)                                       AS n_of_loans,
    ROUND(AVG(CAST(is_default AS FLOAT)) * 100, 2) AS default_rate_pct,
    ROUND(AVG(int_rate), 2)                        AS avg_int_rate,
    ROUND(CAST(SUM(total_pymnt) - SUM(funded_amnt) AS FLOAT)
          / SUM(funded_amnt) * 100, 2)             AS net_return_pct
FROM loans_complete
GROUP BY YEAR(issue_date)
ORDER BY issue_year;