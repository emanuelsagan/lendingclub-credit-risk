# ============================================================
# 02_model.R
# Default-probability model (logistic regression) on LendingClub loans:
# data preparation, time split, model comparison, calibration,
# selection simulation (model vs grade) and recalibration.
#
# Input : data/loans.rds   (saved by 01_load_data.R from the SQL view
#                           loans_complete = 36-month loans, 2012-2015;
#                           the query must include funded_amnt, total_pymnt,
#                           int_rate, sub_grade)
# Target: is_default (1 = Charged Off, 0 = Fully Paid)
# Only variables known at application time are used as predictors (no leakage).
# total_pymnt / funded_amnt are used ONLY to evaluate returns, never in a model.
#
# Sections:
#  1 load | 2 emp_length exploration | 3 data preparation | 4 time split
#  5-7 emp_length in the model | 8 model A | 9 model comparison (AUC)
#  10 calibration of model B | 11 net return per decile
#  12 selection simulation: model vs grade (12a curve, 12b same size, 12c bootstrap)
#  13 recalibration | 14 export for dashboard
# ============================================================

library(dplyr)
library(ggplot2)
library(lubridate)   # year() for the time split
library(pROC)
library(tidyr)       # pivot_longer()

dir.create("output", showWarnings = FALSE)


# ---------- 1. LOAD DATA ----------
loans <- readRDS("data/loans.rds")
# Expected: 589,488 rows, default rate 14.03% (matches the SQL view)


# ---------- 2. EXPLORING emp_length (raw data, no controls) ----------

# 2.1 Counts per category; useNA = "ifany" shows missing values as a category
table(loans$emp_length, useNA = "ifany")
# 35,330 loans (6.0%) have no employment length (NA)

# 2.2 Default rate per category
loans %>%
  group_by(emp_length) %>%
  summarise(
    n = n(),
    default_rate = mean(is_default)
  )
# Categories 1-9 years: ~13.8-14.5%, 10+ years: 12.6%, < 1 year: 14.7%,
# NA: 20.5% -> only the NA group stands out strongly.

# 2.3 Chi-squared test of independence (emp_length vs is_default)
# H0: emp_length and default are independent.
tab <- table(loans$emp_length, loans$is_default, useNA = "ifany")
chisq.test(tab)
# X-squared = 1569.9, df = 11, p < 2.2e-16 -> reject H0: default rates differ
# between categories. With 589k loans the p-value is tiny even for weak effects,
# so we also need an effect size (Cramer's V below).

# 2.4 Cramer's V = strength of the association, 0 (none) to 1 (perfect)
# V = sqrt(chi2 / (n * min(rows - 1, cols - 1)))
chi <- chisq.test(tab)$statistic
n <- sum(tab)
V_emp <- sqrt(chi / (n * min(dim(tab) - 1)))

# Same for grade, as a benchmark of a "strong" signal
tab <- table(loans$grade, loans$is_default, useNA = "ifany")
chi <- chisq.test(tab)$statistic
n <- sum(tab)
V_grade <- sqrt(chi / (n * min(dim(tab) - 1)))

V_emp     # 0.0516
V_grade   # 0.1944

# For a 2-column table, V^2 ~ share of variance in is_default explained by
# the variable alone (like R^2).
V_grade^2             # 0.0378
V_emp^2               # 0.0027
V_grade^2 / V_emp^2   # ~14.2
# grade explains ~3.8%, emp_length ~0.27%: emp_length is ~14x weaker.
# Both are small in absolute terms (single variable, 14% base rate),
# but grade is a strong signal and emp_length a weak one.


# ---------- 3. DATA PREPARATION FOR THE MODEL ----------

# 3.1 Rows the model cannot use
sum(loans$annual_inc <= 0)   # 2 loans with income = 0 (log(0) = -Inf) -> dropped
sum(is.na(loans$dti))        # 2 loans with missing DTI -> dropped
# (300 loans with missing revol_util are dropped as well)

