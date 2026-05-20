import pandas as pd
import numpy as np
from scipy import stats

def demean2(df_in, cols, tol=1e-10, max_iter=500):
    d = df_in[cols].astype(float).copy()
    for _ in range(max_iter):
        prev = d.values.copy()
        d -= d.groupby(df_in["sku_id"]).transform("mean")
        d -= d.groupby(df_in["store"]).transform("mean")
        if np.max(np.abs(d.values - prev)) < tol:
            break
    return d

def make_pstar(series):
    n_s = len(series)
    H   = (series.rank(method="average") - 0.5) / n_s
    return stats.norm.ppf(H.clip(1e-6, 1 - 1e-6))

df = pd.read_stata("final_tna_panel_ultimate.dta")
df = df.rename(columns={'sku_ln_price': 'ln_price', 'sku_ln_cost': 'ln_cost'})
need = ["ln_sales", "ln_price", "ln_cost", "lag_ln_sales", "sku_promo"]
df = df.dropna(subset=need).reset_index(drop=True)

dm = demean2(df, need)
Y = dm["ln_sales"].values
P = dm["ln_price"].values
D = dm["sku_promo"].values
L = dm["lag_ln_sales"].values
n = len(Y)

# Regress P on D and L (since they are already demeaned) to get pure structural shock of price
X_exog = np.column_stack([D, L])
c_exog, _, _, _ = np.linalg.lstsq(X_exog, P, rcond=None)
P_resid = P - X_exog @ c_exog

# ECDF on the pure residual
H = (pd.Series(P_resid).rank(method="average") - 0.5) / n
PS_resid = stats.norm.ppf(H.clip(1e-6, 1 - 1e-6))

# Now run Copula
X_cop = np.column_stack([P, D, L, PS_resid])
c_cop, _, _, _ = np.linalg.lstsq(X_cop, Y, rcond=None)
print("Copula on Pure Residuals (Park & Gupta strict):", c_cop[0])

