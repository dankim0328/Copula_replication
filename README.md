# Canned Tuna Price Elasticity Replication

This repository contains the replication files for estimating the price elasticity of demand for canned tuna using store-SKU level scanner data. The primary contribution of this codebase is the application of the Gaussian Copula control function approach (Park and Gupta, 2012) to correct for price endogeneity in a panel data setting, comparing it against traditional Naive OLS and Instrumental Variables (2SLS) methods.

## Directory Structure

- `code/`: Contains all data processing (`.do`) and modeling (`.py`) scripts.
- `data/`: Contains the raw and processed datasets (ignored in git to save space).
- `paper/`: Contains manuscript drafts and result tables.

## Data

The original data used in this replication is the **Dominick's Finer Foods** scanner dataset, provided by the University of Chicago Booth School of Business.

You can download the data from:
**https://www.chicagobooth.edu/research/kilts/research-data/dominicks**

The following three files are required to run the data cleaning scripts:

- `wtna.zip` — Weekly movement data for the canned tuna category
- `upctna.csv` — UPC-level product information for canned tuna
- `demo.dta` — Store-level demographic data

After downloading, place these files in the `data/` directory before running the cleaning scripts.

---

## Data Processing Pipeline

The data cleaning process uses Stata (`.do`) files to clean raw scanner data and produce the final panel datasets.

* **`data cleaning.do`**: An older, deprecated script. **Not used** in the current pipeline.
* **`data_cleaning_v2.do`**: Generates the `final_tna_panel_ultimate.dta` dataset. This version removes extreme outliers completely.
* **`data_cleaning_v3_outlier.do`**: Generates the `final_tna_panel_outlier.dta` dataset. This version preserves the outliers but cleans true missing values and controls for promotions. **This is the primary dataset used for the final regression analysis.**
* **`data_validation.do`**: Used to validate the generated panel data (e.g., checking market shares, IV validity, and within-panel variation).

**Recommended Execution Order:**
1. Run `data_cleaning_v3_outlier.do` to create the analysis dataset (`final_tna_panel_outlier.dta`).
2. Run `data_validation.do` (optional) to check data integrity.
3. Run `regression_new.py` to estimate the price elasticity.

## Methodology

This analysis estimates a log-log demand model incorporating Two-Way Fixed Effects (Store and SKU). 

Three estimation models are implemented:
1. **Naive OLS**: Baseline model with Two-Way Fixed Effects. Suffers from upward bias due to price endogeneity.
2. **Instrumental Variables (2SLS)**: Uses wholesale cost (`ln_cost`) as an instrument for retail price.
3. **Gaussian Copula (Park and Gupta, 2012)**: A novel control function approach that relies on the non-normality of the endogenous regressor to isolate the structural shock. 
    - *Note on Panel Application*: To correctly extract the pure structural shock of price in a highly parameterized fixed-effects model, the empirical cumulative distribution function (ECDF) is computed strictly on the **pure residuals** of the price equation (after projecting out Store FE, SKU FE, lagged sales, and promotional variables).
    - Standard errors are computed using a **Panel Block Bootstrap (B=500)** to properly account for serial correlation within Store-SKU clusters.
    - **Iterative Demeaning** (Frisch-Waugh-Lovell theorem) is utilized within the bootstrap loop to massively accelerate matrix inversions by avoiding explicit dummy variable creation.

## Results Summary

The implementation correctly demonstrates the theoretical upward bias of OLS and effectively corrects it using the Gaussian Copula approach, yielding an elasticity remarkably consistent with the traditional IV approach without the need for external instruments.

| Model | Price Elasticity | Std. Error |
| :--- | :---: | :---: |
| OLS (Two-Way FE) | -1.3015 | 0.0336 |
| IV (Two-Way FE 2SLS) | -1.4874 | 0.0424 |
| Gaussian Copula | -1.5293 | 0.0527 |

*(Note: Standard Errors for all models are clustered at the Store-SKU panel level).*

## Requirements

The Python replication code (`code/regression_new.py`) requires the following libraries:
- `pandas`
- `numpy`
- `scipy`
- `linearmodels`

## Running the Code

Navigate to the `code/` directory and execute the Python script:

```bash
cd code
python regression_new.py
```
*(Ensure the data file `final_tna_panel_outlier.dta` is placed in the `data/` directory before execution).*
