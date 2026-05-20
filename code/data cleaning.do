/*==================================================
  Project: Dominick's Finer Foods (DFF) Data Cleaning
  Category: Canned Tuna (tna)
  Method: Fixed Effects Demand Model & Copula / IV
==================================================*/

clear all
set more off

// 1. Set working directory (change to your project path)
// cd "/path/to/your/project"

/*==================================================
  Step 1. Load Data and Remove Outliers
==================================================*/
// Load and save UPC data
import delimited "/Users/dankim/Downloads/SNU/대학원/논문/Copula_replication/data/upctna.csv", clear
save "/Users/dankim/Downloads/SNU/대학원/논문/Copula_replication/data/upctna.dta", replace

// Load Movement data (largest file)
import delimited "/Users/dankim/Downloads/SNU/대학원/논문/Copula_replication/data/wtna.csv", clear
// Exclude abnormal/error data (OK=0)
keep if ok == 1 

/*==================================================
  Step 2. Data Merging
==================================================*/
// Merge with UPC master information
merge m:1 upc using "/Users/dankim/Downloads/SNU/대학원/논문/Copula_replication/data/upctna.dta"
keep if _merge == 3
drop _merge

// Merge with store-level Demographics information
merge m:1 store using "/Users/dankim/Downloads/SNU/대학원/논문/Copula_replication/data/demo.dta"
keep if _merge == 3
drop _merge

/*==================================================
  Step 3. Create Basic Derived Variables and Back-calculate Wholesale Cost
==================================================*/
// Calculate accurate 'Unit Price' considering bundle unit (QTY)
gen unit_price = price / qty

// Individual Sales Revenue
gen revenue = unit_price * move

// Calculate 'Wholesale Cost' per unit using profit % (to be used as IV later)
// Basic handling in case profit is less than 0 or missing
gen wholesale_cost = unit_price * (1 - (profit / 100))

/*==================================================
  Step 3.5 Standardize Size and Create Price/Cost per Oz
==================================================*/
// Safety measure: Ensure existing variables are dropped if they remain in memory
capture drop volume_oz
capture drop standardized_move
capture drop price_per_oz
capture drop cost_per_oz
capture drop revenue

// Extract volume (number) from size variable
gen volume_oz = real(regexs(0)) if regexm(size, "[0-9\.]+")
replace volume_oz = 6.5 if volume_oz == . // Impute missing with standard canned tuna volume (6.5oz)

// Standardized sales volume in ounces
gen standardized_move = move * volume_oz

// 'Retail Price per Oz' considering both bundle and volume
gen price_per_oz = (price / qty) / volume_oz

// Recalculate physical sales revenue (newly created)
gen revenue = (price / qty) * move

// Wholesale Cost per Oz (back-calculated from margin)
gen cost_per_oz = price_per_oz * (1 - (profit / 100))

/*==================================================
  Step 3.8 Remove Non-Tuna and Special Package Items (Revision Recommended)
==================================================*/
gen desc_lower = lower(descrip)

// Apply filtering based on Friends report
drop if strpos(desc_lower, "salmon") > 0 | strpos(desc_lower, "crab") > 0 ///
      | strpos(desc_lower, "clam") > 0 | strpos(desc_lower, "oyster") > 0 ///
      | strpos(desc_lower, "sardine") > 0 | strpos(desc_lower, "sleeve") > 0 ///
      | strpos(desc_lower, "lunch") > 0 | strpos(desc_lower, "salad") > 0 ///
      | strpos(desc_lower, "mix") > 0
	  
/*==================================================
  Step 4. Parse UPC Description Text and Map to 9 SKUs
==================================================*/
capture drop sku_id 
capture drop desc_lower 
capture drop brand 
capture drop liquid

gen desc_lower = lower(descrip)
gen brand = "Other"
gen liquid = "Water" // Canned tuna is water-based by default

