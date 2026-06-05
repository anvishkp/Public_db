-- ================================
-- PERFORMANCE MONITOR PTQ
-- =================================
select
SQL_ID,EXECUTIONS,OPTIMIZER_MODE,HASH_VALUE, OLD_HASH_VALUE, PLAN_HASH_VALUE, FULL_PLAN_HASH_VALUE,MODULE,CPU_TIME,ELAPSED_TIME,SQL_TEXT
from v$sql where sql_text like 'UPDATE%' and PARSING_SCHEMA_NAME='ABFCUBSLIVE'

-- ================================
--  PTQ
-- =================================
SELECT inst_id, name, value
FROM gv$sysstat
WHERE name IN ('db block gets', 'consistent gets', 'physical reads', 'consistent gets - examination', 'physical reads direct', 'physical reads direct (lob)');

--Shared Pool Usage:
SELECT inst_id, name, bytes
FROM gv$sgastat
WHERE pool = 'shared pool';

--PGA Usage:
SELECT inst_id, name, value
FROM gv$pgastat;

--Redo Log Usage
SELECT inst_id, thread#, group#, member, bytes
FROM gv$log;

--Database Parameters:
SELECT inst_id, name, value
FROM gv$parameter;

-- Generate an AWR report for a specific time range
SELECT dbid, instance_number, begin_interval_time, end_interval_time
FROM dba_hist_snapshot
WHERE begin_interval_time BETWEEN TO_DATE('start_time', 'YYYY-MM-DD HH24:MI:SS') AND TO_DATE('end_time', 'YYYY-MM-DD HH24:MI:SS');

-- Gather database statistics
EXEC DBMS_STATS.GATHER_DATABASE_STATS();


-- Check the size of tables and indexes
SELECT owner, table_name, segment_type, bytes
FROM dba_segments
ORDER BY bytes DESC;


-- Check index fragmentation
SELECT owner, index_name, blevel, leaf_blocks, distinct_keys, clustering_factor,NUM_ROWS, (NUM_ROWS-clustering_factor) diff
FROM dba_indexes
WHERE owner = 'ABFCUBSLIVE'  AND table_name = 'ACZB_HISTORY';

ANALYZE INDEX &index_name VALIDATE STRUCTURE;

SELECT lf_rows, lf_blks, lf_blks_len, br_rows, br_blks, br_blks_len, del_lf_rows, distinct_keys
FROM V$INDEX_STATS;


SELECT owner, index_name, blevel, leaf_blocks, distinct_keys, clustering_factor
FROM dba_indexes
WHERE owner = 'FCUBSLIVE'
  AND table_name = 'ACTB_HISTORY';
  ;

BEGIN
   DBMS_STATS.GATHER_INDEX_STATS('FCUBSLIVE', 'ACTB_HISTORY');
END;

--
-- auto trace 
select name, value from v$sysstat where name = 'physical reads'
set autotrace traceonly statistics;
select count(*) from all_objects;
set autotrace off
--this one shows SQL that is currently "ACTIVE":-
select S.USERNAME, s.sid, s.osuser, t.sql_id, sql_text
from v$sqltext_with_newlines t,V$SESSION s
where t.address =s.sql_address
and t.hash_value = s.sql_hash_value
and s.status = 'ACTIVE'
and s.username <> 'SYSTEM'
order by s.sid,t.piece
/


--This shows locks. Sometimes things are going slow, but it's because it is blocked waiting for a lock:
select
  object_name, 
  object_type, 
  session_id, 
  type,         -- Type or system/user lock
  lmode,        -- lock mode in which session holds lock
  request, 
  block, 
  ctime         -- Time since current mode was granted
from
  gv$locked_object, all_objects, gv$lock
where
  gv$locked_object.object_id = all_objects.object_id AND
  gv$lock.id1 = all_objects.object_id AND
  gv$lock.sid = gv$locked_object.session_id
order by
  session_id, ctime desc, object_name
/
--This is a good one for finding long operations (e.g. full table scans). If it is because of lots of short operations, nothing will show up.
COLUMN percent FORMAT 999.99 

SELECT inst_id,sid, to_char(start_time,'hh24:mi:ss') stime, 
message,( sofar/totalwork)* 100 percent 
FROM gv$session_longops
WHERE sofar/totalwork < 1
/


-- Check table fragmentation
DECLARE
   total_blocks           NUMBER;
   total_bytes            NUMBER;
   unused_blocks          NUMBER;
   unused_bytes           NUMBER;
   last_used_extent_file_id  NUMBER;
   last_used_extent_block_id NUMBER;
   last_used_block         NUMBER;
BEGIN
   DBMS_SPACE.UNUSED_SPACE(
      segment_owner     => 'FCUBSLIVE',  -- Replace with your schema name
      segment_name      => 'ACTB_HISTORY',   -- Replace with your table name
      segment_type      => 'TABLE',
      total_blocks      => total_blocks,
      total_bytes       => total_bytes,
      unused_blocks     => unused_blocks,
      unused_bytes      => unused_bytes,
      last_used_extent_file_id  => last_used_extent_file_id,
      last_used_extent_block_id => last_used_extent_block_id,
      last_used_block   => last_used_block
   );

   DBMS_OUTPUT.PUT_LINE('Total Blocks: ' || total_blocks);
   DBMS_OUTPUT.PUT_LINE('Total Bytes: ' || total_bytes);
   DBMS_OUTPUT.PUT_LINE('Unused Blocks: ' || unused_blocks);
   DBMS_OUTPUT.PUT_LINE('Unused Bytes: ' || unused_bytes);
   DBMS_OUTPUT.PUT_LINE('Last Used Extent File ID: ' || last_used_extent_file_id);
   DBMS_OUTPUT.PUT_LINE('Last Used Extent Block ID: ' || last_used_extent_block_id);
   DBMS_OUTPUT.PUT_LINE('Last Used Block: ' || last_used_block);
END;
/

-- from deepseek
SELECT 
    s.segment_name AS object_name,
    s.segment_type AS object_type,
    ROUND(100 * (1 - (NVL(fs.bytes, 0) / NVL(s.bytes, 1))), 2) AS "fragmentation%",
    s.tablespace_name AS tablespace,
    ROUND(s.bytes / 1024 / 1024 / 1024, 2) AS size_gb
FROM 
    dba_segments s
LEFT JOIN 
    (SELECT 
         tablespace_name, 
         file_id, 
         SUM(bytes) AS bytes
     FROM 
         dba_free_space
     GROUP BY 
         tablespace_name, file_id) fs
ON 
    s.tablespace_name = fs.tablespace_name
    AND s.header_file = fs.file_id
WHERE 
    s.owner = UPPER('&schema_name')
    AND ROUND(100 * (1 - (NVL(fs.bytes, 0) / NVL(s.bytes, 1))), 2) >= 20 -- Exclude fragmentation < 20%
ORDER BY 
    size_gb DESC;




--- FOR PARTITIONED TABLE FRAGMENTATION
SET SERVEROUTPUT ON
DECLARE
   CURSOR partitions IS
      SELECT partition_name
      FROM all_tab_partitions
      WHERE table_name = 'ACTB_HISTORY'
      AND table_owner = 'FCUBSLIVE';
   
   total_blocks           NUMBER;
   total_bytes            NUMBER;
   unused_blocks          NUMBER;
   unused_bytes           NUMBER;
   last_used_extent_file_id  NUMBER;
   last_used_extent_block_id NUMBER;
   last_used_block         NUMBER;
BEGIN
   FOR part IN partitions LOOP
      DBMS_SPACE.UNUSED_SPACE(
         segment_owner     => 'FCUBSLIVE',
         segment_name      => 'ACTB_HISTORY',
         partition_name    => part.partition_name,
         segment_type      => 'TABLE PARTITION',
         total_blocks      => total_blocks,
         total_bytes       => total_bytes,
         unused_blocks     => unused_blocks,
         unused_bytes      => unused_bytes,
         last_used_extent_file_id  => last_used_extent_file_id,
         last_used_extent_block_id => last_used_extent_block_id,
         last_used_block   => last_used_block
      );
      
      DBMS_OUTPUT.PUT_LINE('Partition: ' || part.partition_name);
      DBMS_OUTPUT.PUT_LINE('Total Blocks: ' || total_blocks);
      DBMS_OUTPUT.PUT_LINE('Total Bytes: ' || total_bytes);
      DBMS_OUTPUT.PUT_LINE('Unused Blocks: ' || unused_blocks);
      DBMS_OUTPUT.PUT_LINE('Unused Bytes: ' || unused_bytes);
      DBMS_OUTPUT.PUT_LINE('Last Used Extent File ID: ' || last_used_extent_file_id);
      DBMS_OUTPUT.PUT_LINE('Last Used Extent Block ID: ' || last_used_extent_block_id);
      DBMS_OUTPUT.PUT_LINE('Last Used Block: ' || last_used_block);
      DBMS_OUTPUT.PUT_LINE('---------------------------');
   END LOOP;
END;
/





-- Check the status of database backups
SELECT * FROM v$rman_backup_job_details;

-- Chek the index helth 
-- ----------------------
-- of clustring factor is higher than the block , then the chance of going full table scan is high

select i.index_name, i.leaf_blocks,i.blevel,i.distinct_keys,
       i.num_rows,i.clustering_factor,t.blocks,
      i.last_analyzed
from user_indexes i ,
     user_tables t
where t.table_name = i.table_name
and t.table_name ='ACTB_HISTORY'
;


-- ================================
-- TO convert to range - interval partition
-- =================================

 ALTER TABLE IFTB_DRCRTAX_HOFF_DTL_EXTGBL MODIFY PARTITION BY RANGE (DTL_HOFF_DATE) INTERVAL (NUMTODSINTERVAL(1, 'DAY')) STORE IN (DATA) 
 ( PARTITION Initial_part VALUES LESS THAN (TO_DATE('2023-01-01', 'YYYY-MM-DD')) tablespace DATA )online ;



 ALTER TABLE IFTB_DRCRTAX_HOFF_DTL_EXTGBL MODIFY PARTITION BY RANGE (DTL_HOFF_DATE) INTERVAL (NUMTODSINTERVAL(1, 'DAY')) STORE IN (DATA) 
 ( PARTITION Initial_part VALUES LESS THAN (TO_DATE('2023-01-01', 'YYYY-MM-DD')) tablespace DATA ) parallel 8 ;
 ----? BELOW IS THE TEST CONDUCTED --

-- create table - random
CREATE TABLE IFTB_DRCRTAX_HOFF_DTL_EXTGBL
(
    transaction_id   NUMBER(10) PRIMARY KEY,
    customer_id      NUMBER(10),
    transaction_date DATE,
    amount          NUMBER(15, 2),
    status          VARCHAR2(20),
    description     VARCHAR2(200),
    created_by      VARCHAR2(50),
    created_date    DATE,
    updated_by      VARCHAR2(50),
    updated_date    DATE,
    tax_amount      NUMBER(15, 2),
    discount_amount NUMBER(15, 2),
    payment_method  VARCHAR2(50),
    dtl_hoff_date   DATE
);

-- fill the table -- random
DECLARE
    -- Variables
    v_transaction_id   NUMBER;
    v_customer_id      NUMBER;
    v_transaction_date DATE;
    v_amount          NUMBER(15, 2);
    v_status          VARCHAR2(20);
    v_description     VARCHAR2(200);
    v_created_by      VARCHAR2(50);
    v_created_date    DATE;
    v_updated_by      VARCHAR2(50);
    v_updated_date    DATE;
    v_tax_amount      NUMBER(15, 2);
    v_discount_amount NUMBER(15, 2);
    v_payment_method  VARCHAR2(50);
    v_dtl_hoff_date   DATE;

    -- Array of 10 distinct dates
    TYPE date_array IS TABLE OF DATE;
    v_dates date_array := date_array(
        TO_DATE('2023-01-01', 'YYYY-MM-DD'),
        TO_DATE('2023-02-01', 'YYYY-MM-DD'),
        TO_DATE('2023-03-01', 'YYYY-MM-DD'),
        TO_DATE('2023-04-01', 'YYYY-MM-DD'),
        TO_DATE('2023-05-01', 'YYYY-MM-DD'),
        TO_DATE('2023-06-01', 'YYYY-MM-DD'),
        TO_DATE('2023-07-01', 'YYYY-MM-DD'),
        TO_DATE('2023-08-01', 'YYYY-MM-DD'),
        TO_DATE('2023-09-01', 'YYYY-MM-DD'),
        TO_DATE('2023-10-01', 'YYYY-MM-DD')
    );
BEGIN
    -- Loop to insert 10,000 rows
    FOR i IN 1..10000 LOOP
        -- Generate random values
        v_transaction_id   := i; -- Sequential transaction ID
        v_customer_id      := FLOOR(DBMS_RANDOM.VALUE(1, 1000)); -- Random customer ID between 1 and 1000
        v_transaction_date := SYSDATE - FLOOR(DBMS_RANDOM.VALUE(1, 365)); -- Random transaction date within the last year
        v_amount          := ROUND(DBMS_RANDOM.VALUE(10, 10000), 2); -- Random amount between 10 and 10,000
        v_status          := CASE FLOOR(DBMS_RANDOM.VALUE(1, 4)) -- Random status
                                WHEN 1 THEN 'Pending'
                                WHEN 2 THEN 'Completed'
                                WHEN 3 THEN 'Cancelled'
                                ELSE 'Failed'
                             END;
        v_description     := 'Transaction ' || i || ' for customer ' || v_customer_id;
        v_created_by      := 'USER' || FLOOR(DBMS_RANDOM.VALUE(1, 100)); -- Random user
        v_created_date    := SYSDATE - FLOOR(DBMS_RANDOM.VALUE(1, 365)); -- Random creation date within the last year
        v_updated_by      := 'USER' || FLOOR(DBMS_RANDOM.VALUE(1, 100)); -- Random user
        v_updated_date    := SYSDATE - FLOOR(DBMS_RANDOM.VALUE(1, 365)); -- Random update date within the last year
        v_tax_amount      := ROUND(v_amount * 0.1, 2); -- 10% of the amount
        v_discount_amount := ROUND(v_amount * 0.05, 2); -- 5% of the amount
        v_payment_method  := CASE FLOOR(DBMS_RANDOM.VALUE(1, 4)) -- Random payment method
                                WHEN 1 THEN 'Credit Card'
                                WHEN 2 THEN 'Debit Card'
                                WHEN 3 THEN 'Net Banking'
                                ELSE 'Cash'
                             END;
        v_dtl_hoff_date   := v_dates(MOD(i, 10) + 1); -- Distribute rows evenly across 10 dates

        -- Insert the row
        INSERT INTO iftb_drcrtax_hoff_dtl_extgbl
        VALUES (
            v_transaction_id,
            v_customer_id,
            v_transaction_date,
            v_amount,
            v_status,
            v_description,
            v_created_by,
            v_created_date,
            v_updated_by,
            v_updated_date,
            v_tax_amount,
            v_discount_amount,
            v_payment_method,
            v_dtl_hoff_date
        );
    END LOOP;

    -- Commit the transaction
    COMMIT;
END;
/
-- drop it , ust incase
--drop table iftb_drcrtax_hoff_dtl_extgbl

    lv_sql := ' ALTER TABLE ' || i.table_name ||
              ' MODIFY PARTITION BY RANGE (' || i.partition_column || ')' ||
              ' INTERVAL (NUMTOYMINTERVAL(3, ''MONTH''))' || ' STORE IN (' ||
              i.table_tablespace ||
              ')( PARTITION P1 VALUES LESS THAN(''01-DEC-2022'') tablespace ' ||
              i.table_tablespace || ' ) ONLINE';

-- CONVERT
 ALTER TABLE IFTB_DRCRTAX_HOFF_DTL_EXTGBL MODIFY PARTITION BY RANGE (DTL_HOFF_DATE) INTERVAL (NUMTODSINTERVAL(1, 'DAY')) STORE IN (DATA) 
 ( PARTITION Initial_part VALUES LESS THAN (TO_DATE('2023-01-01', 'YYYY-MM-DD')) tablespace DATA )online ;
-- GATHER


BEGIN  
    DBMS_STATS.GATHER_TABLE_STATS(  
        ownname => 'ADMIN',  
        tabname => 'IFTB_DRCRTAX_HOFF_DTL_EXTGBL',  
        estimate_percent => 100,  
        method_opt => 'FOR ALL COLUMNS SIZE AUTO',  
        cascade => TRUE,  
        granularity => 'PARTITION'  
    );  
END;  
/

----
SELECT partition_name, high_value
FROM user_tab_partitions
WHERE table_name = 'IFTB_DRCRTAX_HOFF_DTL_EXTGBL'
ORDER BY partition_name;

-- INITIAL_PART	0
-- SYS_P3649	1000
-- SYS_P3650	1000
-- SYS_P3651	1000
-- SYS_P3652	1000
-- SYS_P3653	1000
-- SYS_P3654	1000
-- SYS_P3655	1000
-- SYS_P3656	1000
-- SYS_P3657	1000
-- SYS_P3658	1000

-- NOW ADD FOR SOME NEWDATES USING ABOVE LOOP
DECLARE
    -- Variables
    v_transaction_id   NUMBER;
    v_customer_id      NUMBER;
    v_transaction_date DATE;
    v_amount          NUMBER(15, 2);
    v_status          VARCHAR2(20);
    v_description     VARCHAR2(200);
    v_created_by      VARCHAR2(50);
    v_created_date    DATE;
    v_updated_by      VARCHAR2(50);
    v_updated_date    DATE;
    v_tax_amount      NUMBER(15, 2);
    v_discount_amount NUMBER(15, 2);
    v_payment_method  VARCHAR2(50);
    v_dtl_hoff_date   DATE;

    -- Array of 10 new distinct dates
    TYPE date_array IS TABLE OF DATE;
    v_dates date_array := date_array(
        TO_DATE('2023-11-01', 'YYYY-MM-DD'),
        TO_DATE('2023-12-01', 'YYYY-MM-DD'),
        TO_DATE('2024-01-01', 'YYYY-MM-DD'),
        TO_DATE('2024-02-01', 'YYYY-MM-DD'),
        TO_DATE('2024-03-01', 'YYYY-MM-DD'),
        TO_DATE('2024-04-01', 'YYYY-MM-DD'),
        TO_DATE('2024-05-01', 'YYYY-MM-DD'),
        TO_DATE('2024-06-01', 'YYYY-MM-DD'),
        TO_DATE('2024-07-01', 'YYYY-MM-DD'),
        TO_DATE('2024-08-01', 'YYYY-MM-DD')
    );

    -- Variable to store the next transaction ID
    v_next_transaction_id NUMBER;
BEGIN
    -- Get the maximum transaction_id from the table and set the next starting point
    SELECT NVL(MAX(transaction_id), 0) + 1
    INTO v_next_transaction_id
    FROM iftb_drcrtax_hoff_dtl_extgbl;

    -- Loop to insert 10,000 rows
    FOR i IN 1..10000 LOOP
        -- Generate random values
        v_transaction_id   := v_next_transaction_id + i - 1; -- Ensure unique transaction_id
        v_customer_id      := FLOOR(DBMS_RANDOM.VALUE(1, 1000)); -- Random customer ID between 1 and 1000
        v_transaction_date := SYSDATE - FLOOR(DBMS_RANDOM.VALUE(1, 365)); -- Random transaction date within the last year
        v_amount          := ROUND(DBMS_RANDOM.VALUE(10, 10000), 2); -- Random amount between 10 and 10,000
        v_status          := CASE FLOOR(DBMS_RANDOM.VALUE(1, 4)) -- Random status
                                WHEN 1 THEN 'Pending'
                                WHEN 2 THEN 'Completed'
                                WHEN 3 THEN 'Cancelled'
                                ELSE 'Failed'
                             END;
        v_description     := 'Transaction ' || v_transaction_id || ' for customer ' || v_customer_id;
        v_created_by      := 'USER' || FLOOR(DBMS_RANDOM.VALUE(1, 100)); -- Random user
        v_created_date    := SYSDATE - FLOOR(DBMS_RANDOM.VALUE(1, 365)); -- Random creation date within the last year
        v_updated_by      := 'USER' || FLOOR(DBMS_RANDOM.VALUE(1, 100)); -- Random user
        v_updated_date    := SYSDATE - FLOOR(DBMS_RANDOM.VALUE(1, 365)); -- Random update date within the last year
        v_tax_amount      := ROUND(v_amount * 0.1, 2); -- 10% of the amount
        v_discount_amount := ROUND(v_amount * 0.05, 2); -- 5% of the amount
        v_payment_method  := CASE FLOOR(DBMS_RANDOM.VALUE(1, 4)) -- Random payment method
                                WHEN 1 THEN 'Credit Card'
                                WHEN 2 THEN 'Debit Card'
                                WHEN 3 THEN 'Net Banking'
                                ELSE 'Cash'
                             END;
        v_dtl_hoff_date   := v_dates(MOD(i, 10) + 1); -- Distribute rows evenly across 10 new dates

        -- Insert the row
        INSERT INTO iftb_drcrtax_hoff_dtl_extgbl
        VALUES (
            v_transaction_id,
            v_customer_id,
            v_transaction_date,
            v_amount,
            v_status,
            v_description,
            v_created_by,
            v_created_date,
            v_updated_by,
            v_updated_date,
            v_tax_amount,
            v_discount_amount,
            v_payment_method,
            v_dtl_hoff_date
        );
    END LOOP;

    -- Commit the transaction
    COMMIT;
END;
/

-- =========================================================
-- Index requiremetns and analysis
-- =========================================================
--? in oracle database , how much distinct value against total rows is qualified for index creation
-- A common rule of thumb is that if the number of distinct values is less than 1-5% of the total number of rows
-- Other Factors to Consider: 
-- Query Patterns: If the column is frequently used in WHERE, JOIN, or ORDER BY clauses, it may still benefit from an index, even with lower selectivity.
-- Data Skew: If the data is heavily skewed (e.g., one value appears in 90% of the rows), an index may not be helpful for queries targeting that value.
-- Table Size: For very small tables, indexes may not provide significant performance benefits and could even add overhead.
-- Index Maintenance Overhead: Indexes incur maintenance costs during INSERT, UPDATE, and DELETE operations. Ensure the benefits outweigh the costs.

--? from awr , how can we reach a conculstion to create , remove or modify an index
-- 1. Identify High-Load SQL Statements
-- Use the AWR SQL Report to identify SQL statements with high resource consumption (e.g., high CPU, I/O, or elapsed time).
-- Look for SQL statements that perform full table scans (FTS) or have high buffer gets, which could indicate missing or inefficient indexes.
-- Steps:
-- Run the AWR SQL report for the desired time period:
@$ORACLE_HOME/rdbms/admin/awrsqrpt.sql
-- Analyze the top SQL statements by:
-- Buffer Gets: High buffer gets may indicate inefficient access paths.
-- Disk Reads: High disk reads may suggest missing indexes.
-- Execution Plans: Check for full table scans or inefficient index usage.
-- or from sql as below 
--  - Replace &start_snap_id and &end_snap_id with the appropriate snapshot IDs for your analysis period.
--  - Look for SQL statements with high buffer_gets, disk_reads, or cpu_time.
SELECT 
    sql_id,
    executions_delta AS executions,
    buffer_gets_delta AS buffer_gets,
    disk_reads_delta AS disk_reads,
    cpu_time_delta AS cpu_time,
    elapsed_time_delta AS elapsed_time,
    sql_text
FROM 
    dba_hist_sqlstat stat
JOIN 
    dba_hist_sqltext text ON stat.sql_id = text.sql_id
WHERE 
    stat.snap_id BETWEEN &start_snap_id AND &end_snap_id
    AND buffer_gets_delta > 0
ORDER BY 
    buffer_gets_delta DESC;
-- ----------------------------------------------------------------------------------------------------------------------------------------------------------------
-- 2. Check for Missing Indexes
-- Use the AWR SQL Report or SQL Tuning Advisor to identify SQL statements that could benefit from new indexes.
-- Look for queries with:
-- Full Table Scans (FTS): These may benefit from an index on the columns used in the WHERE clause.
-- High Disk Reads: Indicates that the query is reading a lot of data, which could be reduced with an index.
-- Steps:Run the SQL Tuning Advisor for specific SQL IDs:
DECLARE
  l_task_name VARCHAR2(30);
BEGIN
  l_task_name := DBMS_SQLTUNE.CREATE_TUNING_TASK(sql_id => 'your_sql_id');
  DBMS_SQLTUNE.EXECUTE_TUNING_TASK(task_name => l_task_name);
END;
/
-- Review the recommendations, which may include creating new indexes.

-- or from sql as below 
SELECT 
    sql_id,
    plan_hash_value,
    object_name,
    operation,
    options,
    cpu_cost,
    io_cost,
    cardinality
FROM 
    dba_hist_sql_plan
WHERE 
    operation = 'TABLE ACCESS'
    AND options = 'FULL'
    AND snap_id BETWEEN &start_snap_id AND &end_snap_id
ORDER BY 
    io_cost DESC;


-- ----------------------------------------------------------------------------------------------------------------------------------------------------------------
-- 3. Identify Unused or Redundant Indexes
-- Use the AWR Index Usage Report to identify indexes that are not being used or are rarely used.
-- Unused indexes consume storage and incur maintenance overhead during INSERT, UPDATE, and DELETE operations.
-- Steps: Query the DBA_HIST_SQL_PLAN and DBA_HIST_SQLSTAT views to check index usage:
SELECT   Object_name, COUNT(*) AS usage_count
FROM     dba_hist_sql_plan
WHERE    object_type = 'INDEX'
AND      OBJECT_NAME IN (SELECT INDEX_NAME FROM DBA_INDEXES WHERE TABLE_NAME='ACTB_DAILY_LOG' AND OWNER='FLEXAR')
-- AND snap_id BETWEEN &start_snap_id AND &end_snap_id   --? optional
AND      object_owner ='FLEXAR'
GROUP BY object_owner, object_name
ORDER BY usage_count;
-- Indexes with a usage_count of 0 or very low may be candidates for removal.
-- ----------------------------------------------------------------------------------------------------------------------------------------------------------------
-- 4. Analyze Index Efficiency
-- Use the AWR Segment Statistics Report to analyze the efficiency of existing indexes.
-- Look for indexes with:
-- High Clustering Factor: Indicates that the index may not be efficient for range scans.
-- High Leaf Block Splits: Indicates frequent index maintenance, which may require rebuilding or reorganizing the index.
-- Steps:Run the AWR Segment Statistics report:
@$ORACLE_HOME/rdbms/admin/awrsegstat.sql
-- Analyze the clustering factor and other index-related statistics.
-- or from sql
-- - Look for indexes with a high clustering_factor or disproportionate leaf_blocks to num_rows, which may indicate inefficiency.
SELECT 
    stat.owner,
    stat.object_name,
    stat.tablespace_name,
    stat.obj#,
    stat.dataobj#,
    stat.logical_reads_delta AS logical_reads,
    stat.physical_reads_delta AS physical_reads,
    stat.physical_writes_delta AS physical_writes,
    idx.clustering_factor,
    idx.leaf_blocks,
    idx.num_rows
FROM 
    dba_hist_seg_stat stat
JOIN 
    dba_indexes idx ON stat.obj# = idx.index_id
WHERE 
    stat.snap_id BETWEEN &start_snap_id AND &end_snap_id
ORDER BY 
    logical_reads DESC;
-- ----------------------------------------------------------------------------------------------------------------------------------------------------------------
-- 5. Check for Index Fragmentation
-- Use the AWR Segment Statistics Report or query the DBA_INDEXES view to check for index fragmentation.
-- Fragmented indexes can degrade performance and may need to be rebuilt.
-- Steps: Query the DBA_INDEXES view to check the BLEVEL and LEAF_BLOCKS:
SELECT 
    index_name, 
    blevel, 
    leaf_blocks, 
    num_rows
FROM 
    dba_indexes
WHERE 
    table_name = 'YOUR_TABLE';
-- High BLEVEL or disproportionate LEAF_BLOCKS to NUM_ROWS may indicate fragmentation.
-- ----------------------------------------------------------------------------------------------------------------------------------------------------------------
-- 6. Use AWR Compare Periods Report
-- Compare AWR reports from two different time periods to identify changes in SQL performance and index usage.
-- This can help you determine the impact of index changes (e.g., after creating or removing an index).
-- Steps: Run the AWR Compare Periods report:
@$ORACLE_HOME/rdbms/admin/awrddrpt.sql
-- Compare metrics like buffer gets, disk reads, and execution plans to assess the impact of index changes.
-- or from sql
-- - Compare the results with a similar query for a different time period to identify changes in SQL performance.
SELECT 
    sql_id,
    SUM(buffer_gets_delta) AS total_buffer_gets,
    SUM(disk_reads_delta) AS total_disk_reads,
    SUM(cpu_time_delta) AS total_cpu_time,
    SUM(elapsed_time_delta) AS total_elapsed_time
FROM 
    dba_hist_sqlstat
WHERE 
    snap_id BETWEEN &start_snap_id_1 AND &end_snap_id_1
GROUP BY 
    sql_id
ORDER BY 
    total_buffer_gets DESC;

-- 7. Identify Top Segments by Physical I/O
-- identify segments (tables or indexes) with high physical I/O, query the DBA_HIST_SEG_STAT view.
SELECT 
    stat.owner,
    stat.object_name,
    stat.tablespace_name,
    SUM(stat.physical_reads_delta) AS total_physical_reads,
    SUM(stat.physical_writes_delta) AS total_physical_writes
FROM 
    dba_hist_seg_stat stat
WHERE 
    stat.snap_id BETWEEN &start_snap_id AND &end_snap_id
GROUP BY 
    stat.owner, stat.object_name, stat.tablespace_name
ORDER BY 
    total_physical_reads DESC;

-- This query helps identify segments that are consuming the most I/O resources.

-- ----------------------------------------------------------------------------------------------------------------------------------------------------------------
-- 8. Consider Workload and Maintenance Overhead
-- Before creating or modifying an index, consider:
-- Workload: Will the index benefit the most critical queries?
-- Maintenance Overhead: Will the index impact INSERT, UPDATE, and DELETE operations?
-- Use AWR data to evaluate the trade-offs.
-- Summary of Actions Based on AWR Analysis
-- -----------------------------------------------------------------------------------------------------------
-- | Scenario                               | Action                                                         |
-- -----------------------------------------------------------------------------------------------------------
-- | High buffer gets or disk reads         | Create a new index on columns used in WHERE or JOIN clauses.   |
-- -----------------------------------------------------------------------------------------------------------
-- | Full table scans                       | Create an index to improve access paths.                       |
-- -----------------------------------------------------------------------------------------------------------
-- | Unused or rarely used indexes          | Remove the index to reduce maintenance overhead.               |
-- -----------------------------------------------------------------------------------------------------------
-- | High clustering factor or fragmentation| Rebuild or reorganize the index.                               |
-- -----------------------------------------------------------------------------------------------------------
-- | Index causing high maintenance costs   | Evaluate whether the index is necessary or can be modified.    |
-- -----------------------------------------------------------------------------------------------------------
-- ----------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Tools to Complement AWR Analysis
-- SQL Tuning Advisor: Provides recommendations for SQL optimization, including index creation.
-- Automatic Indexing (Oracle 19c+): Automatically creates, drops, and maintains indexes based on workload patterns.
-- DBMS_STATS: Gathers statistics to ensure the optimizer has accurate information for index usage decisions.
-- By combining AWR data with these tools, you can make informed decisions about creating, removing, or modifying indexes to optimize database performance.
-- Summary of Key Views
-- View	Purpose
-- DBA_HIST_SQLSTAT	SQL    execution statistics (buffer gets, disk reads, CPU time, etc.).
-- DBA_HIST_SQLTEXT	SQL    text for SQL IDs.
-- DBA_HIST_SQL_PLAN	     Execution plans for SQL statements.
-- DBA_HIST_SEG_STAT	     Segment-level statistics (I/O, logical reads, etc.).
-- DBA_INDEXES	           Index metadata (clustering factor, leaf blocks, etc.).







-- ================================
-- Enforce index PTQ
-- =================================

SELECT /*+ INDEX(STZM_CUST_ACCOUNT PK01_STZM_CUST_ACCOUNT) */ *
  FROM STZM_CUST_ACCOUNT A, STZM_CUSTOMER_WRKARND B
WHERE  A.CUST_NO = B.CUSTOMER_NO
AND ACCOUNT_CLASS IN (SELECT DISTINCT (ACCOUNT_CLASS)
                             FROM STZM_ACCOUNT_CLASS C
                            WHERE RD_FLAG = 'N'
                              AND ONCE_AUTH = 'Y'
                              AND RECORD_STAT = 'O');

-- ================================
-- PX Deq Credit: need buffer" 
-- ==================================
select table_name from all_tables
where ( trim(degree) != '1' and trim(degree) != '0' ) or  
      ( trim(instances) != '1' and trim(instances) != '0' )
      and owner = 'ABFCUBSLIVE';


-- ================================
-- Alert log location
-- ==================================

select value from v$diag_info where name ='Diag Trace';

-- ================================
-- AUDIT 
-- ==================================

-- https://docs.oracle.com/en/database/oracle/oracle-database/23/dbseg/value-based-auditing-fine-grained-audit-policies1.html#GUID-C3734BD6-DF2B-46F0-A0E6-92BDBEA3E4EB

-- Auditing Administrative Users
--? AUDIT_SYS_OPERATIONS = TRUE

-- when AUDIT_TRAIL=OS, audit records are written as events to the Event Viewer log file. If either XML or XML,EXTENDED is specified, then audit records are written in the XML format.


--  - Using Oracle Fine-Grained Auditing (FGA)
--------------------------------------------------------------
SELECT POLICY_NAME FROM DBA_AUDIT_POLICIES;
SELECT * FROM DBA_FGA_AUDIT_TRAIL WHERE POLICY_NAME = 'FGA_STTM_CUST_PERSONAL_CHECK'; -- to see the audtied logs

BEGIN
   DBMS_FGA.ADD_POLICY(
      object_schema   => 'schema_name',
      object_name     => 'table_name',
      policy_name     => 'policy_name',
      audit_condition => NULL,
      audit_column    => NULL,
      audit_column_ops => DBMS_FGA.ALL_OPERATIONS
   );
END;
/

