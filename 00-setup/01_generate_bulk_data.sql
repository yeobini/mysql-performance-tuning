-- =====================================================================
-- 01_generate_bulk_data.sql
-- 성능 측정을 위한 대용량 테스트 데이터 생성
-- =====================================================================
-- 목적
--   수십 건 규모의 데이터에서는 옵티마이저가 인덱스를 사용하지 않거나,
--   사용하더라도 실행시간 차이가 측정되지 않는다.
--   인덱스의 효과를 실제 실행시간으로 측정하기 위해 백만 건 규모의
--   테스트 데이터를 생성한다.
--
-- 생성 규모
--   member      1,000,000
--   category           20
--   product        50,000
--   orders      2,000,000
--   orderitem   4,000,000
--   payment     1,200,000
--   delivery    1,000,000
--   review        500,000
--
-- 주의
--   - 약 2GB 내외의 디스크를 사용한다.
--   - 03-SQL/create_tables.sql 로 테이블을 먼저 생성한 상태여야 한다.
--   - 기존 데이터는 모두 삭제된다.
-- =====================================================================

USE dba_portfolio_perf;

-- ---------------------------------------------------------------------
-- 0. 적재 성능을 위한 세션 설정
-- ---------------------------------------------------------------------
-- 대량 적재 중에는 외래키/유니크 검사를 끄고, 트랜잭션 커밋 주기를 늘려
-- 적재 시간을 단축한다. 적재 완료 후 반드시 원복한다.
SET SESSION foreign_key_checks = 0;
SET SESSION unique_checks      = 0;
SET SESSION sql_log_bin        = 0;

-- 재귀 CTE 기본 깊이 제한은 1000이므로 상향한다.
SET SESSION cte_max_recursion_depth = 10000000;

-- ---------------------------------------------------------------------
-- 1. 기존 데이터 삭제
-- ---------------------------------------------------------------------
-- 자식 테이블부터 삭제한다. TRUNCATE는 AUTO_INCREMENT도 초기화한다.
TRUNCATE TABLE review;
TRUNCATE TABLE delivery;
TRUNCATE TABLE payment;
TRUNCATE TABLE orderitem;
TRUNCATE TABLE orders;
TRUNCATE TABLE product;
TRUNCATE TABLE category;
TRUNCATE TABLE member;

-- ---------------------------------------------------------------------
-- 2. 숫자 생성용 보조 테이블
-- ---------------------------------------------------------------------
-- 재귀 CTE를 매번 실행하는 대신, 1 ~ 4,000,000 의 연속된 숫자를 담은
-- 보조 테이블을 한 번만 만들어 두고 이후 INSERT ... SELECT 에 재사용한다.
DROP TABLE IF EXISTS seq;
CREATE TABLE seq (
    n BIGINT NOT NULL PRIMARY KEY
) ENGINE = InnoDB;

INSERT INTO seq (n)
WITH RECURSIVE gen AS (
    SELECT 1 AS n
    UNION ALL
    SELECT n + 1 FROM gen WHERE n < 4000000
)
SELECT n FROM gen;

-- ---------------------------------------------------------------------
-- 3. category (20건)
-- ---------------------------------------------------------------------
INSERT INTO category (category_id, category_name)
SELECT
    n,
    CONCAT('카테고리', LPAD(n, 2, '0'))
FROM seq
WHERE n <= 20;

-- ---------------------------------------------------------------------
-- 4. member (1,000,000건)
-- ---------------------------------------------------------------------
-- member_name 은 실제 서비스처럼 중복이 발생하도록 생성한다.
--   성 20종 x 이름 500종 = 10,000종의 이름이 100만 건에 분포
--   -> 이름 하나당 평균 100건. 인덱스 유무에 따른 차이를 측정하기에 적합하다.
--
-- password 는 bcrypt 해시 형태의 더미 문자열을 넣는다.
-- 테스트 데이터라도 평문 비밀번호를 저장하지 않는다.
INSERT INTO member (member_id, email, password, member_name, phone, created_at, updated_at)
SELECT
    n,
    CONCAT('user', n, '@example.com'),
    CONCAT('$2b$12$', LPAD(MD5(n), 22, '0'), SUBSTRING(SHA2(n, 256), 1, 31)),
    CONCAT(
        ELT(1 + (n % 20),
            '김','이','박','최','정','강','조','윤','장','임',
            '한','오','서','신','권','황','안','송','전','홍'),
        ELT(1 + (FLOOR(n / 20) % 500) % 10,
            '민','서','지','현','준','예','수','하','유','도'),
        ELT(1 + (FLOOR(n / 200) % 10),
            '준','우','윤','아','은','진','호','연','빈','혁')
    ),
    CONCAT('010-', LPAD(n % 10000, 4, '0'), '-', LPAD((n * 7) % 10000, 4, '0')),
    -- 가입일을 2024-01-01 ~ 2025-12-31 사이로 분산한다.
    TIMESTAMPADD(SECOND, (n * 63) % 63072000, '2024-01-01 00:00:00'),
    TIMESTAMPADD(SECOND, (n * 63) % 63072000, '2024-01-01 00:00:00')
