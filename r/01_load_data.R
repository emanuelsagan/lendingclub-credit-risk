pkgs <- c("DBI", "odbc", "dplyr")
missing_pkgs <- setdiff(pkgs, rownames(installed.packages()))
if (length(missing_pkgs) > 0) install.packages(missing_pkgs)

library(DBI)
library(odbc)
library(dplyr)

server <- Sys.getenv("CREDIT_RISK_SERVER", unset = "localhost")  # e.g. "MYPC\\SQLEXPRESS"

con <- dbConnect(
  odbc::odbc(),
  Driver   = "ODBC Driver 17 for SQL Server",
  Server   = server,
  Database = "credit_risk",
  Trusted_Connection = "Yes"   # Windows authentication
)

query <- "
SELECT
    id, issue_date, is_default, grade, loan_amnt, annual_inc, dti,
    fico_low, emp_length, home_ownership, purpose, verification_status,
    revol_util, inq_last_6mths, delinq_2yrs, funded_amnt, total_pymnt,
    int_rate, sub_grade, pub_rec
FROM loans_complete"

loans <- dbGetQuery(con, query)
dbDisconnect(con)

# Checks (expected: 589,488 rows, default rate 14.03%)
nrow(loans)
mean(loans$is_default)
glimpse(loans)
colSums(is.na(loans))

dir.create("data", showWarnings = FALSE)
saveRDS(loans, "data/loans.rds")