BEGIN
   FOR table_record IN (SELECT table_name FROM all_tables WHERE owner = 'FCUBSLIVE') LOOP
      EXECUTE IMMEDIATE 'BEGIN DBMS_FGA.ADD_POLICY(
         object_schema => ''FCUBSLIVE'',
         object_name   => ''' || table_record.table_name || ''',
         policy_name   => ''AUDIT_' || table_record.table_name || ''',
         audit_column  => NULL,
         audit_condition => NULL,
         audit_column_opts => DBMS_FGA.ALL_COLUMNS,
         statement_types => ''INSERT, UPDATE, DELETE, SELECT'',
         enable => TRUE
      ); END;';
   END LOOP;
END;
/



--- test case
-- sample
SELECT COUNT(*) FROM HR.EMPLOYEES WHERE COMMISSION_PCT = 20 AND SALARY > 4500;

SELECT SALARY FROM HR.EMPLOYEES WHERE DEPARTMENT_ID = 50;

DELETE FROM HR.EMPLOYEES WHERE SALARY > 1000000;


-- Enabling a Fine-Grained Audit Policy
DBMS_FGA.ENABLE_POLICY(
   object_schema  VARCHAR2, 
   object_name    VARCHAR2, 
   policy_name    VARCHAR2,
   enable         BOOLEAN);

BEGIN
 DBMS_FGA.ENABLE_POLICY(
  object_schema        => 'HR',
  object_name          => 'EMPLOYEES',
  policy_name          => 'chk_hr_employees',
  enable               => TRUE);
END;
/

-- Disabling a Fine-Grained Audit Policy
DBMS_FGA.DISABLE_POLICY(
   object_schema  VARCHAR2, 
   object_name    VARCHAR2, 
   policy_name    VARCHAR2); 
BEGIN
 DBMS_FGA.DISABLE_POLICY(
  object_schema        => 'HR',
  object_name          => 'EMPLOYEES',
  policy_name          => 'chk_hr_employees');
END;
/

-- Dropping a Fine-Grained Audit Policy
DBMS_FGA.DROP_POLICY(
   object_schema  VARCHAR2, 
   object_name    VARCHAR2, 
   policy_name    IVARCHAR2);

BEGIN
 DBMS_FGA.DROP_POLICY(
  object_schema      => 'HR',
  object_name        => 'EMPLOYEES',
  policy_name        => 'chk_hr_employees');
END;
/



-- Using Standard Auditing
---------------------------------
-- Enable audit trail
ALTER SYSTEM SET audit_trail=db, extended;

-- Audit all DDL operations
AUDIT ALL DDL BY USER;

-- Audit all DML operations
AUDIT ALL ON schema_name.table_name;



-- Check Audit Records - To review the audit logs:

-- For standard auditing
SELECT * FROM DBA_AUDIT_TRAIL;

-- For fine-grained auditing 
SELECT * FROM DBA_FGA_AUDIT_TRAIL;
---------------------------------------------------------------------

DECLARE
  l_sql_stmt varchar2(1000);
BEGIN
  FOR t IN (SELECT owner, table_name
              FROM all_tables
             WHERE owner like 'FCUBSLIVE')
  LOOP
    l_sql_stmt := 'AUDIT ALL ON ' || t.owner || '.' || t.table_name;
    EXECUTE IMMEDIATE l_sql_stmt;
  END LOOP;
END;




-- ================================
-- Gaher stat / analyze function gather stat
-- ==================================


BEGIN
  FOR rec IN (
    SELECT table_name
    FROM MIG_TABLE_LIST
    WHERE FCUBS_BATCH BETWEEN 41 AND 51
  ) LOOP
    EXECUTE IMMEDIATE 'BEGIN
                        DBMS_STATS.GATHER_TABLE_STATS(
                          ownname => ''FCUBSLIVE'', 
                          tabname => :table_name, 
                          estimate_percent => DBMS_STATS.AUTO_SAMPLE_SIZE, 
                          method_opt => ''FOR ALL COLUMNS SIZE 1'', 
                          cascade => true, 
                          degree  => 40
                        );
                       END;'
    USING rec.table_name;
  END LOOP;
END;
/
-- status

SELECT
  CASE
    WHEN mtl.FCUBS_BATCH BETWEEN 1 AND 10 THEN '1-10'
    WHEN mtl.FCUBS_BATCH BETWEEN 11 AND 20 THEN '11-20'
    WHEN mtl.FCUBS_BATCH BETWEEN 21 AND 30 THEN '21-30'
    WHEN mtl.FCUBS_BATCH BETWEEN 31 AND 40 THEN '31-40'
    WHEN mtl.FCUBS_BATCH BETWEEN 41 AND 51 THEN '41-51'
  END AS batch_range,
  COUNT(*) AS analyzed_count
FROM
  MIG_TABLE_LIST mtl
JOIN
  DBA_TAB_STATISTICS dts ON mtl.table_name = dts.table_name
WHERE
  dts.owner = 'FCUBSLIVE'
  AND dts.LAST_ANALYZED = TRUNC(SYSDATE)
GROUP BY
  CASE
    WHEN mtl.FCUBS_BATCH BETWEEN 1 AND 10 THEN '1-10'
    WHEN mtl.FCUBS_BATCH BETWEEN 11 AND 20 THEN '11-20'
    WHEN mtl.FCUBS_BATCH BETWEEN 21 AND 30 THEN '21-30'
    WHEN mtl.FCUBS_BATCH BETWEEN 31 AND 40 THEN '31-40'
    WHEN mtl.FCUBS_BATCH BETWEEN 41 AND 51 THEN '41-51'
  END;

---
SELECT
  s.SID,
  s.SERIAL#,
  s.USERNAME,
  s.STATUS,
  q.SQL_ID,
  q.SQL_TEXT
FROM
  V$SESSION s
JOIN
  V$SQL q ON s.SQL_ID = q.SQL_ID
WHERE
  q.SQL_TEXT LIKE '%DBMS_STATS%'
  AND s.STATUS = 'ACTIVE';

SELECT
  JOB_NAME,
  STATUS,
  START_DATE,
  LAST_UPDATE_DATE
FROM
  DBA_SCHEDULER_RUNNING_JOBS
WHERE
  JOB_NAME LIKE '%GATHER_STATS%'
  AND STATUS = 'RUNNING';

SELECT
  JOB,
  WHAT,
  LAST_DATE,
  THIS_DATE,
  NEXT_DATE,
  FAILURE_COUNT,
  STATUS
FROM
  DBA_JOBS
WHERE
  WHAT LIKE '%DBMS_STATS%'
  AND STATUS = 'RUNNING';

SELECT
  OPERATION,
  STATUS,
  START_TIME,
  END_TIME
FROM
  DBA_OPTSTAT_OPERATIONS
WHERE
  OPERATION LIKE '%GATHER%'
  AND STATUS IN ('RUNNING', 'WAITING');


-- Sqlt135Qet

select count(*) from dba_tables where to_char(last_analyzed,'DD-MON-YY') ='14-JUN-24'


select table_name, to_date(to_char(last_analyzed,'DD/MM/YYYY'),'DD/MM/YYYY') from user_tables where table_name in (select table_name
  from mig_table_list
 where fcubs_batch is not null
   and fcubs_batch = '11')
   
select count(*) from user_tables where table_name in (select table_name
  from mig_table_list
 where fcubs_batch is not null
 and last_analyzed > '19-JUN-24')


exec dbms_stats.GATHER_TABLE_STATS(ownname => 'ABFCUBSLIVE' ,TABNAME => 'CSZB_AUTO_SETTLE_BLOCK_WRKARND',estimate_percent => DBMS_STATS.AUTO_SAMPLE_SIZE,method_opt => 'FOR ALL COLUMNS SIZE 1', cascade => true,  degree  => 40);



exec dbms_stats.GATHER_TABLE_STATS(ownname => 'ABFCUBSLIVE' ,TABNAME => 'CSZB_AUTO_SETTLE_BLOCK_WRKARND',estimate_percent => DBMS_STATS.AUTO_SAMPLE_SIZE,method_opt => 'FOR ALL COLUMNS SIZE 1', cascade => true,  degree  => 40);

exec dbms_stats.GATHER_TABLE_STATS(ownname => 'ABFCUBSLIVE' ,TABNAME => 'ACZB_HISTORY',estimate_percent => DBMS_STATS.AUTO_SAMPLE_SIZE,method_opt => 'FOR ALL COLUMNS SIZE 1', cascade => true,  degree  => 40);

exec dbms_stats.GATHER_TABLE_STATS(ownname => 'FCUBSLIVE' ,TABNAME => 'ACTB_HISTORY',estimate_percent => DBMS_STATS.AUTO_SAMPLE_SIZE,method_opt => 'FOR ALL COLUMNS SIZE 1', cascade => true,  degree  => 40);

EXEC dbms_stats.GATHER_TABLE_STATS(ownname => 'FCUBSLIVE',TABNAME => 'ACTB_HISTORY_ARCHIVE',PARTNAME =>'PART_099' ,estimate_percent => DBMS_STATS.AUTO_SAMPLE_SIZE,  method_opt => 'FOR ALL COLUMNS SIZE 1', cascade => true, degree=> 40);
EXEC dbms_stats.GATHER_TABLE_STATS(ownname => 'FCUBSLIVE',TABNAME => 'ACTB_HISTORY_ARCHIVE',PARTNAME =>'PART_014' ,estimate_percent => DBMS_STATS.AUTO_SAMPLE_SIZE,  method_opt => 'FOR ALL COLUMNS SIZE 1', cascade => true, degree=> 40);



--PR_GATHER_STATS('ABUBSMIG1','STZM_CUST_ACCOUNT');

 exec DBMS_STATS.GATHER_SCHEMA_STATS (ownname =>'ABFCUBSLIVE', estimate_percent => DBMS_STATS.AUTO_SAMPLE_SIZE,cascade => true, degree => 40);




begin
  
--PR_GATHER_STATS('ABUBSMIG1','STZM_CUST_ACCOUNT');

 exec DBMS_STATS.GATHER_SCHEMA_STATS (ownname => 'ABFCUBSLIVE', estimate_percent => DBMS_STATS.AUTO_SAMPLE_SIZE,cascade => true,  degree  => 40);


END;
 exec DBMS_STATS.GATHER_SCHEMA_STATS (ownname => 'ABFCUBSLIVE', estimate_percent => DBMS_STATS.AUTO_SAMPLE_SIZE,method_opt => 'FOR ALL COLUMNS SIZE 1', cascade => true,  degree  => 40);