# 3.2 Model data set. Order inside mutate() matters (runs top to bottom):
#     text operations first, factor() last.
loans_model <- loans %>%
  filter(!is.na(dti), !is.na(revol_util), annual_inc > 0) %>%
  mutate(
    # missing employment length becomes its own category instead of losing 6% of rows
    emp_length = ifelse(is.na(emp_length), "unknown", emp_length),
    # log of income: skewed variable ($0-9M); log makes effects proportional
    # (doubling income has the same effect at $30k and at $300k)
    log_inc = log(annual_inc),
    grade = factor(grade),
    emp_length = factor(emp_length),
    # 2 "ANY" + 35 "NONE" + 40 "OTHER" are too rare -> merged into OTHER (77 loans);
    # MORTGAGE (largest group) is the reference category
    home_ownership = ifelse(home_ownership %in% c("ANY", "NONE"), "OTHER", home_ownership),
    home_ownership = relevel(factor(home_ownership), ref = "MORTGAGE"),
    # reference category = largest purpose (debt consolidation)
    purpose = ifelse(purpose == "educational", "other", purpose),
    purpose = relevel(factor(purpose), ref = "debt_consolidation"),
    verification_status = factor(verification_status),
    # simplified employment length (justified in sections 5-7):
    # only 10+ years and unknown differ from the rest
    emp3 = case_when(
      emp_length == "unknown"   ~ "unknown",
      emp_length == "10+ years" ~ "10+ years",
      TRUE                      ~ "<10 years"
    ),
    emp3 = factor(emp3, levels = c("<10 years", "10+ years", "unknown"))
  )

# 3.3 Checks
nrow(loans_model)                     # 589,186
colSums(is.na(loans_model))           # all zeros
levels(loans_model$emp_length)        # 11 categories + "unknown"
table(loans_model$home_ownership)     # MORTGAGE, OTHER (77), OWN, RENT


# ---------- 4. TIME SPLIT (train / test) ----------
# Time-based, not random: the model learns from older loans and is tested on
# newer ones, like in real use. It also tests robustness to the drift seen in
# the SQL analysis (default rates rising from 2013 to 2015).
train <- loans_model %>% filter(year(issue_date) <= 2014)   # 2012-2014
test  <- loans_model %>% filter(year(issue_date) == 2015)   # 2015

nrow(train); nrow(test)                        # 306,288 ; 282,898
mean(train$is_default); mean(test$is_default)  # 13.25% ; 14.88%

# Check that predict() will not meet unseen factor levels (should be empty)
setdiff(unique(test$purpose), unique(train$purpose))
setdiff(unique(test$home_ownership), unique(train$home_ownership))
setdiff(unique(test$verification_status), unique(train$verification_status))


# ---------- 5. IS emp_length A USEFUL VARIABLE? (train set) ----------

# m0 = baseline: income (log), DTI, FICO, loan amount
# m1 = m0 + emp_length (12 categories; reference = "< 1 year")
m0 <- glm(is_default ~ log_inc + dti + fico_low + loan_amnt,
          data = train, family = binomial)
m1 <- update(m0, . ~ . + emp_length)

# Likelihood ratio test: does emp_length improve the model when the other
# variables are already in it? (deviance = lack of fit, lower is better)
anova(m0, m1, test = "Chisq")
AIC(m0, m1)
# Deviance drop 177.66 on 11 df, p < 2.2e-16; AIC 231,827 -> 231,672.
# emp_length adds information beyond income, DTI, FICO and loan amount,
# but the deviance falls by only 0.08% -> real but very weak signal
# (large sample: even small effects are "significant").

# Coefficients are in log-odds; exp() turns them into odds ratios
# (a multiplier of the odds of default, "other variables held constant").
summary(m1)
exp(coef(m1))
# Key odds ratios: fico_low 0.987 (per point), dti 1.018 (per pp),
# log_inc 0.607 (per unit of log income; doubling income ~ 0.71),
# loan_amnt 1.000018 (per $1; +$10,000 ~ 1.20),
# emp_length 10+ years 0.885, unknown 1.198 (vs "< 1 year").
# Categories 1-9 years: 0.93-0.98, mostly not significant.


# ---------- 6. WHERE DOES THE "unknown" EFFECT COME FROM? ----------

# 6.1 Share of unknown by issue year: stable (changes ~1 pp per year)
train %>%
  group_by(rok = year(issue_date)) %>%
  summarise(n = n(), udzial_unknown = mean(emp_length == "unknown"))

