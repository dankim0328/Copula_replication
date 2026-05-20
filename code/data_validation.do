clear all
set more off

// 0. Load saved final data (set path)
global dir "/Users/dankim/Downloads/SNU/대학원/논문/Copula_replication/data"
use "$dir/final_tna_panel_ultimate.dta", clear

// (Note) Since the Ultimate version skipped summing revenue during the collapse stage, 
// create approximate revenue at the panel level for validation.
capture drop revenue
gen revenue = sku_price * oz_sold


/*==================================================
  [For Q1 & Q2] Understand SKU composition and Market Share
==================================================*/
disp "=== 1. Total Sales (oz) and Total Revenue by SKU ==="
// Output in thousands comma format just like the old code.
tabstat oz_sold revenue, by(sku_id) stat(sum) format(%15.0fc)

disp "=== 2. Sales Volume Share by SKU ==="
// Check how evenly the 9 categories appear among all observations (check if there are few missing panels)
tab sku_id


/*==================================================
  [For Q3] Instrumental Variable (IV) validity and margin analysis
==================================================*/
disp "=== 3. Correlation between Retail Price and Wholesale Cost (IV Relevance) ==="
// Verify IV validity (correlation close to 1 and p-value 0 means excellent IV)
pwcorr sku_price sku_cost, sig

disp "=== 4. Mean Retail Price, Wholesale Cost, and Margin by SKU ==="
tabstat sku_price sku_cost, by(sku_id) stat(mean sd) format(%9.3f)


/*==================================================
  [For Q4] Check Time-Series Variation of Panel Data
==================================================*/
disp "=== 5. Panel Variation Decomposition (Between vs. Within) ==="
// Check if Within (weekly per store) variation is sufficient for Fixed Effects model identification
// Note: In old data, sku_price Max jumped up to 13.8, 
// but in this Ultimate version, extreme outliers are removed so it should be in a much more stable range!
xtsum sku_price oz_sold
