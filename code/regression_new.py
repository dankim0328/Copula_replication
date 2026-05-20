import sys
import pandas as pd
import numpy as np
from scipy import stats
from linearmodels.iv import IV2SLS
from scipy.stats import norm, jarque_bera
import warnings

warnings.filterwarnings('ignore')

def demean2(df_in, cols, tol=1e-8, max_iter=100):
    """SKU + STORE 두 방향 FE (Two-Way Fixed Effects) 반복 제거 (Iterative Demeaning)"""
    d = df_in[cols].astype(float).copy()
    for _ in range(max_iter):
        prev = d.values.copy()
        # SKU 평균 빼기
        d -= d.groupby(df_in["sku_id"]).transform("mean")
        # Store 평균 빼기
        d -= d.groupby(df_in["store"]).transform("mean")
        if np.max(np.abs(d.values - prev)) < tol:
            break
    return d

def make_pstar(series):
    """각 SKU 내 ln_price의 Copula 통제 변수 P* (Mid-rank ECDF 기반)"""
    n_s = len(series)
    H = (series.rank(method="average") - 0.5) / n_s
    return norm.ppf(H.clip(1e-6, 1 - 1e-6))

def run_estimations():
    # ==============================================================================
    # 1. 데이터 로드 및 결측치 제거
    # ==============================================================================
    file_path = "../data/final_tna_panel_ultimate.dta"
    print(f"Loading data from {file_path}...")
    df = pd.read_stata(file_path)

    # 변수명 통일
    rename_dict = {}
    if 'sku_ln_price' in df.columns:
        rename_dict['sku_ln_price'] = 'ln_price'
    if 'sku_ln_cost' in df.columns:
        rename_dict['sku_ln_cost'] = 'ln_cost'
    if rename_dict:
        df = df.rename(columns=rename_dict)

    # 결측치 제거
    df = df.dropna(subset=['ln_sales', 'ln_price', 'ln_cost', 'lag_ln_sales', 'sku_promo',
                           'income', 'educ', 'hsizeavg', 'nocar']).reset_index(drop=True)

    print(f"Analysis rows: {len(df):,}")
    
    # ==============================================================================
    # 2. 데이터 Demeaning (Two-Way FE 제거)
    # ==============================================================================
    print("\nTwo-way FE demeaning (SKU + STORE)...")
    vars_to_demean = ['ln_sales', 'ln_price', 'ln_cost', 'lag_ln_sales', 'sku_promo']
    dm = demean2(df, vars_to_demean)
    
    # 자유도 조정 (N - K - N_store - N_sku)
    n_sku = df["sku_id"].nunique()
    n_store = df["store"].nunique()
    df_resid_base = len(df) - 3 - (n_sku - 1) - (n_store - 1)
    
    # ==============================================================================
    # 사전 검정: 가격 데이터(ln_price)의 비정규성 검정
    # ==============================================================================
    print("\n=== 사전 검정: ln_price 비정규성 검정 (Jarque-Bera Test) ===")
    jb_stat, jb_pval = jarque_bera(df['ln_price'])
    print(f"Jarque-Bera Test Statistic: {jb_stat:.4f}")
    print(f"P-value: {jb_pval:.4e}")
    if jb_pval < 0.05:
        print("결론: ln_price는 정규분포를 따르지 않습니다. (Copula 적용 타당!)\n")

    # ==============================================================================
    # Model 1: Naive OLS (Two-Way Fixed Effects)
    # ==============================================================================
    print("\n" + "=" * 65)
    print("Model 1: Naive OLS (Two-Way FE)")
    print("=" * 65)
    # Demeaning을 했으므로 상수항(const)을 제외하고 회귀
    exog_ols = dm[['ln_price', 'lag_ln_sales', 'sku_promo']]
    model_ols = IV2SLS(dependent=dm['ln_sales'], exog=exog_ols, endog=None, instruments=None)
    # Panel 단위 Clustered SE 적용 (친구 코드의 한계 극복)
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

    # 🚨 핵심 교정 (Park & Gupta Strict Implementation) 🚨
    # 가격(ln_price)은 이미 Demean되어 있으나, 다른 외생변수(lag_ln_sales, sku_promo)의 
    # 영향도 마저 제거해야 순수한 가격의 구조적 충격(Structural Shock, v)을 얻을 수 있습니다.
    # Raw Price에 ECDF를 씌우면 FE 분산이 섞여 Copula가 붕괴됩니다.
    X_exog_price = dm[['lag_ln_sales', 'sku_promo']].values
    P_val = dm['ln_price'].values
    c_exog, _, _, _ = np.linalg.lstsq(X_exog_price, P_val, rcond=None)
    pure_price_resid = P_val - X_exog_price @ c_exog

    # Step 1: 순수 잔차(v)에 대해 ECDF 및 P* 산출
    dm["copula_p_star"] = make_pstar(pd.Series(pure_price_resid))

    exog_copula = dm[['ln_price', 'lag_ln_sales', 'sku_promo', 'copula_p_star']]
    model_copula = IV2SLS(dependent=dm['ln_sales'], exog=exog_copula, endog=None, instruments=None)
    res_copula_initial = model_copula.fit(cov_type='clustered', clusters=df['panel_id'])

    # Step 3: Bootstrapped Standard Errors (B=500, Panel Block Bootstrap)
    print("\nBootstrapping standard errors (B=500, fast iterative demeaning)...")
    np.random.seed(42)
    B = 500
    boot_coefs = []
    
    # 고속 샘플링을 위한 준비
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
        
        # Bootstrap 내 Demeaning
        bdm = demean2(bdf, ['ln_sales', 'ln_price', 'lag_ln_sales', 'sku_promo'], max_iter=50)
        
        # Bootstrap 내 순수 잔차(v) 도출 및 ECDF 재산출
        b_X_exog = bdm[['lag_ln_sales', 'sku_promo']].values
        b_P_val = bdm['ln_price'].values
        b_c_exog, _, _, _ = np.linalg.lstsq(b_X_exog, b_P_val, rcond=None)
        b_pure_resid = b_P_val - b_X_exog @ b_c_exog
        
        bdm["copula_p_star"] = make_pstar(pd.Series(b_pure_resid))
        
        X_b = bdm[['ln_price', 'lag_ln_sales', 'sku_promo', 'copula_p_star']].values
        Y_b = bdm['ln_sales'].values
        
        # Numpy lstsq로 초고속 해 구하기
        try:
            c_b, _, _, _ = np.linalg.lstsq(X_b, Y_b, rcond=None)
            boot_coefs.append(c_b)
        except Exception:
            pass

    # 부트스트랩 계수의 표준편차가 바로 Cluster-robust Standard Error 입니다.
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
    # 최종 요약 비교
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