# 6.2 Default rate of unknown vs known, by issue year
train %>%
  group_by(rok = year(issue_date), unknown = emp_length == "unknown") %>%
  summarise(n = n(), default_rate = mean(is_default), .groups = "drop")
# In every year unknown has a 5-8 pp higher raw default rate -> a stable signal,
# not an artefact of one vintage. The odds ratio in the model (1.20) is smaller
# than the raw difference: part of it is explained by other variables.


# ---------- 7. SIMPLIFYING emp_length (12 -> 3 categories) ----------
# After inspecting m1, only 10+ years and unknown differ from the rest, so
# 1-9 years and < 1 year are merged into "<10 years" (variable emp3, created
# in section 3). The simplification is data-driven, so it is verified below
# and finally on the test set (AUC, section 9).

m2 <- update(m0, . ~ . + emp3)
AIC(m0, m1, m2)
# AIC: m0 = 231,827; m1 = 231,672; m2 = 231,665 (lowest, with 9 fewer parameters)

# m2 is nested in m1, so the LR test applies. H0: splitting 1-9 years adds nothing.
anova(m2, m1, test = "Chisq")
# Deviance 11.47 on 9 df, p = 0.245 -> no evidence that the full variable is
# better; the 3-category emp3 is enough. Decision: use emp3.


# ---------- 8. MODEL A: borrower characteristics only (no grade) ----------
# Variables known at application time, WITHOUT grade / sub_grade / int_rate
# (those are the platform's own risk assessment, so they would hide
# what the borrower's characteristics explain on their own).
# Not used as predictors: emp_length (replaced by emp3), annual_inc (log_inc),
# id, issue_date, funded_amnt, total_pymnt (leakage).
mA <- glm(
  is_default ~ log_inc + dti + fico_low + loan_amnt + emp3 +
    home_ownership + purpose + verification_status +
    revol_util + inq_last_6mths + delinq_2yrs + pub_rec,
  data = train, family = binomial
)
any(is.na(coef(mA)))   # FALSE = no collinear (NA) coefficients

# Prediction on the test set (2015 vintage, never seen by the model)
p_A <- predict(mA, newdata = test, type = "response")

# NOTE: purpose "educational" (1 loan in the whole sample) appeared only in the
# test set, and predict() failed on an unseen factor level. It was merged into
# "other" in section 3, same logic as ANY/NONE in home_ownership:
# rare categories are not kept as separate levels.

# AUC = probability that a randomly chosen defaulted loan gets a higher predicted
# risk than a randomly chosen repaid loan (0.5 = coin flip, 1 = perfect).
roc_A <- roc(test$is_default, p_A)
auc(roc_A)
# AUC (test, 2015) = 0.6549, Gini = 2*AUC - 1 = 0.31 -> better than random,
# moderate. Hard test: trained on 2012-2014, evaluated on 2015, where default
# rates were higher (drift). AUC only measures ranking, not whether the predicted
# probabilities are right (that is the calibration check).


# ---------- 9. COMPARISON ON THE TEST SET (2015) ----------
# grade only
m_grade <- glm(is_default ~ grade, data = train, family = binomial)
auc(roc(test$is_default, predict(m_grade, newdata = test, type = "response")))

# model B = borrower characteristics + grade
mB <- update(mA, . ~ . + grade)
auc(roc(test$is_default, predict(mB, newdata = test, type = "response")))

# model A without employment length
mA2 <- update(mA, . ~ . - emp3)
auc(roc(test$is_default, predict(mA2, newdata = test, type = "response")))

# AUC: model A (borrower only) 0.6549 | grade only 0.6675 | model B (A + grade) 0.6851
# | model A without emp3 0.6536.
# - grade alone beats all borrower characteristics together (+1.3 pp), expected:
#   grade comes from LendingClub's own model with more information (bureau data);
# - adding borrower characteristics to grade improves AUC by +1.8 pp -> grade does
#   not capture all risk (consistent with DTI not being priced within a grade);
# - emp3 adds only +0.13 pp: a real but very weak signal.
# All AUCs are moderate (0.65-0.69): hard setting (train 2012-2014, test 2015, drift).


# ---------- 10. CALIBRATION OF MODEL B ON THE TEST SET (2015) ----------
# test_sim = test set + predicted default probability of model B (p) + risk decile.
# Used in all sections below. Model B is never refitted on 2015.
test_sim <- test %>%
  mutate(p     = predict(mB, newdata = test, type = "response"),
         decyl = ntile(p, 10))

