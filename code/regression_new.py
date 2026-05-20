import sys
import pandas as pd
import numpy as np
from scipy import stats
from linearmodels.iv import IV2SLS
from scipy.stats import norm, jarque_bera
import warnings

warnings.filterwarnings('ignore')

def demean2(df_in, cols, tol=1e-8, max_iter=100):
    """Iterative Demeaning for Two-Way Fixed Effects (SKU + STORE)"""
    d = df_in[cols].astype(float).copy()
    for _ in range(max_iter):
        prev = d.values.copy()
        # Subtract SKU mean
        d -= d.groupby(df_in["sku_id"]).transform("mean")
        # Subtract Store mean
        d -= d.groupby(df_in["store"]).transform("mean")
        if np.max(np.abs(d.values - prev)) < tol:
            break
    return d

def make_pstar(series):
    """Generate Copula control variable P* (based on Mid-rank ECDF)"""
    n_s = len(series)
    H = (series.rank(method="average") - 0.5) / n_s
    return norm.ppf(H.clip(1e-6, 1 - 1e-6))

def run_estimations():
    # ==============================================================================
    # 1. Load Data and Remove Missing Values
    # ==============================================================================
    file_path = "../data/final_tna_panel_outlier.dta"
    print(f"Loading data from {file_path}...")
    df = pd.read_stata(file_path)

    # Standardize variable names
    rename_dict = {}
    if 'sku_ln_price' in df.columns:
        rename_dict['sku_ln_price'] = 'ln_price'
    if 'sku_ln_cost' in df.columns:
        rename_dict['sku_ln_cost'] = 'ln_cost'
    if rename_dict:
        df = df.rename(columns=rename_dict)

    # Drop missing values
    df = df.dropna(subset=['ln_sales', 'ln_price', 'ln_cost', 'lag_ln_sales', 'sku_promo',
                           'income', 'educ', 'hsizeavg', 'nocar']).reset_index(drop=True)

    print(f"Analysis rows: {len(df):,}")
    
    # ==============================================================================
    # 2. Data Demeaning (Remove Two-Way FE)
    # ==============================================================================
    print("\nTwo-way FE demeaning (SKU + STORE)...")
    vars_to_demean = ['ln_sales', 'ln_price', 'ln_cost', 'lag_ln_sales', 'sku_promo']
    dm = demean2(df, vars_to_demean)
    
    # Adjust degrees of freedom (N - K - N_store - N_sku)
    n_sku = df["sku_id"].nunique()
    n_store = df["store"].nunique()
    df_resid_base = len(df) - 3 - (n_sku - 1) - (n_store - 1)
    
    # ==============================================================================
    # Pre-test: Non-normality test for ln_price (Jarque-Bera Test)
    # ==============================================================================
    print("\n=== Pre-test: ln_price Non-normality (Jarque-Bera Test) ===")
    jb_stat, jb_pval = jarque_bera(df['ln_price'])
    print(f"Jarque-Bera Test Statistic: {jb_stat:.4f}")
    print(f"P-value: {jb_pval:.4e}")
    if jb_pval < 0.05:
        print("Conclusion: ln_price is not normally distributed. (Copula approach is valid!)\n")

    # ==============================================================================
    # Model 1: Naive OLS (Two-Way Fixed Effects)
    # ==============================================================================
    print("\n" + "=" * 65)
    print("Model 1: Naive OLS (Two-Way FE)")
    print("=" * 65)
    # Variables are already demeaned, so exclude the constant term
    exog_ols = dm[['ln_price', 'lag_ln_sales', 'sku_promo']]
    model_ols = IV2SLS(dependent=dm['ln_sales'], exog=exog_ols, endog=None, instruments=None)
    # Apply Panel Clustered SE
    res_ols = model_ols.fit(cov_type='clustered', clusters=df['panel_id'])
    print(res_ols.summary.tables[1])

    # ==============================================================================
    # Model 2: Panel IV Regression (2SLS with Two-Way Fixed Effects)
    # ==============================================================================
    print("\n" + "=" * 65)
    print("Model 2: Panel IV Regression (2SLS, Two-Way FE)")
    print("=" * 65)
    exog_iv = dm[['lag_ln_sales', 'sku_promo']]
    model_iv = IV2SLS(dependent=dm['ln_sales'], exog=exog_iv, endog=dm[['ln_price']], instruments=dm[['ln_cost']])
    res_iv = model_iv.fit(cov_type='clustered', clusters=df['panel_id'])
    print(res_iv.summary.tables[1])
    
    print("\n[ Durbin-Wu-Hausman Endogeneity Test ]")
    print(res_iv.wu_hausman())

    # ==============================================================================
    # Model 3: Gaussian Copula Method (Park and Gupta, 2012)
    # ==============================================================================
    print("\n" + "=" * 65)
    print("Model 3: Gaussian Copula (Park and Gupta, 2012)")
    print("=" * 65)

    # 🚨 Core Correction (Strict Park & Gupta Implementation) 🚨
    # Although ln_price is demeaned, we must also partial out the effects of other 
    # exogenous variables (lag_ln_sales, sku_promo) to extract the pure structural shock (v).
    # Computing the ECDF on the raw price directly would confound the Copula with FE variance.
    X_exog_price = dm[['lag_ln_sales', 'sku_promo']].values
    P_val = dm['ln_price'].values
    c_exog, _, _, _ = np.linalg.lstsq(X_exog_price, P_val, rcond=None)
    pure_price_resid = P_val - X_exog_price @ c_exog

    # Step 1: Compute ECDF and P* on the pure residuals
    dm["copula_p_star"] = make_pstar(pd.Series(pure_price_resid))

    exog_copula = dm[['ln_price', 'lag_ln_sales', 'sku_promo', 'copula_p_star']]
    model_copula = IV2SLS(dependent=dm['ln_sales'], exog=exog_copula, endog=None, instruments=None)
    res_copula_initial = model_copula.fit(cov_type='clustered', clusters=df['panel_id'])

    # Step 2: Bootstrapped Standard Errors (B=500, Panel Block Bootstrap)
    print("\nBootstrapping standard errors (B=500, fast iterative demeaning)...")
    np.random.seed(42)
    B = 500
    boot_coefs = []
    
    # Preparation for fast sampling
    panel_grp = {k: v.tolist() for k, v in df.groupby("panel_id").groups.items()}
    pk = list(panel_grp.keys())
    n_pk = len(pk)

    for b in range(B):
        if (b+1) % 50 == 0:
            print(f"  Bootstrap Iteration {b+1}/{B}...")
            
        rnd = np.random.choice(n_pk, n_pk, replace=True)
        idx = []
        for r in rnd:
            idx.extend(panel_grp[pk[r]])
            
        bdf = df.iloc[idx].reset_index(drop=True)
        
        # Demeaning within the Bootstrap
        bdm = demean2(bdf, ['ln_sales', 'ln_price', 'lag_ln_sales', 'sku_promo'], max_iter=50)
        
        # Extract pure residual and recalculate ECDF within Bootstrap
        b_X_exog = bdm[['lag_ln_sales', 'sku_promo']].values
        b_P_val = bdm['ln_price'].values
        b_c_exog, _, _, _ = np.linalg.lstsq(b_X_exog, b_P_val, rcond=None)
        b_pure_resid = b_P_val - b_X_exog @ b_c_exog
        
        bdm["copula_p_star"] = make_pstar(pd.Series(b_pure_resid))
        
        X_b = bdm[['ln_price', 'lag_ln_sales', 'sku_promo', 'copula_p_star']].values
        Y_b = bdm['ln_sales'].values
        
        # Use Numpy lstsq for high-speed estimation
        try:
            c_b, _, _, _ = np.linalg.lstsq(X_b, Y_b, rcond=None)
            boot_coefs.append(c_b)
        except Exception:
            pass

    # The standard deviation of the bootstrap coefficients represents the Cluster-robust Standard Error
    boot_arr = np.array(boot_coefs)
    boot_se = boot_arr.std(axis=0)
    copula_coefs = res_copula_initial.params

    print("\nGaussian Copula Results with Bootstrapped SEs:")
    copula_summary = pd.DataFrame({
        'Coefficient': copula_coefs,
        'Bootstrapped SE': boot_se,
        't-stat': copula_coefs / boot_se,
        'p-value': 2 * (1 - norm.cdf(np.abs(copula_coefs / boot_se)))
    }).round(4)
    print(copula_summary.loc[['ln_price', 'copula_p_star']])
    print("\n")


    # ==============================================================================
    # Final Summary Comparison
    # ==============================================================================
    print("=== 📊 Elasticity Comparison Summary ===")
    summary_df = pd.DataFrame({
        'Model': ['OLS (Two-Way FE)', 'IV (Two-Way FE 2SLS)', 'Gaussian Copula'],
        'Price Elasticity': [res_ols.params['ln_price'], res_iv.params['ln_price'], copula_coefs['ln_price']],
        'Std. Error': [res_ols.std_errors['ln_price'], res_iv.std_errors['ln_price'], boot_se[0]]
    }).round(4)
    print(summary_df.to_string(index=False))
    print("\nExecution Completed. High precision & High Speed.")

if __name__ == "__main__":
    run_estimations()
