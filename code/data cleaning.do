/*==================================================
  Project: Dominick's Finer Foods (DFF) Data Cleaning
  Category: Canned Tuna (tna)
  Method: Fixed Effects Demand Model & Copula / IV
==================================================*/

clear all
set more off

// 1. 작업 공간 설정 (본인의 프로젝트 경로로 변경하세요)
// cd "/path/to/your/project"

/*==================================================
  Step 1. 데이터 로드 및 이상치 제거
==================================================*/
// UPC 데이터 로드 및 저장
import delimited "/Users/dankim/Downloads/SNU/대학원/논문/Copula_replication/data/upctna.csv", clear
save "/Users/dankim/Downloads/SNU/대학원/논문/Copula_replication/data/upctna.dta", replace

// Movement 데이터 로드 (가장 큰 파일)
import delimited "/Users/dankim/Downloads/SNU/대학원/논문/Copula_replication/data/wtna.csv", clear
// 비정상/오류 데이터(OK=0) 제외
keep if ok == 1 

/*==================================================
  Step 2. 데이터 병합 (Merging)
==================================================*/
// UPC 마스터 정보 결합
merge m:1 upc using "/Users/dankim/Downloads/SNU/대학원/논문/Copula_replication/data/upctna.dta"
keep if _merge == 3
drop _merge

// 스토어별 상권(Demographics) 정보 결합
merge m:1 store using "/Users/dankim/Downloads/SNU/대학원/논문/Copula_replication/data/demo.dta"
keep if _merge == 3
drop _merge

/*==================================================
  Step 3. 기본 파생 변수 생성 및 도매가 역산
==================================================*/
// 번들 단위(QTY)를 고려한 정확한 '단위당 가격(Unit Price)' 계산
gen unit_price = price / qty

// 개별 판매액(Revenue)
gen revenue = unit_price * move

// 마진율(profit %)을 활용한 단위당 '도매가(Wholesale Cost)' 산출 (추후 IV로 활용)
// 마진율이 0보다 작거나 결측치인 경우를 대비한 기본적인 처리
gen wholesale_cost = unit_price * (1 - (profit / 100))

/*==================================================
  Step 3.5 용량(Size) 표준화 및 온스당 가격/원가 생성
==================================================*/
// 안전장치: 기존 변수들이 메모리에 남아있다면 확실하게 삭제
capture drop volume_oz
capture drop standardized_move
capture drop price_per_oz
capture drop cost_per_oz
capture drop revenue

// size 변수에서 용량(숫자) 추출
gen volume_oz = real(regexs(0)) if regexm(size, "[0-9\.]+")
replace volume_oz = 6.5 if volume_oz == . // 결측치는 캔참치 표준 용량(6.5oz)으로 대치

// 온스 단위 표준 판매량
gen standardized_move = move * volume_oz

// 번들과 용량을 모두 고려한 '온스당 소매가'
gen price_per_oz = (price / qty) / volume_oz

// 물리적 판매액 재계산 (새로 생성)
gen revenue = (price / qty) * move

// 온스당 도매가 (마진율 역산)
gen cost_per_oz = price_per_oz * (1 - (profit / 100))

/*==================================================
  Step 3.8 비-참치 및 특수 패키지 상품 제거 (수정 권장)
==================================================*/
gen desc_lower = lower(descrip)

// 친구들 리포트 기준 필터링 적용
drop if strpos(desc_lower, "salmon") > 0 | strpos(desc_lower, "crab") > 0 ///
      | strpos(desc_lower, "clam") > 0 | strpos(desc_lower, "oyster") > 0 ///
      | strpos(desc_lower, "sardine") > 0 | strpos(desc_lower, "sleeve") > 0 ///
      | strpos(desc_lower, "lunch") > 0 | strpos(desc_lower, "salad") > 0 ///
      | strpos(desc_lower, "mix") > 0
	  
/*==================================================
  Step 4. UPC Description 텍스트 파싱 및 9개 SKU 매핑
==================================================*/
capture drop sku_id 
capture drop desc_lower 
capture drop brand 
capture drop liquid

gen desc_lower = lower(descrip)
gen brand = "Other"
gen liquid = "Water" // 캔참치는 수분 베이스가 디폴트