mean(test_sim$p)   # ~13.2% (= training default rate 13.25%)

kalibracja <- test_sim %>%
  group_by(decyl) %>%
  summarise(
    n            = n(),
    przewidziane = mean(p),
    rzeczywiste  = mean(is_default)
  )
kalibracja

# Loans split into 10 equal groups by predicted risk (ntile); predicted vs actual
# default rate per group.
# - Ranking is right: actual default rate rises from 3.5% (decile 1) to 30.8%
#   (decile 10), ~8.8x spread.
# - Level is too low: mean predicted risk ~13.2% vs actual 14.9% in 2015.
#   From decile 4 up the model underestimates by 1-4 pp (largest gap in
#   deciles 8-9). Consistent with the drift found in SQL section 6
#   (default rates rose in every grade between 2013 and 2015).

p_cal <- ggplot(kalibracja, aes(x = przewidziane, y = rzeczywiste)) +
  geom_abline(slope = 1, intercept = 0, linetype = "dashed") +
  geom_line(colour = "grey60") +
  geom_point(size = 3) +
  scale_x_continuous(labels = scales::percent, limits = c(0, 0.35)) +
  scale_y_continuous(labels = scales::percent, limits = c(0, 0.35)) +
  coord_equal() +
  labs(
    title    = "Calibration of model B on the 2015 test set",
    subtitle = "Points above the dashed line = risk underestimated",
    x        = "Mean predicted default probability (per decile)",
    y        = "Actual default rate (per decile)"
  ) +
  theme_minimal()
p_cal
ggsave("output/calibration_B.png", p_cal, width = 7, height = 7, dpi = 150)


# ---------- 11. NET RETURN PER DECILE OF PREDICTED RISK (model B, test 2015) ----------
# Net return = (sum of payments - sum of funded amounts) / sum of funded amounts,
# by amounts (not an average of single-loan returns), nominal, whole loan life.
wynik_decyle <- test_sim %>%
  group_by(decyl) %>%
  summarise(
    n            = n(),
    mean_p       = mean(p),
    default_rate = mean(is_default),
    net_return   = (sum(total_pymnt) - sum(funded_amnt)) / sum(funded_amnt)
  )
wynik_decyle

# sanity check: whole test set, should be ~0.0655
with(test_sim, (sum(total_pymnt) - sum(funded_amnt)) / sum(funded_amnt))

# Test set split into 10 equal groups by predicted default probability
# (decile 1 = safest, 10 = riskiest).
# - Ranking is right: actual default rate rises monotonically, 3.5% -> 30.8%.
# - Level is underestimated, and the gap grows with risk: ~0 pp in deciles 1-3,
#   +1-2 pp in 4-7, +3 pp in 8-10 (drift 2013 -> 2015, see SQL section 6).
# - Net return is an inverted U: 7.2% (decile 1) -> peak 7.7% (decile 4)
#   -> 2.7% (decile 10). Nothing is negative, but the riskiest decile earns
#   little for its risk.
# - Interpretation: for low risk the higher interest rate more than offsets
#   extra defaults (A -> B); from roughly decile 5-6 losses grow faster than
#   the rate (each +1 pp of defaults costs ~0.45 pp of return, because a
#   charged-off loan loses ~35-40%). Decile 1 earns less than 4 because grade A
#   has a low rate (~7%), so "safest" is not "most profitable".
# - Limitation: nominal returns, no time value of money; safer loans repay
#   faster, so with discounting their advantage would likely be larger.


# ---------- 12. SELECTION SIMULATION: "BUY THE BEST x%" - MODEL B vs GRADE CUT-OFF ----------
# Test set (2015, 282,898 loans). Loans sorted by predicted default probability of
# model B (lowest first). For each x% the ACTUAL net return of the cumulated basket
# is computed from real funded_amnt and total_pymnt (by amounts, nominal, whole
# loan life). The model only decides WHICH loans enter the basket (prediction at
# issue time), so the comparison is fair. Model was not fitted on 2015.
# Alternative strategy (red points): keep grade A, A-B, A-C ... (7 points).