FROM seq
WHERE n <= 1000000;

-- ---------------------------------------------------------------------
-- 5. product (50,000건)
-- ---------------------------------------------------------------------
-- LIKE 패턴 검색 실습을 위해 상품명 접두어를 의도적으로 분산한다.
--   'Pro...'   로 시작하는 상품  : 전체의 1/5
--   '...Pro...' 중간에 Pro 포함  : 전체의 1/5
--   나머지는 Pro 를 포함하지 않는다.
INSERT INTO product (product_id, category_id, product_name, price, stock, description, created_at, updated_at)
SELECT
    n,
    1 + (n % 20),
    CASE n % 5
        WHEN 0 THEN CONCAT('Pro Display ', n)          -- Pro 로 시작
        WHEN 1 THEN CONCAT('Ultra Pro Mouse ', n)      -- Pro 를 중간에 포함
        WHEN 2 THEN CONCAT('Galaxy Book ', n)
        WHEN 3 THEN CONCAT('ThinkPad ', n)
        ELSE            CONCAT('Magic Keyboard ', n)
    END,
    10000 + (n * 137) % 2990000,
    (n * 31) % 500,
    CONCAT('테스트 상품 설명 ', n),
    TIMESTAMPADD(SECOND, (n * 1261) % 63072000, '2024-01-01 00:00:00'),
    TIMESTAMPADD(SECOND, (n * 1261) % 63072000, '2024-01-01 00:00:00')
FROM seq
WHERE n <= 50000;

-- ---------------------------------------------------------------------
-- 6. orders (2,000,000건)
-- ---------------------------------------------------------------------
-- 실제 쇼핑몰처럼 일부 회원에게 주문이 집중되도록 설계한다.
--   - 전체 회원 1,000,000명 중 주문 이력이 있는 회원은 약 300,000명
--   - 나머지 700,000명은 주문 이력이 없다 (LEFT JOIN 실습용)
--   - 주문이 많은 상위 회원은 수십 건의 주문을 가진다
--
-- order_status 는 실제 운영처럼 편중되게 분포시킨다.
--   배송완료 70% / 배송중 15% / 결제완료 10% / 주문완료 4% / 취소 1%
--   -> 선택도(selectivity)가 다른 값들이 섞여 있어야
--      복합 인덱스와 옵티마이저 동작을 제대로 관찰할 수 있다.
INSERT INTO orders (order_id, member_id, order_date, total_price, order_status)
SELECT
    n,
    -- 제곱 분포를 이용해 상위 회원에게 주문을 집중시킨다.
    1 + FLOOR(POW(RAND(n), 2) * 300000),
    TIMESTAMPADD(SECOND, (n * 31) % 63072000, '2024-01-01 00:00:00'),
    10000 + (n * 379) % 4990000,
    CASE
        WHEN n % 100 <  70 THEN '배송완료'
        WHEN n % 100 <  85 THEN '배송중'
        WHEN n % 100 <  95 THEN '결제완료'
        WHEN n % 100 <  99 THEN '주문완료'
        ELSE                    '취소'
    END
FROM seq
WHERE n <= 2000000;

-- ---------------------------------------------------------------------
-- 7. orderitem (4,000,000건)
-- ---------------------------------------------------------------------
-- 주문 1건당 평균 2개의 상품이 포함되도록 생성한다.
INSERT INTO orderitem (order_item_id, order_id, product_id, quantity, order_price)
SELECT
    n,
    1 + ((n - 1) DIV 2),            -- 주문 1건당 2행
    1 + (n * 17) % 50000,
    1 + (n % 5),
    10000 + (n * 137) % 2990000
