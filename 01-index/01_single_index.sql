-- 01_single_index.sql

USE dba_portfolio_perf;

-- 0) 측정 환경 확인

-- 실행시간은 환경에 종속되므로 측정값과 함께 기록해 둔다.
SELECT @@version                            AS mysql_version,
       @@innodb_buffer_pool_size/1024/1024  AS buffer_pool_mb;

-- 테이블 크기. 버퍼 풀 크기와 비교하기 위해 확인한다.
SELECT table_name,
       ROUND(data_length  / 1024 / 1024, 1) AS data_mb,
       ROUND(index_length / 1024 / 1024, 1) AS index_mb
FROM information_schema.tables
WHERE table_schema = 'dba_portfolio_perf'
  AND table_name   = 'member';

-- 1) 데이터 분포 확인

-- 인덱스의 효과는 조건이 전체 중 얼마를 걸러내는지에 달려 있다.
-- 측정 전에 분포를 확인해야 결과가 정상인지 판단할 수 있다.
SELECT COUNT(*)                                  AS total_rows,
       COUNT(DISTINCT member_name)               AS distinct_names,
       COUNT(*) / COUNT(DISTINCT member_name)    AS rows_per_name
FROM member;

-- 평균만 보면 치우침을 놓친다. 실제 분포를 확인하고 측정 대상을 고른다.
SELECT member_name, COUNT(*) AS cnt
FROM member
GROUP BY member_name
ORDER BY cnt DESC
LIMIT 5;

-- 측정에 사용할 값의 정확한 건수
SELECT COUNT(*) AS matching_rows
FROM member
WHERE member_name = '김민준';

-- 2) 현재 인덱스 확인

-- 측정 전 상태 확인. 이 단계를 건너뛰면 이미 존재하는 인덱스 때문에
-- "인덱스 전" 값을 "인덱스 후" 값으로 잘못 기록할 수 있다.

SHOW INDEX FROM member;

-- 3) 인덱스 삭제 — "인덱스 전" 상태로 만들기

DROP INDEX idx_member_name ON member;

-- 4) 인덱스 없는 상태 측정

-- 실행계획: type, key, key_len, rows, filtered, Extra 를 기록한다.
EXPLAIN
SELECT * FROM member WHERE member_name = '김민준';

-- 실제 측정 1회차 (워밍업)
EXPLAIN ANALYZE
SELECT * FROM member WHERE member_name = '김민준';

-- 실제 측정 2회차 (기록값)
EXPLAIN ANALYZE
SELECT * FROM member WHERE member_name = '김민준';

-- 5) 인덱스 생성

CREATE INDEX idx_member_name ON member(member_name);
ANALYZE TABLE member;

-- 6) 인덱스 있는 상태 측정

EXPLAIN
SELECT * FROM member WHERE member_name = '김민준';

-- 실제 측정 1회차 (워밍업)
EXPLAIN ANALYZE
SELECT * FROM member WHERE member_name = '김민준';

-- 실제 측정 2회차 (기록값)
EXPLAIN ANALYZE
SELECT * FROM member WHERE member_name = '김민준';

-- 7) 인덱스의 저장 비용

-- 인덱스별 페이지 수를 조회한다. 페이지 1개는 16KB 이다.
-- PRIMARY 는 데이터 본체다. InnoDB 는 PK 순서로 데이터를 저장한다.
SELECT index_name,
       stat_value                        AS pages,
       ROUND(stat_value * 16 / 1024, 1)  AS size_mb
FROM mysql.innodb_index_stats
WHERE database_name = 'dba_portfolio_perf'
  AND table_name    = 'member'
  AND stat_name     = 'size';