# 12a. Curves
krzywa_model <- test_sim %>%
  arrange(p) %>%
  mutate(
    skum_wyplacone  = cumsum(funded_amnt),
    skum_splacone   = cumsum(total_pymnt),
    udzial_kredytow = row_number() / n(),
    net_return      = (skum_splacone - skum_wyplacone) / skum_wyplacone
  )

krzywa_grade <- test_sim %>%
  group_by(grade) %>%
  summarise(n = n(), wyplacone = sum(funded_amnt), splacone = sum(total_pymnt)) %>%
  arrange(grade) %>%
  mutate(
    basket          = c("A", "A-B", "A-C", "A-D", "A-E", "A-F", "A-G"),
    udzial_kredytow = cumsum(n) / sum(n),
    net_return      = (cumsum(splacone) - cumsum(wyplacone)) / cumsum(wyplacone)
  )
krzywa_grade

# Plot without the artefact at the start (tiny cumulated sums for the first loans)
p_curve <- ggplot() +
  geom_line(data = filter(krzywa_model, udzial_kredytow > 0.02),
            aes(udzial_kredytow, net_return), colour = "steelblue") +
  geom_line(data = krzywa_grade, aes(udzial_kredytow, net_return), colour = "tomato") +
  geom_point(data = krzywa_grade, aes(udzial_kredytow, net_return),
             colour = "tomato", size = 3) +
  scale_x_continuous(labels = scales::percent) +
  scale_y_continuous(labels = scales::percent) +
  labs(
    title    = "Net return: model B vs grade cut-off (test 2015)",
    subtitle = "Blue = loans sorted by model B; red = keep grade A, A-B, A-C, ...",
    x        = "Share of loans in the portfolio (safest first)",
    y        = "Net return of the portfolio"
  ) +
  theme_minimal()
p_curve
ggsave("output/net_return_curve.png", p_curve, width = 9, height = 5, dpi = 150)

# Peak of the model curve (searched only for > 2% of loans, to skip the artefact)
krzywa_model %>%
  filter(udzial_kredytow > 0.02) %>%
  slice_max(net_return, n = 1) %>%
  select(udzial_kredytow, net_return)

# - Both curves end at the same point: whole portfolio, +6.55%.
# - Model peak: 47.2% of loans, net return 7.43% (+0.9 pp vs no selection).
#   Curve is flat between ~30% and ~70% (7.2-7.4%), so the exact peak is not
#   meaningful; the max is found in-sample (slightly optimistic).
# - Spike near 0% is an artefact (tiny cumulated sums), not a result.
# - Grade strategy: A 6.89% (24.8% of loans), A-B 7.17% (57.2%, its peak),
#   A-C 6.99% (84.5%), then ~6.55-6.75%.

# 12b. Model vs grade at the SAME basket size (model basket = n lowest-p loans,
#      n = size of the grade basket). Only WHICH loans are chosen differs.
#      Grade cuts sharply; the model mixes grades (uses DTI, FICO, income etc.).
n_cut <- cumsum(krzywa_grade$n)   # basket sizes: A, A-B, A-C, ...

porownanie <- krzywa_model %>%
  slice(n_cut) %>%
  transmute(udzial_kredytow, net_model = net_return) %>%
  bind_cols(basket    = krzywa_grade$basket,
            net_grade = krzywa_grade$net_return) %>%
  mutate(roznica_pp = (net_model - net_grade) * 100)
porownanie   # last row (A-G) must be exactly 0

# Composition of the model's basket of the size of grade A (shows grade mixing)
sklad_A <- test_sim %>%
  arrange(p) %>%
  slice(1:krzywa_grade$n[1]) %>%
  count(grade) %>%
  mutate(udzial = n / sum(n))
sklad_A

#   A (24.8%)    7.21% vs 6.89%  -> +0.32 pp
#   A-B (57.2%)  7.38% vs 7.17%  -> +0.21 pp
#   A-C (84.5%)  7.09% vs 6.99%  -> +0.10 pp
#   A-D, A-E, A-F: about 0 (-0.01 to -0.02), noise
#   A-G (100%): 0 (same portfolio, sanity check)
# - Advantage is largest for the most selective baskets and shrinks with size.