// 1. 브랜드 식별 (잘림 현상 및 DFF 축약어 룰 엄격 반영)
// 주의: "chk"는 Chicken of the sea가 아니라 Chunk일 확률이 높으므로 제외
replace brand = "StarKist" if strpos(desc_lower, "star") > 0 | strpos(desc_lower, "sk") > 0
replace brand = "BumbleBee" if strpos(desc_lower, "bumble") > 0 | strpos(desc_lower, "bb") > 0
replace brand = "COS" if strpos(desc_lower, "chick") > 0 | strpos(desc_lower, "cos") > 0 | strpos(desc_lower, "c-o-s") > 0
replace brand = "Dominicks" if strpos(desc_lower, "dom") > 0

// 2. 내용물(Oil) 매핑
replace liquid = "Oil" if strpos(desc_lower, "oil") > 0

// 3. 9개 카테고리 SKU ID 부여 (Sparse Panel 방지용 병합)
gen sku_id = .

// [메인 브랜드 라인업] - 관측치가 충분히 많은 것들만 독립 SKU로 유지
replace sku_id = 1 if brand == "StarKist" & liquid == "Water"
replace sku_id = 2 if brand == "BumbleBee" & liquid == "Water"
replace sku_id = 3 if brand == "COS" & liquid == "Water"
replace sku_id = 4 if brand == "COS" & liquid == "Oil"
replace sku_id = 5 if brand == "Dominicks" & liquid == "Water"

// [Other 계열 세분화] - 참치 품종 및 타겟 기준
// Premium: Albacore(alba) 또는 White(wht) 통조림
replace sku_id = 6 if brand == "Other" & (strpos(desc_lower, "solid") > 0 | strpos(desc_lower, "alba") > 0 | strpos(desc_lower, "wht") > 0 | strpos(desc_lower, "white") > 0)
// Standard: Chunk(chk, chunk) 또는 Light(lgt) 통조림 (Premium이 아닌 것 중)
replace sku_id = 7 if brand == "Other" & (strpos(desc_lower, "chunk") > 0 | strpos(desc_lower, "chk") > 0 | strpos(desc_lower, "lgt") > 0) & sku_id == .
// Diet: Diet, Low sodium, Lite 등
replace sku_id = 8 if brand == "Other" & (strpos(desc_lower, "diet") > 0 | strpos(desc_lower, "low") > 0 | strpos(desc_lower, "lite") > 0)

// [Misc (기타)] - 조건에 안 맞거나, 관측치가 너무 적은 메인 브랜드의 Oil 제품들
replace sku_id = 9 if sku_id == .

// 라벨링 적용
capture label drop sku_lbl
label define sku_lbl 1 "StarKist-Water" 2 "BumbleBee-Water" 3 "COS-Water" 4 "COS-Oil" ///
                     5 "Dominicks-Water" 6 "Other-Premium" 7 "Other-Standard" 8 "Other-Diet" 9 "Misc"
label values sku_id sku_lbl

// 최종 매핑 결과 확인 (친구들 리포트의 N수와 비슷하게 분배되는지 체크)
tab sku_id, missing
drop desc_lower brand liquid

/*==================================================
  Step 5. 기하 점유율 평균(Divisia Price Index) 산출
==================================================*/
capture drop ln_p
gen ln_p = ln(price_per_oz)

bysort store week sku_id: egen total_rev_sku = sum(revenue)
gen share = revenue / total_rev_sku
gen weighted_ln_p = share * ln_p

// SKU 단위로 데이터 집계 (차원의 저주 해결)
collapse (sum) standardized_move (sum) sku_ln_price=weighted_ln_p ///
         (mean) cost_per_oz, by(store week sku_id)

gen sku_price = exp(sku_ln_price)
gen ln_sales = ln(standardized_move)
gen ln_price = ln(sku_price)
gen ln_cost = ln(cost_per_oz)


/*==================================================
  Step 6. 패널 구조 셋팅 및 시차(Lagged) 변수 생성
==================================================*/
egen panel_id = group(store sku_id)
xtset panel_id week

// 선수요/재고 축적 통제를 위한 과거 1주 전 판매량 생성
gen lag_ln_sales = L.ln_sales


/*==================================================
  Step 7. 최종 데이터 저장
==================================================*/
save "/Users/dankim/Downloads/SNU/대학원/논문/Copula_replication/data/final_tna_panel.dta", replace
