clear all
set more off

// 0. 저장해둔 최종 데이터 불러오기 (경로 설정)
global dir "/Users/dankim/Downloads/SNU/대학원/논문/Copula_replication/data"
use "$dir/final_tna_panel_ultimate.dta", clear

// (참고) Ultimate 버전은 collapse 단계에서 revenue 합산을 생략했으므로, 
// 검증을 위해 패널 수준의 대략적인 매출액(revenue)을 다시 생성합니다.
capture drop revenue
gen revenue = sku_price * oz_sold


/*==================================================
  [Q1 & Q2 답변용] SKU별 구성 및 시장 점유율 (Market Share) 파악
==================================================*/
disp "=== 1. SKU별 총 판매량(온스) 및 총 매출액 ==="
// 예전 코드와 동일하게 천단위 콤마 포맷으로 출력합니다.
tabstat oz_sold revenue, by(sku_id) stat(sum) format(%15.0fc)

disp "=== 2. SKU별 판매 건수 비중 ==="
// 전체 관측치 중 9개 카테고리가 얼마나 고르게 등장하는지 확인 (결측 패널이 적은지 체크)
tab sku_id


/*==================================================
  [Q3 답변용] 도구변수(IV) 타당성 및 마진율 분석
==================================================*/
disp "=== 3. 소매가(Price)와 도매가(Cost) 간의 상관관계 (IV Relevance) ==="
// 도구변수 타당성 검증 (상관계수가 1에 가깝고 p-value가 0이면 매우 훌륭한 IV)
pwcorr sku_price sku_cost, sig

disp "=== 4. SKU별 평균 소매가 및 도매가, 마진폭 확인 ==="
tabstat sku_price sku_cost, by(sku_id) stat(mean sd) format(%9.3f)


/*==================================================
  [Q4 답변용] 패널 데이터의 시계열 변동성(Variation) 확인
==================================================*/
disp "=== 5. 패널 변동성 분해 (Between vs. Within) ==="
// Fixed Effects 모형 식별을 위해 Within (점포 내 주차별) 변동성이 충분한지 확인
// 주의: 예전 데이터에서는 sku_price의 Max 값이 13.8까지 튀었지만, 
// 이번 Ultimate 버전에서는 극단치가 제거되어 훨씬 안정적인 범위 내에 있을 것입니다!
xtsum sku_price oz_sold