# 12c. Bootstrap: is the advantage of the model just sampling noise?
# Resample the 2015 test set with replacement; in each resample the grade basket
# size is recomputed and the model basket has the same size. The model is NOT
# refitted. Output: model minus grade, net return, in pp.
roznica_boot <- function(dane, grady = "A") {
  a   <- dane %>% filter(grade %in% grady)
  n_a <- nrow(a)
  
  net_grade <- (sum(a$total_pymnt) - sum(a$funded_amnt)) / sum(a$funded_amnt)
  
  net_model <- dane %>%
    arrange(p) %>%
    slice(1:n_a) %>%
    summarise(r = (sum(total_pymnt) - sum(funded_amnt)) / sum(funded_amnt)) %>%
    pull(r)
  
  (net_model - net_grade) * 100
}

roznica_boot(test_sim, "A")            # 0.3239 (matches porownanie)
roznica_boot(test_sim, c("A", "B"))    # 0.2061

B <- 200
wyniki_A  <- numeric(B)
wyniki_AB <- numeric(B)

set.seed(123)
for (i in 1:B) {
  proba <- test_sim %>% slice_sample(prop = 1, replace = TRUE)
  wyniki_A[i] <- roznica_boot(proba, "A")
}

set.seed(123)
for (i in 1:B) {
  proba <- test_sim %>% slice_sample(prop = 1, replace = TRUE)
  wyniki_AB[i] <- roznica_boot(proba, c("A", "B"))
}

mean(wyniki_A);  quantile(wyniki_A,  c(0.025, 0.975))
mean(wyniki_AB); quantile(wyniki_AB, c(0.025, 0.975))
#   basket A:   point +0.324, mean +0.326, 95% CI [+0.26, +0.40]
#   basket A-B: point +0.206, mean +0.205, 95% CI [+0.15, +0.26]
#   (values from earlier runs; A-B may differ slightly after the seed change)
# - Both intervals are above zero: the advantage is not sampling noise.
#
# CONCLUSIONS
# - The model beats grade at equal basket size, but the effect is small:
#   +0.2 to +0.3 pp over 3 years (nominal), ~0.1 pp per year.
# - Selection helps mostly by removing the riskiest half; tightening further adds
#   nothing (inverted U, consistent with deciles in section 11).
# LIMITATIONS
# - Bootstrap covers only sampling noise within 2015; not tested on another
#   vintage (drift). Optimal cut-off chosen in-sample.
# - Returns are nominal: no time value of money, no platform fees. X-axis is share
#   of loans by count, not by amount.


# ---------- 13. RECALIBRATION OF MODEL B (test 2015) ----------
# Fit: glm(is_default ~ qlogis(p_B)), binomial, on the 2015 test set.
# logit(P(default)) = a + b * logit(p_B); perfect calibration: a = 0, b = 1.
test_sim <- test_sim %>%
  mutate(logit_p = qlogis(p))

recal <- glm(is_default ~ logit_p, data = test_sim, family = binomial)
coef(recal)   # a = 0.255, b = 1.064

test_sim <- test_sim %>%
  mutate(p_recal = predict(recal, newdata = test_sim, type = "response"))

mean(test_sim$p_recal)    # 0.1488
mean(test_sim$is_default) # 0.1488 (guaranteed by the intercept, not a result)

kalibracja2 <- test_sim %>%
  group_by(decyl) %>%
  summarise(
    przed      = mean(p),
    po         = mean(p_recal),
    faktycznie = mean(is_default),
    .groups    = "drop"
  ) %>%
  mutate(
    blad_przed = (przed - faktycznie) * 100,   # pp, negative = underestimate
    blad_po    = (po - faktycznie) * 100
  )
kalibracja2

mean(abs(kalibracja2$blad_przed))   # 1.73 pp
mean(abs(kalibracja2$blad_po))      # 0.52 pp

# Ranking must not change (monotone transformation)
auc(roc(test_sim$is_default, test_sim$p))
auc(roc(test_sim$is_default, test_sim$p_recal))   # identical

kal_long <- kalibracja2 %>%
  select(decyl, faktycznie, przed, po) %>%
  pivot_longer(c(przed, po), names_to = "wersja", values_to = "przewidziane") %>%
  mutate(wersja = recode(wersja, przed = "before", po = "after"))

