-- 02_composite_index.sql

USE dba_portfolio_perf;

-- 0) 측정 환경 확인

SELECT @@innodb_buffer_pool_size / 1024 / 1024 AS buffer_pool_mb;

SELECT
    table_name,
    ROUND(data_length  / 1024 / 1024, 1) AS data_mb,
    ROUND(index_length / 1024 / 1024, 1) AS index_mb,
    table_rows
FROM information_schema.tables
WHERE table_schema = 'dba_portfolio_perf'
  AND table_name   = 'orders';

-- 1) 데이터 분포 확인
-- 인덱스 효과는 선택도에 좌우되므로 먼저 분포를 확인한다.

SELECT
    order_status,
    COUNT(*) AS cnt,
    ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM orders), 2) AS pct
FROM orders
GROUP BY order_status
ORDER BY cnt DESC;

-- 측정에 사용할 회원의 주문 건수
SELECT COUNT(*) AS member_1_total      FROM orders WHERE member_id = 1;

-- 그중 조건에 맞는 건수 
SELECT COUNT(*) AS member_1_delivered  FROM orders
WHERE member_id = 1 AND order_status = '배송완료';


-- 2) 현재 인덱스 확인

SHOW INDEX FROM orders;

-- 3) 1단계 : FK 자동 인덱스만 있는 상태

EXPLAIN
SELECT * FROM orders
WHERE member_id = 1 AND order_status = '배송완료';

-- 워밍업
EXPLAIN ANALYZE
SELECT * FROM orders
WHERE member_id = 1 AND order_status = '배송완료';

-- 기록용
EXPLAIN ANALYZE
SELECT * FROM orders
WHERE member_id = 1 AND order_status = '배송완료';


-- 4) 복합 인덱스 생성

CREATE INDEX idx_orders_member_status
    ON orders(member_id, order_status);

-- 통계 갱신
ANALYZE TABLE orders;

SHOW INDEX FROM orders;

-- 5) 2단계 : 복합 인덱스 적용 후

EXPLAIN
SELECT * FROM orders
WHERE member_id = 1 AND order_status = '배송완료';

-- 5회 측정하고 중앙값을 기록한다.
EXPLAIN ANALYZE
SELECT * FROM orders
WHERE member_id = 1 AND order_status = '배송완료';


-- 6) 3단계 : 커버링 인덱스

-- 인덱스를 새로 만들지 않는다. SELECT 목록만 바꾼다.
-- 인덱스에 들어있는 컬럼은 member_id, order_status, order_id 세 개다.
-- (order_id 는 PK이므로 세컨더리 인덱스 리프에 자동 포함된다)

EXPLAIN
SELECT order_id, member_id, order_status FROM orders
WHERE member_id = 1 AND order_status = '배송완료';

-- 5회 측정하고 중앙값을 기록한다.
EXPLAIN ANALYZE
SELECT order_id, member_id, order_status FROM orders
WHERE member_id = 1 AND order_status = '배송완료';


-- 7) 디스크 읽기 횟수 확인

-- 시간만 재면 "왜 느린지"를 알 수 없다.
-- 쿼리가 디스크까지 갔는지를 버퍼 풀 카운터로 확인한다.
--   Innodb_buffer_pool_read_requests : 페이지를 요청한 총 횟수
--   Innodb_buffer_pool_reads         : 그중 버퍼 풀에 없어서 디스크까지 간 횟수
-- 누적값이므로 쿼리 전후로 두 번 찍어 차이를 본다.

SHOW STATUS LIKE 'Innodb_buffer_pool_read%';

EXPLAIN ANALYZE
SELECT * FROM orders
WHERE member_id = 1 AND order_status = '배송완료';

SHOW STATUS LIKE 'Innodb_buffer_pool_read%';

-- 커버링 쿼리로 같은 측정
SHOW STATUS LIKE 'Innodb_buffer_pool_read%';

EXPLAIN ANALYZE
SELECT order_id, member_id, order_status FROM orders
WHERE member_id = 1 AND order_status = '배송완료';

SHOW STATUS LIKE 'Innodb_buffer_pool_read%';


-- 8) 인덱스의 비용 확인

-- stat_name = 'size' 는 그 인덱스가 차지한 페이지 수다.
-- 페이지 하나가 16KB이므로 * 16 / 1024 로 MB로 환산한다.
SELECT
    index_name,
    stat_value AS pages,
    ROUND(stat_value * 16 / 1024, 1) AS size_mb
FROM mysql.innodb_index_stats
WHERE database_name = 'dba_portfolio_perf'
  AND table_name    = 'orders'
  AND stat_name     = 'size';

-- 참고 : 이 인덱스는 삭제할 수 없다

-- 현재 orders 의 FK(member_id)를 받치는 인덱스가 이것뿐이므로
-- 아래 문장은 Error 1553 으로 거부된다.
--   Cannot drop index 'idx_orders_member_status':
--   needed in a foreign key constraint
--
-- DROP INDEX idx_orders_member_status ON orders;
