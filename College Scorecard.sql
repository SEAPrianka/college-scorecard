CREATE OR REPLACE DIRECTORY DATA_DIR AS '/u01/data';

GRANT READ, WRITE ON DIRECTORY DATA_DIR TO YOUR_SCHEMA;

CREATE TABLE STG_SCORECARD
ORGANIZATION EXTERNAL ( TYPE ORACLE_LOADER
    DEFAULT DIRECTORY DATA_DIR ACCESS PARAMETERS (
        RECORDS
        DELIMITED BY NEWLINE
        SKIP 1
        FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
    ) LOCATION ( 'MERGED2023_24_PP.csv' )
) REJECT LIMIT UNLIMITED;

CREATE TABLE FACT_SCORECARD
    AS
        SELECT
            UNITID,
            INSTNM,
            STABBR,
            CONTROL,
            PREDDEG,
            ADM_RATE,
            SAT_AVG,
            NPT4_PUB,
            NPT4_PRIV,
            RET_FT4,
            C150_4,
            UGDS,
            PCTPELL
        FROM
            STG_SCORECARD
        WHERE
            ADM_RATE IS NOT NULL;

ALTER TABLE FACT_SCORECARD ADD (
    ADM_RATE_PCT  NUMBER GENERATED ALWAYS AS ( ADM_RATE * 100 ) VIRTUAL,
    PELL_PCT      NUMBER GENERATED ALWAYS AS ( PCTPELL * 100 ) VIRTUAL,
    GRAD_RATE_PCT NUMBER GENERATED ALWAYS AS ( C150_4 * 100 ) VIRTUAL,
    RET_RATE_PCT  NUMBER GENERATED ALWAYS AS ( RET_FT4 * 100 ) VIRTUAL
);

SELECT
    NVL(STABBR, 'ALL STATES') AS STATE,
    CASE CONTROL
        WHEN 1 THEN
            'Public'
        WHEN 2 THEN
            'Private Nonprofit'
        WHEN 3 THEN
            'Private For-Profit'
        ELSE
            'Unknown'
    END                       AS CONTROL_TYPE,
    ROUND(
        AVG(ADM_RATE_PCT),
        2
    )                         AS AVG_ADM,
    ROUND(
        AVG(GRAD_RATE_PCT),
        2
    )                         AS AVG_GRAD,
    ROUND(
        AVG(RET_RATE_PCT),
        2
    )                         AS AVG_RET,
    COUNT(*)                  AS N_INST
FROM
    FACT_SCORECARD
GROUP BY
    ROLLUP(STABBR,
           CONTROL)
ORDER BY
    STATE,
    CONTROL_TYPE;

SELECT
    STABBR,
    INSTNM,
    ROUND(GRAD_RATE_PCT, 1) AS GRAD_RATE,
    NTILE(10)
    OVER(PARTITION BY STABBR
         ORDER BY
             GRAD_RATE_PCT DESC
    )                       AS DECILE,
    RANK()
    OVER(PARTITION BY STABBR
         ORDER BY
             GRAD_RATE_PCT DESC
    )                       AS RANK_IN_STATE
FROM
    FACT_SCORECARD
WHERE
    GRAD_RATE_PCT IS NOT NULL
ORDER BY
    STABBR,
    RANK_IN_STATE;

SELECT
    *
FROM
    (
        SELECT
            CASE CONTROL
                WHEN 1 THEN
                    'Public'
                WHEN 2 THEN
                    'Private Nonprofit'
                WHEN 3 THEN
                    'Private For-Profit'
            END AS CONTROL_TYPE,
            ROUND(
                AVG(ADM_RATE_PCT),
                2
            )   AS ADM,
            ROUND(
                AVG(GRAD_RATE_PCT),
                2
            )   AS GRAD,
            ROUND(
                AVG(RET_RATE_PCT),
                2
            )   AS RETENTION
        FROM
            FACT_SCORECARD
        GROUP BY
            CONTROL
    ) PIVOT (
        MAX(ADM)
    AS ADM,
    MAX(GRAD) AS GRAD,
    MAX(RETENTION) AS RET
        FOR CONTROL_TYPE
        IN ( 'Public' AS PUB, 'Private Nonprofit' AS PRIVNP, 'Private For-Profit' AS PRIVFP )
    );

