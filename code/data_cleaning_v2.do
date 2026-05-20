/*==================================================
  Dominick's Finer Foods (DFF) Data Cleaning: Ultimate Version
  Method: Fixed Effects Demand Model & Gaussian Copula / IV
==================================================*/

clear all
set more off

// Specify working directory path as a global variable ($dir)
global dir "/Users/dankim/Downloads/SNU/대학원/논문/Copula_replication/data"


/*==================================================
  1. UPC Master Data Preprocessing (Integrate R & Python Logic)
==================================================*/
import delimited "$dir/upctna.csv", clear
gen desc_lower = lower(descrip)
gen size_upper = upper(size)

// [Best Logic 1] Multi-pack and general volume regex parsing (Python method)
gen volume_oz = .
// Case 1: Format like "3/3.2 OZ" (handle multiplication)
gen mult1 = real(ustrregexs(1)) if ustrregexm(size_upper, "^([0-9]+)/")
gen mult2 = real(ustrregexs(1)) if ustrregexm(size_upper, "/([0-9\.]+)")
replace volume_oz = mult1 * mult2 if !missing(mult1) & !missing(mult2)
// Case 2: Format like "6.5 OZ"
replace volume_oz = real(ustrregexs(1)) if missing(volume_oz) & ustrregexm(size_upper, "([0-9\.]+)")

// [Best Logic 2] Hard filtering and Outlier removal (Sohee's R method)
drop if volume_oz < 2 | volume_oz > 13 | missing(volume_oz)

// Perfectly remove non-tuna and heterogeneous packaging types
drop if ustrregexm(desc_lower, "salmon|oyster|clam|crab|mack|sardine|anchov|caviar|shrimp|lobster")
drop if ustrregexm(desc_lower, "sleeve|lunch|pre-mix|salad|kit|snack|pack")

// Identify brands and characteristics (for 9-SKU mapping)
gen brand = "Other"
replace brand = "StarKist" if ustrregexm(desc_lower, "star|sk ")
replace brand = "BumbleBee" if ustrregexm(desc_lower, "bumble|bb|bum bee")
replace brand = "COS" if ustrregexm(desc_lower, "cos|c o s|chick")
replace brand = "Dominicks" if ustrregexm(desc_lower, "dom")

gen is_oil = ustrregexm(desc_lower, "oil|/oi")
gen is_diet = ustrregexm(desc_lower, "diet|low|lite|l/s")
gen is_premium = ustrregexm(desc_lower, "alba|solid|sld|white|wht")
gen is_standard = ustrregexm(desc_lower, "chunk|chk|light|lgt")

// 9-SKU Mapping
gen sku_id = 9 // Default: Misc (only true unknown misc items remain)

// [Major Brands: Consolidate by brand regardless of Water/Oil]
replace sku_id = 1 if brand == "StarKist" 
replace sku_id = 2 if brand == "BumbleBee" 
replace sku_id = 5 if brand == "Dominicks" 

// [COS: Maintain separation of Water and Oil due to large volume]
replace sku_id = 3 if brand == "COS" & is_oil == 0
replace sku_id = 4 if brand == "COS" & is_oil == 1

// [Other Brands: Classify by characteristics (incorporating fixes from previous logic errors)]
replace sku_id = 6 if brand == "Other" & is_premium == 1
replace sku_id = 7 if brand == "Other" & is_standard == 1
replace sku_id = 8 if brand == "Other" & is_diet == 1 // Group only Diet from Other brands

// Change labeling names intuitively and safeguard against duplicate errors
capture label drop sku_lbl 
label define sku_lbl 1 "StarKist(All)" 2 "BumbleBee(All)" 3 "COS-Water" 4 "COS-Oil" ///
                     5 "Dominicks(All)" 6 "Other-Premium" 7 "Other-Standard" 8 "Other-Diet" 9 "Misc"
label values sku_id sku_lbl

keep upc descrip size volume_oz brand sku_id
save "$dir/upctna_clean.dta", replace


/*==================================================
  2. Movement Data Merging and Aggregation
==================================================*/
import delimited "$dir/wtna.csv", clear
keep if ok == 1 & move > 0 & price > 0 & qty > 0

// [Best Logic 3] Remove margin (Profit) outliers (Python method)
keep if !missing(profit) & profit > 0 & profit < 100

// ★ Modified merging logic (Added merging of missing upcs and modified key variables) ★
// 2-1. Merge cleaned UPC data (Key: upc)
merge m:1 upc using "$dir/upctna_clean.dta"
keep if _merge == 3
drop _merge

// 2-2. Merge store demographic information (Key: store)
merge m:1 store using "$dir/demo.dta"
keep if _merge == 3
drop _merge

// Calculate retail price per ounce and back-calculated wholesale cost
gen unit_price = price / qty
gen price_per_oz = unit_price / volume_oz
gen cost_per_oz = price_per_oz * (1 - (profit / 100))
gen revenue = unit_price * move
gen oz_sold = move * volume_oz

// Calculate Divisia Price Index weights
gen ln_p = ln(price_per_oz)
gen ln_c = ln(cost_per_oz)

bysort store week sku_id: egen total_rev_sku = sum(revenue)
gen share = revenue / total_rev_sku
gen weighted_ln_p = share * ln_p
gen weighted_ln_c = share * ln_c

// Collapse to SKU level (Synthesize and construct panel)
collapse (sum) oz_sold (sum) sku_ln_price=weighted_ln_p ///
         (sum) sku_ln_cost=weighted_ln_c (mean) income educ hsizeavg nocar, by(store week sku_id)

gen ln_sales = ln(oz_sold)
gen sku_price = exp(sku_ln_price)
gen sku_cost = exp(sku_ln_cost)

// [Best Logic 4] Stata built-in Lag to perfectly control time-series gaps
egen panel_id = group(store sku_id)
xtset panel_id week

gen lag_ln_sales = L.ln_sales

// Save final data
save "$dir/final_tna_panel_ultimate.dta", replace