// 1. Identify Brand (Strictly reflecting truncation and DFF abbreviation rules)
// Note: "chk" is likely Chunk, not Chicken of the sea, so exclude it
replace brand = "StarKist" if strpos(desc_lower, "star") > 0 | strpos(desc_lower, "sk") > 0
replace brand = "BumbleBee" if strpos(desc_lower, "bumble") > 0 | strpos(desc_lower, "bb") > 0
replace brand = "COS" if strpos(desc_lower, "chick") > 0 | strpos(desc_lower, "cos") > 0 | strpos(desc_lower, "c-o-s") > 0
replace brand = "Dominicks" if strpos(desc_lower, "dom") > 0

// 2. Map Content (Oil)
replace liquid = "Oil" if strpos(desc_lower, "oil") > 0

// 3. Assign 9 Category SKU IDs (To prevent Sparse Panel)
gen sku_id = .

// [Main Brand Lineup] - Keep as independent SKUs only for those with sufficient observations
replace sku_id = 1 if brand == "StarKist" & liquid == "Water"
replace sku_id = 2 if brand == "BumbleBee" & liquid == "Water"
replace sku_id = 3 if brand == "COS" & liquid == "Water"
replace sku_id = 4 if brand == "COS" & liquid == "Oil"
replace sku_id = 5 if brand == "Dominicks" & liquid == "Water"

// [Other Series Segmentation] - Based on tuna variety and target
// Premium: Albacore(alba) or White(wht) canned tuna
replace sku_id = 6 if brand == "Other" & (strpos(desc_lower, "solid") > 0 | strpos(desc_lower, "alba") > 0 | strpos(desc_lower, "wht") > 0 | strpos(desc_lower, "white") > 0)
// Standard: Chunk(chk, chunk) or Light(lgt) canned tuna (among non-Premium)
replace sku_id = 7 if brand == "Other" & (strpos(desc_lower, "chunk") > 0 | strpos(desc_lower, "chk") > 0 | strpos(desc_lower, "lgt") > 0) & sku_id == .
// Diet: Diet, Low sodium, Lite, etc.
replace sku_id = 8 if brand == "Other" & (strpos(desc_lower, "diet") > 0 | strpos(desc_lower, "low") > 0 | strpos(desc_lower, "lite") > 0)

// [Misc (Others)] - Oil products of main brands that do not fit the conditions or have too few observations
replace sku_id = 9 if sku_id == .

// Apply Labeling
capture label drop sku_lbl
label define sku_lbl 1 "StarKist-Water" 2 "BumbleBee-Water" 3 "COS-Water" 4 "COS-Oil" ///
                     5 "Dominicks-Water" 6 "Other-Premium" 7 "Other-Standard" 8 "Other-Diet" 9 "Misc"
label values sku_id sku_lbl

// Check final mapping results (Check if distributed similarly to the N count in Friends report)
tab sku_id, missing
drop desc_lower brand liquid

/*==================================================
  Step 5. Calculate Geometric Mean Share (Divisia Price Index)
==================================================*/
capture drop ln_p
gen ln_p = ln(price_per_oz)

bysort store week sku_id: egen total_rev_sku = sum(revenue)
gen share = revenue / total_rev_sku
gen weighted_ln_p = share * ln_p

// Aggregate data at SKU level (Solve curse of dimensionality)
collapse (sum) standardized_move (sum) sku_ln_price=weighted_ln_p ///
         (mean) cost_per_oz, by(store week sku_id)

gen sku_price = exp(sku_ln_price)
gen ln_sales = ln(standardized_move)
gen ln_price = ln(sku_price)
gen ln_cost = ln(cost_per_oz)


/*==================================================
  Step 6. Setup Panel Structure and Create Lagged Variables
==================================================*/
egen panel_id = group(store sku_id)
xtset panel_id week

// Create sales volume from 1 week ago to control for pre-demand/inventory accumulation
gen lag_ln_sales = L.ln_sales


/*==================================================
  Step 7. Save Final Data
==================================================*/
save "/Users/dankim/Downloads/SNU/대학원/논문/Copula_replication/data/final_tna_panel.dta", replace