WITH STATS AS (
    SELECT
        RET_RATE_PCT,
        ( RET_RATE_PCT - AVG(RET_RATE_PCT)
                         OVER() ) / NULLIF(STDDEV(RET_RATE_PCT)
                                           OVER(),
                                           0) AS Z_SCORE,
        INSTNM,
        STABBR
    FROM
        FACT_SCORECARD
    WHERE
        RET_RATE_PCT IS NOT NULL
)
SELECT
    INSTNM,
    STABBR,
    ROUND(RET_RATE_PCT, 1) AS RET_RATE,
    ROUND(Z_SCORE, 2)      AS Z_SCORE
FROM
    STATS
WHERE
    ABS(Z_SCORE) > 2
ORDER BY
    ABS(Z_SCORE) DESC
FETCH FIRST 25 ROWS ONLY;

SELECT
    *
FROM
    (
        SELECT
            INSTNM,
            CAST(2023 AS NUMBER) AS YEAR,
            UGDS                 AS ENROLLMENT
        FROM
            FACT_SCORECARD
    ) MATCH_RECOGNIZE (
        PARTITION BY INSTNM
        ORDER BY
            YEAR
        MEASURES
            FIRST ( A.ENROLLMENT ) AS START_ENR,
            LAST ( C.ENROLLMENT ) AS END_ENR
        ONE ROW PER MATCH
    PATTERN ( A B C ) DEFINE
        A AS TRUE,
        B AS ( B.ENROLLMENT < A.ENROLLMENT * 0.95 ),
        C AS ( C.ENROLLMENT < B.ENROLLMENT * 0.95 )
    );

WITH BASE AS (
    SELECT
        INSTNM,
        SAT_AVG,
        NPT4_PUB      AS NET_PRICE,
        RET_FT4 * 100 AS RET_RATE
    FROM
        FACT_SCORECARD
    WHERE
            CONTROL = 1
        AND SAT_AVG IS NOT NULL
        AND NPT4_PUB IS NOT NULL
)
SELECT
    INSTNM,
    ROUND(RET0, 1) AS BASE_RET,
    ROUND(RET1, 1) AS SCENARIO_RET
FROM
    BASE
MODEL
    DIMENSION BY ( INSTNM )
    MEASURES ( RET_RATE RET0, SAT_AVG S, NET_PRICE P, 0 RET1 )
    RULES (
        RET1[INSTNM]= 1 / ( 1 + EXP(-(- 50 + 0.05 *(S[CV()]+ 50) - 0.002 *(P[CV()]* 0.9))) ) * 100
    )
ORDER BY
    SCENARIO_RET - BASE_RET DESC
FETCH FIRST 15 ROWS ONLY;

WITH MODEL AS (
    SELECT
        INSTNM,
        STABBR,
        SAT_AVG,
        GRAD_RATE_PCT,
        ( 0.07 * SAT_AVG - 50 )                 AS EXP_GRAD,
        GRAD_RATE_PCT - ( 0.07 * SAT_AVG - 50 ) AS RESID
    FROM
        FACT_SCORECARD
    WHERE
        SAT_AVG IS NOT NULL
        AND GRAD_RATE_PCT IS NOT NULL
)
SELECT
    INSTNM,
    STABBR,
    ROUND(SAT_AVG, 0)       AS SAT,
    ROUND(GRAD_RATE_PCT, 1) AS GRAD,
    ROUND(RESID, 1)         AS RESIDUAL
FROM
    MODEL
WHERE
    RESID < - 10
ORDER BY
    RESID ASC
FETCH FIRST 20 ROWS ONLY;

SELECT
    STABBR,
    ROUND(
        CORR(GRAD_RATE_PCT, PELL_PCT),
        3
    ) AS CORR_GRAD_PELL,
    ROUND(
        AVG(GRAD_RATE_PCT),
        1
    ) AS AVG_GRAD,
    ROUND(
        AVG(PELL_PCT),
        1
    ) AS AVG_PELL
FROM
    FACT_SCORECARD
WHERE
    GRAD_RATE_PCT IS NOT NULL
    AND PELL_PCT IS NOT NULL
GROUP BY
    STABBR
ORDER BY
    CORR_GRAD_PELL;

