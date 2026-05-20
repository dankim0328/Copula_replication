/*==================================================
  Dominick's Finer Foods (DFF) Data Cleaning: Ultimate Version
  Method: Fixed Effects Demand Model & Gaussian Copula / IV
==================================================*/

clear all
set more off

// 글로벌 변수($dir)로 작업 경로 지정
global dir "/Users/dankim/Downloads/SNU/대학원/논문/Copula_replication/data"


/*==================================================
  1. UPC 마스터 데이터 전처리 (R & Python 로직 통합)
==================================================*/
import delimited "$dir/upctna.csv", clear
gen desc_lower = lower(descrip)
gen size_upper = upper(size)

// [Best Logic 1] 멀티팩(Multi-pack) 및 일반 용량 정규표현식 파싱 (Python 방식)
gen volume_oz = .
// 케이스 1: "3/3.2 OZ" 형태 (곱셈 처리)
gen mult1 = real(ustrregexs(1)) if ustrregexm(size_upper, "^([0-9]+)/")
gen mult2 = real(ustrregexs(1)) if ustrregexm(size_upper, "/([0-9\.]+)")
replace volume_oz = mult1 * mult2 if !missing(mult1) & !missing(mult2)
// 케이스 2: "6.5 OZ" 형태
replace volume_oz = real(ustrregexs(1)) if missing(volume_oz) & ustrregexm(size_upper, "([0-9\.]+)")

// [Best Logic 2] 하드 필터링 및 Outlier 제거 (Sohee's R 방식)
drop if volume_oz < 2 | volume_oz > 13 | missing(volume_oz)

// 비-참치 및 이질적 포장 형태 완벽 제거
drop if ustrregexm(desc_lower, "salmon|oyster|clam|crab|mack|sardine|anchov|caviar|shrimp|lobster")
drop if ustrregexm(desc_lower, "sleeve|lunch|pre-mix|salad|kit|snack|pack")

// 브랜드 및 특성 식별 (9개 SKU 매핑용)
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
gen sku_id = 9 // Default: Misc (진짜 정체를 알 수 없는 기타 등등만 남음)

// [메이저 브랜드: Water/Oil 묻지도 따지지도 않고 브랜드로 통합]
replace sku_id = 1 if brand == "StarKist" 
replace sku_id = 2 if brand == "BumbleBee" 
replace sku_id = 5 if brand == "Dominicks" 

// [COS: 물량이 많으므로 Water와 Oil 분리 유지]
replace sku_id = 3 if brand == "COS" & is_oil == 0
replace sku_id = 4 if brand == "COS" & is_oil == 1

// [Other 브랜드: 특성별로 분류 (이전 논리 오류 수정 반영)]
replace sku_id = 6 if brand == "Other" & is_premium == 1
replace sku_id = 7 if brand == "Other" & is_standard == 1
replace sku_id = 8 if brand == "Other" & is_diet == 1 // Other 브랜드의 Diet만 묶음

// 라벨링 이름 직관적으로 변경 및 중복 에러 방지 안전장치
capture label drop sku_lbl 
label define sku_lbl 1 "StarKist(All)" 2 "BumbleBee(All)" 3 "COS-Water" 4 "COS-Oil" ///
                     5 "Dominicks(All)" 6 "Other-Premium" 7 "Other-Standard" 8 "Other-Diet" 9 "Misc"
label values sku_id sku_lbl

keep upc descrip size volume_oz brand sku_id
save "$dir/upctna_clean.dta", replace


/*==================================================
  2. Movement 데이터 병합 및 집계
==================================================*/
import delimited "$dir/wtna.csv", clear
keep if ok == 1 & move > 0 & price > 0 & qty > 0

// [Best Logic 3] 마진율(Profit) 이상치 제거 (Python 방식)
keep if !missing(profit) & profit > 0 & profit < 100

// ★ 수정된 병합 로직 (누락된 upc 병합 추가 및 기준 변수 수정) ★
// 2-1. 정제된 UPC 데이터 병합 (기준: upc)
merge m:1 upc using "$dir/upctna_clean.dta"
keep if _merge == 3
drop _merge

// 2-2. 스토어 상권 정보 병합 (기준: store)
merge m:1 store using "$dir/demo.dta"
keep if _merge == 3
drop _merge

// 온스당 소매가 및 역산 도매가 계산
gen unit_price = price / qty
gen price_per_oz = unit_price / volume_oz
gen cost_per_oz = price_per_oz * (1 - (profit / 100))
gen revenue = unit_price * move
gen oz_sold = move * volume_oz

// Divisia Price Index 가중치 산출
gen ln_p = ln(price_per_oz)
gen ln_c = ln(cost_per_oz)

bysort store week sku_id: egen total_rev_sku = sum(revenue)
gen share = revenue / total_rev_sku
gen weighted_ln_p = share * ln_p
gen weighted_ln_c = share * ln_c

// SKU 수준으로 Collapse (합성 및 패널 구성)
collapse (sum) oz_sold (sum) sku_ln_price=weighted_ln_p ///
         (sum) sku_ln_cost=weighted_ln_c (mean) income educ hsizeavg nocar, by(store week sku_id)

gen ln_sales = ln(oz_sold)
gen sku_price = exp(sku_ln_price)
gen sku_cost = exp(sku_ln_cost)

// [Best Logic 4] 시계열 갭을 완벽하게 통제하는 Stata 내장 Lag
egen panel_id = group(store sku_id)
xtset panel_id week

gen lag_ln_sales = L.ln_sales

// 최종 데이터 저장
save "$dir/final_tna_panel_ultimate.dta", replace