p_recal_plot <- ggplot(kal_long, aes(przewidziane, faktycznie, colour = wersja)) +
  geom_abline(slope = 1, intercept = 0, linetype = "dashed") +
  geom_line() +
  geom_point(size = 3) +
  scale_x_continuous(labels = scales::percent, limits = c(0, 0.35)) +
  scale_y_continuous(labels = scales::percent, limits = c(0, 0.35)) +
  coord_equal() +
  scale_colour_manual(values = c(before = "tomato", after = "steelblue")) +
  labs(title    = "Calibration of model B, test 2015: before and after recalibration",
       subtitle = "Points above the dashed line = risk underestimated",
       x        = "Mean predicted default probability (per decile)",
       y        = "Actual default rate (per decile)",
       colour   = NULL) +
  theme_minimal()
p_recal_plot
ggsave("output/calibration_recal.png", p_recal_plot, width = 7, height = 7, dpi = 150)

# - a = 0.255, b = 1.064: b close to 1 -> spread of risk about right; a > 0 ->
#   model underestimates the LEVEL (trained on 2012-2014, default rate 13.25%,
#   vs 14.88% in 2015). The drift is mostly a level shift.
# - The gap in pp grows with risk even for a constant shift in log-odds, so the
#   growing error in deciles does not imply b >> 1.
# - Mean absolute decile error: 1.73 pp before, 0.52 pp after (in-sample).
# - Remaining error has a wave shape, not noise: deciles 1-3 +0.2 to +0.6 pp
#   (overestimate), deciles 4-9 -0.2 to -0.8 pp (underestimate), decile 10 +1.4 pp
#   (32.2% vs 30.8%). A level shift + slope does not capture the whole curve.
# LIMITATION: a and b are fitted AND evaluated on 2015, so this is a diagnosis,
# not an honest correction. A fair version would fit on one vintage (or on the
# first half of 2015) and evaluate on the next.


# ---------- 14. EXPORT FOR DASHBOARD (Power BI / Excel) ----------
# krzywa_model: skip the first 2% (artefact) and keep every 100th row
krzywa_model_export <- krzywa_model %>%
  filter(udzial_kredytow > 0.02) %>%
  slice(seq(1, n(), by = 100)) %>%
  select(udzial_kredytow, net_return)

write.csv(wynik_decyle,        "output/decile_net_return.csv",   row.names = FALSE)
write.csv(krzywa_grade,        "output/curve_grade.csv",         row.names = FALSE)
write.csv(krzywa_model_export, "output/curve_model.csv",         row.names = FALSE)
write.csv(porownanie,          "output/model_vs_grade.csv",      row.names = FALSE)
write.csv(kalibracja2,         "output/calibration_before_after.csv", row.names = FALSE)
write.csv(data.frame(A = wyniki_A, AB = wyniki_AB),
          "output/bootstrap_results.csv", row.names = FALSE)


# tabela AUC
auc_tab <- data.frame(
  model = c("Grade only", "Borrower only (A)", "Borrower + grade (B)", "A without emp. length"),
  auc = c(
    auc(roc(test$is_default, predict(m_grade, newdata = test, type = "response"))),
    auc(roc(test$is_default, predict(mA,      newdata = test, type = "response"))),
    auc(roc(test$is_default, predict(mB,      newdata = test, type = "response"))),
    auc(roc(test$is_default, predict(mA2,     newdata = test, type = "response")))
  )
)

# AUC table for the dashboard
auc_tab <- data.frame(
  model = c("Grade only (LendingClub rating)",
            "Borrower data only (no grade)",
            "Borrower data + grade",
            "Borrower data only, no employment length"),
  auc = c(
    auc(roc(test$is_default, predict(m_grade, newdata = test, type = "response"))),
    auc(roc(test$is_default, predict(mA,      newdata = test, type = "response"))),
    auc(roc(test$is_default, predict(mB,      newdata = test, type = "response"))),
    auc(roc(test$is_default, predict(mA2,     newdata = test, type = "response")))
  )
)

# calibration table with English column names
calib_tab <- kalibracja %>%
  rename(decile = decyl, n_of_loans = n,
         predicted = przewidziane, actual = rzeczywiste)

dir.create("export", showWarnings = FALSE)
write.csv(auc_tab,   "export/model_auc.csv",         row.names = FALSE)
write.csv(calib_tab, "export/model_calibration.csv", row.names = FALSE)
