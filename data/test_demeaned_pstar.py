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

# 1. Demean all variables
dm = demean2(df, need)
Y = dm["ln_sales"].values
P = dm["ln_price"].values
W = dm["ln_cost"].values
L = dm["lag_ln_sales"].values
D = dm["sku_promo"].values
n = len(Y)

# 2. Copula on DEMEANED PRICE?
# df['demeaned_price'] = P
# P_star_demeaned = df.groupby("sku_id")['demeaned_price'].transform(make_pstar)
# But wait, if price is demeaned, we don't even need to group by SKU? Or maybe we still do.
# Let's just compute ECDF on the demeaned price overall.
H = (pd.Series(P).rank(method="average") - 0.5) / n
PS_dm_overall = stats.norm.ppf(H.clip(1e-6, 1 - 1e-6))

X_cop_overall = np.column_stack([P, D, L, PS_dm_overall])
c_overall, _, _, _ = np.linalg.lstsq(X_cop_overall, Y, rcond=None)
print("Copula on overall Demeaned Price:", c_overall[0])

# 3. Copula on Demeaned Price by SKU
df['demeaned_price'] = P
PS_by_sku = df.groupby("sku_id")['demeaned_price'].transform(make_pstar).values
X_cop_sku = np.column_stack([P, D, L, PS_by_sku])
c_sku, _, _, _ = np.linalg.lstsq(X_cop_sku, Y, rcond=None)
print("Copula on Demeaned Price (grouped by SKU):", c_sku[0])