CREATE TABLE DIM_STATE (
    STABBR     CHAR(2) PRIMARY KEY,
    REGION     VARCHAR2(25),
    COST_INDEX NUMBER(5, 2)
);

INSERT INTO DIM_STATE (
    STABBR,
    REGION,
    COST_INDEX
) VALUES ( 'CA',
           'West',
           1.15 );

INSERT INTO DIM_STATE (
    STABBR,
    REGION,
    COST_INDEX
) VALUES ( 'TX',
           'South',
           0.95 );

INSERT INTO DIM_STATE (
    STABBR,
    REGION,
    COST_INDEX
) VALUES ( 'NY',
           'Northeast',
           1.20 );

INSERT INTO DIM_STATE (
    STABBR,
    REGION,
    COST_INDEX
) VALUES ( 'FL',
           'South',
           0.90 );

INSERT INTO DIM_STATE (
    STABBR,
    REGION,
    COST_INDEX
) VALUES ( 'IL',
           'Midwest',
           1.05 );

COMMIT;

SELECT
    S.STABBR AS STATE,
    D.REGION,
    ROUND(
        AVG(F.ADM_RATE * 100),
        2
    )        AS AVG_ADM_RATE,
    ROUND(
        AVG(F.C150_4 * 100),
        2
    )        AS AVG_GRAD_RATE
FROM
         FACT_SCORECARD F
    INNER JOIN DIM_STATE D ON F.STABBR = D.STABBR
GROUP BY
    S.STABBR,
    D.REGION
ORDER BY
    AVG_GRAD_RATE DESC;

SELECT
    F.STABBR,
    NVL(D.REGION, 'Unknown') AS REGION,
    COUNT(DISTINCT F.UNITID) AS N_INSTITUTIONS,
    ROUND(
        AVG(F.RET_FT4 * 100),
        1
    )                        AS AVG_RETENTION
FROM
    FACT_SCORECARD F
    LEFT OUTER JOIN DIM_STATE      D ON F.STABBR = D.STABBR
GROUP BY
    F.STABBR,
    D.REGION
ORDER BY
    AVG_RETENTION DESC;

SELECT
    NVL(F.STABBR, D.STABBR)  AS STATE,
    D.REGION,
    COUNT(DISTINCT F.UNITID) AS N_INSTITUTIONS
FROM
    FACT_SCORECARD F
    FULL OUTER JOIN DIM_STATE      D ON F.STABBR = D.STABBR
GROUP BY
    NVL(F.STABBR, D.STABBR),
    D.REGION
ORDER BY
    STATE;

SELECT
    INSTNM,
    STABBR,
    ROUND(C150_4 * 100, 1)  AS GRAD_RATE,
    ROUND(PCTPELL * 100, 1) AS PELL_PCT,
    CASE
        WHEN C150_4 >= 0.70                THEN
            'High Performing'
        WHEN C150_4 BETWEEN 0.50 AND 0.699 THEN
            'Average'
        ELSE
            'Low Performing'
    END                     AS PERFORMANCE_BAND,
    CASE
        WHEN PCTPELL > 0.5
             AND C150_4 < 0.5 THEN
            'Equity Concern'
        WHEN PCTPELL > 0.5
             AND C150_4 >= 0.5 THEN
            'Inclusive Success'
        ELSE
            'Other'
    END                     AS EQUITY_FLAG
FROM
    FACT_SCORECARD
WHERE
    C150_4 IS NOT NULL
    AND PCTPELL IS NOT NULL
ORDER BY
    PERFORMANCE_BAND,
    GRAD_RATE DESC;

SELECT
    F.INSTNM,
    F.STABBR,
    D.REGION,
    ROUND(F.NPT4_PUB / NULLIF(D.COST_INDEX, 0),
          0)                 AS ADJ_NET_PRICE,
    ROUND(F.C150_4 * 100, 1) AS GRAD_RATE
FROM
    FACT_SCORECARD F
    LEFT JOIN DIM_STATE      D ON F.STABBR = D.STABBR
WHERE
        F.CONTROL = 1
    AND F.NPT4_PUB IS NOT NULL
ORDER BY
    ADJ_NET_PRICE DESC
FETCH FIRST 15 ROWS ONLY;