exec dbms_stats.GATHER_SCHEMA_STATS(ownname => 'ABFCUBSLIVE', estimate_percent =>  DBMS_STATS.AUTO_SAMPLE_SIZE, method_opt => 'FOR ALL COLUMNS SIZE 1', cascade => true, degree=>40; 

begin
exec dbms_stats.GATHER_SCHEMA_STATS(ownname => 'FCUBSLIVE', estimate_percent =>  DBMS_STATS.AUTO_SAMPLE_SIZE, method_opt => 'FOR ALL COLUMNS SIZE 1', cascade => true, degree=>40; 
END;

EXEC dbms_stats.GATHER_SCHEMA_STATS(ownname => 'ABFCUBSLIVE',estimate_percent => DBMS_STATS.AUTO_SAMPLE_SIZE,  method_opt => 'FOR ALL COLUMNS SIZE 1', cascade => true, degree=> 40);



CREATE OR REPLACE PROCEDURE PR_GATHER_STATS(P_SCHEMA_NAME IN VARCHAR2,
                                            P_TABLE_NAME  IN VARCHAR2) IS
  p_Upload_Id varchar2(100);
  p_err_code  VARCHAR2(100);
  p_err_param VARCHAR2(100);
BEGIN
  --execute dbms_stats.gather_table_stats(ownname => 'FCUBSLIVE', tabname =>'SVTM_JH_TEMPTBL', estimate_percent =>DBMS_STATS.AUTO_SAMPLE_SIZE, method_opt =>'FOR ALL COLUMNS SIZE 1', cascade => true, degree => 40);
  dbms_stats.gather_table_stats(ownname          => P_SCHEMA_NAME,
                                tabname          => P_TABLE_NAME,
                                estimate_percent => DBMS_STATS.AUTO_SAMPLE_SIZE,
                                method_opt       => 'FOR ALL COLUMNS SIZE 1',
                                cascade          => true,
                                degree           => 40);

EXCEPTION
  WHEN OTHERS THEN
    DEBUG.PR_DEBUG('DE', 'err while processing- err-' || SQLERRM);
END PR_GATHER_STATS;

--- ----------- Direct executes - single table | not really required for a single table
DECLARE
  P_SCHEMA_NAME VARCHAR2(100) := 'YourSchemaName'; -- Assign your schema name
  P_TABLE_NAME  VARCHAR2(100) := 'YourTableName';  -- Assign your table name
  p_Upload_Id VARCHAR2(100);
  p_err_code  VARCHAR2(100);
  p_err_param VARCHAR2(100);
BEGIN
  --execute dbms_stats.gather_table_stats(ownname => 'FCUBSLIVE', tabname =>'SVTM_JH_TEMPTBL', estimate_percent =>DBMS_STATS.AUTO_SAMPLE_SIZE, method_opt =>'FOR ALL COLUMNS SIZE 1', cascade => true, degree => 40);
  dbms_stats.gather_table_stats(ownname          => P_SCHEMA_NAME,
                                tabname          => P_TABLE_NAME,
                                estimate_percent => DBMS_STATS.AUTO_SAMPLE_SIZE,
                                method_opt       => 'FOR ALL COLUMNS SIZE 1',
                                cascade          => true,
                                degree           => 40);

EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('err while processing- err-' || SQLERRM);
END;
/


-------------

DECLARE
  P_SCHEMA_NAME VARCHAR2(100) := 'ABFCUBSLIVE'; -- Assign your schema name
  CURSOR table_cursor IS
    SELECT table_name
    FROM all_tables
    WHERE owner = P_SCHEMA_NAME;
  
  p_table_name VARCHAR2(100);
BEGIN
  FOR table_record IN table_cursor LOOP
    p_table_name := table_record.table_name;
    BEGIN
      dbms_stats.gather_table_stats(ownname          => P_SCHEMA_NAME,
                                    tabname          => p_table_name,
                                    estimate_percent => DBMS_STATS.AUTO_SAMPLE_SIZE,
                                    method_opt       => 'FOR ALL COLUMNS SIZE 1',
                                    cascade          => true,
                                    degree           => 40);
    EXCEPTION
      WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Error processing table ' || p_table_name || ' - ' || SQLERRM);
    END;
  END LOOP;
END;
/



-- ================================
-- Duplicate 
-- ==================================


DELETE FROM YOUR_TABLE_NAME
WHERE ROWID NOT IN (
  SELECT MAX(ROWID)
  FROM YOUR_TABLE_NAME
  GROUP BY YOUR_UNIQUE_COLUMN   -- ...  -- list all columns that define a unique record in comma separated
);


-- ================================
-- read only schema READ ONLY ro RO
-- ==================================


create user ABFCUBSLIVE_ro identified by moving123 ;

create role ABFCUBSLIVE_ro_role ;

grant ABFCUBSLIVE_ro_role to ABFCUBSLIVE_ro;




-- Grant SELECT privilege on tables in the main schema
BEGIN
  FOR t IN (SELECT table_name FROM all_tables WHERE owner = 'CMNUSER') LOOP
    BEGIN
      EXECUTE IMMEDIATE 'GRANT SELECT ON CMNUSER.' || t.table_name || ' TO CMNUSER_RO';
    EXCEPTION
      WHEN others THEN
        NULL; -- Do nothing and continue loop
    END;
  END LOOP;
END;
/


-- Grant SELECT privilege on views in the main schema
BEGIN
  FOR v IN (SELECT view_name FROM all_views WHERE owner = 'CMNUSER') LOOP
	BEGIN
	  EXECUTE IMMEDIATE 'GRANT SELECT ON CMNUSER.' || v.view_name || ' TO CMNUSER_RO';
	EXCEPTION
	  WHEN OTHERS THEN
	    NULL;
	END;
  END LOOP;
END;
/

-- Grant SELECT privilege on materialized views in the main schema
BEGIN
  FOR mv IN (SELECT mview_name FROM all_mviews WHERE owner = 'CMNUSER') LOOP
    EXECUTE IMMEDIATE 'GRANT SELECT ON CMNUSER.' || mv.mview_name || ' TO CMNUSER_RO';
  END LOOP;
END;
/



--------------------------------------------------------------------------------------------------------------------------------
-- ! Grant EXECUTE  privilege on FUNCTION in the main schema

BEGIN
  FOR ob IN (SELECT object_name FROM dba_objects WHERE owner='PNGTRNFCUBS' and object_type in ('FUNCTION','PACKAGE','PROCEDURE')) LOOP
    EXECUTE IMMEDIATE 'GRANT EXECUTE ON PNGTRNFCUBS.' || ob.OBJECT_NAME || ' TO PNGTRNOBDX_UBS';
  END LOOP;
END;
/



grant ABFCUBSLIVE_ro_role to ABFCUBSLIVE_ro;

--- RW 


BEGIN
  FOR obj IN (SELECT object_name, object_type
              FROM all_objects
              WHERE owner = 'FCUBS147') LOOP
    EXECUTE IMMEDIATE 'GRANT SELECT, INSERT, UPDATE, DELETE ON FCUBS147.' || obj.object_name || ' TO FCUBS147';
  END LOOP;
END;
/






--============================== 
--ons service
--============================== 
set lines 333 pages 3333
col NETWORK for a10
col VALUE for a100
col TYPE for a20
select * from v$listener_network;
-- srvctl status service
-- 



--============================== 
--DROP / drop schema objects / drop user
--============================== 
--- DROP SCHEMA OBJECTS ============== user drop ======= drop user====My Code==================================
REM drop all the objects in schema

set lines 333 pages 4444 
col object_name for a30 
col object_type for a30 
col owner for a20

select object_type,count(*) 
from dba_objects 
where owner='CMNUSER'
group by object_type 
order by 1;

select object_type,status,object_name from user_objects where object_type='TABLE' order by 3;




SELECT
	DECODE
	(
		object_type,
			'FUNCTION','drop FUNCTION '||object_name,
      'TYPE','drop TYPE '||object_name,
      'PROCEDURE','drop PROCEDURE '||object_name,
			'VIEW','drop VIEW '||object_name,
			'PACKAGE','drop PACKAGE '||object_name,
      'SEQUENCE','drop SEQUENCE '||object_name,
			'FUNCTION','drop FUNCTION '||object_name,
      'LIBRARY','drop LIBRARY '||object_name,
      'FUNCTION','drop FUNCTION '||object_name,
      'TRIGGER','drop TRIGGER '||object_name,
      'PACKAGE BODY','drop PACKAGE BODY '||object_name,
      'SYNONYM', 'drop SYNONYM '||object_name,
      'JAVA CLASS', 'drop JAVA CLASS '||object_name,
      'JAVA RESOURCE', 'drop JAVA RESOURCE '||object_name,
      'JAVA SOURCE', 'drop JAVA SOURCE '||object_name,
      'PROGRAM', 'drop PROGRAM '||object_name,
      'MATERIALIZED VIEW','drop MATERIALIZED VIEW '||object_name,
      'TABLE','drop TABLE '||object_name||' cascade constraint purge'
	) || ';' 
FROM user_objects 
WHERE OBJECT_TYPE IN ( 'TYPE','TABLE', 'VIEW',
 'SEQUENCE', 'PROCEDURE', 'PACKAGE','FUNCTION',
 'LIBRARY','TRIGGER','PACKAGE BODY', 'SYNONYM','JAVA CLASS',
  'JAVA RESOURCE','JAVA SOURCE','PROGRAM','MATERIALIZED VIEW')
and object_name not like 'SYS%'
ORDER BY OBJECT_TYPE
/
-- special objcts
-- drop program
-- FORMAT
BEGIN
  DBMS_SCHEDULER.drop_program (program_name => 'test_plsql_block_prog');
  DBMS_SCHEDULER.drop_program (program_name => 'test_stored_procedure_prog');
  DBMS_SCHEDULER.drop_program (program_name => 'test_executable_prog');
END;
/

EXEC  DBMS_SCHEDULER.drop_program (program_name => 'P_RP_0000000000000000000000005');
--!QUERY

SELECT
	DECODE
	(
		object_type,
      'PROGRAM', 'EXEC  DBMS_SCHEDULER.drop_program (program_name => '''||object_name||''')'
	) || ';' 
FROM user_objects 
WHERE OBJECT_TYPE IN ('PROGRAM')
ORDER BY OBJECT_TYPE
/

-- ! java class
SELECT
	DECODE
	(
		object_type,
      'JAVA CLASS', 'drop JAVA CLASS "'||object_name||'"'
	) || ';' 
FROM user_objects 
WHERE OBJECT_TYPE IN ('JAVA CLASS')
ORDER BY OBJECT_TYPE
/

--! DROP JOB 


-- below will create the scrip to drop job , execute from respective schema
SELECT
	DECODE
	(
		object_type,
		  'JOB','exec dbms_scheduler.drop_job(JOB_NAME =>'''||object_name||''')'
	) || ';' 
FROM user_objects 
WHERE OBJECT_TYPE IN ( 'JOB')
ORDER BY OBJECT_TYPE
/

-- BELOW WILL work
exec dbms_scheduler.drop_job(JOB_NAME => 'P_HOST319122023161145CY901') -- 


--! queue

BEGIN
  DBMS_AQADM.STOP_QUEUE(queue_name => 'AQ$_MSG_REQ_QUEUE_ASYNC_E');
  DBMS_AQADM.DROP_QUEUE(queue_name => 'AQ$_MSG_REQ_QUEUE_ASYNC_E');
  DBMS_AQADM.DROP_QUEUE_TABLE(queue_table => 'QUEUE_TABLE_NAME');  -- optional
END;

BEGIN
  DBMS_AQADM.STOP_QUEUE(queue_name => 'AQ$_MSG_REQ_QUEUE_ASYNC_E');
  DBMS_AQADM.DROP_QUEUE(queue_name => 'AQ$_MSG_REQ_QUEUE_ASYNC_E');
END;

EXEC DBMS_AQADM.DROP_QUEUE_TABLE(queue_table => '&1');




-- #!/bin/bash

-- # Run SQL script in the background
-- sqlplus sys/welcome123@UATOVMPDB @clean147.sql > /dev/null 2>&1 &

-- # Add any additional commands or logic if needed


DECLARE
   l_sql VARCHAR2(1000);
BEGIN
   FOR r IN (
      SELECT table_name, column_name
      FROM all_tab_cols
      WHERE data_type LIKE 'LOB%'
      and  owner LIKE '%%'
   )
   LOOP
      l_sql := 'BEGIN DBMS_LOB.DROP_SEGMENT(SEGMENT_NAME => ''' || r.table_name || '.' || r.column_name || ''', FORCE => TRUE); END;';
      EXECUTE IMMEDIATE l_sql;
   END LOOP;
END;
/





--- fr aq table --  working query 

set verify off;
 
declare
l_po_t dbms_aqadm.aq$_purge_options_t;
begin
l_po_t.block := TRUE;
dbms_aqadm.purge_queue_table(
queue_table => 'EVENT_PDF_Q_T',
purge_condition => NULL,
purge_options => l_po_t);
end;
 /
-- worked query , from schema

exec DBMS_AQADM.DROP_QUEUE_TABLE(queue_table => 'EVENT_PDF_Q_T',force=>true);

 -- force option worked on 26feb
exec DBMS_AQADM.DROP_QUEUE_TABLE(queue_table => '&T',force=>true);



-- EVENT_NOTIF_Q5_T
-- EVENT_NOTIF_Q6_T
-- EVENT_NOTIFY_XML_T
-- EVENT_NOTIF_Q7_T
-- EVENT_NOTIF_Q8_T
-- EVENT_PDF_Q_T
-- EVENT_NOTIF_SMTP_T
-- EVENT_NOTIF_Q4_T
-- EVENT_NOTIF_Q9_T

--- login to user and execute as there is no owner option in the procedure

DECLARE
  v_sql VARCHAR2(1000);
BEGIN
  FOR q IN (SELECT NAME
            FROM all_queues
            WHERE owner = 'TISA147CONVERTION') 
  LOOP
    v_sql := 'BEGIN DBMS_AQADM.STOP_QUEUE(queue_name => ''' || q.name || '''); END;';
    EXECUTE IMMEDIATE v_sql;

    v_sql := 'BEGIN DBMS_AQADM.DROP_QUEUE(queue_name => ''' || q.name || '''); END;';
    EXECUTE IMMEDIATE v_sql;
  END LOOP;
-- END;
-- /
  FOR qt IN (SELECT queue_table
             FROM all_queue_tables
             WHERE owner = 'TISA147CONVERTION') 
  LOOP
    v_sql := 'BEGIN DBMS_AQADM.DROP_QUEUE_TABLE(queue_table => ''' || qt.queue_table || '''); END;';
    EXECUTE IMMEDIATE v_sql;
  END LOOP;
END;
/


-- By CGPT

DECLARE
  v_sql VARCHAR2(1000);
BEGIN
  FOR t IN (SELECT object_name, object_type
            FROM all_objects
            WHERE owner = 'TISA147CONVERTION' AND object_type IN ('LOB', 'QUEUE','TYPE', 'PACKAGE BODY')) 
  LOOP
    v_sql := 'DROP ' || t.object_type || ' ' || 'TISA147CONVERTION.' || t.object_name;
    EXECUTE IMMEDIATE v_sql;
  END LOOP;
END;
/


--- For AQ queue and table




--- By Naveen OFSS

begin
for x in (select *
            from dba_objects
           where owner=upper('PNGTRNFCUBS')
             and not regexp_like(object_type,'(BODY|INDEX|LINK|LOB|PARTITION)$')
           order by object_type desc)
    loop
     Begin
       case
        when x.object_type='CHAIN' then
         DBMS_SCHEDULER.DROP_CHAIN(''||x.owner||'.'||x.object_name||'',TRUE);
        when x.object_type like 'INDEX%' then NULL;
        when x.object_type='JOB' then
         DBMS_SCHEDULER.DROP_JOB(job_name => ''||x.owner||'.'||x.object_name||'',force => TRUE);
        when x.object_type='PROGRAM' then
         DBMS_SCHEDULER.DROP_PROGRAM(''||x.owner||'.'||x.object_name||'',TRUE);
        when x.object_type='TABLE' then
         execute immediate 'Drop '||x.object_type||' '||x.owner||'.""'||x.object_name||'"" cascade constraints purge';
        else
         execute immediate 'Drop '||x.object_type||' '||x.owner||'.""'||x.object_name||'""';
       end case;
     EXCEPTION
        when others then
         DBMS_OUTPUT.PUT_LINE('Failed to drop '||x.object_type||' '''||x.owner||'.'||x.object_name||'''');
         DBMS_OUTPUT.PUT_LINE(''||chr(10)||DBMS_UTILITY.FORMAT_ERROR_STACK
                            ||''||chr(10)||DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
     End;
    end loop;
end;
/

select owner,object_type,status,count(*) from dba_objects where owner='&owner'
group by owner,object_type,status order by 1,3,2;


--============================== 
-- user related 
--============================== 
set lines 444 pages 4444
col ACCOUNT_STATUS for a20
col username for a30
col profile for a20
select username,account_status,profile,EXPIRY_DATE from dba_users where oracle_maintained='N' order by 3,1
/
select username,account_status from dba_users where oracle_maintained='N' and account_status !='OPEN' order by 1
/
select 'alter user '||username ||' identified by welcome1;' from dba_users where oracle_maintained='N' order by 1
/
select 'alter user '||username ||' identified by '||username||' ;' from dba_users  where oracle_maintained='N' and PROFILE ='OBMA_PROFILE'  order by 1
/


 
-- ======================
-- INVALID COMPILE 
-- ====================
-- make sure library cache no locked with below script

select
distinct
ses.ksusenum sid, ses.ksuseser serial#, ses.ksuudlna username,KSUSEMNM module,
ob.kglnaown obj_owner, ob.kglnaobj obj_name
,lk.kgllkcnt lck_cnt, lk.kgllkmod lock_mode, lk.kgllkreq lock_req
, w.state, w.event, w.wait_Time, w.seconds_in_Wait
from
x$kgllk lk, x$kglob ob,x$ksuse ses
, v$session_wait w
where lk.kgllkhdl in
(select kgllkhdl from x$kgllk where kgllkreq >0 )
and ob.kglhdadr = lk.kgllkhdl
and lk.kgllkuse = ses.addr
and w.sid = ses.indx
order by seconds_in_wait desc
/

---
Select COUNT(*) from dba_objects where status='INVALID' AND OWNER='ABFCUBSLIVE' AND OBJECT_NAME NOT LIKE '%$%'; 

 ---cyclic flexcube databases
DECLARE
  l_err_code VARCHAR2(20) := NULL;
  l_err_param VARCHAR2(20) := NULL;
BEGIN
  pr_instlr_cyclic_compile(p_err_code => l_err_code, p_err_param => l_err_param);
END;
/


---------
begin
  -- Call the procedure
--  p_err_code varchar2(20);
  --p_err_param varchar2(20);
  pr_instlr_cyclic_compile(p_err_code => :p_err_code,
                           p_err_param => :p_err_param);
end;



SELECT * FROM USER_ERRORS   -- fcubs only
------- otheres as below ----------------



set lines 333 pages 20000 
col owner for a30 
col table_name for a30 
set markup html on 
select table_name from dba_tables where owner='PDB' order by 1; 
 
set lines 333 pages 2000 
col OWNER for a30 
col DIRECTORY_NAME for a30 
col DIRECTORY_PATH for a70 
col OWNER for a30 
select * from dba_directories; 




select 'grant read,write on directory '||DIRECTORY_NAME||' to TISA147CONVERTION;' from dba_directories; 

 
-- below query to create  file in the directory from db
CREATE OR REPLACE PROCEDURE USERNAME.TEST_WRITEFILE IS
out_File UTL_FILE.FILE_TYPE;
BEGIN
out_File := UTL_FILE.FOPEN ('DEBUG', 'test.txt', 'W');
UTL_FILE.PUT_LINE (out_File, 'hello world');
UTL_FILE.FCLOSE (out_File);
END;

-- CSTB_DEBUG - for  application debug enable and disable



set lines 333 pages 4444 
col object_name for a30 
col object_type for a30 
col owner for a20
select owner,object_name,object_type,status from dba_objects where object_name like upper('&object_name'); 
select owner,object_name,object_type,status from dba_objects where status='INVALID';
select owner,object_name,object_type,status from dba_objects where owner in ('&owner') ;
select owner,object_type,status,count(*) from dba_objects where owner='&owner'
group by owner,object_type,status order by 1,3,2;

select object_type,status,count(*) from dba_objects where owner='&owner' group by object_type,status order by 1,2;


select owner,object_type,status,count(*) from dba_objects 
where owner in (select username from dba_users where oracle_maintained='N')
and status='INVALID'
group by owner,object_type,status
ORDER BY 1,2;



 
set lines 333 pages 4444 
col object_name for a30 
col object_type for a30 
col owner for a20
select con_id,owner,object_name,object_type,status from cdb_objects where object_name like upper('&object_name'); 
select owner,object_name,object_type,status from dba_objects where status='INVALID';
select owner,object_name,object_type,status from dba_objects where owner in ('OBDXTISA_B1A1','OBDX_TISA') ;
select owner,object_type,status,count(*) from dba_objects --where owner='&owner'
group by owner,object_type,status order by 1,3,2;
select owner,object_type,status,count(*) from dba_objects 
where owner in (select username from dba_users where oracle_maintained='N')
and status='INVALID'
group by owner,object_type,status
ORDER BY 1,2;

-- DDL
SELECT DBMS_METADATA.GET_DDL('&type','&name','&owner') FROM DUAL;


select count(*) from dba_objects 
where owner in (select username from dba_users where oracle_maintained='N');



select owner,stcount(*) from dba_objects where owner in (select username from dba_users where oracle_maintained='N')  group by owner  order by 1


select 'alter '||object_type||' '||owner||'.'||object_name||' compile;' 
from dba_objects where owner in ('ABFCUBSLIVE') AND OBJECT_TYPE !='PACKAGE BODY' AND STATUS='INVALID';

select 'alter '||object_type||' '||owner||'.'||object_name||' compile;' 
from dba_objects 
where owner in ('ABFCUBSLIVE') 
AND STATUS='INVALID' 
AND OBJECT_TYPE!='PACKAGE BODY' 
AND OBJECT_NAME NOT LIKE ('#')


select 'alter package '||owner||'.'||object_name||' compile body;' from dba_objects where owner in ('PNGTRNFCUBS') AND OBJECT_TYPE='PACKAGE BODY' AND STATUS='INVALID';

select 'alter '||OBJECT_TYPE ||' '||owner||'.'||object_name||' compile;' from dba_objects where owner in ('PNGTRNFCUBS') AND OBJECT_TYPE='PACKAGE' AND STATUS='INVALID';



-- Completed
SET SERVEROUTPUT ON
DECLARE
    v_errors    BOOLEAN := FALSE;
BEGIN
    -- Compile procedures, functions, packages, package bodies, views, and triggers for specific schemas
    FOR c IN (SELECT object_name, object_type, owner
              FROM dba_objects
              WHERE object_type IN ('PROCEDURE', 'FUNCTION', 'PACKAGE', 'PACKAGE BODY', 'VIEW')
                AND owner IN ('OBDX_TISA', 'OBDXTISA_B1A1')) LOOP
        BEGIN
            IF c.object_type = 'PACKAGE BODY' THEN
                EXECUTE IMMEDIATE 'ALTER PACKAGE "' || c.owner || '"."' || c.object_name || '" COMPILE BODY';
            ELSE
                EXECUTE IMMEDIATE 'ALTER ' || c.object_type || ' "' || c.owner || '"."' || c.object_name || '" COMPILE';
            END IF;
        EXCEPTION
            WHEN OTHERS THEN
                DBMS_OUTPUT.PUT_LINE('Error compiling ' || c.object_type || ' "' || c.owner || '"."' || c.object_name || '": ' || SQLERRM);
                v_errors := TRUE;
        END;
    END LOOP; -- for loop should close with end loop
    IF v_errors = FALSE THEN
        DBMS_OUTPUT.PUT_LINE('All objects compiled successfully.');
    ELSE
        DBMS_OUTPUT.PUT_LINE('Some objects encountered compilation errors. Please review the output for details.');
    END IF;
END;
/



--=====================
--Object compare in schemas
--=====================

set lines 333 pages 4444 

SELECT
  object_type,
  status,
  COALESCE(SUM(CASE WHEN owner = 'ABSUPPBKP' THEN 1 END), 0) AS ABSUPPBKP,
  COALESCE(SUM(CASE WHEN owner = 'ACCESSUBS' THEN 1 END), 0) AS ACCESSUBS
FROM
  dba_objects
WHERE
  owner IN ('ABSUPPBKP', 'ACCESSUBS')
GROUP BY
  object_type, status
ORDER BY
  object_type, status;


SELECT
  object_type,
  COALESCE(SUM(CASE WHEN owner = 'ABSUPPBKP' THEN 1 END), 0) AS ABSUPPBKP,
  COALESCE(SUM(CASE WHEN owner = 'ACCESSUBS' THEN 1 END), 0) AS ACCESSUBS
FROM
  dba_objects
WHERE
  owner IN ('ABSUPPBKP', 'ACCESSUBS')
GROUP BY
  object_type
ORDER BY
  object_type;



  select owner,count(*) from dba_objects where owner in ('TISA147CONVBKP','TISA147CONVERTION') group by owner;

  
SELECT
  object_type,
  COALESCE(SUM(CASE WHEN owner = 'TISA147BKP' THEN 1 END), 0) AS TISA147BKP,
  COALESCE(SUM(CASE WHEN owner = 'TISA147CONVERTION' THEN 1 END), 0) AS TISA147CONVERTION
FROM
  dba_objects
WHERE
  owner IN ('TISA147BKP', 'TISA147CONVERTION')
GROUP BY
  object_type
ORDER BY
  object_type;


--! to create -- works some time

DECLARE
  v_ddl CLOB;
  w_ddl CLOB;
  x_ddl CLOB;
  v_type_name VARCHAR2(30);
BEGIN
  FOR cur_type IN (SELECT TYPE_NAME FROM DBA_TYPES WHERE OWNER = 'ACCESSUBS' AND TYPE_NAME LIKE '%TYPE%')
  LOOP
    v_type_name := cur_type.TYPE_NAME;
    v_ddl := DBMS_METADATA.GET_DDL('TYPE', v_type_name, 'ACCESSUBS');
    -- Append a semicolon if it's not already present at the end of the DDL statement
    IF SUBSTR(v_ddl, -1) != ';' THEN
      w_ddl := v_ddl || ';';
    END IF;
    -- Replace schema name with ABSUPPBKP
    x_ddl := REPLACE(w_ddl, '"ACCESSUBS"', '"ABSUPPBKP"');
    -- Execute the modified DDL statement
    EXECUTE IMMEDIATE v_ddl;
  END LOOP;
END;
/


DECLARE
  v_ddl CLOB;
  w_ddl CLOB;
  x_ddl CLOB;
BEGIN
  FOR cur_obj IN (
    SELECT src.object_type, src.object_name
    FROM (
        SELECT object_type, object_name
        FROM dba_objects
        WHERE owner = 'ACCESSUBS'
        AND object_name NOT LIKE 'SYS%'
        AND object_type != 'PACKAGE BODY' -- Exclude package bodies
    ) src
    WHERE NOT EXISTS (
        SELECT 1
        FROM dba_objects
        WHERE owner = 'ABSUPPBKP'
        AND object_type = src.object_type
        AND object_name = src.object_name
    )
  )
  LOOP
    BEGIN
      v_ddl := DBMS_METADATA.GET_DDL(cur_obj.object_type, cur_obj.object_name, 'ACCESSUBS');
      -- Append a semicolon if it's not already present at the end of the DDL statement
      IF SUBSTR(v_ddl, -1) != ';' THEN
        w_ddl := v_ddl || ';';
      ELSE
        w_ddl := v_ddl;
      END IF;
      -- Replace schema name with ABSUPPBKP
      x_ddl := REPLACE(w_ddl, '"ACCESSUBS"', '"ABSUPPBKP"');
      -- Print or do something with the modified DDL statement
      DBMS_OUTPUT.PUT_LINE(x_ddl);
      -- Execute the modified DDL statement
      -- EXECUTE IMMEDIATE x_ddl;
    EXCEPTION
      WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Error retrieving DDL for ' || cur_obj.object_type || ' ' || cur_obj.object_name || ': ' || SQLERRM);
    END;
  END LOOP;
END;
/




--=====================
--Object comapre with db link
--=====================


SELECT 
    COALESCE(sit.OBJECT_TYPE, dm.OBJECT_TYPE) AS OBJECT_TYPE,
    sit.SIT_COUNT,
    dm.DM_COUNT
FROM (
    SELECT OBJECT_TYPE, COUNT(*) AS SIT_COUNT
    FROM user_objects@dblink_sit
    GROUP BY OBJECT_TYPE
) sit
FULL JOIN (
    SELECT OBJECT_TYPE, COUNT(*) AS DM_COUNT
    FROM user_objects
    GROUP BY OBJECT_TYPE
) dm ON sit.OBJECT_TYPE = dm.OBJECT_TYPE;


-- Also

SELECT src.object_type, src.count - COALESCE(dest.count, 0) AS missing_count
FROM (
    SELECT object_type, COUNT(*) AS count
    FROM dba_objects@dblink_gc
    WHERE owner = 'FCUBS147'
    GROUP BY object_type
) src
LEFT JOIN (
    SELECT object_type, COUNT(*) AS count
    FROM dba_objects
    WHERE owner = 'FCUBS147'
    GROUP BY object_type
) dest
ON src.object_type = dest.object_type
WHERE src.count - COALESCE(dest.count, 0) > 0 OR dest.count IS NULL;
-----



SELECT src.object_type, src.count - COALESCE(dest.count, 0) AS missing_count
FROM (
    SELECT object_type, COUNT(*) AS count
    FROM dba_objects@dblink_sit
    WHERE owner = 'TISA147CONVERTION'
    GROUP BY object_type
) src
LEFT JOIN (
    SELECT object_type, COUNT(*) AS count
    FROM dba_objects
    WHERE owner = 'FCUBS147'
    GROUP BY object_type
) dest
ON src.object_type = dest.object_type
WHERE src.count - COALESCE(dest.count, 0) > 0 OR dest.count IS NULL;




---------------------------------

--- for object names 

SELECT src.object_type, src.object_name
FROM (
    SELECT object_type, object_name
    FROM dba_objects@dblink_gc
    WHERE owner = 'FCUBS147'
    AND object_name not like 'SYS%'
) src
WHERE NOT EXISTS (
    SELECT 1
    FROM dba_objects
    WHERE owner = 'FCUBS147'
    AND object_type = src.object_type
    AND object_name = src.object_name
)
order by 1,2;


SELECT src.object_type, src.object_name
FROM (
    SELECT object_type, object_name
    FROM dba_objects
    WHERE owner = 'ACCESSUBS'
    --- AND object_name not like 'SYS%'
) src
WHERE NOT EXISTS (
    SELECT 1
    FROM dba_objects
    WHERE owner = 'ABSUPPBKP'
    AND object_type = src.object_type
    AND object_name = src.object_name
)
order by 1,2;



-- with exclude 

SELECT src.object_type, src.object_name
FROM (
    SELECT object_type, object_name
    FROM dba_objects@dblink_sit
    WHERE owner = 'TISA147CONVERTION'
    AND object_type not in ('LOB','INDEX','TABLE')
) src
WHERE NOT EXISTS (
    SELECT 1
    FROM dba_objects
    WHERE owner = 'FCUBS147'
    AND object_type = src.object_type
    AND object_name = src.object_name
);


----- fixing missing objects 

---! below query will ddl for the missing objects
SET SERVEROUTPUT ON;
DECLARE
  v_ddl CLOB;
  w_ddl CLOB;
  x_ddl CLOB;
BEGIN
  FOR cur_obj IN (
    SELECT src.object_type, src.object_name
    FROM (
        SELECT object_type, object_name
        FROM dba_objects
        WHERE owner = 'ACCESSUBS'
        AND object_name NOT LIKE 'SYS%'
        AND object_type != 'PACKAGE BODY' -- Exclude package bodies
    ) src
    WHERE NOT EXISTS (
        SELECT 1
        FROM dba_objects
        WHERE owner = 'ABSUPPBKP'
        AND object_type = src.object_type
        AND object_name = src.object_name
    )
  )
  LOOP
    BEGIN
      v_ddl := DBMS_METADATA.GET_DDL(cur_obj.object_type, cur_obj.object_name, 'ACCESSUBS');
      -- Append a semicolon if it's not already present at the end of the DDL statement
      IF SUBSTR(v_ddl, -1) != ';' THEN
        w_ddl := v_ddl || ';';
      ELSE
        w_ddl := v_ddl;
      END IF;
      -- Replace schema name with ABSUPPBKP
      x_ddl := REPLACE(w_ddl, '"ACCESSUBS"', '"ABSUPPBKP"');
      -- Print or do something with the modified DDL statement
      DBMS_OUTPUT.PUT_LINE(x_ddl);
      -- Execute the modified DDL statement
      -- EXECUTE IMMEDIATE x_ddl;
    EXCEPTION
      WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Error retrieving DDL for ' || cur_obj.object_type || ' ' || cur_obj.object_name || ': ' || SQLERRM);
    END;
  END LOOP;
END;
/




---- to get missing sequences


set pagesize 299
set long 999
select dbms_metadata.get_ddl('PROCOBJ','P_DAHOFFY_017102023164356','TISA147CONVERTION') from dual@dblink_sit;

SELECT DBMS_METADATA.GET_DDL('JOB','P_DAHOFFY_017102023164356','TISA147CONVERTION') FROM DUAL;

SELECT DBMS_METADATA.GET_DDL('JAVA CLASS','UNWRAP_UTIL','FCUBS144') FROM DUAL;

-- below is the workig option for DDL for JOb - execute inn 
set lines 333 pages 4444
set long 9999999
SELECT dbms_metadata.get_ddl('PROCOBJ', job_name, owner) AS ddl_output 
FROM ALL_SCHEDULER_JOBS
where job_name like 'P_D%'



SELECT DBMS_METADATA.GET_DDL('INDEX',u.index_name,'VUTTRNFCUBS')  
FROM DUAL ,dba_indexes u 
where u.owner='VUTTRNFCUBS' and u.index_name in
(
'PK01_SVTM_ACC_SIG_DET',
'PK_CL_ACNT_PARTIES',
'PK01_STTM_KYC_FINANCIAL',
'PK01_STTM_CUSTOMER',
'PK01_MSTM_CUST_ADDRESS',
'PK01_MSTM_MSG_ADDRESS',
'PK01_STTM_CUST_PROFESSIONAL',
'PK01_STTM_CUST_PERSONAL',
'PK_CLTP_MASTER',
'PK01_CATM_CHECK_BOOK',
'PK01_STTM_CUST_CORPORATE',
'PK_STTM_CORP_DIRECTORS',
'PK_MSTM_ACC_ADDR',
'PK01_STTM_AC_LINKED_ENTITIES',
'PK01_STTM_KYC_CORP_BOI',
'PK01_STTM_AUTO_LIAB_DETAILS',
'PK01_STTM_KYC_CORPORATE',
'PK01_STTM_CUST_ACCOUNT',
'PK01_STTM_KYC_MASTER',
'PK01_STTM_KYC_RETAIL'
)

SELECT 'CREATE SEQUENCE ' || sequence_name || ' START WITH ' || last_number || ' INCREMENT BY ' || increment_by || ';'
FROM dba_sequences@dblink_sit
WHERE sequence_owner = 'TISA147CONVERTION'
AND sequence_name NOT IN (
    SELECT sequence_name
    FROM dba_sequences
    WHERE sequence_owner = 'TISA147CONVERTION'
);

SELECT 'CREATE OR REPLACE SYNONYM ' || synonym_name || ' FOR ' || table_owner || '.' || table_name || ';'
FROM dba_synonyms@dblink_sit
WHERE owner = 'TISA147CONVERTION'
AND synonym_name NOT IN (
    SELECT synonym_name
    FROM dba_synonyms
    WHERE owner = 'TISA147CONVERTION'
);



SELECT 'CREATE OR REPLACE JOB ' || object_name || ' AS ' || dbms_metadata.get_ddl('JOB', object_name, owner) || ';'
FROM dba_objects@dblink_sit
WHERE object_type = 'JOB'
AND owner = 'TISA147CONVERTION'
AND object_name NOT IN (
    SELECT object_name
    FROM dba_objects
    WHERE object_type = 'JOB'
    AND owner = 'TISA147CONVERTION'
);




SELECT 'CREATE OR REPLACE PACKAGE ' || object_name || ' AS ' || dbms_metadata.get_ddl('PACKAGE', object_name, owner) || ';'
FROM dba_objects@dblink_sit
WHERE object_type = 'PACKAGE'
AND owner = 'TISA147CONVERTION'
AND object_name NOT IN (
    SELECT object_name
    FROM dba_objects
    WHERE object_type = 'PACKAGE'
    AND owner = 'TISA147CONVERTION'
);





SELECT 'CREATE OR REPLACE PACKAGE BODY ' || object_name || ' AS ' || dbms_metadata.get_ddl('PACKAGE_BODY', object_name, owner) || ';'
FROM dba_objects@dblink_sit
WHERE object_type = 'PACKAGE BODY'
AND owner = 'TISA147CONVERTION'
AND object_name NOT IN (
    SELECT object_name
    FROM dba_objects
    WHERE object_type = 'PACKAGE BODY'
    AND owner = 'TISA147CONVERTION'
);



---=================================
---NUMBER OF ROWS IN ALL TABLES IN SCHEMA
---===========================

declare
    v_count integer;
begin
    for r in (select table_name, owner from all_tables
              where owner = 'FCCHOST') 
    loop
        execute immediate 'select count(*) from ' || r.table_name 
            into v_count;
        INSERT INTO STATS_TABLE(TABLE_NAME,SCHEMA_NAME,RECORD_COUNT,CREATED)
        VALUES (r.table_name,r.owner,v_count,SYSDATE);
    end loop;
end;


--================================================================================================
--Object comapre within two schemas in same db
--================================================================================================
SELECT 
    COALESCE(s1.OBJECT_TYPE, s2.OBJECT_TYPE) AS OBJECT_TYPE,
    s1.B1A1_SIT_COUNT,
    s2.BKP_B1A1_SIT_COUNT
FROM (
    SELECT OBJECT_TYPE, COUNT(*) AS B1A1_SIT_COUNT
    FROM DBA_OBJECTS
    WHERE OWNER = 'B1A1_SIT'
    GROUP BY OBJECT_TYPE
) s1
FULL JOIN (
    SELECT OBJECT_TYPE, COUNT(*) AS BKP_B1A1_SIT_COUNT
    FROM DBA_OBJECTS
    WHERE OWNER = 'BKP_B1A1_SIT'
    GROUP BY OBJECT_TYPE
) s2 ON s1.OBJECT_TYPE = s2.OBJECT_TYPE;





--- ================================================
 
set lines 333 pages 4444 
col RESOURCE_NAME for a30 
col INITIAL_ALLOCATION for a20 
col LIMIT_VALUE for a15 
select * from gv$resource_limit order by 2 
/ 




30% memory should be reserved on server and 70% can be allocated to SGA+PGA
Total Server memory 288G
70% of 288G=200G
40% PGA and 60% SGA from 200G
PGA=80G
SGA=120G
alter system set sga_target=100G scope=spfile;
alter system set sga_max_size=100G scope=spfile;
ALTER SYSTEM SET pga_aggregate_limit=80G SCOPE=BOTH;
ALTER SYSTEM SET pga_aggregate_target=40G SCOPE=BOTH;

-- SGA allocation check
set lines 333 pages 4444 
 SELECT COMPONENT, CURRENT_SIZE/1024/1024/1024 CURRENT_GB,MAX_SIZE/1024/1024/1024 MAX_GB,USER_SPECIFIED_SIZE/1024/1024/1024 USER_SPECIFIED_GB FROM V$MEMORY_DYNAMIC_COMPONENTS;


--=====================
-- VALIDATE WHOLE DATABASE FOR CORRUPTION
--=====================

run {
 CONFIGURE DEFAULT DEVICE TYPE TO DISK;
 CONFIGURE DEVICE TYPE DISK PARALLELISM 10 BACKUP TYPE TO BACKUPSET;
 BACKUP VALIDATE CHECK LOGICAL DATABASE FILESPERSET=10;
 }

--=====================
-- CONSTRAINTS DISABLE / ENABLE  
--=====================


select owner,status,count(1) from dba_constraints where owner='&owner' group by owner,status


Spool disable_trigger.sql
select 'alter trigger '|| table_owner||'.'||trigger_name ||' disable;' From dba_triggers where status ='ENABLED' and table_owner='PNGTRNFCUBS';
Spool off
@disable_trigger.sql
Spool disable_Constraints.sql
select 'alter table '||owner||'.'||table_name ||' disable constraint '||constraint_name||' keep index ;' 
From dba_constraints where status ='ENABLED' and owner='OBDX_PNGTRN'
and table_name in ('DIGX_FW_ERROR_MESSAGES',
'DIGX_CM_TASK',
'DIGX_CM_TASK_ASPECTS',
'DIGX_FW_CONFIG_ALL_B',
'DIGX_FW_CONFIG_ALL_O',
'DIGX_FW_CONFIG_CONTENT_PUB_B',
'DIGX_AA_BANKFEEDUSERREGISTER',
'DIGX_AA_OAUTHACCESSTOKEN',
'DIGX_CM_RESOURCE_TASK_REL',
'DIGX_CM_TASK_ACCTTYPE_REL',
'DIGX_ME_ENTITY_DETERMINANT_B',
'DIGX_FW_CONFIG_OUT_RS_CFG_B',
'DIGX_FW_CONFIG_OUT_WS_CFG_B'
)
;


Spool off
@disable_Constraints.sql
Spool drop_sequences.sql
select 'drop sequence '||sequence_owner||'.'||sequence_name||';' from dba_sequences where sequence_owner ='VANUATFCUBS';
Spool off


select 'alter table '||owner||'.'||table_name ||' disable constraint '||constraint_name||' keep index ;' From dba_constraints where status ='ENABLED' and owner='PNGTRNFCUBS';



Spool disable_trigger.sql
select 'alter trigger '|| table_owner||'.'||trigger_name ||' disable;' From dba_triggers where status ='ENABLED' and table_owner='PNGTRNFCUBS';
Spool off
@disable_trigger.sql
Spool disable_Constraints.sql
select 'alter table '||owner||'.'||table_name ||' enable constraint '||constraint_name||' keep index ;' 
From dba_constraints where status ='ENABLED' and owner='OBDX_PNGTRN'
and table_name in ('DIGX_FW_ERROR_MESSAGES',
'DIGX_CM_TASK',
'DIGX_CM_TASK_ASPECTS',
'DIGX_FW_CONFIG_ALL_B',
'DIGX_FW_CONFIG_ALL_O',
'DIGX_FW_CONFIG_CONTENT_PUB_B',
'DIGX_AA_BANKFEEDUSERREGISTER',
'DIGX_AA_OAUTHACCESSTOKEN',
'DIGX_CM_RESOURCE_TASK_REL',
'DIGX_CM_TASK_ACCTTYPE_REL',
'DIGX_ME_ENTITY_DETERMINANT_B',
'DIGX_FW_CONFIG_OUT_RS_CFG_B',
'DIGX_FW_CONFIG_OUT_WS_CFG_B'
)
;


Spool off
@disable_Constraints.sql
Spool drop_sequences.sql
select 'drop sequence '||sequence_owner||'.'||sequence_name||';' from dba_sequences where sequence_owner ='VANUATFCUBS';
Spool off


--
BEGIN
  FOR c IN
  (SELECT c.owner, c.table_name, c.constraint_name
   FROM user_constraints c, user_tables t
   WHERE c.table_name = t.table_name
   AND c.status = 'ENABLED'
   --AND NOT (t.iot_type IS NOT NULL AND c.constraint_type = 'P') 
   ORDER BY c.constraint_type DESC)
  LOOP
    dbms_utility.exec_ddl_statement('alter table "' || c.owner || '"."' || c.table_name || '" disable constraint ' || c.constraint_name);
  END LOOP;
END;
/

select constraint_type,status ,count(*) from user_constraints group by  constraint_type,status order by 1,2




--=========================
-- DATABASE STATUS STATE DB 
--==========================
set lines 333 pages 4444 
col DBID for 9999999999
col NAME for a8
col LOG_MODE for a30
col OPEN_MODE for a30
col PROTECTION_MODE for a30
col DATABASE_ROLE for a30
col DATAGUARD_BROKER for a30

SELECT DBID,NAME,CREATED,LOG_MODE,OPEN_MODE,PROTECTION_MODE,DATABASE_ROLE,DATAGUARD_BROKER
FROM V$DATABASE
/




--=====================
-- IMPDP EXPDP DATAPUMP 
--=====================

set lines 333 pages 4444 
col owner_name for a25
col JOB_NAME for a25
col operation for a15
col job_mode for a25
col state for a20
select * from dba_datapump_jobs where state != 'NOT RUNNING';
select * from dba_datapump_sessions;

--Check the active datapump job sessions:
set lines 150 pages 100
numwidth 7
col program for a38
col username for a10
col spid for a7

SELECT 
  TO_CHAR(SYSDATE,'YYYY-MM-DD HH24:MI:SS') "DATE",
  s.program, 
  s.sid, 
  s.status, 
  s.username,
  d.job_name, 
  p.spid, 
  s.serial#, 
  p.pid,
  s.event
FROM 
  v$session s, 
  v$process p, 
  dba_datapump_sessions d
WHERE 
  p.addr=s.paddr 
  AND s.saddr=d.saddr;
-- Monitor the progress of the datapump job:

SELECT
  ROUND(sofar/totalwork*100,2) percent_completed,
  v$session_longops.*
FROM
  v$session_longops
WHERE
  sofar <> totalwork
ORDER BY
  target,
  sid;



  -- Check the current job details:

SELECT 
  x.job_name,
  b.state,
  b.job_mode,
  b.degree, 
  x.owner_name,
  z.sql_text, 
  p.message, 
  p.totalwork, 
  p.sofar, 
  ROUND((p.sofar/p.totalwork)*100,2) done, 
  p.time_remaining
FROM 
  dba_datapump_jobs b
  LEFT JOIN dba_datapump_sessions x ON (x.job_name = b.job_name)
  LEFT JOIN v$session y ON (y.saddr = x.saddr)
  LEFT JOIN v$sql z ON (y.sql_id = z.sql_id)
  LEFT JOIN v$session_longops p ON (p.sql_id = y.sql_id)
WHERE 
  y.module='Data Pump Worker'
  AND p.time_remaining > 0;




--==================== 
--RECOVERY DEST -- FRA reco 
--==================== 
 
SET LINES 333 PAGES 4444 
SELECT * FROM V$RECOVERY_AREA_USAGE; 
SELECT * FROM V$FLASH_RECOVERY_AREA_USAGE
select sum(PERCENT_SPACE_USED) tot_usd_pct,sum(PERCENT_SPACE_RECLAIMABLE) tot_rclmbl_pc ,sum(NUMBER_OF_FILES) tot_num_files from V$RECOVERY_AREA_USAGE ;
 
SET LINES 333 PAGES 4444 
COL NAME FOR A30 
SELECT NAME,SPACE_LIMIT/1024/1024/1024 SPACE_LIMIT_GB,SPACE_USED/1024/1024/1024 SPACE_USED_GB,SPACE_RECLAIMABLE/1024/1024/1024 SPACE_RECLAIMABLE_GB,NUMBER_OF_FILES,CON_ID from V$RECOVERY_FILE_DEST; 
 
 
-- for NON Container

SET LINES 333 PAGES 4444 
SELECT * FROM V$RECOVERY_AREA_USAGE; 
 
select sum(PERCENT_SPACE_USED) tot_usd_pct,sum(PERCENT_SPACE_RECLAIMABLE) tot_rclmbl_pc ,sum(NUMBER_OF_FILES) tot_num_files from V$RECOVERY_AREA_USAGE ;
 
SET LINES 333 PAGES 4444 
COL NAME FOR A30 
SELECT NAME,SPACE_LIMIT/1024/1024/1024 SPACE_LIMIT_GB,SPACE_USED/1024/1024/1024 SPACE_USED_GB,SPACE_RECLAIMABLE/1024/1024/1024 SPACE_RECLAIMABLE_GB,NUMBER_OF_FILES from V$RECOVERY_FILE_DEST; 
 
 
--==================== 
-- patch deails in db level
--==================== 
SELECT patch_id, patch_type, action, action_time, status, description
FROM dba_registry_sqlpatch
ORDER BY action_time DESC;



-- Below is -- cat archive_removal.sh
-- cron --> 
-- #!/bin/bash

-- # Set Oracle Environment Variables
-- export ORACLE_SID=dc1ovmdb1
-- export ORACLE_BASE=/u01/app/oracle
-- export ORACLE_HOME=/u01/app/oracle/product/19.0.0/dbhome_1
-- export LD_LIBRARY_PATH=$ORACLE_HOME/lib
-- export JAVA_HOME=$ORACLE_HOME/jdk/bin
-- export PATH=$PATH:$ORACLE_HOME/bin:$ORACLE_HOME/lib:$ORACLE_HOME/OPatch:$ORACLE_HOME/jdk/bin:.


-- # Function to remove archived logs older than 2 hours
-- cleanup_archived_logs() {
--     rman target / <<EOF
--     RUN {
--         ALLOCATE CHANNEL ch1 TYPE DISK;
--         DELETE NOPROMPT ARCHIVELOG ALL COMPLETED BEFORE 'SYSDATE-1/2';
--     }
--     EXIT;
-- EOF
-- }

-- # Main script execution
-- cleanup_archived_logs
-- ---------------------------------

-- #!/bin/bash

-- # Function to remove archived logs older than 2 hours
-- cleanup_archived_logs() {
--     local ORACLE_SID=$1
--     export ORACLE_SID

--     # Set Oracle Environment Variables
--     export ORACLE_BASE=/vol1/app/oracle
--     export ORACLE_HOME=/vol1/app/oracle/product/19c/dbhome_1
--     export LD_LIBRARY_PATH=$ORACLE_HOME/lib
--     export JAVA_HOME=$ORACLE_HOME/jdk/bin
--     export PATH=$PATH:$ORACLE_HOME/bin:$ORACLE_HOME/lib:$ORACLE_HOME/OPatch:$ORACLE_HOME/jdk/bin:.

--     rman target / <<EOF
--     RUN {
--         ALLOCATE CHANNEL ch1 TYPE DISK;
--         DELETE NOPROMPT ARCHIVELOG ALL COMPLETED BEFORE 'SYSDATE-1';
--     }
--     EXIT;
-- EOF
-- }

-- # Main script execution
-- cleanup_archived_logs rptovm
-- cleanup_archived_logs agencybank



--========================= 
--ASM 
--========================== 
SET LINES 333 PAGES 4444 
Col name for a50 
-- in TB
select GROUP_NUMBER,NAME,STATE,TOTAL_MB/1024/1024 TOTAL_TB,FREE_MB/1024/1024 FREE_TB,USABLE_FILE_MB/1024/1024 FREE_USABLE_TB,OFFLINE_DISKS from v$asm_diskgroup; 
-- in GB
select GROUP_NUMBER,NAME,STATE,TOTAL_MB/1024 TOTAL_GB,FREE_MB/1024 FREE_GB,USABLE_FILE_MB/1024 FREE_USABLE_GB,OFFLINE_DISKS from v$asm_diskgroup; 

 --in MB
 select GROUP_NUMBER,NAME,STATE,TOTAL_MB,FREE_MB,USABLE_FILE_MB,OFFLINE_DISKS from v$asm_diskgroup; 
--====================== 
--PDB 
--====================== 
 
set lines 333 pages 444 
col NAME for ae15 
col CAUSE for a10 
col MESSAGE for a20 
col ACTION for a20 
col time for a30 
select * from PDB_PLUG_IN_VIOLATIONS; 
select name,cause,type,message,status from PDB_PLUG_IN_VIOLATIONs order by name;

COLUMN DB_NAME FORMAT A10
COLUMN CON_ID FORMAT 999
COLUMN PDB_NAME FORMAT A15
COLUMN OPERATION FORMAT A16
COLUMN OP_TIMESTAMP FORMAT A10
COLUMN CLONED_FROM_PDB_NAME FORMAT A15
 
SELECT DB_NAME, CON_ID, PDB_NAME, OPERATION, OP_TIMESTAMP, CLONED_FROM_PDB_NAME
  FROM CDB_PDB_HISTORY
  WHERE CON_ID > 2
  ORDER BY CON_ID;

-- Run below query to find createion or cloning time of specific PDB:
SELECT DB_NAME, CON_ID, PDB_NAME, OPERATION, OP_TIMESTAMP, CLONED_FROM_PDB_NAME
  FROM CDB_PDB_HISTORY
  WHERE CON_ID = <conainer ID>;

--============================== 
--REDO LOGS 
--============================== 
SET LINES 333 PAGES 4444 
COL GROUP# FOR 99999 
col member for a100

select * from  v$logfile; 
select * from  v$log; 
select * from  v$standby_log;
 
 
ALTER DATABASE DROP LOGFILE GROUP &G; 

ALTER DATABASE DROP LOGFILE MEMBER &G
 
ALTER DATABASE ADD LOGFILE THREAD 1 GROUP 5 SIZE 4G; 
ALTER DATABASE ADD LOGFILE THREAD 2 GROUP 6 SIZE 4G; 

ALTER DATABASE ADD LOGFILE THREAD 1 GROUP &G SIZE 2G; 
ALTER DATABASE ADD LOGFILE THREAD 2 GROUP &G SIZE 200M; 
 
ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP &G SIZE 2G; 
ALTER DATABASE ADD STANDBY LOGFILE THREAD 2 GROUP &G SIZE 2G; 
 
ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP &G SIZE 200M; 
ALTER DATABASE ADD STANDBY LOGFILE THREAD 2 GROUP &G SIZE 200M; 
 
 ALTER DATABASE ADD LOGFILE MEMBER '+RECO01' TO GROUP &g;
 ALTER DATABASE ADD STANDBY LOGFILE MEMBER '+RECO01' TO GROUP &g;
 
--If unable to drop [current log] 
 
ALTER DATABASE CLEAR LOGFILE GROUP &G; 
 
ALTER DATABASE CLEAR UNARCHIVED LOGFILE GROUP &G; 
 
--From <https://www.oracle-dba-online.com/managing_redo_logfiles.htm>  
 
 611398

--- === ARCHIVE SEQUENCE CHECK =====================  SYNC =================================================
 
--========================== 
--ARCHIVE - SYNC 
--========================== 
 
SET LINES 333 PAGES 4444 
COL PID  FOR A10 
COL CLIENT_PID FOR A10 
COL CLIENT_DBID FOR A10 
COL GROUP# FOR A10 
SELECT * FROM V$MANAGED_STANDBY; 


SET LINESIZE 200
COLUMN SOURCE_DBID FORMAT 9999999999
COLUMN SOURCE_DB_UNIQUE_NAME FORMAT A30
COLUMN NAME FORMAT A25
COLUMN VALUE FORMAT A15
COLUMN UNIT FORMAT A30
COLUMN TIME_COMPUTED FORMAT A20
COLUMN DATUM_TIME FORMAT A20
COLUMN CON_ID FORMAT 999

SELECT * FROM v$dataguard_stats WHERE name LIKE '%lag%';
 
--RAC DR SYNC STATUS ========== 
--user 
 
--csdba/r3dros3 
 
select MAX(SEQUENCE#) "Max_log_generated", to_char(max(completion_time),'DD-MON-YYYY : hh24:MI:SS') "Max_log_Date_Time" 
from v$archived_log 
where completion_time = (select max(completion_time) from v$archived_log);

select MAX(SEQUENCE#) "Max_log_applied",to_char(max(completion_time),'DD-MON-YYYY : hh24:MI:SS') "Max_Applied_Date_Time" 
from v$archived_log 
where completion_time = (select max(completion_time) from v$archived_log where applied='YES');
 

https://docs.oracle.com/cd/E11882_01/server.112/e41134/create_ps.htm#SBYDB4728

SELECT thread#, MAX(sequence#) AS max_sequence FROM gv$archived_log GROUP BY thread#;



GIPKS_UPLOAD_COLLT_CUSTOM=>Connecting to URL..................
GIPKS_UPLOAD_COLLT_CUSTOM=>HTTP_METHOD..................POST
GIPKS_UPLOAD_COLLT_CUSTOM=>HTTP_VERSION..................HTTP/1.1
GIPKS_UPLOAD_COLLT_CUSTOM=>l_service_url https://172.16.44.3:8101/FCUBS-ELCMWeb/ELFacilityService?wsdl
GIPKS_UPLOAD_COLLT_CUSTOM=>Failed in connecting to url : ORA-29024: Certificate validation failure
GIPKS_UPLOAD_COLLT_CUSTOM=>ORA-06512: at "SYS.UTL_HTTP", line 380
ORA-06512: at "SYS.UTL_HTTP", line 1148
ORA-06512: at "ABFCUBSLIVE.GIPKS_UPLOAD_COLLT_CUSTOM", line 557
GIPKS_UPLOAD_COLLT_CUSTOM=>Failed in fn_process_util_http_request
GIPKS_UPLOAD_COLLT_CUSTOM=>Unable to establish connection
GIPKS_UPLOAD_COLLT_CUSTOM=>Failed in web service call. Update error description and status of this record
GIPKS_UPLOAD_COLLT_CUSTOM=>l_error_description ST-FCWS-ERR:Currently Web Service Is Not Reachable


--- === DR check ===============

SET LINES 333 PAGES 4444 
COL GROUP# FOR 99999 
col member for a100
col dest_id for 999
col dest_name for A30
col status for a15
col type for a20
select DEST_ID,dest_name,status,type,srl,recovery_mode from v$archive_dest_status where dest_id=1;


-- generic 
SELECT 
    TO_CHAR(completion_time, 'YYYY-MM-DD HH24') AS hour_start,
    TO_CHAR(completion_time, 'DY') AS day_of_week,
    COUNT(*) AS archive_logs_generated,
    ROUND(SUM(blocks * block_size)/1024/1024, 2) AS total_size_mb,
    ROUND(AVG(blocks * block_size)/1024/1024, 2) AS avg_size_mb,
    ROUND(SUM(blocks * block_size)/1024/1024/60, 2) AS mb_per_minute,
    ROUND(SUM(blocks * block_size)/1024/1024/3600, 2) AS mb_per_second
FROM 
    v$archived_log
WHERE 
    completion_time > SYSDATE - 30
    AND archived = 'YES'
    AND dest_id = 1
GROUP BY 
    TO_CHAR(completion_time, 'YYYY-MM-DD HH24'),
    TO_CHAR(completion_time, 'DY')
ORDER BY 
    hour_start;

-- DAILY
SELECT 
    TRUNC(completion_time) AS day,
    TO_CHAR(TRUNC(completion_time), 'DY') AS day_name,
    COUNT(*) AS archive_logs,
    ROUND(SUM(blocks * block_size)/1024/1024, 2) AS total_gb,
    ROUND(SUM(blocks * block_size)/1024/1024/24, 2) AS gb_per_hour
FROM 
    v$archived_log
WHERE 
    completion_time > SYSDATE - 90
    AND archived = 'YES'
GROUP BY 
    TRUNC(completion_time),
    TO_CHAR(TRUNC(completion_time), 'DY')
ORDER BY 
    day;

-- hour
SELECT 
    TO_CHAR(completion_time, 'HH24') AS hour_of_day,
    COUNT(*) AS archive_logs,
    ROUND(SUM(blocks * block_size)/1024/1024, 2) AS total_mb,
    ROUND(AVG(blocks * block_size)/1024/1024, 2) AS avg_mb_per_log
FROM 
    v$archived_log
WHERE 
    completion_time > SYSDATE - 30
    AND archived = 'YES'
GROUP BY 
    TO_CHAR(completion_time, 'HH24')
ORDER BY 
    hour_of_day;

-- size
SELECT 
    ROUND((blocks * block_size)/1024/1024, 0) AS size_mb,
    COUNT(*) AS log_count,
    ROUND(RATIO_TO_REPORT(COUNT(*)) OVER () * 100, 2) AS percentage
FROM 
    v$archived_log
WHERE 
    completion_time > SYSDATE - 30
    AND archived = 'YES'
GROUP BY 
    ROUND((blocks * block_size)/1024/1024, 0)
ORDER BY 
    size_mb;


--=============================== 
-- ACL GRANTS 
--===============================

-- status
-- Verify the ACL configuration
SELECT * FROM DBA_NETWORK_ACLS;
SELECT * FROM DBA_NETWORK_ACL_PRIVILEGES;
-- Grants
grant execute on utl_http to "ABFCUBSLIVE";
grant execute on utl_smtp to "ABFCUBSLIVE";
grant execute on  utl_tcp to "ABFCUBSLIVE";
-- connect and resolve
BEGIN
  -- Create the ACL if it doesn't exist
  DBMS_NETWORK_ACL_ADMIN.CREATE_ACL(
    acl         => 'fcubs_web_services_testing.xml',
    description => 'HTTP Access for UTL_HTTP',
    principal   => 'ABFCUBSLIVE',
    is_grant    => TRUE,
    privilege   => 'connect',
    start_date  => NULL,
    end_date    => NULL
  );

  BEGIN
  -- Add the resolve privilege
  DBMS_NETWORK_ACL_ADMIN.ADD_PRIVILEGE(
    acl        => '/sys/acls/utl_http.xml',
    principal  => 'ABFCUBSLIVE',
    is_grant   => TRUE,
    privilege  => 'resolve',
    start_date => NULL,
    end_date   => NULL
  );
  COMMIT;
END;
/
-- Assign 


-- below will assing Ip from less 
BEGIN
  -- Assign the ACL to the specified IP addresses with the port range 80 to 9999
  FOR ip IN (
    SELECT '172.16.44.' || TO_CHAR(LEVEL + 18) AS host  -- LEVEL + 18 will make count start from 19
    FROM dual
    CONNECT BY LEVEL <= 9  -- number of ips to be added limit of the IP 172.16.44.27
  )
  LOOP
    DBMS_NETWORK_ACL_ADMIN.ASSIGN_ACL(
      acl        => '/sys/acls/utl_http.xml',
      host       => ip.host,
      lower_port => 80,
      upper_port => 9999
    );
  END LOOP;

  COMMIT;
END;
/

---


-- Assign scripts
BEGIN
  DBMS_NETWORK_ACL_ADMIN.ASSIGN_ACL(
    acl        => '/sys/acls/utl_http.xml',
    host       => '172.16.44.4',
    lower_port => 80,
    upper_port => 9999
  );
  COMMIT;
END;
/




-- UN Assign scripts
BEGIN
  DBMS_NETWORK_ACL_ADMIN.UNASSIGN_ACL(
    acl        => '/sys/acls/utl_http.xml',
    host       => '172.16.44.4',
    lower_port => 80,
    upper_port => 9999
  );
  COMMIT;
END;
/

--GET WALLET ACCESS IF HTTPS IS USED IN WEBSERVICES

Certificates
orapki wallet create -wallet https_wallet -pwd AccWallPwd24 -auto_login
orapki wallet add -wallet https_wallet -trusted_cert -cert "root.crt" -pwd AccWallPwd24
orapki wallet add -wallet https_wallet -trusted_cert -cert "inter.crt" -pwd AccWallPwd24
orapki wallet display -wallet https_wallet -pwd AccWallPwd24 -complete

Update CSTBS_PARAM set param_val='/acfs01/database/wallet/https_wallet' where PARAM_NAME='GIDIFAUP_WALLET_STORE';
Update CSTBS_PARAM set param_val='AccWallPwd24' where PARAM_NAME='GIDIFAUP_WALLET_PASS';
UPDATE STTM_STATIC_TYPE SET TYPE_VALUE='UTIL_HTTPS' WHERE type = 'PMS_COLLATERAL_UPD' AND type_name = 'PMS_HTTP_TYPE';




srvctl status listener
srvctl stop listener -listener LISTENER2
srvctl status listener
srvctl start listener -listener LISTENER2
srvctl status listener
curl -kv https://ab01-ubsodt01.pcaprod.accessbankplc.com:8101/FCUBS-ELCMWeb/ELFacilityService?wsdl

SELECT utl_http.request('https://172.16.44.3:8101/FCUBS-ELCMWeb/ELFacilityService?wsdl') FROM dual;

SELECT utl_http.request('https://ab01-ubsodt01.pcaprod.accessbankplc.com:8101/FCUBS-ELCMWeb/ELFacilityService?wsdl') FROM dual;
SELECT utl_http.request('http://ab01-ubsodt01.pcaprod.accessbankplc.com:7101/FCUBS-ELCMWeb/ELFacilityService?wsdl') FROM dual;
SELECT utl_http.request('https://172.16.44.3:8101/FCUBS-ELCMWeb/ELFacilityService?wsdl') FROM dual;
SELECT utl_http.request('http://172.16.44.3:7101/FCUBS-ELCMWeb/ELFacilityService?wsdl') FROM dual;
SELECT utl_http.request('https://flexcube-uat.accessbankplc.com/FCUBS-ELCMWeb/ELFacilityService?wsdl') FROM dual;
SELECT utl_http.request('https://172.23.37.11:8101/FCUBS-ELCMWeb/ELFacilityService?wsdl') FROM dual;

-- remove cert from wallet

orapki wallet remove -wallet https_wallet -dn "CN=AB Root CA 01 v1" -pwd AccWallPwd24
orapki wallet remove -wallet https_wallet -trusted_cert -alias alias [-summary]


select apex_web_service.make_rest_request(
    p_url         => 'https://172.16.44.3:8101/FCUBS-ELCMWeb/ELFacilityService?wsdl', 
    p_http_method => 'GET',
    p_wallet_path => 'file:///acfs01/database/wallet/https_wallet' ) from dual;

--========================= 
--WALLET 
--========================== 
 
 
 
set lines 333 pages 44444 
COL WRL_PARAMETER FOR A50 
SELECT * FROM gv$encryption_wallet; 
 
ADMINISTER KEY MANAGEMENT SET KEYSTORE close IDENTIFIED BY "br15ban3stg" CONTAINER=all; 
ADMINISTER KEY MANAGEMENT SET KEYSTORE open IDENTIFIED BY "br15ban3stg" CONTAINER=all; 


--------------!--------------------------------------------------

ADMINISTER KEY MANAGEMENT SET KEYSTORE OPEN IDENTIFIED BY "<wallet_password>" CONTAINER = CURRENT;
ADMINISTER KEY MANAGEMENT SET KEYSTORE CLOSE CONTAINER = ALL;
ADMINISTER KEY MANAGEMENT SET AUTO_LOGIN KEYSTORE USING 'file:<wallet_directory>';

-- Wallet creation referance
===================Wallet Steps In Prod==========
mkdir -p /u01/admin/CFCUBS1/wallet
chmod -R 700 /u01/admin/CFCUBS1/wallet
===============Below Command run in db_home/bin location ==========
orapki wallet create -wallet /u01/admin/CFCUBS1/wallet -auto_login
==============================Add all schema's in wallet location ===================
mkstore -wrl /u01/admin/CFCUBS1/wallet -createCredential FCUBS147 FCUBS147
schema password:
wallet password:
===================Below Details add in sqlnet.ora================
WALLET_LOCATION = (SOURCE = (METHOD = FILE) (METHOD_DATA = (DIRECTORY = /u01/admin/CFCUBS1/wallet)))
SQLNET.WALLET_OVERRIDE = TRUE
SSL_CLIENT_AUTHENTICATION = FALSE
NAMES.DIRECTORY_PATH= (TNSNAMES)

===============================Add alias name's in tnsnames.ora location ==============
example :
TRANSACTION=
(DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = ksadcl5031)(PORT = 1530))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = core)
    )
  )
  
-- https://www.br8dba.com/store-db-credentials-in-oracle-wallet/

--=============================== 
--TABLESPACE SIZE INCLUDING AUTOEXENDS =================
--===============================
-- DBA_TABLESPACE_USAGE_METRICS

set linesize 100
set pagesize 100
select
a.tablespace_name,
round(SUM(a.bytes)/(1024*1024*1024)) CURRENT_GB,
round(SUM(decode(b.maxextend, null, A.BYTES/(1024*1024*1024),
b.maxextend*8192/(1024*1024*1024)))) MAX_GB,
(SUM(a.bytes)/(1024*1024*1024) - round(c.Free/1024/1024/1024)) USED_GB,
round((SUM(decode(b.maxextend, null, A.BYTES/(1024*1024*1024),
b.maxextend*8192/(1024*1024*1024))) - (SUM(a.bytes)/(1024*1024*1024) -
round(c.Free/1024/1024/1024))),2) FREE_GB,
round(100*(SUM(a.bytes)/(1024*1024*1024) -
round(c.Free/1024/1024/1024))/(SUM(decode(b.maxextend, null, A.BYTES/(1024*1024*1024),
b.maxextend*8192/(1024*1024*1024))))) USED_PCT
from
dba_data_files a,
sys.filext$ b,
(SELECT
d.tablespace_name ,sum(nvl(c.bytes,0)) Free
FROM
dba_tablespaces d,
DBA_FREE_SPACE c
WHERE
d.tablespace_name = c.tablespace_name(+)
group by d.tablespace_name) c
WHERE
a.file_id = b.file#(+)
and a.tablespace_name = c.tablespace_name
GROUP BY a.tablespace_name, c.Free/1024
ORDER BY tablespace_name
/

--------------- better below

set feedback off
set pagesize 70;
set linesize 2000
set head on
COLUMN Tablespace format a25 heading 'Tablespace Name'
COLUMN autoextensible format a11 heading 'AutoExtend'
COLUMN files_in_tablespace format 999 heading 'Files'
COLUMN total_tablespace_space format 99999999 heading 'TotalSpace'
COLUMN total_used_space format 99999999 heading 'UsedSpace'
COLUMN total_tablespace_free_space format 99999999 heading 'FreeSpace'
COLUMN total_used_pct format 9999 heading '%Used'
COLUMN total_free_pct format 9999 heading '%Free'
COLUMN max_size_of_tablespace format 99999999 heading 'ExtendUpto'
COLUM total_auto_used_pct format 999.99 heading 'Max%Used'
COLUMN total_auto_free_pct format 999.99 heading 'Max%Free'
WITH tbs_auto AS
(SELECT DISTINCT tablespace_name, autoextensible
FROM dba_data_files
WHERE autoextensible = 'YES'),
files AS
(SELECT tablespace_name, COUNT (*) tbs_files,
SUM (BYTES/1024/1024) total_tbs_bytes
FROM dba_data_files
GROUP BY tablespace_name),
fragments AS
(SELECT tablespace_name, COUNT (*) tbs_fragments,
SUM (BYTES)/1024/1024 total_tbs_free_bytes,
MAX (BYTES)/1024/1024 max_free_chunk_bytes
FROM dba_free_space
GROUP BY tablespace_name),
AUTOEXTEND AS
(SELECT tablespace_name, SUM (size_to_grow) total_growth_tbs
FROM (SELECT tablespace_name, SUM (maxbytes)/1024/1024 size_to_grow
FROM dba_data_files
WHERE autoextensible = 'YES'
GROUP BY tablespace_name
UNION
SELECT tablespace_name, SUM (BYTES)/1024/1024 size_to_grow
FROM dba_data_files
WHERE autoextensible = 'NO'
GROUP BY tablespace_name)
GROUP BY tablespace_name)
SELECT c.instance_name,a.tablespace_name Tablespace,
CASE tbs_auto.autoextensible
WHEN 'YES'
THEN 'YES'
ELSE 'NO'
END AS autoextensible,
files.tbs_files files_in_tablespace,
files.total_tbs_bytes total_tablespace_space,
(files.total_tbs_bytes - fragments.total_tbs_free_bytes
) total_used_space,
fragments.total_tbs_free_bytes total_tablespace_free_space,
round(( ( (files.total_tbs_bytes - fragments.total_tbs_free_bytes)
/ files.total_tbs_bytes
)
* 100
)) total_used_pct,
round(((fragments.total_tbs_free_bytes / files.total_tbs_bytes) * 100
)) total_free_pct
FROM dba_tablespaces a,v$instance c , files, fragments, AUTOEXTEND, tbs_auto
WHERE a.tablespace_name = files.tablespace_name
AND a.tablespace_name = fragments.tablespace_name
AND a.tablespace_name = AUTOEXTEND.tablespace_name
AND a.tablespace_name = tbs_auto.tablespace_name(+)
order by total_free_pct;

---- single tablespace

SELECT
    df.tablespace_name,
    df.total_space_mb,
    (df.total_space_mb - fs.free_space_mb) AS used_space_mb,
    ROUND((df.total_space_mb - fs.free_space_mb) / df.total_space_mb * 100, 2) AS pct_used
FROM
    (SELECT
        tablespace_name,
        ROUND(SUM(bytes) / 1024 / 1024, 2) AS total_space_mb
     FROM
        dba_data_files
     WHERE
        tablespace_name = 'FCCDFLT'
     GROUP BY
        tablespace_name) df
JOIN
    (SELECT
        tablespace_name,
        ROUND(SUM(bytes) / 1024 / 1024, 2) AS free_space_mb
     FROM
        dba_free_space
     WHERE
        tablespace_name = 'FCCDFLT'
     GROUP BY
        tablespace_name) fs
ON df.tablespace_name = fs.tablespace_name;



--From <http://blog.ronnyegner-consulting.de/2012/08/23/query-for-tablespace-usage-with-autoextend/> 


--- === Tablespace growth report query === from awr ===== by Santhosh ===

set lines 333 pages 4444
col SNAP_TIME for a30
SELECT distinct DHSS.SNAP_ID,VTS.NAME, TO_CHAR(DHSS.END_INTERVAL_TIME, 'DD-MM HH:MI') AS SNAP_Time,
ROUND((DHTS.TABLESPACE_USEDSIZE*8192)/1024/1024)/&&max_instance_num AS USED_MB,
ROUND((DHTS.TABLESPACE_SIZE*8192)/1024/1024)/&&max_instance_num AS SIZE_MB
FROM DBA_HIST_TBSPC_SPACE_USAGE DHTS,V$TABLESPACE VTS,DBA_HIST_SNAPSHOT DHSS
WHERE VTS.TS#=DHTS.TABLESPACE_ID
AND DHTS.SNAP_ID=DHSS.SNAP_ID
ORDER BY 1;



set lines 333 pages 4444
col SNAP_TIME for a30
SELECT distinct DHSS.SNAP_ID,VTS.NAME, TO_CHAR(DHSS.END_INTERVAL_TIME, 'DD-MM HH:MI') AS SNAP_Time,
ROUND((DHTS.TABLESPACE_USEDSIZE*8192)/1024/1024)/&&max_instance_num AS USED_MB,
ROUND((DHTS.TABLESPACE_SIZE*8192)/1024/1024)/&&max_instance_num AS SIZE_MB
FROM DBA_HIST_TBSPC_SPACE_USAGE DHTS,V$TABLESPACE VTS,DBA_HIST_SNAPSHOT DHSS
WHERE VTS.TS#=DHTS.TABLESPACE_ID
AND DHTS.SNAP_ID=DHSS.SNAP_ID
AND VTS.NAME='TISA147CONVERTION'
ORDER BY 1;


--=============================== 
--TEMP TABLESPACE SIZE INCLUDING AUTOEXENDS =================
--===============================

set linesize 200 tab off trimspool on
set pagesize 105
set pause off
set echo off
set feedb on

column tablespace format a30
column "TOTAL (MB)" format 9,999,990.00
column "USED (MB)" format  9,999,990.00
column "FREE (MB)" format 9,999,990.00



SELECT   A.tablespace_name tablespace, D.mb_total "TOTAL (GB)",
         SUM (A.used_blocks * D.block_size) / 1024 / 1024 / 1024 "USED (GB)",
         D.mb_total - SUM (A.used_blocks * D.block_size) / 1024 / 1024 / 1024 "FREE (GB)"
FROM     Gv$sort_segment A,
         (
         SELECT   B.name, C.block_size, SUM (C.bytes) / 1024 / 1024 /1024 mb_total
         FROM     v$tablespace B, v$tempfile C
         WHERE    B.ts#= C.ts#
         GROUP BY B.name, C.block_size
         ) D
WHERE    A.tablespace_name = D.name
GROUP by A.tablespace_name, D.mb_total
/

set pages 999
set lines 400
col FILE_NAME format a75
select d.TABLESPACE_NAME, d.FILE_NAME, d.BYTES/1024/1024 SIZE_MB, d.AUTOEXTENSIBLE, d.MAXBYTES/1024/1024 MAXSIZE_MB, d.INCREMENT_BY*(v.BLOCK_SIZE/1024)/1024 INCREMENT_BY_MB
from dba_temp_files d,
 v$tempfile v
where d.FILE_ID = v.FILE#
order by d.TABLESPACE_NAME, d.FILE_NAME;


 



--=============================== 
--CREATE TABLESPACE 
--=============================== 

select username,DEFAULT_TABLESPACE,TEMPORARY_TABLESPACE from dba_users where account_status='OPEN' and username='JSDOHS1_IAU' ; 
 
--USERNAME 
-------------------------------------------------------------------------------- 
--DEFAULT_TABLESPACE             TEMPORARY_TABLESPACE 
------------------------------ ------------------------------ 
--JSDOHS1_IAU 
--JSDOHS1_IAU                    JSDOHS1_IAS_TEMP 
 
SET LONG 33333333
select dbms_metadata.get_ddl('TABLESPACE','JSDOHS1_IAU') FROM DUAL; 
 
--DBMS_METADATA.GET_DDL('TABLESPACE','JSDOHS1_IAU') 
-------------------------------------------------------------------------------- 
 
  CREATE TABLESPACE "JSDOHS1_IAU" DATAFILE 
  SIZE 62914560 
  AUTOEXTEND ON NEX 
 
 
 
 
 
--DBMS_METADATA.GET_DDL('TABLESPACE','JSDOHS1_IAU') 
-------------------------------------------------------------------------------- 
 
  CREATE TABLESPACE "JSDOHS1_IAU" DATAFILE 
  SIZE 62914560 
  AUTOEXTEND ON NEXT 62914560 MAXSIZE 32767M 
  LOGGING ONLINE PERMANENT BLOCKSIZE 8192 
  EXTENT MANAGEMENT LOCAL AUTOALLOCATE ENCRYPTION US 
ING 'AES128' DEFAULT 
 NOCOMPRESS STORAGE(ENCRYPT) SEGMENT SPACE MANAGEMENT AUTO 
 
 
select dbms_metadata.get_ddl('TABLESPACE','JSDOHS1_IAS_TEMP') FROM DUAL; 
 
--DBMS_METADATA.GET_DDL('TABLESPACE','JSDOHS1_IAS_TEMP') 
-------------------------------------------------------------------------------- 
 
  CREATE TEMPORARY TABLESPACE "JSDOHS1_IAS_TEMP" TEMPFILE 
  SIZE 104857600 
  AUTOEXTEND ON NEXT 52428800 MAXSIZE 32767 
  EXTENT MANAGEMENT LOCAL UNIFORM SIZE 1048576 
 
 
 
select username,DEFAULT_TABLESPACE,TEMPORARY_TABLESPACE from dba_users where account_status='OPEN' and username='JSDJMS1_IAU' ; 
 
USERNAME 
-------------------------------------------------------------------------------- 
DEFAULT_TABLESPACE             TEMPORARY_TABLESPACE 
------------------------------ ------------------------------ 
JSDJMS1_IAU 
JSDJMS1_IAU                    JSDJMS1_IAS_TEMP 
 
 
  CREATE TABLESPACE JSDJMS1 DATAFILE SIZE 62914560 AUTOEXTEND ON NEXT 62914560 MAXSIZE 32767M EXTENT MANAGEMENT LOCAL AUTOALLOCATE ENCRYPTION USING 'AES128' DEFAULT NOCOMPRESS STORAGE(ENCRYPT) SEGMENT SPACE MANAGEMENT AUTO; 

 
  CREATE TEMPORARY TABLESPACE JSDJMS1_TEMP TEMPFILE SIZE 104857600 AUTOEXTEND ON NEXT 52428800 MAXSIZE 32767M EXTENT MANAGEMENT LOCAL UNIFORM SIZE 1048576; 
 
  

-- From <https://onenote.officeapps.live.com/o/onenoteframe.aspx?ui=en-US&rs=en-IN&hid=Hs3Z3ltl8EumdxWqZ1ipCw.0&WOPISrc=https%3A%2F%2Fwopi.onedrive.com%2Fwopi%2Ffolders%2F27FE72D898B2FFAA%21621&wdo=6&wdorigin=701&sc=host%3D%26qt%3DFolders&mscc=1&wdp=0>


/*
#!/bin/bash

# Define database information
databases=("uatovm" "ofsasit" "devovm" "dmovm")
pdbs=("uatovmpdb" "ofsasitpdb" "devovmpdb" "dmovmpdb")

# Loop through each database
for ((i=0; i<${#databases[@]}; i++)); do
    database=${databases[i]}
    pdb=${pdbs[i]}

    # Connect to the database using sqlplus with TNS alias
    sqlplus username/password@${database} <<SQL
    -- Connect to the specified PDB
    ALTER SESSION SET CONTAINER=${pdb};

    -- Query tablespaces with auto-extend enabled
    SET PAGESIZE 1000;
    COLUMN tablespace_name FORMAT A20;
    COLUMN autoextensible FORMAT A15;
    SELECT tablespace_name, autoextensible, status
    FROM dba_tablespaces
    WHERE autoextensible = 'YES';

    -- Exit SQLPlus
    EXIT;
SQL
done





#!/bin/bash

# Define database information
databases=("uatovmpdb" "ofsasitpdb" "devovmpdb" "dmovmpdb")

# Loop through each database
for ((i=0; i<${#databases[@]}; i++)); do
    database=${databases[i]}
    
    # Connect to the database using sqlplus with TNS alias
    sqlplus system/welcome123@${database} <<SQL
    -- Connect to the specified PDB
    --ALTER SESSION SET CONTAINER=${pdb};
    -- Query tablespaces with auto-extend enabled
    SET PAGESIZE 1000;
    COLUMN tablespace_name FORMAT A20;
    COLUMN autoextensible FORMAT A15;
    SELECT tablespace_name, autoextensible, status
    FROM dba_tablespaces
    WHERE autoextensible = 'YES';
    -- Exit SQLPlus
    EXIT;
SQL
done

--=============================== 
--DATAFILES 
--=============================== 
 
SET LINES 333 PAGES 4444 
COL NAME FOR A80 
SELECT FILE#,NAME,BYTES FROM V$DATAFILE ORDER BY 1; 
 
SET LINES 333 PAGES 4444 
COL TABLESPACE_NAME FOR A15 
COL FILE_NAME FOR A70 
SELECT FILE_NO,TABLESPACE_NAME,FILE_NAME,AUTOEXTENSIBLE,BYTES/1024/1024/1024 GB FROM DBA_DATA_FILES WHERE TABLESPACE_NAME LIKE '&TBS' ORDER BY 1; 
 

--=============================== 
-- FLEXCUBE QUERIES
--=============================== 

--EOD BATCH TIMINGS

select eod_date,session_id sid,serial_no serial,branch_code brn_code,eoc_stage,eoc_batch,eoc_batch_status status,
to_char(start_time,'DD-MM-YYYY HH24:MI:SS') start_time,to_char(end_time,'DD-MM-YYYY HH24:MI:SS') end_time,
(24 * extract(day from (end_time - start_time) day(9) to second))+ extract(hour from (end_time - start_time) day(9) to second) as "Hours",
((extract(minute from (end_time - start_time) day(9) to second))+((1/100)*extract(second from (end_time - start_time) day(9) to second))) as "Min.Sec"
from flexar.aetb_eoc_programs_history
where EOD_DATE=to_date('02/04/2025','DD/MM/YYYY') 
and eoc_batch_status in ('C','W')
order by 10 desc,11 desc;

--Session activity

select inst_id ,action,sql_id,sql_plan_hash_value,event,session_state,count(1)
from gv$active_session_history 
where 
action like 'ACBSTVAL%' and
session_id = 5705  and 
session_serial#=60777  and
machine like '%createamountblockservice%' and
SAMPLE_TIME>to_timestamp('30-11-2021 02:29:44','DD-MM-YYYY HH24:MI:SS') and
SAMPLE_TIME<to_timestamp('30-11-2021 00:17:52','DD-MM-YYYY HH24:MI:SS') 
group by inst_id,action,sql_id,sql_plan_hash_value,event,session_state order by count(1) desc;

--Source of sql_id

select program_id from gv$sqlarea where sql_id='';
select object_name,object_id from dba_objects where object_id=''; --put program_id from previous query

--TABLE Size

WITH
T as
(select /*+ materialize */ table_name,round(sum(bytes)/1024/1024/1024,2) "TAB_SIZE"
from dba_tables t, dba_segments s 
where t.table_name=s.segment_name and t.owner='FLEXAR'
group by table_name order by 2 desc),
I as
(select /*+ materialize */ table_name,round(sum(bytes)/1024/1024/1024,2) "INDEX_SIZE"
from dba_indexes i, dba_segments s
where i.index_name=s.segment_name and i.owner='FLEXAR'
group by table_name order by 2 desc),
L as
(select /*+ materialize */ l.table_name,round(sum(bytes)/1024/1024/1024,2) "LOB_SIZE"
from dba_lobs l, dba_segments s
where l.segment_name=s.segment_name and l.owner='FLEXAR'
group by table_name order by 2 desc)
select T.table_name,T.TAB_SIZE,NVL(I.INDEX_SIZE,0) IND_SIZE,NVL(L.LOB_SIZE,0) LOB_SIZE,(T.TAB_SIZE+NVL(I.INDEX_SIZE,0)+NVL(L.LOB_SIZE,0)) TOTAL_SIZE
from T,I,L where T.table_name=I.table_name(+) and T.table_name=L.table_name(+)
order by 5 desc;

--transactions per miniearmark

 select /*+ PARALLEL 8 */ trunc(FCC_RECEIVE_TIME, 'MI'),count(1) from flexar.IFTB_acpst_mst_extgbl 
 where FCC_RECEIVE_TIME BETWEEN '29-NOV-2021 02:00:00 AM' AND  '29-NOV-2021 09:00:00 AM'
 group by trunc(FCC_RECEIVE_TIME, 'MI') order by 1 desc;

--troubleshooting miniearmark 
 
--time taken for insert iftb_acpst_dtl_extgbl F1
--time taken for insert iftb_acpst_mst_extgbl F2
--time taken for fn_build_type F3
--time taken for fn_default_validations_ear F4
--time taken for fn_dup_txn_earmarking F5
--time taken for Fn_bal_update F6
--time taken for fn_notif_table_insert F7
select  /*+  PARALLEL 16 */ REGEXP_substr(validation_log_timestamp,'[^ ]+',29,1) sid,

round(extract( second from
(to_timestamp(substr(substr(process_log_timestamp,instr(process_log_timestamp,'End insert in iftb_acpst_dtl_extgbl'),66),
(instr(substr(process_log_timestamp,instr(process_log_timestamp,'End insert in iftb_acpst_dtl_extgbl'),66),'>')+1),28), 'DD-MM-YYYY HH24:MI:SS:FF9')  -
to_timestamp(substr(substr(process_log_timestamp,instr(process_log_timestamp,'Start insert in iftb_acpst_dtl_extgbl'),68),
(instr(substr(process_log_timestamp,instr(process_log_timestamp,'Start insert in iftb_acpst_dtl_extgbl'),58),'>')+1),68), 'DD-MM-YYYY HH24:MI:SS:FF9') ) )*1000) F1,

round(extract( second from
(to_timestamp(substr(substr(process_log_timestamp,instr(process_log_timestamp,'End insert in iftb_acpst_mst_extgbl'),66),
(instr(substr(process_log_timestamp,instr(process_log_timestamp,'End insert in iftb_acpst_mst_extgbl'),66),'>')+1),28), 'DD-MM-YYYY HH24:MI:SS:FF9')  -
to_timestamp(substr(substr(process_log_timestamp,instr(process_log_timestamp,'Start insert in iftb_acpst_mst_extgbl'),68),
(instr(substr(process_log_timestamp,instr(process_log_timestamp,'Start insert in iftb_acpst_mst_extgbl'),68),'>')+1),28), 'DD-MM-YYYY HH24:MI:SS:FF9') ) )*1000) F2,

round(extract( second from
(to_timestamp(substr(substr(process_log_timestamp,instr(process_log_timestamp,'End fn_build_type'),48),
(instr(substr(process_log_timestamp,instr(process_log_timestamp,'End fn_build_type'),48),'>')+1),28), 'DD-MM-YYYY HH24:MI:SS:FF9')  -
to_timestamp(substr(substr(process_log_timestamp,instr(process_log_timestamp,'Start fn_build_type'),50),
(instr(substr(process_log_timestamp,instr(process_log_timestamp,'Start fn_build_type'),50),'>')+1),28), 'DD-MM-YYYY HH24:MI:SS:FF9') ) )*1000) F3,

round(extract( second from
(to_timestamp(substr(substr(process_log_timestamp,instr(process_log_timestamp,'End fn_default_validations_ear'),61),
(instr(substr(process_log_timestamp,instr(process_log_timestamp,'End fn_default_validations_ear'),63),'>')+1),28), 'DD-MM-YYYY HH24:MI:SS:FF9')  -
to_timestamp(substr(substr(process_log_timestamp,instr(process_log_timestamp,'Start fn_default_validations_ear'),61),
(instr(substr(process_log_timestamp,instr(process_log_timestamp,'Start fn_default_validations_ear'),63),'>')+1),28), 'DD-MM-YYYY HH24:MI:SS:FF9') ) )*1000) F4,

round(extract( second from
(to_timestamp(substr(substr(process_log_timestamp,instr(process_log_timestamp,'End fn_dup_txn_earmarking'),56),
(instr(substr(process_log_timestamp,instr(process_log_timestamp,'End fn_dup_txn_earmarking'),56),'>')+1),28), 'DD-MM-YYYY HH24:MI:SS:FF9')  -
to_timestamp(substr(substr(process_log_timestamp,instr(process_log_timestamp,'Start fn_dup_txn_earmarking'),58),
(instr(substr(process_log_timestamp,instr(process_log_timestamp,'Start fn_dup_txn_earmarking'),58),'>')+1),28), 'DD-MM-YYYY HH24:MI:SS:FF9') ) )*1000) F5,

round(extract( second from
(to_timestamp(substr(substr(process_log_timestamp,instr(process_log_timestamp,'End of Fn_bal_update'),51),
(instr(substr(process_log_timestamp,instr(process_log_timestamp,'End of Fn_bal_update'),51),'>')+1),28), 'DD-MM-YYYY HH24:MI:SS:FF9')  -
to_timestamp(substr(substr(process_log_timestamp,instr(process_log_timestamp,'Start of Fn_bal_update'),53),
(instr(substr(process_log_timestamp,instr(process_log_timestamp,'Start of Fn_bal_update'),53),'>')+1),28), 'DD-MM-YYYY HH24:MI:SS:FF9') ) )*1000) F6,

round(extract( second from
(to_timestamp(substr(substr(process_log_timestamp,instr(process_log_timestamp,'End of fn_notif_table_insert'),59),
(instr(substr(process_log_timestamp,instr(process_log_timestamp,'End of fn_notif_table_insert'),59),'>')+1),28), 'DD-MM-YYYY HH24:MI:SS:FF9')  -
to_timestamp(substr(substr(process_log_timestamp,instr(process_log_timestamp,'start of fn_notif_table_insert'),61),
(instr(substr(process_log_timestamp,instr(process_log_timestamp,'start of fn_notif_table_insert'),61),'>')+1),28), 'DD-MM-YYYY HH24:MI:SS:FF9') ) )*1000) F7,

to_char(fcc_receive_time,'HH24') HH, to_char(fcc_receive_time,'MI') MI, to_char(fcc_receive_time,'SS') SS,
fcc_receive_time,round(extract(second from (valid_end_time - fcc_receive_time)),2) secs,process_log_timestamp
 from flexar.iftb_acpst_mst_extgbl
where FCC_RECEIVE_TIME BETWEEN '17-NOV-2021 12:00:00 AM' AND  '12-NOV-2021 02:00:00 PM'
and MINIEARMK='Y' and extract(second from (valid_end_time - fcc_receive_time)) > 1 order by fcc_receive_time desc;

-- ================================
-- Partitions 
-- =================================
--? to check partition type and columns of a table
SELECT TABLE_NAME,PARTITIONING_TYPE,COLUMN_NAME FROM  USER_PART_TABLES pt JOIN USER_PART_KEY_COLUMNS pkc ON pt.TABLE_NAME = pkc.NAME
-- WHERE TABLE_NAME = 'YOUR_TABLE_NAME';
ORDER BY 1




--=============================== 
-- Index status 
--=============================== 


 SELECT TABLE_NAME,index_name,PARTITIONING_TYPE,LOCALITY,PARTITION_COUNT,ALIGNMENT FROM user_part_indexes 
 WHERE INDEX_NAME IN ('PK01_CSTB_DOC_UPLD_MASTER','PK01_CSZB_AUTO_SETTLE_BLOCK','PK01_STZM_CUST_DOMESTIC')



  SELECT TABLE_NAME,index_name,PARTITIONING_TYPE,LOCALITY,PARTITION_COUNT,ALIGNMENT FROM user_part_indexes 
 WHERE INDEX_NAME IN ('PK01_CSTB_DOC_UPLD_MASTER','PK01_CSZB_AUTO_SETTLE_BLOCK','PK01_STZM_CUST_DOMESTIC')
-- ================================
-- TABLE Partitions 
-- =================================
--! PARTITION CONVERTION .SH IS IN formatted.sh
--- ---------TO TRACK THE ACTIVITY----------------------
--? to identify the table realted to the views 
select substr(text_vc,instr(text_vc,' FROM')+6,length(text_vc)) from user_views where view_name in ('ACTB_DAILY_LOG')
--? in fcubs12c all the tables are the view names in the 14.7 onwards 
CREATE TABLE NV_CONVERT_12_TO_14 (
    table_con_id number,
    owner VARCHAR2(20),
    old_table_name VARCHAR2(30),
    new_table_name VARCHAR2(40),
    old_part_type VARCHAR2(10),
    new_part_type VARCHAR2(10),
    comp_part_type VARCHAR2(10),
    part_col VARCHAR2(20),
    tablespace1 VARCHAR2(20),
    tablespace2 VARCHAR2(20),
    FROM_MIG VARCHAR2(20),
    ARG1 VARCHAR2(20),
    convert_status VARCHAR2(10),
    ARG2 VARCHAR2(20),
    ARG3 VARCHAR2(20),
    ARG4 VARCHAR2(20)
);
--! TO UPDATE ABOVE TABLE -- CHECK VALUES AFTER UPDATE, SOME VALUES TO BE RE ADJUSTED 
UPDATE NV_CONVERT_12_TO_14 a
SET new_table_name = (
    SELECT SUBSTR(text_vc, INSTR(text_vc, ' FROM') + 6, LENGTH(text_vc))
    FROM user_views b
    WHERE b.view_name = a.old_table_name
    and a.new_table_name is null
);

UPDATE NV_CONVERT_12_TO_14 SET convert_status = 'CONVERTED' WHERE new_table_name IN (SELECT TABLE_NAME FROM user_part_tables) 
/



select * from NV_CONVERT_12_TO_14 
WHERE convert_status='PENDING' 
AND CMT='12 TO 14 AS PER BP'
AND comp_part_type='NO_CHANGE'
AND NEW_part_type='LIST'
/



--!---------------------------------------------------------------------------------------------
--! EXAMPLES
--!---------------------------------------------------------------------------------------------
--? ALL EXAMPLES ARE CUT WITH 1000 PARTITION IN ACTUAL TABLE
--! list
ALTER TABLE "ABFCUBSLIVE"."ACZB_HISTORY" MODIFY PARTITION BY LIST ("AC_BRANCH") 
(PARTITION "PART_001"  VALUES ('001') TABLESPACE "FCCDATAXLBF4" , 
 PARTITION "PART_002"  VALUES ('002') TABLESPACE "FCCDATAXLBF2" , 
 PARTITION "PART_003"  VALUES ('003') TABLESPACE "FCCDATAXLBF4" ,
 PARTITION "PART_DEFAULT"  VALUES (default) TABLESPACE "FCCDATAXLBF2" )  ENABLE ROW MOVEMENT ;
--! hash
SELECT 'ALTER TABLE ' || NEW_TABLE_NAME || ' MOVE TABLESPACE ' || TABLESPACE2 ||';'
SELECT 'ALTER TABLE ' || NEW_TABLE_NAME || ' MODIFY PARTITION BY HASH ('||PART_COL||') PARTITIONS 512 ENABLE ROW MOVEMENT ;'
ALTER TABLE SIZB_CONTRACT_MASTER MODIFY PARTITION BY HASH (USER_REFNO) PARTITIONS 256;
-- THIS WILL WORK WITH TABLE WITH LOB AS WELL

--! range
ALTER TABLE "ABFCUBSLIVE"."CLZB_ACCOUNT_EVENTS_DIARY" MODIFY
PARTITION BY RANGE ("BRANCH_CODE","PROCESS_NO") 
(
PARTITION "PART_001_1" VALUES LESS THAN ('001', 1),
PARTITION "PART_002_1" VALUES LESS THAN ('002', 1),
PARTITION "PART_003_1" VALUES LESS THAN ('003', 1),
PARTITION "PART_DEFAULT"  VALUES LESS THAN (MAXVALUE, MAXVALUE)  )  ENABLE ROW MOVEMENT ;


--!---------------------------------------------------------------------------------------------
--!---------------------------------------------------------------------------------------------




-- OUPUT OF THE QUERY LIKE BELOW 

-- CREATE INDEX "ABFCUBSLIVE"."INDEX_NAME" ON "ABFCUBSLIVE"."TABLE_NAME"  ("COL1", "COL2")    LOCAL TABLESPACE "TABLESAPCE_NAME" ;
 
-- index_name, TABLE_NAME, col details should be from below query

SELECT  INDEX_NAME, INDEX_OWNER, TABLE_NAME, LISTAGG(COLUMN_NAME, ', ') WITHIN GROUP (ORDER BY COLUMN_POSITION) AS COLUMN_NAMES
FROM  ALL_IND_COLUMNS
WHERE  INDEX_NAME in 
(SELECT INDEX_NAME FROM NV_IND_PART_TBS
WHERE  TO_BE_PART='YES' 
AND PART_STAT='NO') 
 AND INDEX_OWNER='ABFCUBSLIVE' 
GROUP BY  INDEX_NAME, INDEX_OWNER, TABLE_NAME;

-- TABLESAPCE_NAME should be from column ARG1 in table NV_IND_PART_TBS if its not null, if null the argument TABLESPACE "TABLESAPCE_NAME"  should not be in the out

-- if the UNIQUENESS column in dba_indexes for the same index is UNIQUE then CREATE INDEX should be like CREATE UNIQUE INDEX otherwise just CREATE INDEX

SELECT 
  'CREATE ' || 
  CASE WHEN di.uniqueness = 'UNIQUE' THEN 'UNIQUE ' ELSE '' END || 
  'INDEX "' || ic.INDEX_OWNER || '"."' || ic.INDEX_NAME || '" ON "' || ic.INDEX_OWNER || '"."' || ic.TABLE_NAME || '" (' || ic.COLUMN_NAMES || ')"' ||
  CASE WHEN nip.ARG1 IS NOT NULL THEN ' LOCAL TABLESPACE "' || nip.ARG1 || '"' ELSE '' END || ';' AS CREATE_INDEX_STMT
FROM 
  (SELECT 
     INDEX_NAME, 
     INDEX_OWNER, 
     TABLE_NAME, 
     LISTAGG(COLUMN_NAME, ', ') WITHIN GROUP (ORDER BY COLUMN_POSITION) AS COLUMN_NAMES
   FROM 
     ALL_IND_COLUMNS
   WHERE 
     INDEX_NAME IN (SELECT INDEX_NAME FROM NV_IND_PART_TBS WHERE TO_BE_PART='YES' AND PART_STAT='NO') 
     AND INDEX_OWNER='ABFCUBSLIVE' 
   GROUP BY 
     INDEX_NAME, INDEX_OWNER, TABLE_NAME) ic
LEFT JOIN 
  dba_indexes di ON ic.INDEX_NAME = di.INDEX_NAME AND ic.INDEX_OWNER = di.OWNER
LEFT JOIN 
  NV_IND_PART_TBS nip ON ic.INDEX_NAME = nip.INDEX_NAME;


--! ALSO GIVES DROP SCRIPT BEFORE CEEATE - NOT WOKS WITH UNIQUE INDEX

SELECT 
  'DROP INDEX "' || ic.INDEX_OWNER || '"."' || ic.INDEX_NAME || '";' ||
  'CREATE ' || 
  CASE WHEN di.uniqueness = 'UNIQUE' THEN 'UNIQUE ' ELSE '' END || 
  'INDEX "' || ic.INDEX_OWNER || '"."' || ic.INDEX_NAME || '" ON "' || ic.INDEX_OWNER || '"."' || ic.TABLE_NAME || '" (' || ic.COLUMN_NAMES || ')' ||
  CASE WHEN nip.ARG1 IS NOT NULL THEN ' LOCAL TABLESPACE "' || nip.ARG1 || '"' ELSE '' END || ';' AS CREATE_INDEX_STMT
FROM 
  (SELECT 
     INDEX_NAME, 
     INDEX_OWNER, 
     TABLE_NAME, 
     LISTAGG(COLUMN_NAME, ', ') WITHIN GROUP (ORDER BY COLUMN_POSITION) AS COLUMN_NAMES
   FROM 
     ALL_IND_COLUMNS
   WHERE 
     INDEX_NAME IN (SELECT INDEX_NAME FROM NV_IND_PART_TBS WHERE TO_BE_PART='YES' AND PART_STAT='NO') 
     AND INDEX_OWNER='ABFCUBSLIVE' 
   GROUP BY 
     INDEX_NAME, INDEX_OWNER, TABLE_NAME) ic
LEFT JOIN 
  dba_indexes di ON ic.INDEX_NAME = di.INDEX_NAME AND ic.INDEX_OWNER = di.OWNER
LEFT JOIN 
  NV_IND_PART_TBS nip ON ic.INDEX_NAME = nip.INDEX_NAME
  ORDER BY 1


-----------?--------------------Exclude unique 
SELECT 
  'DROP INDEX "' || ic.INDEX_OWNER || '"."' || ic.INDEX_NAME || '";' ||
  'CREATE ' || 
  CASE WHEN di.uniqueness = 'UNIQUE' THEN 'UNIQUE ' ELSE '' END || 
  'INDEX "' || ic.INDEX_OWNER || '"."' || ic.INDEX_NAME || '" ON "' || ic.INDEX_OWNER || '"."' || ic.TABLE_NAME || '" (' || ic.COLUMN_NAMES || ')' ||
  CASE WHEN nip.ARG1 IS NOT NULL THEN ' LOCAL TABLESPACE "' || nip.ARG1 || '"' ELSE '' END || ';' AS CREATE_INDEX_STMT
FROM 
  (SELECT 
     INDEX_NAME, 
     INDEX_OWNER, 
     TABLE_NAME, 
     LISTAGG(COLUMN_NAME, ', ') WITHIN GROUP (ORDER BY COLUMN_POSITION) AS COLUMN_NAMES
   FROM 
     ALL_IND_COLUMNS
   WHERE 
     INDEX_NAME IN (SELECT INDEX_NAME FROM NV_IND_PART_TBS WHERE TO_BE_PART='YES' AND PART_STAT='NO') 
     AND INDEX_OWNER='ABFCUBSLIVE' 
   GROUP BY 
     INDEX_NAME, INDEX_OWNER, TABLE_NAME) ic
LEFT JOIN 
  dba_indexes di ON ic.INDEX_NAME = di.INDEX_NAME AND ic.INDEX_OWNER = di.OWNER
LEFT JOIN 
  NV_IND_PART_TBS nip ON ic.INDEX_NAME = nip.INDEX_NAME
WHERE 
  di.uniqueness <> 'UNIQUE'  -- Add this line to exclude unique indexes
  OR di.uniqueness IS NULL;  -- Add this line to include indexes with no uniqueness defined

--- to receate the primary key tables 
--! THIS WILL NOT WORK COMPLETELY - WILL GET ERROR FOR THE PRIMARY KEY WHICH SHOULD BE CREATED WITHOUT GIVING "USING INDEX"
SELECT 
  'ALTER TABLE "' || ic.TABLE_NAME || '" DROP PRIMARY KEY;' ||
  'DROP INDEX "' || ic.INDEX_OWNER || '"."' || ic.INDEX_NAME || '";' ||
  'CREATE ' || 
  CASE WHEN di.uniqueness = 'UNIQUE' THEN 'UNIQUE ' ELSE '' END || 
  'INDEX "' || ic.INDEX_OWNER || '"."' || ic.INDEX_NAME || '" ON "' || ic.INDEX_OWNER || '"."' || ic.TABLE_NAME || '" (' || ic.COLUMN_NAMES || ')' ||
  CASE WHEN nip.ARG1 IS NOT NULL THEN ' LOCAL TABLESPACE "' || nip.ARG1 || '"' ELSE '' END || ';' ||
  'ALTER TABLE "' || ic.TABLE_NAME || '" ADD CONSTRAINT "' || dc.CONSTRAINT_NAME || '" PRIMARY KEY (' || ic.COLUMN_NAMES || ') USING INDEX "' || ic.INDEX_NAME || '";' AS CREATE_INDEX_STMT
FROM 
  (SELECT 
     INDEX_NAME, 
     INDEX_OWNER, 
     TABLE_NAME, 
     LISTAGG(COLUMN_NAME, ', ') WITHIN GROUP (ORDER BY COLUMN_POSITION) AS COLUMN_NAMES
   FROM 
     ALL_IND_COLUMNS
   WHERE 
     INDEX_NAME IN (SELECT INDEX_NAME FROM NV_IND_PART_TBS WHERE TO_BE_PART='YES' AND PART_STAT='NO') 
     AND INDEX_OWNER='ABFCUBSLIVE' 
   GROUP BY 
     INDEX_NAME, INDEX_OWNER, TABLE_NAME) ic
LEFT JOIN 
  dba_indexes di ON ic.INDEX_NAME = di.INDEX_NAME AND ic.INDEX_OWNER = di.OWNER
LEFT JOIN 
  NV_IND_PART_TBS nip ON ic.INDEX_NAME = nip.INDEX_NAME
LEFT JOIN 
  dba_constraints dc ON ic.INDEX_OWNER = dc.OWNER AND ic.INDEX_NAME = dc.CONSTRAINT_NAME
WHERE 
  di.uniqueness = 'UNIQUE' 
  AND dc.CONSTRAINT_TYPE = 'P';  -- Filter by unique indexes and partitioned indexes


--- to receate the UNIQUE key tables 
--! THIS WILL NOT WORK COMPLETELY - WILL GET ERROR FOR THE PRIMARY KEY WHICH SHOULD BE CREATED WITHOUT GIVING "USING INDEX"
SELECT 
  'ALTER TABLE "' || ic.TABLE_NAME || '" DROP PRIMARY KEY;' ||
  'DROP INDEX "' || ic.INDEX_OWNER || '"."' || ic.INDEX_NAME || '";' ||
  'CREATE ' || 
  CASE WHEN di.uniqueness = 'UNIQUE' THEN 'UNIQUE ' ELSE '' END || 
  'INDEX "' || ic.INDEX_OWNER || '"."' || ic.INDEX_NAME || '" ON "' || ic.INDEX_OWNER || '"."' || ic.TABLE_NAME || '" (' || ic.COLUMN_NAMES || ')' ||
  CASE WHEN nip.ARG1 IS NOT NULL THEN ' LOCAL TABLESPACE "' || nip.ARG1 || '"' ELSE '' END || ';' ||
  'ALTER TABLE "' || ic.TABLE_NAME || '" ADD CONSTRAINT "' || dc.CONSTRAINT_NAME || '" PRIMARY KEY (' || ic.COLUMN_NAMES || ') USING INDEX "' || ic.INDEX_NAME || '";' AS CREATE_INDEX_STMT
FROM 
  (SELECT 
     INDEX_NAME, 
     INDEX_OWNER, 
     TABLE_NAME, 
     LISTAGG(COLUMN_NAME, ', ') WITHIN GROUP (ORDER BY COLUMN_POSITION) AS COLUMN_NAMES
   FROM 
     ALL_IND_COLUMNS
   WHERE 
     INDEX_NAME IN (SELECT INDEX_NAME FROM NV_IND_PART_TBS WHERE TO_BE_PART='YES' AND PART_STAT='NO') 
     AND INDEX_OWNER='ABFCUBSLIVE' 
   GROUP BY 
     INDEX_NAME, INDEX_OWNER, TABLE_NAME) ic
LEFT JOIN 
  dba_indexes di ON ic.INDEX_NAME = di.INDEX_NAME AND ic.INDEX_OWNER = di.OWNER
LEFT JOIN 
  NV_IND_PART_TBS nip ON ic.INDEX_NAME = nip.INDEX_NAME
LEFT JOIN 
  dba_constraints dc ON ic.INDEX_OWNER = dc.OWNER AND ic.INDEX_NAME = dc.CONSTRAINT_NAME
WHERE 
  di.uniqueness = 'UNIQUE' 
  AND dc.CONSTRAINT_TYPE = 'U';  -- Filter by unique indexes and partitioned indexes




--! THIS WILL NOT WORK COMPLETELY - WILL GET ERROR FOR THE PRIMARY KEY WHICH SHOULD BE CREATED WITHOUT GIVING "USING INDEX"
SELECT 
  'ALTER TABLE "' || ic.TABLE_NAME || '" DROP PRIMARY KEY;' ||
  'DROP INDEX "' || ic.INDEX_OWNER || '"."' || ic.INDEX_NAME || '";' ||
  'CREATE ' || 
  CASE WHEN di.uniqueness = 'UNIQUE' THEN 'UNIQUE ' ELSE '' END || 
  'INDEX "' || ic.INDEX_OWNER || '"."' || ic.INDEX_NAME || '" ON "' || ic.INDEX_OWNER || '"."' || ic.TABLE_NAME || '" (' || ic.COLUMN_NAMES || ')' ||
  CASE WHEN nip.ARG1 IS NOT NULL THEN ' LOCAL TABLESPACE "' || nip.ARG1 || '"' ELSE '' END || ';' ||
  'ALTER TABLE "' || ic.TABLE_NAME || '" ADD CONSTRAINT "' || dc.CONSTRAINT_NAME || '" PRIMARY KEY (' || ic.COLUMN_NAMES || ') USING INDEX "' || ic.INDEX_NAME || '";' AS CREATE_INDEX_STMT
FROM 
  (SELECT 
     INDEX_NAME, 
     INDEX_OWNER, 
     TABLE_NAME, 
     LISTAGG(COLUMN_NAME, ', ') WITHIN GROUP (ORDER BY COLUMN_POSITION) AS COLUMN_NAMES
   FROM 
     DBA_IND_COLUMNS
   WHERE 
     INDEX_NAME IN (SELECT INDEX_NAME FROM NV_IND_PART_TBS WHERE TO_BE_PART='YES' AND PART_STAT='NO') 
     AND INDEX_OWNER='ABFCUBSLIVE' 
   GROUP BY 
     INDEX_NAME, INDEX_OWNER, TABLE_NAME) ic
LEFT JOIN 
  dba_indexes di ON ic.INDEX_NAME = di.INDEX_NAME AND ic.INDEX_OWNER = di.OWNER
LEFT JOIN 
  NV_IND_PART_TBS nip ON ic.INDEX_NAME = nip.INDEX_NAME
LEFT JOIN 
  dba_constraints dc ON ic.INDEX_OWNER = dc.OWNER AND ic.INDEX_NAME = dc.CONSTRAINT_NAME
WHERE 
  di.uniqueness = 'UNIQUE' 
  AND dc.CONSTRAINT_TYPE = 'U';  -- Filter by unique indexes and partitioned indexes

--------------------
-- for unique indexe  

ALTER TABLE STZM_CUSTOMER DROP CONSTRAINT UK01_STZM_CUSTOMER;





























  
  
  ALTER TABLE STZM_CUST_ACCOUNT DROP PRIMARY KEY;
  
  drop index PK01_STZM_CUST_ACCOUNT;
  
  CREATE UNIQUE INDEX "ABFCUBSLIVE"."PK01_STZM_CUST_ACCOUNT" ON "ABFCUBSLIVE"."STZM_CUST_ACCOUNT"  ("BRANCH_CODE", "CUST_AC_NO")    LOCAL TABLESPACE "FCCINDXXL" ;
  
  Alter table STZM_CUST_ACCOUNT add constraint PK01_STZM_CUST_ACCOUNT primary key  ("BRANCH_CODE", "CUST_AC_NO")   using index PK01_STZM_CUST_ACCOUNT;
  
  Alter table ACZB_HISTORY add constraint PK01_ACZB_HISTORY primary key  ("AC_ENTRY_SR_NO")  using index PK01_ACZB_HISTORY;
  
  





-- Sample Partitions


--============================== 
-- INDEX PARTITION PARTITIONED 
--============================== 
set echo on feed on timing on time on

CREATE TABLE NV_MIG2_TBL (
    TABLE_NAME VARCHAR2(50),
    TABLE_NAME_14 VARCHAR2(50),
    ARG1 VARCHAR2(50),
    ARG2 VARCHAR2(50),
    ARG3 VARCHAR2(50),
    ARG4 VARCHAR2(50),
    ARG5 VARCHAR2(50),
    ARG6 VARCHAR2(50),
    ARG7 VARCHAR2(50),
    ARG8 VARCHAR2(50),
    ARG9 VARCHAR2(50)
);


CREATE TABLE NV_BP_TABLESPACES (
    TABLE_NAME VARCHAR2(50),
    TBL_TABLESPACE VARCHAR2(30),
    IND_TABLESPACE VARCHAR2(30),
    ARG1 VARCHAR2(20),
    ARG2 VARCHAR2(20),
    ARG3 VARCHAR2(20),
    ARG4 VARCHAR2(20),
    ARG5 VARCHAR2(20),
    ARG6 VARCHAR2(10),
    ARG7 VARCHAR2(20),
    ARG8 VARCHAR2(20),
    ARG9 VARCHAR2(20)
);


CREATE TABLE NV_BP_IND_PART (
    TABLE_NAME VARCHAR2(50),
    INDEX_NAME VARCHAR2(30),
    PART_TYPE VARCHAR2(30),
    PART_COL VARCHAR2(20),
    ARG1 VARCHAR2(20),
    ARG2 VARCHAR2(20)
);


DROP TABLE NV_IND_COL;
CREATE TABLE NV_IND_COL  (
    INDEX_NAME VARCHAR2(100),
    INDEX_OWNER VARCHAR2(100),
    TABLE_NAME VARCHAR2(100),
    COLUMN_NAME VARCHAR2(300),
    PARTITIONED VARCHAR2(100),
    ARG1 VARCHAR2(100),
    ARG2 VARCHAR2(100),
    ARG3 VARCHAR2(100),
    ARG4 VARCHAR2(100),
    ARG5 VARCHAR2(100)
);

INSERT INTO NV_IND_COL (INDEX_NAME, INDEX_OWNER, TABLE_NAME, COLUMN_NAME)
SELECT 
     INDEX_NAME, 
     INDEX_OWNER, 
     TABLE_NAME, 
     LISTAGG(COLUMN_NAME, ', ') WITHIN GROUP (ORDER BY COLUMN_POSITION) AS COLUMN_NAMES
FROM 
     ALL_IND_COLUMNS
WHERE 
     INDEX_OWNER = 'ABFCUBSLIVE' 
GROUP BY 
     INDEX_NAME, INDEX_OWNER, TABLE_NAME;
COMMIT;


INSERT INTO NV_BP_IND_PART (TABLE_NAME, INDEX_NAME, PART_TYPE, PART_COL) VALUES () ;



CREATE TABLE NV_IND_PART_TBS (
    TABLE_NAME VARCHAR2(50),
    INDEX_NAME VARCHAR2(50),
    CURRENT_TBS VARCHAR2(30),
    PART_STAT VARCHAR2(20),
    TO_BE_PART VARCHAR2(20),
    STATUS VARCHAR2(30),
    ARG1 VARCHAR2(20),
    ARG2 VARCHAR2(20),
    ARG3 VARCHAR2(10),
    ARG4 VARCHAR2(20),
    ARG5 VARCHAR2(20),
    ARG6 VARCHAR2(20),
    ARG7 VARCHAR2(20),
    ARG8 VARCHAR2(20),
    ARG9 VARCHAR2(20)
);


 
INSERT INTO NV_IND_PART_TBS (TABLE_NAME, CURRENT_TBS, INDEX_NAME, PART_STAT)
SELECT TABLE_NAME, TABLESPACE_NAME, INDEX_NAME, PARTITIONED
FROM DBA_INDEXES 
WHERE TABLE_OWNER = 'ABFCUBSLIVE';

commit;


--! BELOW WILL LIST TABLES WHICH ARE NOT PARTITIONED AND AVAILABLE IN DATABASE

select 'ALTER TABLE ABFCUBSLIVE.'||TABLE_NAME||' MOVE TABLESPACE '||TBL_TABLESPACE||' ;'
from ABFCUBSLIVE.NV_BP_TABLESPACES 
where TABLE_NAME NOT in 
(select NEW_TABLE_NAME from ABFCUBSLIVE.NV_CONVERT_12_TO_14 
where NEW_TABLE_NAME is not null 
and  CONVERT_STATUS ='CONVERTED'
AND CMT NOT LIKE '%NOT AVAILABLE%')
AND TABLE_NAME IN (SELECT TABLE_NAME FROM DBA_TABLES )

-------------------

SELECT count(*)  FROM user_part_tables;

SELECT table_name, partitioning_type, ref_ptn_constraint_name
 FROM user_part_tables
 WHERE table_name IN ('CLTB_ACCOUNT_APPS_MASTER');

 SELECT table_name, partition_name, high_value
 FROM user_tab_partitions
 WHERE table_name in ('PROJECT','PROJECT_CUSTOMER')
 ORDER BY table_name, partition_position;



SELECT 'ALTER TABLE ' || NEW_TABLE_NAME || ' MOVE TABLESPACE ' || TABLESPACE2 ||';'
SELECT 'ALTER TABLE ' || NEW_TABLE_NAME || ' MODIFY PARTITION BY HASH ('||PART_COL||') PARTITIONS 512 ENABLE ROW MOVEMENT ;'

ALTER TABLE GEZB_UTILS MODIFY PARTITION BY HASH (USER_REFNO) PARTITIONS 256;


ALTER INDEX PK01_SMZB_SMS_LOG MODIFY PARTITION BY HASH (SEQUENCE_NO) ;

CREATE INDEX PK01_SMZB_SMS_LOG ON SMTB_SMS_LOG (SEQUENCE_NO) LOCAL;



SELECT
    cols.table_name,
    cols.column_name,
    tabs.partitioning_type
FROM
    all_tab_columns cols
JOIN
    all_part_tables tabs
ON
    cols.table_name = tabs.table_name
WHERE
    cols.owner = 'ABFCUBSLIVE'
ORDER BY 1,2
------------------?----------------------------------------------
------------------?----------------------------------------------
--! IF THE old table pave primary key exists, only then the online redefinition will work
-- Create an interim table
CREATE TABLE GEZB_UTILS_NPT
PARTITION BY HASH (USER_REFNO )
PARTITIONS 256
AS
SELECT * FROM old_table WHERE 1=2;



-- Start the redefinition process
BEGIN
   DBMS_REDEFINITION.start_redef_table(
      uname => 'schema',
      orig_table => 'old_table',
      int_table => 'new_table');
END;
/

-- Copy the data
INSERT INTO new_table SELECT * FROM old_table;

-- Complete the redefinition
BEGIN
   DBMS_REDEFINITION.finish_redef_table(
      uname => 'schema',
      orig_table => 'old_table',
      int_table => 'new_table');
END;
/

-- Drop the old table
DROP TABLE old_table;

-- Rename the new table to the old table's name
ALTER TABLE new_table RENAME TO old_table;
--! offline redefinition
-- Create an interim table
CREATE TABLE GEZB_UTILS_NPT
PARTITION BY HASH (USER_REFNO )
PARTITIONS 256
AS
SELECT * FROM old_table WHERE 1=2;



ALTER TRIGGER trigger_name DISABLE;


INSERT INTO new_table SELECT * FROM old_table;


ALTER TRIGGER trigger_name ENABLE;



DROP TABLE old_table;
ALTER TABLE new_table RENAME TO old_table;



----
SELECT 'ALTER TRIGGER ' || trigger_name || ' DISABLE;' 
FROM user_triggers
WHERE table_name = 'YOUR_TABLE_NAME';


SELECT 'ALTER TRIGGER ' || trigger_name || ' ENABLE;' 
FROM user_triggers
WHERE table_name = 'YOUR_TABLE_NAME';



ALTER TABLE old_table ADD (new_column NUMBER);
UPDATE old_table SET new_column = ROWNUM;
ALTER TABLE old_table ADD CONSTRAINT pk_old_table PRIMARY KEY (new_column);
-----

--- -------------------------------
--- checking DEPENDENCIES
--- -------------------------------

--! query starts 

-- Dependent views
SELECT NAME, TYPE, REFERENCED_NAME, REFERENCED_TYPE 
FROM USER_DEPENDENCIES 
WHERE REFERENCED_NAME = 'ACZB_DAILY_LOG' 
AND REFERENCED_TYPE = 'TABLE' 
AND TYPE = 'VIEW'

UNION ALL

-- Dependent procedures, functions, and packages
SELECT NAME, TYPE, REFERENCED_NAME, REFERENCED_TYPE 
FROM USER_DEPENDENCIES 
WHERE REFERENCED_NAME = 'ACZB_DAILY_LOG' 
AND REFERENCED_TYPE = 'TABLE' 
AND TYPE IN ('PROCEDURE', 'FUNCTION', 'PACKAGE')

UNION ALL

-- Dependent triggers
SELECT NAME, TYPE, REFERENCED_NAME, REFERENCED_TYPE 
FROM USER_DEPENDENCIES 
WHERE REFERENCED_NAME = 'ACZB_DAILY_LOG' 
AND REFERENCED_TYPE = 'TABLE' 
AND TYPE = 'TRIGGER'

UNION ALL

-- Dependent constraints
SELECT CONSTRAINT_NAME AS NAME, CONSTRAINT_TYPE AS TYPE, TABLE_NAME AS REFERENCED_NAME, 'TABLE' AS REFERENCED_TYPE 
FROM USER_CONSTRAINTS 
WHERE TABLE_NAME = 'ACZB_DAILY_LOG'

UNION ALL

-- Dependent indexes
SELECT INDEX_NAME AS NAME, 'INDEX' AS TYPE, TABLE_NAME AS REFERENCED_NAME, 'TABLE' AS REFERENCED_TYPE 
FROM USER_INDEXES 
WHERE TABLE_NAME = 'ACZB_DAILY_LOG';


--! query ends

SELECT 'ALTER INDEX '||INDEX_NAME||' REBUILD ONLINE; '
FROM dba_indEXES
WHERE  OWNER='ABFCUBSLIVE'
and status='UNUSABLE'
 

DECLARE
  v_sql VARCHAR2(1000);
BEGIN
  FOR index_rec IN (SELECT INDEX_NAME
                    FROM dba_indexes
                    WHERE OWNER='ABFCUBSLIVE'
                    AND status='UNUSABLE')
  LOOP
    BEGIN
      v_sql := 'ALTER INDEX ' || index_rec.INDEX_NAME || ' REBUILD ONLINE';
      EXECUTE IMMEDIATE v_sql;
      DBMS_OUTPUT.PUT_LINE('Index ' || index_rec.INDEX_NAME || ' successfully rebuilt online.');
    EXCEPTION
      WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Error rebuilding index ' || index_rec.INDEX_NAME || ': ' || SQLERRM);
    END;
  END LOOP;
END;
/



DECLARE
  v_sql VARCHAR2(1000);
BEGIN
  FOR index_rec IN (SELECT INDEX_NAME
                    FROM dba_indexes
                    WHERE OWNER='FCUBSLIVE'
                    AND status='UNUSABLE'
                    )
  LOOP
    BEGIN
      v_sql := 'ALTER INDEX ' || index_rec.INDEX_NAME || ' REBUILD ONLINE';
      EXECUTE IMMEDIATE v_sql;
      DBMS_OUTPUT.PUT_LINE('Index ' || index_rec.INDEX_NAME || ' successfully rebuilt online.');
    EXCEPTION
      WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Error rebuilding index ' || index_rec.INDEX_NAME || ': ' || SQLERRM);
    END;
  END LOOP;
END;
/




--============================== 
-- INDEX PARTITION PARTITIONED 
--============================== 

CREATE TABLE NV_INDEX_TBS (
    con_id number,
    owner VARCHAR2(20),
    index_name VARCHAR2(30),
    part_type VARCHAR2(50),
    part_col VARCHAR2(10),
    tablespace1 VARCHAR2(10),
    status VARCHAR2(10),
    ARG1 VARCHAR2(20),
    ARG2 VARCHAR2(20),
    ARG3 VARCHAR2(20),
    ARG4 VARCHAR2(20),
    ARG5 VARCHAR2(20),
    ARG6 VARCHAR2(10)
    ARG7 VARCHAR2(20)
    ARG8 VARCHAR2(20)
    ARG9 VARCHAR2(20)
);


-- To rebuild unusable partition indexes with exception

SELECT 'ALTER INDEX '||INDEX_NAME|| ' REBUILD PARTITION '||PARTITION_NAME||' ;' FROM dba_ind_partitions WHERE INDEX_NAME='ACTB_HISTORY'

DECLARE
  v_sql VARCHAR2(4000);
BEGIN
  FOR partition_rec IN (SELECT INDEX_NAME, PARTITION_NAME
                        FROM dba_ind_partitions
                        WHERE INDEX_OWNER = 'FCUBSLIVE'
                        AND STATUS = 'UNUSABLE'
                        AND TABLE_NAME='ACTB_HISTORY')
  LOOP
    v_sql := 'ALTER INDEX ' || partition_rec.INDEX_NAME || ' REBUILD PARTITION ' || partition_rec.PARTITION_NAME;
    BEGIN
      EXECUTE IMMEDIATE v_sql;
    EXCEPTION
      WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Error rebuilding partition ' || partition_rec.PARTITION_NAME || ' of index ' || partition_rec.INDEX_NAME || ': ' || SQLERRM);
    END;
  END LOOP;
END;
/


DECLARE
  v_sql VARCHAR2(4000);
BEGIN
  FOR partition_rec IN (SELECT INDEX_NAME, PARTITION_NAME
                        FROM dba_ind_partitions
                        WHERE INDEX_OWNER = 'FCUBSLIVE'
                        AND STATUS = 'UNUSABLE'
                        )
  LOOP
    v_sql := 'ALTER INDEX ' || partition_rec.INDEX_NAME || ' REBUILD PARTITION ' || partition_rec.PARTITION_NAME;
    BEGIN
      EXECUTE IMMEDIATE v_sql;
    EXCEPTION
      WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Error rebuilding partition ' || partition_rec.PARTITION_NAME || ' of index ' || partition_rec.INDEX_NAME || ': ' || SQLERRM);
    END;
  END LOOP;
END;
/








  DECLARE
  v_sql VARCHAR2(4000);
BEGIN
  FOR partition_rec IN (SELECT INDEX_NAME, PARTITION_NAME
                        FROM dba_ind_partitions
                        WHERE INDEX_OWNER = 'ABFCUBSLIVE' and INDEX_NAME in (select index_name FROM dba_indexes where table_name NOT IN ('CSZB_AUTO_SETTLE_BLOCK','ICZB_ENTRIES','ICZB_UDVALS','STZM_CUSTOMER'))
                        AND STATUS = 'UNUSABLE')
  LOOP
    v_sql := 'ALTER INDEX ' || partition_rec.INDEX_NAME || ' REBUILD PARTITION ' || partition_rec.PARTITION_NAME;
    BEGIN
      EXECUTE IMMEDIATE v_sql;
    EXCEPTION
      WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Error rebuilding partition ' || partition_rec.PARTITION_NAME || ' of index ' || partition_rec.INDEX_NAME || ': ' || SQLERRM);
    END;
  END LOOP;
END;
/





SELECT 'ALTER INDEX '||INDEX_NAME||' REBUILD PARTITION '||PARTITION_NAME||';'
FROM dba_ind_partitions
WHERE  INDEX_OWNER='ABFCUBSLIVE'
and status='UNUSABLE'
and INDEX_NAME='UX01_ICZB_UDEVALS'

SELECT 'ALTER INDEX '||INDEX_NAME||' REBUILD ONLINE; '
FROM dba_indEXES
WHERE  OWNER='ABFCUBSLIVE'
and status='UNUSABLE'
 


--============================== 
--CDB DIRECTORIES 
--============================== 
 
SET LINES 333 PAGES 4444 
COL OWNER FOR a15 
col DIRECTORY_NAME for a25 
Col DIRECTORY_PATH for a70 
 
select * from cdb_directories 
/ 
 

--there was a database and its standby configured with data guard, 
--i was maintaining both , but while trying to open the db as snapshot stanby for testing , it is noticed that .... <text loss>...

SET LINES 333 PAGES 4444 
COL OWNER FOR a15 
col DIRECTORY_NAME for a25 
Col DIRECTORY_PATH for a70 
select * from dba_directories 
/ 

--============================== 
-- SGA PGA Calculations 
--============================== 

COLUMN finding_time      FOR a20    HEAD 'Finding Time'
COLUMN current_target_mb FOR 999,999 HEAD 'Current SGA|Target (MB)'
COLUMN advised_target_mb FOR 999,999 HEAD 'Advised SGA|Target (MB)'

BREAK ON REPORT
COMPUTE maximum LABEL 'Recommended Min. SGA' OF advised_target_mb ON report

SELECT TO_CHAR( al.execution_start, 'dd Mon yyyy HH24:MI:SS') AS finding_time,
       aa.num_attr1/1048576 AS current_target_mb,
       aa.num_attr2/1048576 AS advised_target_mb
  FROM dba_advisor_actions  aa,
       dba_advisor_findings af,
       dba_advisor_log      al
 WHERE 1=1
   AND al.owner          = af.owner
   AND al.task_name      = af.task_name
   AND aa.owner          = af.owner
   AND aa.task_name      = af.task_name
   AND aa.execution_name = af.execution_name
   AND af.finding_name   = 'Undersized SGA'
   AND aa.attr1          = 'sga_target'
 ORDER
    BY al.execution_start
;
 

COLUMN finding_time      FOR a20    HEAD 'Finding Time'
COLUMN current_target_mb FOR 999,999 HEAD 'Current PGA|Target (MB)'
COLUMN advised_target_mb FOR 999,999 HEAD 'Advised PGA|Target (MB)'

BREAK ON REPORT
COMPUTE maximum LABEL 'Recommended Min. PGA' OF advised_target_mb ON report

SELECT TO_CHAR( al.execution_start, 'dd Mon yyyy HH24:MI:SS') AS finding_time,
       aa.num_attr1/1048576 AS current_target_mb,
       aa.num_attr2/1048576 AS advised_target_mb
  FROM dba_advisor_actions  aa,
       dba_advisor_findings af,
       dba_advisor_log      al
 WHERE 1=1
   AND al.owner          = af.owner
   AND al.task_name      = af.task_name
   AND aa.owner          = af.owner
   AND aa.task_name      = af.task_name
   AND aa.execution_name = af.execution_name
   AND af.finding_name   = 'Undersized PGA'
   AND aa.attr1          = 'pga_aggregate_target'
 ORDER
    BY al.execution_start
;
 
 
--=========================== 
--Nls date 
--=========================== 
alter session set nls_date_format='DD-MM-YY HH24:MI'; 
alter session set nls_date_format='DD-MM-YY HH24:MI:SS'; 
 

 
--========================== 
--BLOCKING - SESSION DETAILS 
--========================== 
 
SET LINES 333 PAGES 4444 
col BLOCKER for a10 
col BLOCKEE for a10 
 
select 
(select username from v$session where sid=a.sid) blocker, 
a.sid,' is blocking ',(select username from v$session where sid=b.sid) blockee,b 
.sid 
from v$lock a, v$lock b 
where a.block = 1 
and b.request > 0 
and a.id1 = b.id1 
and a.id2 = b.id2; 
-- rac
select 
(select username from gv$session where sid=a.sid) blocker, 
a.sid,' is blocking ',(select username from gv$session where sid=b.sid) blockee,b 
.sid 
from gv$lock a, gv$lock b 
where a.block = 1 
and b.request > 0 
and a.id1 = b.id1 
and a.id2 = b.id2; 
 
SET LINES 333 PAGES 4444  
col owner for a10 
col object_name for a20 
col object_type for a20 
col sid for 99999 
col serial# for 999999999 
col status for a10 
col osuser for a10   
col machine for a10   

select c.owner,c.object_name,c.object_type,b.sid,b.serial#,b.status,b.osuser,b.machine
from gv$locked_object a ,gv$session b,dba_objects c
where b.sid = a.session_id 
and a.object_id = c.object_id;



COLUMN "Object Owner" FORMAT A10
COLUMN "Object Name" FORMAT A30
COLUMN "Object Type" FORMAT A15
COLUMN "Locked Session ID" FORMAT 9999
COLUMN "Locked Serial Number" FORMAT 99999
COLUMN "Locked Session Status" FORMAT A10
COLUMN "Locked Session OS User" FORMAT A15
COLUMN "Locked Session Machine" FORMAT A20
COLUMN "Blocking Session ID" FORMAT 9999
COLUMN "Blocking Serial Number" FORMAT 99999
COLUMN "Blocking Session Status" FORMAT A10
COLUMN "Blocking Session OS User" FORMAT A15
COLUMN "Blocking Session Machine" FORMAT A20

SELECT c.owner AS "Object Owner",
       c.object_name AS "Object Name",
       c.object_type AS "Object Type",
       b.sid AS "Locked Session ID",
       b.serial# AS "Locked Serial Number",
       b.status AS "Locked Session Status",
       b.osuser AS "Locked Session OS User",
       b.machine AS "Locked Session Machine",
       bs.sid AS "Blocking Session ID",
       bs.serial# AS "Blocking Serial Number",
       bs.status AS "Blocking Session Status",
       bs.osuser AS "Blocking Session OS User",
       bs.machine AS "Blocking Session Machine"
FROM gv$locked_object a
JOIN gv$session b ON b.sid = a.session_id
JOIN dba_objects c ON a.object_id = c.object_id
LEFT JOIN gv$session bs ON b.blocking_session = bs.sid;



-- SQL from SID


select  sql.sql_text
      from   v$session ses, v$sqltext sql
      where sql.address=ses.sql_address
      and     sql.hash_value=ses.sql_hash_value
      and     sid=&session_ida
      order   by piece;


------------------------
 
select 
(select username from gv$session where sid=a.sid) blocker, 
a.sid,' is blocking ',(select username from gv$session where sid=b.sid) blockee,b 
.sid 
from gv$lock a, gv$lock b 
where a.block = 1 
and b.request > 0 
and a.id1 = b.id1 
and a.id2 = b.id2; 
 
-- test

SELECT a.sql_text, b.sql_hash_value ,b.status,b.sql_id
FROM   gv$sqltext a, 
       gv$session b 
WHERE  a.address = b.sql_address 
AND    a.hash_value = b.sql_hash_value 
AND    b.sid = &1 
ORDER BY a.piece; 

-- =============================
-- DBA_SEGMENTS
-- =============================
SET LINES 333 PAGES 4444
COL SEGMENT_NAME FOR A40

SELECT SEGMENT_NAME, ROUND(SUM(BYTES/1024/1024/1024),2) AS GB
FROM DBA_segments  
WHERE OWNER LIKE 'ABUBSMIG1' 
AND SEGMENT_TYPE='INDEX'  
GROUP BY SEGMENT_NAME
HAVING SUM(BYTES/1024/1024/1024) > 2
ORDER BY 2 DESC, 1;






-- =============================
-- Resource limit
-- =============================
set lines 333 pages 4444
col RESOURCE_NAME for a40
col INITIAL_ALLOCATION for A20
col LIMIT_VALUE for a20
select * from v$resource_limit;


 
--============================== 
--CDB - SERVICE NAME MAPPINGS 
--============================== 
set lines 333 pages 4444 
Col name for a30 
Col pdb for a30 
select service_id,name,pdb,con_id from cdb_services order by con_id 
/ 


CITM ENTRIES 
CITM ENTRIES HISTORY

--================================= 
--INACTIVE - SESSION DETAILS 
--=========================== 
-- https://oracle-base.com/articles/misc/killing-oracle-sessions

ALTER SYSTEM CANCEL SQL 'SID, SERIAL[, @INST_ID][, SQL_ID]';


select 'alter system kill session '''||sid||','|| serial#||''' IMMEDIATE;' from v$session WHERE TYPE='USER' and last_call_et> 1000 and status='INACTIVE' 
/ 


 select 'alter system kill session '''||sid||','|| serial#||',@'||inst_id||''' IMMEDIATE;'  from gv$session WHERE TYPE='USER' and last_call_et> 1000 and status='INACTIVE'
 from gv$session WHERE sid in (select sid from gv$access where OBJECT='GETM_LIAB');

 select 'alter system kill session '''||sid||','|| serial#||',@'||inst_id||''' IMMEDIATE;' FROM gv$session WHERE sid in (select sid from gv$access where OBJECT='EIPKS');
 -- from gv$session WHERE TYPE='USER' and  USERNAME='ABFCUBSLIVE';
 from gv$session WHERE OSUSER !='Padmanabhanv.y' in (select sid from gv$access where OBJECT='EIPKS');

select 'alter system kill session '''||sid||','|| serial#||',@'||inst_id||''' IMMEDIATE;' 
FROM gv$session 
WHERE sid in 
(select sid from gv$access where OBJECT in ('ACPKS_UTILS',
'ACPKSS_UTILS',
'ACPKS_UTILS',
'ICPKS_ICDREDMN_KERNEL',
'STPKS_STCCUACC_KERNEL',
'ICPKS_ICDOLIQ_KERNEL',
'MSPKS_ISO',
'ICPKS_ICDREDRN_KERNEL',
'STPKS_STDCUSAC_UTILS_2',
'PKG_CLDMDSBR',
'CLPKS_CLDCMTMT_UTILS_1',
'DEPKS_RETAILTELLERUPLOAD',
'IFPKS_EPS_INTERFACE',
'CIPKS_CIDTKFVM_UTILS',
'ACPKS_EOD',
'ACPKS_DEFERRED',
'CLPKS_MADC',
'CLPKS_EVENTSDIARY',
'EIPKS',
'STPKS_STDCUSAC_MAIN',
'TAPKS_TADFATRF_KERNEL',
'CLPKS_CLDFGDSB_KERNEL',
'GWPKS_CI_ACCOUNTSERVICE',
'CLPKS_ACC_VALS',
'STPKS_STDFIACC_KERNEL',
'CLPKS_PAYMENT',
'ACPKS',
'CSPKS_BRANCH_TRANSFER',
'CSPKS_ACC_SERVICE',
'CSPKS_CSDJBBRW_KERNEL',
'CSPKS_FCJ_CSDJOBBR',
'IAPKS_IADREDMN_KERNEL',
'STPKS_ACCOUNT_CLOSE',
'ACPKS_ACDENTRY_KERNEL',
'WRP_BATCH',
'CIPKS_CIDACCNT_VALIDATE',
'PKG_CLDACCDT',
'IC_ONLIQ',
'MFPKS_MFDBLKPT_UTILS',
'CLPKS_SPLITROLL',
'ICPKS_ONLIQ_NEW',
'CLPKS_CLDINSQR_KERNEL',
'STPKS_STDCUSAC_KERNEL',
'GIPKS_FACUPLD_FACUPLD_CSV',
'GIPKS_FACUPLD_FACUPLD_CSV'));


set lines 333 pages 4444 
col username for a30 
col machine for a30 
select inst_id,username,machine,status,count(*) from gv$session group by inst_id,username,machine,status order by 1,2,3; 
 
sh incative_kill.sh 
sqlplus / as sysdba << eof 
set head off feed off 
set pages 4444 
spool inctsql1.sql REP 
select 'alter system kill session '''||sid||','|| serial#||''' IMMEDIATE;' 
from v$session WHERE TYPE='USER' and last_call_et> 3600 and status='INACTIVE' 
/ 
spool off 
exit 
eof 
>inctsql.sql 
cat inctsql1.sql |grep -i -v  sql >> inctsql.sql 
sqlplus / as sysdba << eof 
spool kill.log REP 
set head on feed on time on 
@inctsql.sql 
spool off 
exit 
eof 

select 'alter system kill session '''||sid||','|| serial#||''' IMMEDIATE;' from v$session where sid=&sid;


spool inctsql1.sql REP 
select 'alter system kill session '''||sid||','|| serial#||''' IMMEDIATE;' from v$session WHERE TYPE='USER' and last_call_et> 3600 and status='INACTIVE' 
/


alter system kill session '1677,57443' IMMEDIATE;

	select  sid,serial#,machine,process,module
	from   v$session 
	where paddr in (select addr from v$process
	                          where background is null 
                          and    spid=&Server_process_id);







--==============
--Sessions 
--============== 


set lines 333 pages 4444 
col SERVICE_NAME for a25 
col machine for a30 
set lines 200 pages 200 
col username for a25 
col eventfor a25 
Col osuser for a15 
select inst_id, username,service_name,machine,osuser , status, count(*) from gv$session 
where type='USER' 
group by inst_id,username,service_name,machine,status,osuser  
order by 6,2,5; 
 
Select inst_id, sid,serial#,status from  gv$session where osuser ='&user'; 
 
 
select inst_id, username,service_name,machine ,event, status,PROGRAM,PROCESS, count(*) from gv$session 
group by inst_id,username,service_name,machine,status,event ,PROGRAM,PROCESS
order by 2,5; 


select inst_id, username,service_name,machine ,event, status,count(*) from gv$session 
group by inst_id,username,service_name,machine,status,event 
order by 2,5; 
 
select inst_id, username,service_name,machine ,event, status, count(*) from gv$session 
Where event like '%mutex%' 
group by inst_id,username,service_name,machine,status,event 
order by 2,5; 
 
 
 
 
select inst_id, username,service_name,machine , status, count(*) from gv$session 
where MACHINE not in (select unique HOST_NAME from gv$instance) 
group by inst_id,username,service_name,machine,status 
order by 2,5; 
 
-- Sql from sid 
  select  sql.sql_text 
      from   gv$session ses, gv$sqltext sql 
      where sql.address=ses.sql_address 
      and     sql.hash_value=ses.sql_hash_value 
      and     sid=&session_id 
      order   by piece; 
 
 
 
col OPNAME for a20 
col TARGET for a20 
col MESSAGE for a30 
col Units for a12 
col SQL_ID for a15 
 
select SID,SERIAL#,OPNAME,TARGET,SOFAR,TOTALWORK,UNITS,(1-(TOTALWORK-SOFAR)/TOTALWORK)*100 as " COmpleted (%)" ,START_TIME,LAST_UPDATE_TIME,TIME_REMAINING,ELAPSED_SECONDS,MESSAGE,SQL_ID 
from gv$session_longops where TIME_REMAINING > 0 
/ 
 
col event for a60 
set lines 200 
col machine for a20 
col module for a30 
col sql_id for a20 
col module for a15 
 
 
select sid,serial#,machine, event,sql_id,status,last_call_et,substr(MODULE,0,19) as MODULE 
from gv$session where status = 'ACTIVE' 
and module like 'rman%' 
order by 5 desc 
/ 
 
 
select sid,serial#,machine, event,sql_id,status,last_call_et,substr(MODULE,0,19) as MODULE 
from gv$session where status = 'ACTIVE' 
and module like 'GoldenGate%' 
--and machine not like 'acmsdbv4021%' 
order by 5 desc 
/ 
 
 
 
 
 
-- ${ORACLE_HOME}/bin/sqlplus -s "/ as sysdba" << EOF 
set echo off head off pages 9999 
select 'TAHITI_PROD|'||GG_REP_DIR||'|'|| LAST_HB_MINUTE from 
(select ID,GG_REP_DIR,extract( day from diff ) *24*60 + extract( hour from diff ) *60 + extract( minute from diff ) as LAST_HB_MINUTE 
from (select ID,GG_REP_DIR,systimestamp-LAST_DML_TIME as diff from GSEARCH.GG_MONITOR where GG_REP_DIR='ADC_TO_UCF_REP')) 
; 
EOF 
 
 
 
alter session set nls_date_format='DD-MM-YY HH24:MI'; 
 
alter session set nls_date_format='DD-MM-YY HH24:MI:SS'; 
--============================
--Editioned queries
--============================

set lines 333 pages 4444
col username for a40
col profile for a30
select username,account_status,profile,expiry_date from dba_users where oracle_maintained='N';

-- to check user is editioned
select EDITIONS_ENABLED from dba_users where username='&username';



COLUMN SID FORMAT 99999
COLUMN USERNAME FORMAT A20
COLUMN SCHEMANAME FORMAT A20
COLUMN OSUSER FORMAT A15
COLUMN PROCESS FORMAT A20
COLUMN MACHINE FORMAT A20
COLUMN TERMINAL FORMAT A15
COLUMN PROGRAM FORMAT A30
COLUMN SESSION_EDITION_ID FORMAT 99999
SELECT SID,
       USERNAME,
       SCHEMANAME,
       OSUSER,
       PROCESS,
       MACHINE,
       TERMINAL,
       PROGRAM,
       SESSION_EDITION_ID
  from V$SESSION
  where USERNAME='&USERNAME'
 order by SESSION_EDITION_ID;




--============================
--Editioned materialized view
--============================

CREATE MATERIALIZED VIEW PMXW_OUTGPISTATUSDETAIL
REFRESH COMPLETE ON DEMAND
START WITH TO_DATE('08-05-2023 07:29:13', 'DD-MM-YYYY HH24:MI:SS') NEXT SYSDATE + (1/288)
EVALUATE USING CURRENT EDITION   -- <<<<<<<<<<<< This keyword will help to create the mviews in referance to editionable objects
AS
SELECT X.PAYMENT,
       --X.NETWORK,
       --X.TRANSACTION_TYPE,
       nvl(X.HOST_CODE,global.host_code) HOST_CODE,
       nvl(X.TOTALMSG, 0) TOTALMSG,
       nvl(X.CONFIRMEDMSG, 0) CONFIRMEDMSG,
       nvl(X.REJECTEDMSG, 0) REJECTEDMSG,
       nvl(X.AWAITNGCONFMSG, 0) AWAITNGCONFMSG,
       nvl(X.INTERIMCONF, 0) INTERIMCONF
FROM (select "PAYMENT",
               --"NETWORK",
               --"TRANSACTION_TYPE",
               nvl(HOST_CODE,global.host_code) HOST_CODE,
               nvl(TOTALMSG, 0) TOTALMSG,
               nvl(CONFIRMEDMSG, 0) CONFIRMEDMSG,
               nvl(REJECTEDMSG, 0) REJECTEDMSG,
               nvl(AWAITNGCONFMSG, 0) AWAITNGCONFMSG,
               nvl(INTERIMCONF, 0) INTERIMCONF,
               count(*) over() as num_rows
          from pmvw_out_gcct_confmsgdetail
        union all
		select "PAYMENT",
               --"NETWORK",
               --"TRANSACTION_TYPE",
               nvl(HOST_CODE,global.host_code) HOST_CODE,
               nvl(TOTALMSG, 0) TOTALMSG,
               nvl(CONFIRMEDMSG, 0) CONFIRMEDMSG,
               nvl(REJECTEDMSG, 0) REJECTEDMSG,
               nvl(AWAITNGCONFMSG, 0) AWAITNGCONFMSG,
               nvl(INTERIMCONF, 0) INTERIMCONF,
               count(*) over() as num_rows
          from pmvw_out_gcov_confmsgdetail
        ) X
 where ((X.num_rows >= 1)
    or (X.num_rows = 1)) --and X.host_code=global.host_code --FCUBS_12.3Payments_Host_Code_Changes;
/
 
 
 
 
--==================== 
--DB LINKS 
--==================== 
 
 desc dba_db_links 
-- Name                                      Null?    Type 
-- ----------------------------------------- -------- ---------------------------- 
 OWNER                                     NOT NULL VARCHAR2(128) 
 DB_LINK                                   NOT NULL VARCHAR2(128) 
 USERNAME                                           VARCHAR2(128) 
 HOST                                               VARCHAR2(2000) 
 CREATED                                   NOT NULL DATE 
 
set lines 333 pages 44444 
col OWNER for a30 
col DB_LINK for a30 
col USERNAME for a30 
col HOST for a30  
select * from dba_db_links 
/ 
 
select * from dba_db_links where db_link in ('%DBSPMODEV%') 
select * from dba_db_links where db_link in ('ARIA_GCWAP7.US.ORACLE.COM'); 


SET LONG 999999999 
SET PAGES 3333 LINES 333 
SELECT DBMS_METADATA.GET_DDL('DB_LINK','DBL_AC_PROD_RPT','FCRHOST') FROM DUAL; 
SELECT DBMS_METADATA.GET_DDL('DB_LINK','STP.US.ORACLE.COM','PDB') FROM DUAL; 
 

--format
create database link dblink_sit connect to TISA147CONVERTION identified by TISA147CONVERTION using '10.96.34.2:1521/FCUBSUAT';

--cust

create database link dblink_ext3 connect to fcubslive identified by moving123 using '10.111.23.208:1521/FCUBSUAT';


create database link dblink_gold connect to fcubslive identified by moving123 using '10.1.72.11:6699/ABNUBSPDBGOLD';
create database link dblink_12x connect to fcubslive identified by moving123 using '10.111.23.216:6655/FCUBSUAT';
create database link mig2 connect to ABFCUBSLIVE identified by ABFCUBSLIVE using '10.0.70.33:6699/ABNUBSPDBMIG2';
create database link dblink_dr connect to ABFCUBSLIVE identified by ABFCUBSLIVE using '10.1.70.11:6699/ABNUBSPDB';


create database link dblink_OBBRN connect to SRVCMNTXN_RO identified by SRVCMNTXN_RO using 'localhost:6699/ABNOBBRNPDBMIG2';
create database link dblink_PROD connect to SRVCMNTXN_RO identified by SRVCMNTXN_RO using 'ab01x9ubs-scan1:6699/ABNUBSPDB';



create database link dblink_gcdr connect to ABFCUBSLIVE identified by ABFCUBSLIVE using '10.1.70.11:6699/ABNUBSPDB2';

create database link dblink_sup connect to ABFCUBSLIVE identified by ABFCUBSLIVE using '10.1.72.11:6699/ABNUBSPDBSUP';




create database link dblink_12x connect to fcubslive identified by moving123 using '(DESCRIPTION =(ADDRESS = (PROTOCOL = TCP)(HOST = 10.111.23.216)(PORT =6655))(CONNECT_DATA =(SERVER= DEDICATED) (SERVICE_NAME = FCUBSUAT)))';



create database link dblink_ext2 connect to fcubslive identified by moving123 using '10.1.72.27:6699/FCUBSDBDREXT';

create database link dblink_mig1 connect to ABUBSMIG1 identified by ABUBSMIG1 using '10.1.70.29:6699/ABNUBSPDBMIG';


create database link dblink_sit connect to TISA147CONVERTION identified by TISA147CONVERTION using '10.96.34.2:1521/uatovmpdb';


create database link dblink_rpt7 connect to CBSPRODFCR identified by CBSPRODFCR#2022aU using '10.58.38.183:1535/RPT7CORE';

create database link dblink_gc connect to FCUBS147 identified by Flextisa24 using '10.1.49.4:1521/ovmpdb';

create database link dblink_rpt6 connect to CBSPRODFCR identified by CBSPRODFCR#2022aU using '10.57.27.132:1535/RPT6CORE';
create database link dblink_rpt5 connect to CBSPRODFCR identified by CBSPRODFCR_123 using '10.58.38.125:1535/RPT5CBS';

create database link test connect to ATUMVERSE identified by sdfkj2kdi32 using '10.96.34.27:1521/uatovmpdb'


drop database link dblink_SBC;
drop database link dblink_SPY;
drop database link dblink_CCR;



 
--========================== 
--METADATA 
--========================== 
 
SET LONG 999999999 
SET PAGES 3333 LINES 333 
SELECT DBMS_METADATA.GET_DDL('DB_LINK','DBL_AC_PROD_RPT','FCRHOST') FROM DUAL; 
SELECT DBMS_METADATA.GET_DDL('DB_LINK','STP.US.ORACLE.COM','PDB') FROM DUAL; 
 
SELECT DBMS_METADATA.GET_DDL('TABLE','ACTB_ACCBAL_HISTORY','FCUBSLIVE') FROM DUAL; 


SELECT DBMS_METADATA.GET_DDL('MATERIALIZED_VIEW','EMP_BASIC_INFO','PDB') FROM DUAL; 
 
SELECT DBMS_METADATA.GET_DDL('MATERIALIZED_VIEW','FEATURE_DOCMAP_STPROJ','PDB') FROM DUAL; 
 
SELECT DBMS_METADATA.GET_DDL('PROCOBJ','P_DAHOFFY_017102023164356','TISA147CONVERTION') FROM DUAL   --- < for JOB DDL
 
select * from dba_db_links where USERNAME='PDB' and DB_LINK like 'STP%' 
 
 
 
 
SET LONG 999999999 
SET PAGES 3333 LINES 333 
COL ABC FOR A200 
SELECT DBMS_METADATA.GET_DDL('TABLESPACE','DATA02') as ABC FROM DUAL; 
 
 
--EMP_BASIC_INFO 
 
 
--22279953 status 80 
--Bug 24656577 - no update 
 --========================== 
-- Update query
--========================== 
 
-- SAMPLE
UPDATE NV_IND_PART_TBS a
SET ARG1 = (
    SELECT ARG1
    FROM NV_IND_PART_TBS@dblink_gcdr b
    WHERE b.INDEX_NAME = a.INDEX_NAME
);




--=================================== 
--RESTORE POINTS 
--=================================== 
set pages 5555 lines 333 
col NAME for a30 
col timed for a17 
col RPT for a17 
col SCN for 999999999999999 
Col CON_ID for 999 
select NAME,SCN,DATABASE_INCARNATION#,GUARANTEE_FLASHBACK_DATABASE,STORAGE_SIZE,to_char(TIME,'dd-mm-yy hh24:mi:ss') TIMED,to_char(RESTORE_POINT_TIME,'dd-mm-yy hh24:mi:ss') RPT,PRESERVED,CON_ID from v$restore_point; 
 
select NAME from v$restore_point; 
 
 
 
CREATE RESTORE POINT OCI_BKP GUARANTEE FLASHBACK DATABASE; 
 
CREATE RESTORE POINT After_activate GUARANTEE FLASHBACK DATABASE; 
 
 
 
--=================================== 
 
col MACHINE for a30 
SET LINES 333 pages 4444 
 
select inst_id,MACHINE,status ,count(*) from gv$session where type='USER' group by inst_id,status,MACHINE order by 1,3; 
 
 
--========================= 
-- AWR/awr snapshots
--========================== 

select snap_id,BEGIN_INTERVAL_TIME,END_INTERVAL_TIME 
from dba_hist_snapshot where BEGIN_INTERVAL_TIME > systimestamp -1 
order by BEGIN_INTERVAL_TIME ;

EXEC DBMS_WORKLOAD_REPOSITORY.create_snapshot();


SELECT snap_interval ,RETENTION FROM dba_hist_wr_control;

execute dbms_workload_repository.modify_snapshot_settings(interval => 15,retention => 43200); 
execute dbms_workload_repository.modify_snapshot_settings(interval => ,retention => 43200);



-- to delete snaps
BEGIN
  DBMS_WORKLOAD_REPOSITORY.DROP_SNAPSHOT_RANGE(
    low_snap_id  => 1,
    high_snap_id => 10
  );
END;

@?/rdbms/admin/awrrpt
--========================= 
-- startup / shutdown / restart
--========================== 
sho parameter name
sho pdbs

EXEC DBMS_WORKLOAD_REPOSITORY.create_snapshot;
alter system switch logfile;
alter system switch logfile;
alter system switch logfile;
alter system switch logfile;
alter system switch logfile;
alter system switch logfile;
alter system switch logfile;
alter system switch logfile;
alter system switch logfile;
alter system checkpoint;
alter system checkpoint;
alter system checkpoint;
alter system checkpoint;
alter system checkpoint;
EXEC DBMS_WORKLOAD_REPOSITORY.create_snapshot;








--- shu immediate 

startup


cd $ORACLE_BASE/diag/rdbms/<>/<>/trace/




 
--========= 
--JOBS 
--========== 
 
set pages 1000 lines 200 
col owner format a30 
col job_name format a30 
col session_id format 99999999 
col elapsed_time format a40 
col start_d for a17 
col next_d for a17 
col last_d for a17 
col STATE for a10 
col ENABLED for a5 
select running_instance as inst,owner,job_name,session_id,ELAPSED_TIME from dba_scheduler_running_jobs order by ELAPSED_TIME; 
 
SELECT DBMS_METADATA.GET_DDL('PROCOBJ','P_DAHOFFY_017102023164356','TISA147CONVERTION') FROM DUAL   --- < for JOB DDL                           
 
select owner,job_name,JOB_CREATOR,to_char(START_DATE,'dd-mm-yy hh24:mi:ss') start_d,to_char(NEXT_RUN_DATE,'dd-mm-yy hh24:mi:ss')next_d,RUN_COUNT,FAILURE_COUNT,ENABLED,STATE from dba_scheduler_jobs where job_name='EBA_SB_SURVEY_JOB'; 
 


-- Monitor currently running jobs
set pages 1000 lines 200 
col owner format a30 
col job_name format a30 
col session_id format 99999999 
col elapsed_time format a40 
col start_d for a17 
col next_d for a17 
col last_d for a17 
col STATE for a10 
col ENABLED for a5
SELECT job_name, session_id, running_instance, elapsed_time FROM dba_scheduler_running_jobs;

-- View the job run details

select * from DBA_SCHEDULER_JOB_RUN_DETAILS;

-- View the job related logs:

select * from DBA_SCHEDULER_JOB_LOG;
-- STOP AND DISABLE
 BEGIN
  DBMS_SCHEDULER.STOP_JOB('ABFCUBSLIVE.FN_POPULATE_TF_CUST_ADDR387', force => TRUE);
END;
/


BEGIN
  DBMS_SCHEDULER.DISABLE('ABFCUBSLIVE.FN_POPULATE_TF_CUST_ADDR387');
END;
/
--- STOP WEEKDAYS
BEGIN
DBMS_AUTO_TASK_ADMIN.DISABLE(
CLIENT_NAME => 'auto optimizer stats collection',
OPERATION => NULL,
WINDOW_NAME => 'MONDAY_WINDOW');
DBMS_AUTO_TASK_ADMIN.DISABLE(
CLIENT_NAME =>'auto optimizer stats collection',
OPERATION => NULL,
WINDOW_NAME => 'TUESDAY_WINDOW');
DBMS_AUTO_TASK_ADMIN.DISABLE(
CLIENT_NAME =>'auto optimizer stats collection',
OPERATION => NULL,
WINDOW_NAME => 'WEDNESDAY_WINDOW');
DBMS_AUTO_TASK_ADMIN.DISABLE(
CLIENT_NAME => 'auto optimizer stats collection',
OPERATION => NULL,
WINDOW_NAME => 'THURSDAY_WINDOW');
DBMS_AUTO_TASK_ADMIN.DISABLE(
CLIENT_NAME => 'auto optimizer stats collection',
OPERATION => NULL,
WINDOW_NAME => 'FRIDAY_WINDOW');
END;
/

--

select  sql.sql_text
      from   v$session ses, v$sqltext sql
      where sql.address=ses.sql_address
      and     sql.hash_value=ses.sql_hash_value
      and     sid=&session_id
      order   by piece;

--1.	How to identify the sid using Client Process id?

select sid 
from  v$session 
where process=’&client_process_id’;

--2.	How to identify the sid using Server Process id?
      
	select  sid,machine,process,module,serial#
	from   v$session 
	where paddr in (select addr from v$process
	                          where background is null 
	                          and    spid=&Server_process_id);
	
--3.	How to Identify the Server Process Id using the oracle session id (sid) ?

select spid 
from  gv$process 
where background is null 
and     addr in (select paddr
                        from   gv$session
                        where  sid=&session_id);
          
 
--4.	How to identify the sessions which are Inactive for more than 1 hour?

select  sid,serial#
from   gv$session
where  paddr in (select addr from gv$process where  background is null)
and     status='INACTIVE'  and  last_call_et/60/60>1;  

select 'alter system disconnect session '''||sid||','|| serial#||''' IMMEDIATE;'
from gv$session
WHERE
TYPE='USER'
AND last_call_et >=3600
AND paddr in (select addr from v$process where  background is null)
and status='INACTIVE'
AND substr(NVL(CLIENT_IDENTIFIER,'X'),1,8) <> 'menucall'
/



-- == NEVER SUCCESS JOBS 
 
select owner,job_name,to_char(START_DATE,'dd-mm-yy hh24:mi:ss') start_d,to_char(NEXT_RUN_DATE,'dd-mm-yy hh24:mi:ss')next_d,RUN_COUNT,FAILURE_COUNT,ENABLED,STATE 
from dba_scheduler_jobs  
where  
run_count != 0 
and 
failure_count != 0 
and 
STATE != 'DISABLED' 
and 
failure_count >= (run_count - 10) 
order by 1 
/ 

 
select owner,job_name, 
to_char(START_DATE,'dd-mm-yy hh24:mi:ss') start_d, 
to_char(NEXT_RUN_DATE,'dd-mm-yy hh24:mi:ss')next_d, 
to_char(LAST_START_DATE,'dd-mm-yy hh24:mi:ss')last_d, 
RUN_COUNT,FAILURE_COUNT,ENABLED,STATE, 
LAST_RUN_DURATION 
from dba_scheduler_jobs  
where  
run_count != 0 
and 
failure_count != 0 
and 
STATE != 'DISABLED' 
order by 5 
/ 
 
 
--== RECENT FAILED JOBS 
 
--== STOP JOBS 
 
exec sys.dbms_scheduler.STOP_JOB(job_name=>'DOCENG_LOGGER.LOGGER_PURGE_JOB', force=>true); 
 
 
--== DISABLE JOBS 
 
ALTER INDEX SYS.I_JOB_NEXT REBUILD ONLINE; 
exec dbms_ijob.broken(98060,FALSE); 
 
BEGIN 
  DBMS_SCHEDULER.DISABLE('IDENTITY.TEST_JOB23'); 
END; 
/ 
 
EXEC DBMS_SCHEDULER.DISABLE('IDENTITY.TEST_JOB23'); 
 
--=================================== 
--STATUS
--=====================================
 
 select eid, subject ,AUTH_SENDER, TO_STRING,SENDER,SENT_ON from es_messages where eid in (SELECT b.message_eid FROM es_recipients a, es_retry_queue b WHERE a.message_eid = b.message_eid and a.DELIVERY_STATUS=5 and lower(RESOLVED_ADDRESS) not like '%oracle.com' ); 
  
 select eid from es_messages where eid in (SELECT b.message_eid FROM es_recipients a, es_retry_queue b WHERE a.message_eid = b.message_eid and a.DELIVERY_STATUS=5 and lower(RESOLVED_ADDRESS) not like '%oracle.com' ); 


-- =============================== 
-- USERS 
-- =============================== 
set lines 333 pages 4444 
col USERNAME for a35 
col PROFILE for a10 
select username,account_status,profile,EXPIRY_DATE,ORACLE_MAINTAINED from dba_users where ORACLE_MAINTAINED='N' order by 1; 

-- 11:55 AM
-- --To check user grants

-- Create user…
select 'create user ICS identified by values '''||password||''''||
-- select 'create user ICS identified by &psw'||
       ' default tablespace '||default_tablespace||
       ' temporary tablespace '||temporary_tablespace||' profile '||
       profile||';'
from   sys.dba_users 
where  username = upper('ICS');
 
-- Grant Roles...
select 'grant '||granted_role||' to ICS'||
       decode(ADMIN_OPTION, 'YES', ' WITH ADMIN OPTION')||';'
from   sys.dba_role_privs
where  grantee = upper('ICS');  
 
-- Grant System Privs...
select 'grant '||privilege||' to ICS'||
       decode(ADMIN_OPTION, 'YES', ' WITH ADMIN OPTION')||';'
from   sys.dba_sys_privs
where  grantee = upper('ICS');  
 
-- Grant Table Privs...
select 'grant '||privilege||' on '||owner||'.'||table_name||' to ICS;'
from   sys.dba_tab_privs
where  grantee = upper('ICS');  
 
-- Grant Column Privs...
select 'grant '||privilege||' on '||owner||'.'||table_name||
       '('||column_name||') to ICS;'
from   sys.dba_col_privs
where  grantee = upper('ICS');  
 
-- Tablespace Quotas...
select 'alter user '||username||' quota '||
decode(max_bytes, -1, 'UNLIMITED', max_bytes)||
' on '||tablespace_name||';'
from  sys.dba_ts_quotas
where  username = upper('ICS'); 


-- =============================== 
-- PLSQL 
-- =============================== 
SET SERVEROUTPUT ON;
BEGIN
DBMS_OUTPUT.PUT_LINE('Hello PL/SOL worLd');
END;

-- =============================== 
-- while loop --! NOT WORKING
-- =============================== 
SET SERVEROUTPUT ON;
DECLARE
  interval_number pls_integer := 10; -- seconds
  sql_stmt VARCHAR2(4000);
BEGIN
  LOOP
    sql_stmt := '
      SELECT   A.tablespace_name tablespace, D.mb_total "TOTAL (GB)",
               SUM (A.used_blocks * D.block_size) / 1024 / 1024 / 1024 "USED (GB)",
               D.mb_total - SUM (A.used_blocks * D.block_size) / 1024 / 1024 / 1024 "FREE (GB)"
      FROM     Gv$sort_segment A,
               (
               SELECT   B.name, C.block_size, SUM (C.bytes) / 1024 / 1024 /1024 mb_total
               FROM     v$tablespace B, v$tempfile C
               WHERE    B.ts#= C.ts#
               GROUP BY B.name, C.block_size
               ) D
      WHERE    A.tablespace_name = D.name
      GROUP by A.tablespace_name, D.mb_total
    ';
    EXECUTE IMMEDIATE 'BEGIN DBMS_OUTPUT.PUT_LINE(:sql_stmt); END;' USING sql_stmt;
    DBMS_LOCK.SLEEP(interval_number);
  END LOOP;
END;
/






--============================================================================
$ cat /oracle/Dailycheck/Checklist_new.sh
ORACLE_HOME=/oracle11g/app/oracle/product/11.2.0/dbhome_1
export ORACLE_HOME
 
PATH=$ORACLE_HOME/bin:$PATH
export PATH
 
ORACLE_SID=PRODCAMS1
export ORACLE_SID
 
sqlplus " / as sysdba" @/oracle/Dailycheck/Dailycheck_CAMS.sql
exit


*/
-- $ cat /oracle/Dailycheck/Dailycheck_CAMS.sql
 
-- +----------------------------------------------------------------------------+
-- | DATABASE : Oracle                                                          |
-- | CLASS    : Database Administration                                         |
-- | PURPOSE  : This SQL script provides a detailed report (in HTML format) on  |
-- |            all database metrics including installed options, storage,      |
-- |            performance data, and security.                                 |
-- | Author   : Anvish KP                                                       |
-- | USAGE    :                                                                 |
-- |                                                                            |
-- |    sqlplus -s <dba>/<password>@<TNS string> @dba_snapshot_database_10g.sql |
-- |                                                                            |
-- | NOTE     : As with any code, ensure to test this script in a development   |
-- |            environment before attempting to run it in production.          |
-- +----------------------------------------------------------------------------+
define reportHeader="<font size=+3 color=darkgreen><b>Daily Checklist<i>DB</i></b></font><hr>Oracle Database(<a target=""_blank"" href=""DB"">DB_Info</a>)<p>"
-- +----------------------------------------------------------------------------+
-- |                           SCRIPT SETTINGS                                  |
-- +----------------------------------------------------------------------------+
set termout      off
set echo         off
set feedback     off
set heading      off
set verify       off
set wrap         on
set trimspool    on
set serveroutput on
 
set pagesize 50000
set linesize 145
 
clear buffer computes columns breaks screen
 
define fileName=/home/oracle/anvi/report
-- +----------------------------------------------------------------------------+
-- |                   GATHER DATABASE REPORT INFORMATION                       |
-- +----------------------------------------------------------------------------+
 
COLUMN tdate NEW_VALUE _date NOPRINT
SELECT TO_CHAR(SYSDATE,'MM/DD/YYYY') tdate FROM dual;
 
COLUMN time NEW_VALUE _time NOPRINT
SELECT TO_CHAR(SYSDATE,'HH24:MI:SS') time FROM dual;
 
COLUMN date_time NEW_VALUE _date_time NOPRINT
SELECT TO_CHAR(SYSDATE,'MM/DD/YYYY HH24:MI:SS') date_time FROM dual;
 
COLUMN spool_time NEW_VALUE _spool_time NOPRINT
SELECT TO_CHAR(SYSDATE,'YYYYMMDD') spool_time FROM dual;
 
COLUMN dbname NEW_VALUE _dbname NOPRINT
SELECT name dbname FROM v$database;
 
COLUMN global_name NEW_VALUE _global_name NOPRINT
SELECT global_name global_name FROM global_name;
 
COLUMN blocksize NEW_VALUE _blocksize NOPRINT
SELECT value blocksize FROM v$parameter WHERE name='db_block_size';
 
COLUMN startup_time NEW_VALUE _startup_time NOPRINT
SELECT TO_CHAR(startup_time, 'MM/DD/YYYY HH24:MI:SS') startup_time FROM v$instance;
 
COLUMN reportRunUser NEW_VALUE _reportRunUser NOPRINT
SELECT user reportRunUser FROM dual;
 
-- +----------------------------------------------------------------------------+
-- |                   GATHER DATABASE REPORT INFORMATION                       |
-- +----------------------------------------------------------------------------+
 
set heading on
 
set markup html on spool on preformat off entmap on -
head ' -
  <title>Database Report</title> -
  <style type="text/css"> -
    body              {font:9pt Arial,Helvetica,sans-serif; color:black; background:White;} -
    p                 {font:9pt Arial,Helvetica,sans-serif; color:black; background:White;} -
    table,tr,td       {font:9pt Arial,Helvetica,sans-serif; color:Black; background:#C0C0C0; padding:0px 0px 0px 0px; margin:0px 0px 0px 0px;} -
    th                {font:bold 9pt Arial,Helvetica,sans-serif; color:#336699; background:#cccc99; padding:0px 0px 0px 0px;} -
    h1                {font:bold 12pt Arial,Helvetica,Geneva,sans-serif; color:#336699; background-color:White; border-bottom:1px solid #cccc99; margin-top:0pt; margin-bottom:0pt; padding:0px 0px 0px 0px;} -
    h2                {font:bold 10pt Arial,Helvetica,Geneva,sans-serif; color:#336699; background-color:White; margin-top:4pt; margin-bottom:0pt;} -
    a                 {font:9pt Arial,Helvetica,sans-serif; color:#663300; margin-top:0pt; margin-bottom:0pt; vertical-align:top;} -
    a.link            {font:9pt Arial,Helvetica,sans-serif; color:#663300; margin-top:0pt; margin-bottom:0pt; vertical-align:top;} -
    a.noLink          {font:9pt Arial,Helvetica,sans-serif; color:#663300; text-decoration: none; margin-top:0pt; margin-bottom:0pt; vertical-align:top;} -
    a.noLinkBlue      {font:9pt Arial,Helvetica,sans-serif; color:#0000ff; text-decoration: none; margin-top:0pt; margin-bottom:0pt; vertical-align:top;} -
    a.noLinkDarkBlue  {font:9pt Arial,Helvetica,sans-serif; color:#000099; text-decoration: none; margin-top:0pt; margin-bottom:0pt; vertical-align:top;} -
    a.noLinkRed       {font:9pt Arial,Helvetica,sans-serif; color:#ff0000; text-decoration: none; margin-top:0pt; margin-bottom:0pt; vertical-align:top;} -
    a.noLinkDarkRed   {font:9pt Arial,Helvetica,sans-serif; color:#990000; text-decoration: none; margin-top:0pt; margin-bottom:0pt; vertical-align:top;} -
    a.noLinkGreen     {font:9pt Arial,Helvetica,sans-serif; color:#00ff00; text-decoration: none; margin-top:0pt; margin-bottom:0pt; vertical-align:top;} -
    a.noLinkDarkGreen {font:9pt Arial,Helvetica,sans-serif; color:#009900; text-decoration: none; margin-top:0pt; margin-bottom:0pt; vertical-align:top;} -
  </style>' -
body   'BGCOLOR="#C0C0C0"' -
table  'WIDTH="90%" BORDER="1"'
 
spool &FileName._&_dbname._&_spool_time..html
set markup html on entmap off
-- +----------------------------------------------------------------------------+
-- |                             - REPORT HEADER -                              |
-- +----------------------------------------------------------------------------+
prompt <a name="Test"></a>
prompt <font size="+2" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>DATABASE : Oracle</b></font><hr align="left" width="460">
-- +----------------------------------------------------------------------------+
-- |                                 - VERSION -                                |
-- +----------------------------------------------------------------------------+
prompt <a name="version"></a>
prompt <font size="+2" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Version</b></font><hr align="left" width="460">
COLUMN banner HEADING "Banner"
SELECT * FROM v$version;
prompt <center>[<a class="noLink" href="#top">Top</a>]</center><p>
-- +----------------------------------------------------------------------------+
-- |                           - INSTANCE OVERVIEW -                            |
-- +----------------------------------------------------------------------------+
prompt <a name="instance_overview"></a>
prompt <font size="+2" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Instance Overview</b></font><hr align="left" width="460">
COLUMN instance_number     FORMAT a75    HEADING 'Instance|Num'
COLUMN instance_name                     HEADING 'Instance|Name'
COLUMN host_name                         HEADING 'Host|Name'
COLUMN version                           HEADING 'Oracle|Version'
COLUMN parallel                          HEADING 'Parallel'
COLUMN status                            HEADING 'Instance|Status'
COLUMN database_status                   HEADING 'Database|Status'
COLUMN logins                            HEADING 'Logins'
COLUMN archiver                          HEADING 'Archiver'
COLUMN start_time                        HEADING 'Start|Time'
COLUMN current_time                      HEADING 'Current|Time'
COLUMN uptime                            HEADING 'Uptime|(in days)'

SELECT
    '<div align="center"><font color="#336699"><b>' || instance_number || '</b></font></div>'   instance_number
  , '<div align="center">' || instance_name   || '</div>'   instance_name
  , '<div align="center">' || host_name       || '</div>'   host_name
  , '<div align="center">' || version         || '</div>'   version
  , '<div align="center">' || parallel        || '</div>'   parallel
  , '<div align="center">' || status          || '</div>'   status
  , '<div align="center">'  || TO_CHAR(startup_time,'MM/DD/YYYY HH24:MI:SS') || '</div>' start_time
  , '<div align="center">'  || TO_CHAR(sysdate,'MM/DD/YYYY HH24:MI:SS')      || '</div>' current_time
  , ROUND(TO_CHAR(SYSDATE-startup_time), 2)        uptime
  , '<div align="center">' || logins          || '</div>'   logins
  , '<div align="center">' || archiver        || '</div>'   archiver
FROM v$instance;

prompt <center>[<a class="noLink" href="#top">Top</a>]</center><p>
-- +----------------------------------------------------------------------------+
-- |                           - DATABASE OVERVIEW -                            |
-- +----------------------------------------------------------------------------+
prompt <a name="database_overview"></a>
prompt <font size="+2" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Database Overview</b></font><hr align="left" width="460">
COLUMN name            FORMAT a75   HEADING 'DB Name'
COLUMN dbid                         HEADING 'DB ID'
COLUMN log_mode                     HEADING 'Log Mode'
COLUMN version_time                 HEADING 'Version Time'
COLUMN open_mode                    HEADING 'Open Mode'
 
SELECT
    '<div align="center"><font color="#336699"><b>' || name  || '</b></font></div>'          name
  , '<div align="center">' || dbid       || '</div>'          dbid
  , '<div align="center">' || log_mode   || '</div>'          log_mode
  , '<div align="center">' || TO_CHAR(version_time, 'MM/DD/YYYY HH24:MI:SS') || '</div>' version_time
  , '<div align="center">' || open_mode  || '</div>'          open_mode
FROM v$database;
 
prompt <center>[<a class="noLink" href="#top">Top</a>]</center><p>
-- +------------------------------------------------------------------------------------+
-- |                      TABLESPACE ABOVE 70% UTILIZED                                 |
-- +------------------------------------------------------------------------------------+
prompt <a name="TABLESPACE ABOVE 70% UTILIZED"></a>
prompt <font size="+2" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>ASM</b></font><hr align="left" width="460">
set linesize 100
set pagesize 100
select
a.tablespace_name,
round(SUM(a.bytes)/(1024*1024*1024)) CURRENT_GB,
round(SUM(decode(b.maxextend, null, A.BYTES/(1024*1024*1024),
b.maxextend*8192/(1024*1024*1024)))) MAX_GB,
(SUM(a.bytes)/(1024*1024*1024) - round(c.Free/1024/1024/1024)) USED_GB,
round((SUM(decode(b.maxextend, null, A.BYTES/(1024*1024*1024),
b.maxextend*8192/(1024*1024*1024))) - (SUM(a.bytes)/(1024*1024*1024) -
round(c.Free/1024/1024/1024))),2) FREE_GB,
round(100*(SUM(a.bytes)/(1024*1024*1024) -
round(c.Free/1024/1024/1024))/(SUM(decode(b.maxextend, null, A.BYTES/(1024*1024*1024),
b.maxextend*8192/(1024*1024*1024))))) USED_PCT
from
dba_data_files a,
sys.filext$ b,
(SELECT
d.tablespace_name ,sum(nvl(c.bytes,0)) Free
FROM
dba_tablespaces d,
DBA_FREE_SPACE c
WHERE
d.tablespace_name = c.tablespace_name(+)
group by d.tablespace_name) c
WHERE
a.file_id = b.file#(+)
and a.tablespace_name = c.tablespace_name
GROUP BY a.tablespace_name, c.Free/1024
ORDER BY tablespace_name
/

-- +----------------------------------------------------------------------------+
-- |                            - END OF REPORT -                               |
-- +----------------------------------------------------------------------------+
SPOOL OFF
SET MARKUP HTML OFF
SET TERMOUT ON
prompt
prompt Output written to: &FileName._&_dbname._&_spool_time..html

-----------------------------------------------------------------------------------------
echo "This is the email body." | mail -s "test" anvish.k.peedikayil@oracle.com

/*
#!/bin/bash

TO="your.email@example.com"
SUBJECT="Subject of the Email"
BODY="This is the email body."

echo -e "To: anvish.k.peedikayil@oracle.com\nSubject: SUBJECT\n\nBODY" | /usr/sbin/sendmail -t



DB_UATOVM_20230814.html > Database_report.html
DB_OFSASIT_20230814.html >> Database_report.html
DB_DEVOVM_20230814.html >> Database_report.html
DB_DMOVM_20230814.html >> Database_report.html
rm -f DB_*html

*/

RUN {
  ALLOCATE CHANNEL c1 DEVICE TYPE DISK FORMAT '/vol1/backup/rman/oct9/full_backup_%U';
  BACKUP DATABASE PLUS ARCHIVELOG;
  RELEASE CHANNEL c1;
  SQL 'ALTER SYSTEM ARCHIVE LOG CURRENT';
}


RUN {
  ALLOCATE CHANNEL c1 DEVICE TYPE DISK FORMAT '/vol1/backup/rman/oct9/full_backup_%U';
  ALLOCATE CHANNEL c2 DEVICE TYPE DISK FORMAT '/vol1/backup/rman/oct9/controlfile_backup_%U';
  ALLOCATE CHANNEL c3 DEVICE TYPE DISK FORMAT '/vol1/backup/rman/oct9/spfile_backup_%U';  
  BACKUP DATABASE PLUS ARCHIVELOG;
  BACKUP CURRENT CONTROLFILE;
  BACKUP SPFILE;  
  RELEASE CHANNEL c1;
  RELEASE CHANNEL c2;
  RELEASE CHANNEL c3;
  SQL 'ALTER SYSTEM ARCHIVE LOG CURRENT';
}



RUN {
  ALLOCATE CHANNEL c1 DEVICE TYPE DISK FORMAT '/vol1/backup/rman/nov20/backup_%U';
  ALLOCATE CHANNEL c2 DEVICE TYPE DISK FORMAT '/vol1/backup/rman/nov20/backup_%U';
  ALLOCATE CHANNEL c3 DEVICE TYPE DISK FORMAT '/vol1/backup/rman/nov20/backup_%U';  
  BACKUP DATABASE PLUS ARCHIVELOG;
  BACKUP CURRENT CONTROLFILE;
  BACKUP SPFILE;  
  RELEASE CHANNEL c1;
  RELEASE CHANNEL c2;
  RELEASE CHANNEL c3;
}




--  UTL_HTTP.REQUEST Fails with ORA-24247 Even if the Called HTTP Server is Associated to the ACL (Doc ID 972052.1)	To BottomTo Bottom	 / cat ac2.sql << -- Successful script

begin
DBMS_NETWORK_ACL_ADMIN.DROP_ACL('www.TISA147CONVERTION_ACL.xml');
end;
/

-- if to remove the existing or recreate , to cleanup please use above query



BEGIN
--CREATE THE ACL AND ASSIGN THE CONNECT PRIVILEGE TO SCOTT TO RUN THE UTL_HTTP PACKAGE
DBMS_NETWORK_ACL_ADMIN.CREATE_ACL(acl => 'www.TISA147CONVERTION_ACL.xml',
description => 'WWW ACL',
principal => 'TISA147CONVERTION',
is_grant => true,
privilege => 'connect'
);


DBMS_NETWORK_ACL_ADMIN.ASSIGN_ACL(acl => 'www.TISA147CONVERTION_ACL.xml',
host => '10.96.34.3',
lower_port => null,
upper_port => null);

END;
/

COMMIT;

SELECT * FROM dba_network_acls;
SELECT * FROM dba_network_acl_privileges;



---- ACTB_HISTORY

-- 1. Take Table DDL like below

 SELECT DBMS_METADATA.GET_DDL('TABLE','ACTB_HISTORY','&SCHEMA_NAME')     FROM  dual;

-- 2. Take index and constraints count

select count(1) from dba_indexes where owner='&owner' and table_name='ACTB_HISTORY';
select count(1) from dba_constraints where owner='&owner' and table_name='ACTB_HISTORY';


SELECT INDEX_NAME FROM DBA_INDEXES WHERE TABLE_NAME='ACTB_HISTORY'  and owner='CBSPRODFCGL';

-- 3. Take INDEX DDL.
-------------------
DROP INDEX IX01_ACZB_HISTORY ;
DROP INDEX IX02_ACZB_HISTORY ;
DROP INDEX X4_ACZB_HISTORY ;
DROP INDEX X67_ACZB_HISTORY ;
DROP INDEX IX05_ACZB_HISTORY ;
DROP INDEX PK01_ACZB_HISTORY ;
DROP INDEX IDX$$_1800F0003 ;
DROP INDEX NS_IX07_ACZB_HISTORY ;

CREATE INDEX "ABFCUBSLIVE"."IDX$$_1800F0003" ON "ABFCUBSLIVE"."ACZB_HISTORY" ("AC_NO", "TXN_INIT_DATE")  TABLESPACE "FCCINDPARTXL"  parallel 40;
CREATE INDEX "ABFCUBSLIVE"."IX01_ACZB_HISTORY" ON "ABFCUBSLIVE"."ACZB_HISTORY" ("AC_BRANCH", "CUST_GL", "FINANCIAL_CYCLE", "PERIOD_CODE") TABLESPACE "FCCDATAXLBF3"  LOCAL parallel 40;
CREATE INDEX "ABFCUBSLIVE"."IX02_ACZB_HISTORY" ON "ABFCUBSLIVE"."ACZB_HISTORY" ("EVENT_SR_NO", "TRN_REF_NO")  TABLESPACE "FCCINDPARTXL"  LOCAL parallel 40;  
CREATE INDEX "ABFCUBSLIVE"."IX05_ACZB_HISTORY" ON "ABFCUBSLIVE"."ACZB_HISTORY" ("AC_NO", "AC_BRANCH", "TRN_DT", "TRN_CODE")   TABLESPACE "FCCINDPARTXL"  LOCAL parallel 40;  
CREATE INDEX "ABFCUBSLIVE"."NS_IX07_ACZB_HISTORY" ON "ABFCUBSLIVE"."ACZB_HISTORY" ("IB", "TRN_REF_NO")  TABLESPACE "FCCINDPARTXL"  parallel 40;  
CREATE UNIQUE INDEX "ABFCUBSLIVE"."PK01_ACZB_HISTORY" ON "ABFCUBSLIVE"."ACZB_HISTORY" ("AC_ENTRY_SR_NO")  TABLESPACE "FCCINDPARTXL"  parallel 40;
CREATE INDEX "ABFCUBSLIVE"."X4_ACZB_HISTORY" ON "ABFCUBSLIVE"."ACZB_HISTORY" ("RELATED_ACCOUNT")   TABLESPACE "FCCINDPARTXL"  LOCAL parallel 40;
CREATE INDEX "ABFCUBSLIVE"."X67_ACZB_HISTORY" ON "ABFCUBSLIVE"."ACZB_HISTORY" ("AC_NO", "AC_ENTRY_SR_NO", "TRN_DT", "EVENT")   TABLESPACE "FCCINDPARTXL"  LOCAL  parallel 40;

ALTER INDEX "ABFCUBSLIVE"."IDX$$_1800F0003" NOPARALLEL;
ALTER INDEX "ABFCUBSLIVE"."IX01_ACZB_HISTORY" NOPARALLEL;
ALTER INDEX "ABFCUBSLIVE"."IX02_ACZB_HISTORY" NOPARALLEL;
ALTER INDEX "ABFCUBSLIVE"."IX05_ACZB_HISTORY" NOPARALLEL;
ALTER INDEX "ABFCUBSLIVE"."NS_IX07_ACZB_HISTORY" NOPARALLEL;
ALTER INDEX "ABFCUBSLIVE"."PK01_ACZB_HISTORY" NOPARALLEL;
ALTER INDEX "ABFCUBSLIVE"."X4_ACZB_HISTORY" NOPARALLEL;
ALTER INDEX "ABFCUBSLIVE"."X67_ACZB_HISTORY" NOPARALLEL;
------------------------------------

SELECT DBMS_METADATA.GET_DDL('INDEX',u.index_name,'FCUBS19C')  FROM DUAL ,dba_indexes u where u.owner='CBSPRODFCGL' and u.table_name='ACTB_HISTORY';

SELECT INDEX_NAME FROM DBA_INDEXES WHERE TABLE_NAME='ACTB_HISTORY'  and owner='CBSPRODFCGL';
SELECT DBMS_METADATA.GET_DDL('INDEX','&index_name','CBSPRODFCGL')  FROM DUAL;

SELECT CONSTRAINT_NAME FROM  DBA_constraints c where    c.constraint_type = 'P' AND OWNER='CBSPRODFCGL' AND TABLE_NAME='ACTB_HISTORY';

select dbms_metadata.get_ddl('CONSTRAINT','PK01_ACTB_HISTORY','CBSPRODFCGL') from dual;

-- 4.drop all indexes and primary key like below.


 Alter table CBSPRODFCGL.ACTB_HISTORY drop primary key;

-- 5. Import table data.

-- 6. recreate indexes  with parallelism and enable primary key like below.

CREATE INDEX PARALLALLY 

-- /*+parallel(20)*/

CREATE INDEX "FCUBS19C"."IX01_ACTB_HISTORY" ON "FCUBS19C"."ACTB_HISTORY" ("AC_BRANCH", "CUST_GL", "FINANCIAL_CYCLE", "PERIOD_CODE")
  PCTFREE 10 INITRANS 2 MAXTRANS 255 COMPUTE STATISTICS
  STORAGE(INITIAL 65536 NEXT 1048576 MINEXTENTS 1 MAXEXTENTS 2147483645
  PCTINCREASE 0 FREELISTS 1 FREELIST GROUPS 1
  BUFFER_POOL DEFAULT FLASH_CACHE DEFAULT CELL_FLASH_CACHE DEFAULT)
  TABLESPACE "FCCDFLT" parallel 10;


--  Below will take time , run it in bg


Alter table ACTB_HISTORY add constraint PK01_ACTB_HISTORY primary key (AC_ENTRY_SR_NO) using index PK01_ACTB_HISTORY;


-- edited
Alter table ACTB_HISTORY_NEW add constraint PK01_ACTB_HISTORY_NEW primary key (AC_ENTRY_SR_NO) using index PK01_ACTB_HISTORY_NEW;



Alter table ACTB_HISTORY  enable constraint PK01_ACTB_HISTORY;

-- 7. Change the degree of indexes to 1.You can you below sample scripts to use same.


select 'alter index CBSPRODFCGL.'||INDEX_NAME||' NOPARALLEL;' FROM DBA_INDEXES WHERE OWNER='CBSPRODFCGL' and TABLE_NAME='ACTB_HISTORY_NEW';

-- 8. Post Validation.

select count(1) from dba_indexes where owner='FCUBS19C' and table_name='ACTB_HISTORY';
select count(1) from dba_constraints where owner='FCUBS19C' and table_name='ACTB_HISTORY';

select distinct degree from dba_indexes where  owner='FCUBS19C' and table_name='ACTB_HISTORY'





--! ===============================================
--! ===============================================
--! ===============================================
--! ===============================================

--! ===============================================
--! ===============================================
--! =============================================== PT 
--! =============================================== ITS CHAOS DOWN THERE , GO WITH CAUTION

--! ===============================================
--! ===============================================
--! ===============================================
--! ===============================================





-- ===============================================
-- Historival SQL Plan
-- ===============================================
SELECT     p.plan_hash_value, p.operation,p.options,p.object_name,p.object_type,p.cost,p.cardinality,p.bytes
FROM       dba_hist_sql_plan p
WHERE      p.sql_id = '&SQL_ID'
ORDER BY   p.plan_hash_value, p.id;

-- ===============================================
-- Cached SQL Plan
-- ===============================================
SELECT    p.plan_hash_value,p.operation,p.options,p.object_name,p.object_type,p.cost,p.cardinality,p.bytes
FROM      v$sql_plan p
WHERE     p.sql_id = '&SQL_ID'
ORDER BY  p.plan_hash_value, p.id;

-- ===============================================
-- All  SQL Plan with stats
-- ===============================================
SELECT     s.sql_id,s.plan_hash_value, s.executions,s.elapsed_time/1000000 total_elapsed_sec,
           s.elapsed_time/DECODE(s.executions,0,1,s.executions)/1000000 avg_elapsed_sec,
           p.operation,p.optionsp.object_name,p.object_type
FROM       v$sql s,v$sql_plan p
WHERE      s.sql_id = '&SQL_ID' 
  AND      s.sql_id = p.sql_id
  AND      s.child_number = p.child_number 
ORDER BY   s.plan_hash_value, p.id;











-- To see inside a profile 

SELECT EXTRACTVALUE(VALUE(H),'.') as hint
FROM DBMSHSXP_SQL_PROFILE_ATTR dspa,
     TABLE (xmlsequence(
        extract(xmltype(dspa.comp_data),'/outline_data/hint'))) h
where dspa.profile_name = 'SYS_SQLPROF_23948JWER9348R';

-- checking plan of a baseline

select plan_table_output from table(dbms_xplane.display_sql_plan_baseline('&sql_handle','&plan_name'));


SELECT extractValue (value(h) , '.' ) AS hint
FROM sys.sqlobj$plan od,
      TABLE(xm1sequence(
WHERE
AND


sys.sqlobj$plan od,
TABLE(xm1sequence(
other_xml), ' ' ) ) ) h
od.other xml is not null
(signature, category, obj _ type, plan_id )
= (select signature,
from
where
category,
obj _ type,
plan_id
sys.sqlobj$ so
- SQL
so. name —
--! ===============================================

--====================
--SQL PLAN FIX PTQ  RUNNING QUERY PT
--====================
SELECT 
    ses.status,
    ROUND((SYSDATE - ses.sql_exec_start) * 24 * 60, 2) AS duration_minutes,
    ses.sid,
    ses.serial#,
    ses.sql_id,
    ses.inst_id,
    sqla.program_id,
    do.object_name,
    do.object_type,
    sql.sql_text,
    do.object_id,
    do.status,
    plan.plan_hash_value,
    ses.username,
    ses.osuser,
    ses.event,
    ses.machine,
    ses.module,
    ses.program,
    ses.process pid,
    ROUND(ses.last_call_et / 100, 2) AS database_time_seconds,
    io.block_gets,
    io.physical_reads,
    ses.sql_exec_start,
    ses.last_call_et + ses.sql_exec_start AS end_time
FROM 
    gv$session ses
LEFT JOIN 
    gv$sql sql ON ses.sql_id = sql.sql_id AND ses.inst_id = sql.inst_id
LEFT JOIN 
    gv$sql_plan plan ON ses.sql_id = plan.sql_id AND ses.inst_id = plan.inst_id
LEFT JOIN 
    gv$sqlarea sqla ON ses.sql_id = sqla.sql_id
LEFT JOIN 
    dba_objects do ON sqla.program_id = do.object_id
LEFT JOIN 
    gv$sess_io io ON ses.sid = io.sid AND ses.inst_id = io.inst_id
WHERE 
    ses.type = 'USER'
    AND ses.status = 'ACTIVE'
    AND ses.sql_id IS NOT NULL
    and ses.sql_id !='c6yamf6vjtwy6'
    AND ses.username IS NOT NULL
    AND sql.sql_text NOT LIKE 'SELECT%ses.status,%ROUND('
    -- AND ses.machine='ab01-ubsodt05'
    --AND ses.sid=495
ORDER BY duration_minutes ;


----  

EXPLAIN PLAN FOR
-- Your SQL query goes here;
SELECT * FROM your_table WHERE condition;

-- To display the execution plan:
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);


Cursor Query in Offset consolidation Job:
SELECT * FROM iftbs_ofst_consl_dtl_extgbl d
WHERE d.consol_status = 'N'
AND d.transaction_date = p_application_Date
ORDER BY ofst_consol_serial
FETCH FIRST p_limit ROWS ONLY;

select * from TABLE(dbms_xplan.display_awr('dgfvnd04crf07'));



--Please find the Query for EXPLAIN PLAN.

EXPLAIN PLAN SET statement_id = 'ex_plan2'
    FOR
           SELECT OBJID, NAME, OWNER, OWNERID, TABLESPACE, TSNO, FILENO, BLOCKNO,AUDIT$,COMMENT$,CLUSTERFLAG,PCTFREE$,PCTUSED$,INITRANS,MAXTRANS,DEGREE,INSTANCES,CACHE, PROPERTY, DEFLOG, TSDEFLOG,ROID,ROWCNT,BLKCNT, AVGRLEN,TFLAGS,TRIGFLAG, OBJSTATUS,             XDBOOL FROM  SYS.EXU10TAB T$ WHERE  OWNERID = :1 AND NOT EXISTS (SELECT NAME  FROM SYS.EXU8NXP N$  WHERE  N$.OWNERID = T$.OWNERID AND N$.NAME = T$.NAME AND N$.TYPE = 2) ORDER BY T$.XDBOOL DESC,T$.NAME;

--Explained.

SELECT plan_table_output  FROM   TABLE(DBMS_XPLAN.DISPLAY('PLAN_TABLE','qb_name','ALL'));


EXPLAIN PLAN FOR
SELECT OBJID, NAME, OWNER, OWNERID, TABLESPACE, TSNO, FILENO, BLOCKNO,AUDIT$,COMMENT$,CLUSTERFLAG,PCTFREE$,PCTUSED$,INITRANS,MAXTRANS,DEGREE,INSTANCES,CACHE, PROPERTY, DEFLOG, TSDEFLOG,ROID,ROWCNT,BLKCNT, AVGRLEN,TFLAGS,TRIGFLAG, OBJSTATUS,             XDBOOL FROM  SYS.EXU10TAB T$ WHERE  OWNERID = :1 AND NOT EXISTS (SELECT NAME  FROM SYS.EXU8NXP N$  WHERE  N$.OWNERID = T$.OWNERID AND N$.NAME = T$.NAME AND N$.TYPE = 2) ORDER BY T$.XDBOOL DESC,T$.NAME;

--Explained

@?/rdbms/admin/utlxpls 	-	serial execution

@?/rdbms/admin/utlxplp	-	Parallel execution

--If error – you can drop table and recreate

--Create plan_table

@?/rdbms/admin/utlxplan.sql

SELECT PLAN_TABLE_OUTPUT FROM TABLE(DBMS_XPLAN.DISPLAY(NULL, 'ex_plan1','ALL'));

---From awr snap
 select * from table (DBMS_XPLAN.DISPLAY_AWR('dgfvnd04crf07'));

---From cursor snap

 select * from table (DBMS_XPLAN.DISPLAY_CURSOR ('dgfvnd04crf07',0));

-- TUNING ADVISOR

EXPLAIN PLAN FOR
select ac.*
  FROM sttms_cust_account ac, sttm_account_balance ab
 WHERE ac.branch_code  = ab.cust_ac_brn
   AND ac.cust_ac_no   = ab.cust_ac_no
   AND NVL(ac.fi_customer,'N')<> 'Y';
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);
 
-- b024whb2x0f4b
-- 5cpa4nhnnf3nw
 
 select sql_id, sql_text from v$sqltext where sql_text like '%ac.*%FROM sttms_cust_account ac, sttm_account_balance ab%'
---------------------------------------------------------------------------------
--  Create tuning task:
---------------------------------------------------------------------------------
DECLARE
l_sql_tune_task_id VARCHAR2(100);
BEGIN
l_sql_tune_task_id := DBMS_SQLTUNE.create_tuning_task (
sql_id => 'b024whb2x0f4b',
scope => DBMS_SQLTUNE.scope_comprehensive,
time_limit => 500,
task_name => 'b024whb2x0f4b_tuning_task',
description => 'Tuning task1 for statement b024whb2x0f4b');
DBMS_OUTPUT.put_line('l_sql_tune_task_id: ' || l_sql_tune_task_id);
END;
/

-- Execute tuning task:

EXEC DBMS_SQLTUNE.execute_tuning_task(task_name => 'b024whb2x0f4b_tuning_task');

-- Get the tuning advisory report

set serveroutput on
set long 65536
set longchunksize 65536
set linesize 400
set pages 5000
select dbms_sqltune.report_tuning_task('b024whb2x0f4b_tuning_task') from dual;
---------------------------------------------------------------------------------
-- From MOS \
-- Her use case is two similar query working with defferent performance, to analyze both oracle suggested below
-- Execute the sql 1

set trimspool on
set pages 0
set linesize 1000
set long 1000000
set longchunksize 1000000
spool sqlmon_original.html
select dbms_sqltune.report_sql_monitor(type=>'active',sql_id=>'<sqlid>') from dual;
spool off

-- Execute the sql 2

set trimspool on
set pages 0
set linesize 1000
set long 1000000
set longchunksize 1000000
spool sqlmon_modified.html
select dbms_sqltune.report_sql_monitor(type=>'active',sql_id=>'<sqlid>') from dual;
spool off

-- START sqlhc.sql "T" djkbyr8vkc64h

-- then gather sqlhc report using scripts in note below.
-- SQL Tuning Health-Check Script (SQLHC) ( Doc ID 1366133.1 )
https://support.oracle.com/epmos/faces/DocumentDisplay?_afrLoop=102899328922677&parent=SrDetailText&sourceId=3-37158897111&id=1366133.1&_afrWindowMode=0&_adf.ctrl-state=fflw73gcx_168

-- Regards,
-- Yong



--

-- tkprof
------------------

sho parameter user_dump

alter session set tracefile_identifier=PT;

alter session set sql_trace=TRUE;

SELECT S.SQL_TRACE,S.SQL_TRACE_WAIT,S.SQL_TRACE_BINDS,TRACEID,TRACEFILE
FROM V$SESSION S 
JOIN V$PROCESS P ON (P.ADDR=S.PADDR)
WHERE AUDSID =USERENV('SESSIONID')
/

QUERY HERE 

SELECT S.SQL_TRACE,S.SQL_TRACE_WAIT,S.SQL_TRACE_BINDS,TRACEID,TRACEFILE
FROM V$SESSION S 
JOIN V$PROCESS P ON (P.ADDR=S.PADDR)
WHERE AUDSID =USERENV('SESSIONID')
/


alter session set sql_trace=FALSE;



-- 3401626116

-- script sql.sql
set lines 180 pages 500
col sql_id format a14
col sql_plan_baseline format a30
col plan_hash_value format 999999999999999
col exact_matching_signature format 99999999999999999999
col sql_text format a50
select sql_id,
plan_hash_value,
sql_plan_baseline,
executions,
elapsed_time,
exact_matching_signature,
substr(sql_text,0,50) sql_text
from v$sql
where parsing_schema_name != 'SYS'
and sql_text like 'SELECT p.AC_GL_NO%' ;

-- script spm.sql
set lines 200
set pages 500
col signature format 99999999999999999999
col sql_handle format a30
col plan_name format a30
col enabled format a5
col accepted format a5
col fixed format a5
select
signature,
sql_handle,
plan_name,
enabled,
accepted,
fixed
from dba_sql_plan_baselines
where signature = '&signature.'

set serveroutput on
declare
  plans_loaded pls_integer ;
begin
  plans_loaded := dbms_spm.load_plans_from_cursor_cache( sql_id => '54mpf1q3r07z4' ) ;
  dbms_output.put_line( 'plans loaded: '||plans_loaded ) ;
end ;
/





--Baseline fixing
--  - Consider creating a SQL plan baseline for the plan with the best average     elapsed time.

execute dbms_sqltune.create_sql_plan_baseline(task_name => 'TASK_37096',  owner_name => 'ABFCUBSLIVE', plan_hash_value => 3401626116);

execute dbms_sqltune.create_sql_plan_baseline(task_name => 'TASK_37096',  owner_name => 'SYS', plan_hash_value => 264656111);


-- ===========================================================================================
-- 1. SQL_ID 6h8s7rxahh832 ,Plan hash value: 4202842841

--------------------
DELETE FROM LN_DRAWDOWN_ACTIONS WHERE DRAWDOWN_DATE <= :B1
-- Plan hash value: 4202842841

-- 2. SQL_ID f2sq9zc66vaa5 -- Plan hash value: 2059333316
--------------------
select interestca0_.cod_acct_no as cod_acct_no1_1231_, interestca0_.id
as id2_1231_, interestca0_.flg_int_type as flg_int_type3_1231_,
interestca0_.date_time as date_time4_1231_, interestca0_.dat_to as
dat_to5_1231_, interestca0_.dat_from as dat_from6_1231_,
interestca0_.no_of_days as no_of_days7_1231_,
interestca0_.effective_rate as effective_rate8_1231_,
interestca0_.amt_base as amt_base9_1231_, interestca0_.amt_int as
amt_int10_1231_, interestca0_.base_compounding as
base_compounding11_1231_, interestca0_.flg_from as flg_from12_1231_
from ln_tmp_rln_interest interestca0_ where interestca0_.cod_acct_no=:1
 and interestca0_.dat_from>=:2 and interestca0_.dat_to<=:3 and
interestca0_.flg_from=:4 order by interestca0_.dat_from
Plan hash value: 2059333316


--  3. SQL_ID fxsbxdwhg6dk0
-- Plan hash value: 3150996987
-- ======================================================================================
-- How to Load SQL Plans into SQL Plan Management (SPM) from the Automatic Workload Repository (AWR) (Doc ID 789888.1)
-- sql id :dqqmvha779fz1

-- 1. 
BEGIN
  DBMS_SQLTUNE.CREATE_SQLSET(sqlset_name => 'SQLTUNINGSET_fxsbxdwhg6dk0');
END;
/



-- 2. 
DECLARE
  cur sys_refcursor;
BEGIN
open cur for
select value(p) from table(dbms_sqltune.select_workload_repository(
      begin_snap => 16791,
      end_snap => 16793,
      basic_filter => 'sql_id IN (''fxsbxdwhg6dk0'') AND plan_hash_value = ''3150996987''')) p;
    dbms_sqltune.load_sqlset('SQLTUNINGSET_fxsbxdwhg6dk0', cur);
  close cur;
END;
/




-- 3.
DECLARE
my_plans PLS_INTEGER;
BEGIN
my_plans := DBMS_SPM.LOAD_PLANS_FROM_SQLSET(
   sqlset_name => 'SQLTUNINGSET_fxsbxdwhg6dk0',
    fixed => 'YES');
END;
/

-- 4. check :

SELECT SQL_HANDLE, SQL_TEXT, PLAN_NAME,ORIGIN, ENABLED, ACCEPTED FROM DBA_SQL_PLAN_BASELINES 
	

-- 5. verify plan:

SELECT * FROM table (DBMS_XPLAN.DISPLAY_SQLSET('SQLTUNINGSET_fxsbxdwhg6dk0','fxsbxdwhg6dk0'));

-- 6. drop spm:

BEGIN
  DBMS_SQLTUNE.DROP_SQLSET( sqlset_name => 'SQLTUNINGSET_fxsbxdwhg6dk0' );
END;
/

--! --- NOT RELATED TO ABOVE
-- basline cleanup

-- Identify the SQL Profile:
SELECT name, sql_text
FROM dba_sql_profiles
WHERE sql_text like  '&sql_txt';
-- Drop the SQL Profile:
BEGIN
    DBMS_SQLTUNE.DROP_SQL_PROFILE(name => 'coe_gr47njcx4gys9_1887136398');
END;
/
-- Identify the SQL Plan Baseline:
SELECT sql_handle, plan_name, sql_id, sql_text
FROM dba_sql_plan_baselines
WHERE sql_id = '&sql_id';

-- Drop the SQL Plan Baseline:
BEGIN
    DBMS_SPM.DROP_SQL_PLAN_BASELINE(
        sql_handle => 'sql_handle_value',
        plan_name  => 'plan_name_value'
    );
END;
/


SELECT s.sid, 
       s.serial#, 
       s.sql_id, 
       s.sql_child_number, 
       q.sql_text 
FROM   gv$session s 
       LEFT JOIN gv$sql q 
              ON s.sql_id = q.sql_id 
WHERE  s.sid = 2609
and 




-- MY REASEARCH 
-- ======================

-- SQL_ID 6h8s7rxahh832 ,Plan hash value: 4202842841

-- ========================================
-- 0. Query to check the multiple hash plans for sql id.
-- ========================================================
select
SQL_ID
, PLAN_HASH_VALUE
, sum(EXECUTIONS_DELTA) EXECUTIONS
, sum(ROWS_PROCESSED_DELTA) CROWS
, trunc(sum(CPU_TIME_DELTA)/1000000/60) CPU_MINS
, trunc(sum(ELAPSED_TIME_DELTA)/1000000/60)  ELA_MINS
from DBA_HIST_SQLSTAT
where SQL_ID in (
'&sql_id') --repalce sqlid with your sqlid
group by SQL_ID , PLAN_HASH_VALUE
order by SQL_ID, CPU_MINS
/

-- I find out the best execution plan (Plan_hash_value) and force the query to use that plan. 
-- Below are the steps I did to create and fix bad queries by creating SQL baseline.

-- STEP 1: GENERATE ALL PREVIOUS HISTORY RUN DETAILS OF SQL_ID FROM AWR
-- ============================================================================
break off sdate
set lines 2000
set linesize 2000
col SDATE format a10
col STIME format a10
select to_char(begin_interval_time,'YYYY/MM/DD') SDATE,to_char(begin_interval_time,'HH24:MI')  STIME,s.snap_id,
        sql_id, plan_hash_value PLAN,
        ROUND(elapsed_time_delta/1000000,2) ET_SECS,
        nvl(executions_delta,0) execs,
        ROUND((elapsed_time_delta/decode(executions_delta,null,1,0,1,executions_delta))/1000000,2) ET_PER_EXEC,
        ROUND((buffer_gets_delta/decode(executions_delta,null,1,0,1,executions_delta)), 2) avg_lio,
        ROUND((CPU_TIME_DELTA/decode(executions_delta,null,1,0,1,executions_delta))/1000, 2) avg_cpu_ms,
        ROUND((IOWAIT_DELTA/decode(executions_delta,null,1,0,1,executions_delta))/1000, 2) avg_iow_ms,
        ROUND((DISK_READS_DELTA/decode(executions_delta,null,1,0,1,executions_delta)), 2) avg_pio,
        ROWS_PROCESSED_DELTA num_rows
from DBA_HIST_SQLSTAT S,  DBA_HIST_SNAPSHOT SS
where s.sql_id = '&sql_id'
and ss.snap_id  =S.snap_id
and ss.instance_number = S.instance_number
and s.plan_hash_value=&plan_hash_value
order by sdate,stime;

--------------
-- here in this case , below are the awr snaps

-- 13231
-- 12410

-- STEP 2: DROP SQL TUNING SET (STS) IF EXISTS

-- Check
-- =====
select SQLSET_NAME from dba_sqlset_statements where SQL_ID='&sql_id';

-- DROP
-- ====
BEGIN
  DBMS_SQLTUNE.DROP_SQLSET(
    sqlset_name => 'SQL_FOR_dgfvnd04crf07');
END;




-- STEP 3: CREATE SQL TUNING SET 


BEGIN
  DBMS_SQLTUNE.create_sqlset (
    sqlset_name => 'SQL_FOR_dgfvnd04crf07',
    description => 'SQL tuning set for dgfvnd04crf07');
END;
/

/* Populate STS from AWR by specifying snapshot for a desired plan which we found using the above query.
In this scenario snap ids are 89684 and 89688 and change plan_hash_value accordingly.*/

DECLARE
  l_cursor  DBMS_SQLTUNE.sqlset_cursor;
BEGIN
  OPEN l_cursor FOR
    SELECT VALUE(p)
    FROM   TABLE (DBMS_SQLTUNE.select_workload_repository (
                    726,  -- begin_snap
                    834,  -- end_snap
                    q'<sql_id in ('dgfvnd04crf07') and plan_hash_value in (1887136398)>',  -- basic_filter 
                    NULL, -- object_filter
                    NULL, -- ranking_measure1
                    NULL, -- ranking_measure2
                    NULL, -- ranking_measure3
                    NULL, -- result_percentage
                    100)   -- result_limit
                  ) p;
  DBMS_SQLTUNE.load_sqlset (
    sqlset_name     => 'SQL_FOR_dgfvnd04crf07',   --- change this too
    populate_cursor => l_cursor);
END;
/

-- --------
-- 12087
-- 12410

-- STEP 4: CHECK SQL SET DETAILS 

column text format a20
select sqlset_name, sqlset_owner, sqlset_id, sql_id,substr(sql_text,1,20) text,elapsed_time,buffer_gets,
parsing_schema_name, plan_hash_value, bind_data from dba_sqlset_statements where sqlset_name ='SQL_FOR_dgfvnd04crf07';


-- STEP 5: LOAD DESIRED PLAN FROM STS AS SQL PLAN BASELINE

DECLARE
  L_PLANS_LOADED  PLS_INTEGER;
BEGIN
  L_PLANS_LOADED := DBMS_SPM.LOAD_PLANS_FROM_SQLSET(
    SQLSET_NAME => 'SQL_FOR_dgfvnd04crf07');
END;

-- STEP 6: CHECK SQL PLAN BASELINE DETAILS 

SELECT sql_handle, plan_name,enabled,accepted,fixed FROM dba_sql_plan_baselines
WHERE signature IN (SELECT exact_matching_signature FROM v$sql WHERE sql_id='&SQL_ID')
order by accepted,enabled;

-- STEP 7: ENABLE FIXED=YES

var pbsts varchar2(30);
exec :pbsts := dbms_spm.alter_sql_plan_baseline('SQL_912addc57994d8b5','SQL_PLAN_92aqxspwt9q5p885c598a','FIXED','YES');


-- STEP 8: PURGE OLD EXECUTION PLAN FROM SHARED POOL 

-- Find below two parameter which are required to purge specific sql from the shared pool.

select address||','||hash_value from gv$sqlarea where sql_id ='&sql_id';

-- ADDRESS||','||HASH_VALUE
-- ----------------------------------------------------------------------------------------
-- 00000001C966CDA0,3656254283

-- Now use below command to purge sql from shared pool.

exec sys.dbms_shared_pool.purge('00000001C966CDA0,3656254283','C',1);

exec sys.dbms_shared_pool.purge('&adr_hash','C',1);
-- Re-run query or program to test
-- ===========================================


--? TESTING
sho user


CREATE TABLE actb_daily_log (
    ac_sr NUMBER PRIMARY KEY,
    col1  VARCHAR2(100),
    col2  VARCHAR2(100),
    col3  NUMBER,
    col4  DATE,
    col5  VARCHAR2(200),
    col6  NUMBER,
    col7  DATE,
    col8  VARCHAR2(50),
    col9  NUMBER
);

ALTER TABLE ACTB_DAILY_LOG MODIFY PARTITION  BY HASH (AC_SR) PARTITIONS 128;


BEGIN
    FOR i IN 1..10000 LOOP
        INSERT INTO actb_daily_log (
            ac_sr, col1, col2, col3, col4, col5, col6, col7, col8, col9
        ) VALUES (
            i, 
            'Value ' || i, 
            'Data ' || i, 
            MOD(i, 1000), 
            SYSDATE - MOD(i, 365), 
            'Description ' || i, 
            MOD(i, 500), 
            SYSDATE - MOD(i, 730), 
            'Tag ' || i, 
            MOD(i, 100)
        );
    END LOOP;
    COMMIT;
END;
/

BEGIN
    FOR i IN 10001..15000 LOOP
        INSERT INTO actb_daily_log (
            ac_sr, col1, col2, col3, col4, col5, col6, col7, col8, col9
        ) VALUES (
            i * 129,  -- Ensures distribution across all 128 partitions
            'Value ' || i, 
            'Data ' || i, 
            MOD(i, 1000), 
            SYSDATE - MOD(i, 365), 
            'Description ' || i, 
            MOD(i, 500), 
            SYSDATE - MOD(i, 730), 
            'Tag ' || i, 
            MOD(i, 100)
        );
    END LOOP;
    COMMIT;
END;
/

alter index SYS_C0024595 rebuild

CREATE INDEX idx_actb_daily_log_col1 
ON actb_daily_log (col1);

CREATE INDEX idx_actb_daily_log_col4_col7 
ON actb_daily_log (col4, col7);

CREATE INDEX idx_actb_daily_log_col6 
ON actb_daily_log (col6);


-- TO MERGE HASH PARTITION
ALTER TABLE ACTB_DAILY_LOG COALESCE PARTITION PARALLEL 64;

SELECT * FROM ALL_PART_TABLES WHERE TABLE_NAME='ACTB_DAILY_LOG';

ALTER TABLE ACTB_DAILY_LOG DROP PRIMARY KEY
/
ALTER INDEX SYS_C0024595 PARALLEL 8;
DROP INDEX "ADMIN"."SYS_C0024595" ;
CREATE UNIQUE INDEX "ADMIN"."SYS_C0024595" ON "ADMIN"."ACTB_DAILY_LOG" ("AC_SR") PARALLEL 16;

ALTER INDEX SYS_C0024595 NOPARALLEL
/
ALTER TABLE ACTB_DAILY_LOG ADD CONSTRAINT SYS_C0024595 PRIMARY KEY ("AC_SR") USING INDEX SYS_C0024595 PARALLEL 16;
/

13:06
You Can Try Changing Degree Then Drop

-- =================================================
-- TABLE REDEFINITION FOR CLEANING UP THE PARTITION
-- =================================================
-- Step 1: Create an interim non-partitioned table with the same structure

CREATE TABLE ACTB_DAILY_LOG_T AS SELECT * FROM ACTB_DAILY_LOG WHERE 1=0;

-- Step 2: Start the redefinition process
BEGIN
  DBMS_REDEFINITION.START_REDEF_TABLE(
    uname        => 'ADMIN', 
    orig_table   => 'ACTB_DAILY_LOG', 
    int_table    => 'ACTB_DAILY_LOG_T'
  );
END;
/

-- Step 3: Copy dependent objects (indexes, constraints, triggers)
DECLARE
  l_num_errors PLS_INTEGER;
BEGIN
  DBMS_REDEFINITION.COPY_TABLE_DEPENDENTS(
    uname              => 'ADMIN', 
    orig_table         => 'ACTB_DAILY_LOG', 
    int_table          => 'ACTB_DAILY_LOG_T', 
    copy_indexes       => 1,  -- Use numeric value 1 instead of BOOLEAN
    copy_triggers      => TRUE, 
    copy_constraints   => TRUE, 
    copy_privileges    => TRUE, 
    ignore_errors      => FALSE,
    num_errors         => l_num_errors,
    copy_statistics    => FALSE, 
    copy_mvlog         => FALSE
  );

  DBMS_OUTPUT.PUT_LINE('Number of errors: ' || l_num_errors);
END;
/


-- Step 4: Synchronize interim table with partitioned table (optional)
BEGIN
  DBMS_REDEFINITION.SYNC_INTERIM_TABLE(
    uname      => 'ADMIN', 
    orig_table => 'ACTB_DAILY_LOG', 
    int_table  => 'ACTB_DAILY_LOG_T'
  );
END;
/

-- Step 5: Complete the redefinition process
BEGIN
  DBMS_REDEFINITION.FINISH_REDEF_TABLE(
    uname        => 'ADMIN', 
    orig_table   => 'ACTB_DAILY_LOG', 
    int_table    => 'ACTB_DAILY_LOG_T'
  );
END;
/

-- Step 6: Drop the interim table if redefinition is successful
DROP TABLE ACTB_DAILY_LOG_T;



--! usefull queries / sequenced queries
-- ===========================================
-- ===========================================
-- ===========================================
-- ===========================================




-- 1.	How to identify the sid using Client Process id?

select sid 
from  v$session 
where process=’&client_process_id’;

-- 2.	How to identify the sid using Server Process id?
      
	select  sid,machine,process,module
	from   v$session 
	where paddr in (select addr from v$process
	                          where background is null 
	                          and    spid=&Server_process_id);
	
-- 3.	How to Identify the Server Process Id using the oracle session id (sid) ?

select spid from  gv$process 
where background is null 
and     addr in (select paddr
                        from   gv$session
                        where  sid=&session_id);
          
 
-- 4.	How to identify the sessions which are Inactive for more than 1 hour?

select  sid,serial#
from   gv$session
where  paddr in (select addr from gv$process where  background is null)
and     status='INACTIVE'  and  last_call_et/60/60>1;  

select 'alter system disconnect session '''||sid||','|| serial#||''' IMMEDIATE;'
from gv$session
WHERE
TYPE='USER'
AND last_call_et >=3600
AND paddr in (select addr from v$process where  background is null)
and status='INACTIVE'
AND substr(NVL(CLIENT_IDENTIFIER,'X'),1,8) <> 'menucall'
/



-- 5.	How to identify the sql used by a session?

      select  sql.sql_text,program_id
      from   v$session ses, v$sqltext sql
      where sql.address=ses.sql_address
      and     sql.hash_value=ses.sql_hash_value
      and     sid=&session_id
      order   by piece;

-- 'ACTIVE'

-- 6.	How to identify the rollback/Undo segments used by a session?

select * 
from   v$rollname
where usn = (select xidusn 
                      from   v$transaction
                      where addr in (select taddr 
                                              from   v$session
                                              where sid=&session_id));

-- 7.	How to troubleshoot temp space issues?

-- Step 1:  The following query will give you the Temp segment usage:

              select current_users, free_blocks, used_blocks, total_blocks
              from   v$sort_segment;

-- Step 2:   The following query will give the sessions using the temp space:

               select sess.sid 
               from   v$session sess, v$sort_usage su 
               where sess.saddr   =su.session_addr 
               and     sess.serial# =su.session_num;

-- Step 3:   Identify the Session Query Using the Point No. 5.

-- Step 4.   Work with the application Developer and find out why the session is           
--               using more temp space. (You can also trouble shoot using the approach 
--               mentioned in Point No. 11).


-- 8.	How to identify the free space in undo tablespaces?

select sum(bytes)/1024/1024/1024, status, tablespace_name
from  dba_undo_extents
      group by status, tablespace_name;

--       Definition of Transaction Status:
-- a.	ACTIVE means that this undo segment contains active transactions
-- b.	EXPIRED means that this segment is not required at all (as per undo_retention).
-- c.	UNEXPIRED means that this segment does not contain any active transactions but it contains transactions which are still required for Flashback option (as per Undo_retention).


-- 9.	How to Handle Max no of processes exceeded (ORA-00020) error?

-- Fix:

-- Step  1 : Connect to the database as sqlplus “/ as sysdba”
-- Step  2:  Identify the Inactive process based on some threshold (may be Session
--               Inactive for more than 5 hours) using the query given in Point No 4 
--               and then kill them. (Check for the guidelines documents for 
--               killing the session with  your Senior dba’s/Manager/Client).

-- Long Term Solution:

-- Step 1: Write a script to Identify and report the Inactive Sessions 
--              Running for Long Hours and Schedule this in Cron. Analyze this report 
--              and take Corrective Action.

-- Step 2:  Check the following:
             select  SESSIONS_HIGHWATER, SESSIONS_MAX
             from    v$license;

             SESSION_HIGHWATER = Highest number of concurrent user sessions  
                                                            since the instance started.
          
             SESSIONS_MAX              = Maximum number of concurrent user 
                                                            sessions allowed for the instance

-- Step 3: Check the Process parameter value set in init.ora file.

-- Step 4: If the Process parameter value is less than session_highwater value,  
--             Take Necessary approvals and Get the downtime to Shutdown the   
--              instance.

-- Step 5: Increase the value of the Process init.ora parameter upto the value of  
--             session_highwater value.

 
-- 10.	How to identify the wait events for a Session?

select p1, p2, p3, event
from   v$session_wait
where sid=&session_id;

-- Also check the following:

select count(*), event 
from    v$session_wait
group   by event;


-- 11.	Why the session is taking more time than normal?

-- Step 1: Check the Alert log for errors
-- Step 2: Check with the end user on how long the session used to take to complete.
-- Step 3: Check with user whether any increase in the volume of data being 
--              Processed.
-- Step 4:  Check the wait events for this sessions by using the query given in Point
--               No.10.
-- Step 5:  Identify the tables begin accessed by that session using the Point No.18.
-- Step 6:  Check whether Statistics have been generated for these tables identified 
--               in Step 4 using the following query:

              select  last_analyzed, num_rows
              from   dba_tables
              where  owner=’&table_owner’
              and      table_name=’&object_name’;

              Note: If the table is partitioned, check in dba_tab_partitions also and 
                         for subpartitions check in dba_tab_subpartitions.

-- Step 7: Check whether Statistics have been generated for the indexes of the tables Identified in Step 4 Using the following query:

             select  last_analyzed, num_rows
             from   dba_indexes
             where  table_owner=’&table_owner’
             and      table_name=’&table_name’;

--              Note: If the table is partitioned, check in dba_ind_partitions and for 
--                        subpartitions check in dba_ind_subpartitions.

-- Step 8:  If Statistics is not up-to-date, Generate stats using dbms_stats package. 
-- Step 9:  Follow the approach given in Point No 20 for sql tuning.

-- 12.	Is the session hanging or running fine?

select last_call_et/60/60, status
from  v$session 
where sid=&session_id;

-- If the Status in the above query is 'ACTIVE', then the current sql being executed by the session  is running for so many hours(last_call_et/60/60).

-- If the time taken by the current sql is too high, then trouble shoot using the steps mentioned in Point No. 11.

-- If the Status in the above query is 'INACTIVE', then the session is 'INACTIVE' for so many hours(last_call_et/60/60).  
-- If you run the query mentioned in Point No. 5, You may not get any sql. 
--       ou can discuss with the end user and you can kill this session and re-start the job.

-- 13.	How to handle 'db file sequential Read' wait event?

--      db file sequential Read wait event signify time waited for I/O read requests to       
--      complete.  Time is reported in 1000s of a second.  

--     A db file sequential read operation reads data into contiguous memory 
--     (usually a single-block read with p3=1, but can be multiple blocks). 
--     Single block I/Os are usually the result of using indexes. 
--     This event is also used for rebuilding the control file and 
--     reading datafile headers (P2=1). In general, this event is indicative of 
--     disk contention on index reads. 

--     Find out the P1, P2, and P3 for this Wait event using the query mentioned in Point   
--     No 10.
--     In this case:
--     P1 = file#
--     P2 = block#
--     P3 = blocks

--     To find out the Segment on which it is doing the db file sequential read, Use the    
--     following query:

    select segment_name
    from  dba_extents 
    where file_id=&p1
    and     p2 between block_id and block_id+blocks-1;

--     Follow the Steps Mentioned in  Point No. 11 to troubleshoot it further.

-- 14.	How to handle “db file scattered Read” wait event?
  
--             A db file scattered read is the same type of event as "db file sequential read",
--             Except that Oracle will read multiple data blocks. Multi-block reads are
--             typically used on full table scans. The name "scattered read" may seem  
--             misleading but it refers to the fact that multiple blocks are read into DB block 
--             buffers that are 'scattered' throughout memory.

--       Find out the P1, P2 and P3 for this Wait event using the query mentioned in Point       
--       No 10.
--       In this case:

--      P1 = file#
--      P2 = block#
--      P3 = blocks

--     To find out the Segment on which it is doing the db file sequential read, Use the    
--     following query:

    select segment_name
    from  dba_extents 
    where file_id=&p1
    and     p2 between block_id and block_id+blocks-1;

--     Follow the Steps Mentioned in  Point No. 11 to troubleshoot it further.

-- 15.	Why should we avoid using trunate command in a production database?

--              The truncate invalidates current cursors that are dependent on the object
--              being truncated - this could lead to  lot of library cache latch activity, 
--              and  subsequent re-parse costs. (Can be monitored in v$librarycache as
--              invalidations).

-- 16.	What should we do if the CPU load on the server is high?

-- Use the top command to identify the top 5 sessions.  Identify the process id of these top sessions. 
-- Identify the Oracle Session id using the query given in Point No. 2.
-- Identify the SQL used by this session using the query given in Point No. 5.

-- Follow the Steps mentioned in the Point No 11 to Troubleshoot it further.
-- 17.	How to identify the sid of the session in the remote database?

-- Step 1: Identify the spid of the Session in the local database:

select spid 
from  v$process 
where background is null 
and     addr in (select paddr
                        from   v$session
                        where  sid=&session_id);

-- Step 2: Identify the Session id in the Remote Database:

select sid 
from  v$session 
where process=’&SPID_IDENTIFIED_IN_STEP 1’;

-- 18.	How to identify the objects accessed by a session?

select owner, object, type
from   v$access
where sid=&session_id
and     owner not in (‘SYS’,’SYSTEM’);

-- 19.	How to identify the parallel sessions for any oracle session id?

Select qcsid, sid 
from   v$px_session
where qcsid=&session_id;

-- 20.	What is the best approach for Tuning an Oracle Sql Query?
           
--               Avoid Using the Following:
-- a.	Boolean Operators, Is null & Is not Null.
-- b.	not in, != Operators
-- c.	like ‘%patterns’, not exists
           
--              Do’s:

-- a.	Enable aliases to prefix all columns.
-- b.	Use sql joins instead of sub-queries
-- c.	Make the tables with the least number of rows as the driving table by keeping them first in the FROM clause.
-- d.	Use concatenated indexes wherever appropriate.
-- e.	Pick up the Best Join method.
-- f.	Nested loops joins are best for indexed joins of subsets.
-- g.	Hash joins are usually the best choice for "big" joins
-- h.	Pick the best "driving" table
-- i.	Use bind variables. Bind variables are key to application scalability.
-- j.	Use Oracle hints wherever appropriate
-- k.	Compare performance between alternative syntax for your SQL statement


--                   Use Explain Plan to Identify the Access path being used by the query.
--                   Syntax is explain plan for actual_sql_statement;

--                   You can see the output of the explain plan by running the following sql:
--                    $ORACLE_HOME/rdbms/admin/utlxplp.sql

--                   Alternatively, You can also trace the session by using the 
--                   following Command: 

--                   alter session set events '10046 trace name context forever,level 12';
--                   Run the sql Query.  This will generate the trace file in udump directory.

--                   Use tkprof utility to get the readable output of this trace file.  Use the 
--                   following Syntax:

--                   tkprof trace_file_name trace_file_name.out sys=no explain=userid/pwd

--                   This tkprof output file trace_file_name.out will have the access path 
--                   Used by the queries and as well the various timed statistics like 
--                   cpu time, elapsed time etc.