FROM seq
WHERE n <= 4000000;

-- ---------------------------------------------------------------------
-- 8. payment (1,200,000건)
-- ---------------------------------------------------------------------
-- 결제가 완료된 주문에 대해서만 결제 정보를 생성한다.
-- order_id 에 UNIQUE 제약이 있으므로 주문당 1건만 생성한다.
INSERT INTO payment (payment_id, order_id, payment_method, payment_amount, payment_status, payment_date)
SELECT
    n,
    n,
    ELT(1 + (n % 4), '카드', '계좌이체', '간편결제', '무통장입금'),
    10000 + (n * 379) % 4990000,
    '결제완료',
    TIMESTAMPADD(SECOND, (n * 31) % 63072000, '2024-01-01 00:00:10')
FROM seq
WHERE n <= 1200000;

-- ---------------------------------------------------------------------
-- 9. delivery (1,000,000건)
-- ---------------------------------------------------------------------
INSERT INTO delivery (delivery_id, order_id, recipient_name, recipient_phone, address, delivery_status, shipped_at, delivered_at)
SELECT
    n,
    n,
    CONCAT('수령인', n),
    CONCAT('010-', LPAD(n % 10000, 4, '0'), '-', LPAD((n * 3) % 10000, 4, '0')),
    CONCAT('서울시 테스트구 테스트로 ', n, '길 ', 1 + (n % 100)),
    '배송완료',
    TIMESTAMPADD(SECOND, (n * 31) % 63072000, '2024-01-02 00:00:00'),
    TIMESTAMPADD(SECOND, (n * 31) % 63072000, '2024-01-04 00:00:00')
FROM seq
WHERE n <= 1000000;

-- ---------------------------------------------------------------------
-- 10. review (500,000건)
-- ---------------------------------------------------------------------
-- order_item_id 에 UNIQUE 제약이 있으므로 주문 상품당 1건만 생성한다.
INSERT INTO review (review_id, member_id, order_item_id, rating, content, created_at)
SELECT
    n,
    1 + FLOOR(POW(RAND(n + 1), 2) * 300000),
    n,
    1 + (n % 5),
    CONCAT('테스트 리뷰 내용 ', n),
    TIMESTAMPADD(SECOND, (n * 31) % 63072000, '2024-01-10 00:00:00')
FROM seq
WHERE n <= 500000;

-- ---------------------------------------------------------------------
-- 11. 세션 설정 원복
-- ---------------------------------------------------------------------
SET SESSION foreign_key_checks = 1;
SET SESSION unique_checks      = 1;
SET SESSION sql_log_bin        = 1;

-- ---------------------------------------------------------------------
-- 12. 통계 정보 갱신
-- ---------------------------------------------------------------------
-- 대량 적재 직후에는 옵티마이저 통계가 실제 데이터 분포와 다를 수 있다.
-- 통계가 부정확하면 인덱스가 있어도 옵티마이저가 선택하지 않을 수 있으므로
-- 성능 측정 전에 반드시 통계를 갱신한다.
ANALYZE TABLE member, category, product, orders, orderitem, payment, delivery, review;

-- ---------------------------------------------------------------------
-- 13. 적재 결과 확인
-- ---------------------------------------------------------------------
SELECT 'member'    AS table_name, COUNT(*) AS row_count FROM member
UNION ALL SELECT 'category',  COUNT(*) FROM category
UNION ALL SELECT 'product',   COUNT(*) FROM product
UNION ALL SELECT 'orders',    COUNT(*) FROM orders
UNION ALL SELECT 'orderitem', COUNT(*) FROM orderitem
UNION ALL SELECT 'payment',   COUNT(*) FROM payment
UNION ALL SELECT 'delivery',  COUNT(*) FROM delivery
UNION ALL SELECT 'review',    COUNT(*) FROM review;

-- ---------------------------------------------------------------------
-- 14. 보조 테이블 정리
-- ---------------------------------------------------------------------
-- seq 테이블은 데이터 생성 용도로만 쓰이므로 삭제한다. (약 110MB 회수)
-- 데이터를 다시 생성할 때 이 스크립트가 재생성한다.
DROP TABLE IF EXISTS seq;
