PRAGMA foreign_keys = ON;

BEGIN IMMEDIATE;


/**********************************************************************
 * 1. BUILD BACKFILL DATA
 **********************************************************************/

DROP TABLE IF EXISTS temp.weather_backfill;
DROP TABLE IF EXISTS temp.sensor_cleanup;


CREATE TEMP TABLE weather_backfill AS
WITH

target AS (
    SELECT metadata_id
    FROM states_meta
    WHERE entity_id = 'sensor.outdoor_temperature'
),

/*
 * Use the newest existing sensor attributes as the template.
 * If there aren't any usable attributes yet, construct the basic set.
 */
base AS (
    SELECT COALESCE(
        (
            SELECT sa.shared_attrs
            FROM states AS s

            JOIN target AS t
              ON t.metadata_id = s.metadata_id

            LEFT JOIN state_attributes AS sa
              ON sa.attributes_id = s.attributes_id

            WHERE sa.shared_attrs IS NOT NULL

            ORDER BY s.last_updated_ts DESC
            LIMIT 1
        ),

        json_object(
            'state_class', 'measurement',
            'unit_of_measurement', '°F',
            'device_class', 'temperature',
            'friendly_name', 'Outdoor Temperature'
        )
    ) AS attrs
),

raw AS (
    SELECT
        ws.state_id AS source_state_id,
        ws.last_updated_ts AS source_ts,

        /*
         * Numeric source temperature becomes the sensor state.
         * If no valid temperature was supplied, preserve the update
         * as HA state "unknown".
         */
        CASE
            WHEN json_type(
                     wa.shared_attrs,
                     '$.temperature'
                 ) IN ('integer', 'real')
            THEN CAST(
                     json_extract(
                         wa.shared_attrs,
                         '$.temperature'
                     ) AS TEXT
                 )
            ELSE 'unknown'
        END AS sensor_state,

        /*
         * weather.forecast_home's state is the weather condition.
         */
        ws.state AS condition,

        /*
         * Preserve source_ts as a JSON number with six decimal places.
         *
         * This avoids SQLite json_set() shortening, for example:
         *
         *   1786905437.607608
         *
         * to:
         *
         *   1786905437.60761
         */
        json_set(
            (SELECT attrs FROM base),

            '$.condition',
            ws.state,

            '$.source_ts',
            json(printf('%.6f', ws.last_updated_ts))
        ) AS attrs_json

    FROM states AS ws

    JOIN states_meta AS wm
      ON wm.metadata_id = ws.metadata_id

    LEFT JOIN state_attributes AS wa
      ON wa.attributes_id = ws.attributes_id

    CROSS JOIN target AS t

    WHERE wm.entity_id = 'weather.forecast_home'

      AND ws.last_updated_ts IS NOT NULL

      /*
       * Mainly makes this safe against an already-backfilled exact row.
       * On a fresh DB copy this normally won't exclude anything.
       */
      AND NOT EXISTS (
          SELECT 1
          FROM states AS existing

          WHERE existing.metadata_id = t.metadata_id

            AND ABS(
                    existing.last_updated_ts
                    - ws.last_updated_ts
                ) < 0.0000005
      )
),

/*
 * Determine runs of identical sensor states so last_changed_ts
 * resembles normal HA Recorder semantics.
 */
marked AS (
    SELECT
        *,

        CASE
            WHEN LAG(sensor_state)
                 OVER (ORDER BY source_ts) = sensor_state
            THEN 0
            ELSE 1
        END AS new_run

    FROM raw
),

grouped AS (
    SELECT
        *,

        SUM(new_run)
            OVER (ORDER BY source_ts) AS run_no

    FROM marked
)

SELECT
    source_state_id,
    source_ts,
    sensor_state,
    condition,
    attrs_json,

    MIN(source_ts)
        OVER (PARTITION BY run_no) AS run_start_ts

FROM grouped;


/**********************************************************************
 * 2. CREATE ATTRIBUTE ROWS
 **********************************************************************/

/*
 * source_ts makes these attribute sets inherently unique, so we
 * don't need to reproduce Recorder's FNV hash here.
 */
INSERT INTO state_attributes (
    hash,
    shared_attrs
)
SELECT
    NULL,
    attrs_json

FROM weather_backfill

ORDER BY source_ts;


/**********************************************************************
 * 3. CREATE HISTORICAL SENSOR STATES
 **********************************************************************/

INSERT INTO states (
    metadata_id,
    state,
    last_changed_ts,
    last_reported_ts,
    last_updated_ts,
    old_state_id,
    attributes_id,
    context_id_bin,
    context_user_id_bin,
    context_parent_id_bin,
    origin_idx
)

SELECT
    tm.metadata_id,

    wb.sensor_state,

    /*
     * HA stores NULL when last_changed == last_updated.
     * Otherwise retain the beginning of the same-state run.
     */
    CASE
        WHEN wb.source_ts = wb.run_start_ts
        THEN NULL
        ELSE wb.run_start_ts
    END,

    NULL,                       -- last_reported_ts

    wb.source_ts,               -- exact original weather timestamp

    NULL,                       -- old_state_id

    /*
     * Get the attribute row just inserted for this sample.
     */
    (
        SELECT MAX(sa.attributes_id)

        FROM state_attributes AS sa

        WHERE sa.hash IS NULL
          AND sa.shared_attrs = wb.attrs_json
    ),

    NULL,                       -- context_id_bin
    NULL,                       -- context_user_id_bin
    NULL,                       -- context_parent_id_bin

    0                           -- local origin

FROM weather_backfill AS wb

CROSS JOIN states_meta AS tm

WHERE tm.entity_id = 'sensor.outdoor_temperature'

ORDER BY wb.source_ts;


/**********************************************************************
 * 4. BUILD LIST OF SENSOR ROWS TO REMOVE
 **********************************************************************/

CREATE TEMP TABLE sensor_cleanup (
    state_id       INTEGER PRIMARY KEY,
    attributes_id INTEGER,
    reason         TEXT
);


/**********************************************************************
 * 4A. REMOVE RESTART/INITIALIZATION "unknown" ROWS
 *
 * These are sensor rows with:
 *
 *   state = unknown
 *   no source_ts
 *
 * followed within 60 seconds by a proper source-backed sensor row.
 *
 * A real source observation such as:
 *
 *   unknown / unavailable / source_ts=<timestamp>
 *
 * does NOT match this test and is retained.
 **********************************************************************/

INSERT OR IGNORE INTO sensor_cleanup (
    state_id,
    attributes_id,
    reason
)

SELECT
    s.state_id,
    s.attributes_id,
    'startup unknown'

FROM states AS s

JOIN states_meta AS sm
  ON sm.metadata_id = s.metadata_id

LEFT JOIN state_attributes AS sa
  ON sa.attributes_id = s.attributes_id

WHERE sm.entity_id = 'sensor.outdoor_temperature'

  AND s.state = 'unknown'

  AND json_extract(
          sa.shared_attrs,
          '$.source_ts'
      ) IS NULL

  AND EXISTS (
      SELECT 1

      FROM states AS n

      LEFT JOIN state_attributes AS na
        ON na.attributes_id = n.attributes_id

      WHERE n.metadata_id = s.metadata_id

        AND n.last_updated_ts > s.last_updated_ts

        AND n.last_updated_ts
              <= s.last_updated_ts + 60

        AND json_extract(
                na.shared_attrs,
                '$.source_ts'
            ) IS NOT NULL
  );


/**********************************************************************
 * 4B. FIND MULTIPLE SENSOR ROWS REPRESENTING THE SAME WEATHER ROW
 *
 * Don't compare source_ts values for exact equality.
 *
 * Instead:
 *
 *   1. Match each sensor source_ts to an actual weather row
 *      within 100 us.
 *
 *   2. If multiple sensor rows map to the same weather state_id,
 *      keep the sensor row whose own timestamp is closest to the
 *      weather row timestamp.
 *
 * A backfilled row should have difference = 0 and therefore win.
 **********************************************************************/

WITH

sensor_rows AS (
    SELECT
        s.state_id,
        s.attributes_id,
        s.last_updated_ts,

        CAST(
            json_extract(
                sa.shared_attrs,
                '$.source_ts'
            ) AS REAL
        ) AS source_ts

    FROM states AS s

    JOIN states_meta AS sm
      ON sm.metadata_id = s.metadata_id

    LEFT JOIN state_attributes AS sa
      ON sa.attributes_id = s.attributes_id

    WHERE sm.entity_id = 'sensor.outdoor_temperature'

      AND json_extract(
              sa.shared_attrs,
              '$.source_ts'
          ) IS NOT NULL
),

weather_rows AS (
    SELECT
        s.state_id AS weather_state_id,
        s.last_updated_ts AS weather_ts

    FROM states AS s

    JOIN states_meta AS sm
      ON sm.metadata_id = s.metadata_id

    WHERE sm.entity_id = 'weather.forecast_home'

      AND s.last_updated_ts IS NOT NULL
),

/*
 * Generate possible source-weather matches within 100 microseconds,
 * then choose the nearest one for each sensor row.
 */
candidates AS (
    SELECT
        sr.*,

        wr.weather_state_id,
        wr.weather_ts,

        ROW_NUMBER() OVER (
            PARTITION BY sr.state_id

            ORDER BY
                ABS(
                    wr.weather_ts
                    - sr.source_ts
                ),

                wr.weather_state_id
        ) AS match_rank

    FROM sensor_rows AS sr

    JOIN weather_rows AS wr

      ON ABS(
             wr.weather_ts
             - sr.source_ts
         ) < 0.0001
),

matched AS (
    SELECT *
    FROM candidates
    WHERE match_rank = 1
),

/*
 * For each actual source-weather row, choose which sensor row to keep.
 */
ranked AS (
    SELECT
        *,

        COUNT(*) OVER (
            PARTITION BY weather_state_id
        ) AS copies,

        ROW_NUMBER() OVER (
            PARTITION BY weather_state_id

            ORDER BY

                /*
                 * Backfilled rows should normally be exactly zero.
                 */
                ABS(
                    last_updated_ts
                    - weather_ts
                ),

                last_updated_ts,

                state_id
        ) AS rn

    FROM matched
)

INSERT OR IGNORE INTO sensor_cleanup (
    state_id,
    attributes_id,
    reason
)

SELECT
    state_id,
    attributes_id,
    'duplicate source weather row'

FROM ranked

WHERE copies > 1
  AND rn > 1;


/**********************************************************************
 * 5. SHOW WHAT WILL BE DELETED
 *
 * Since you're running this on a temp DB copy, this is informational;
 * execution continues after the SELECT.
 **********************************************************************/

SELECT
    c.reason,

    s.state_id,

    datetime(
        s.last_updated_ts,
        'unixepoch',
        'localtime'
    ) AS time,

    printf(
        '%.6f',
        s.last_updated_ts
    ) AS row_ts,

    s.state,

    json_extract(
        sa.shared_attrs,
        '$.condition'
    ) AS condition,

    printf(
        '%.6f',
        CAST(
            json_extract(
                sa.shared_attrs,
                '$.source_ts'
            ) AS REAL
        )
    ) AS source_ts

FROM sensor_cleanup AS c

JOIN states AS s
  ON s.state_id = c.state_id

LEFT JOIN state_attributes AS sa
  ON sa.attributes_id = s.attributes_id

ORDER BY s.last_updated_ts;


/**********************************************************************
 * 6. REMOVE REFERENCES TO STATES WE'RE DELETING
 **********************************************************************/

UPDATE states

SET old_state_id = NULL

WHERE old_state_id IN (
    SELECT state_id
    FROM sensor_cleanup
);


/**********************************************************************
 * 7. DELETE DUPLICATE / STARTUP SENSOR STATES
 **********************************************************************/

DELETE FROM states

WHERE state_id IN (
    SELECT state_id
    FROM sensor_cleanup
);


/**********************************************************************
 * 8. REMOVE ATTRIBUTE ROWS THAT ARE NOW ORPHANED
 *
 * If another state still uses the same attributes_id, retain it.
 **********************************************************************/

DELETE FROM state_attributes

WHERE attributes_id IN (
    SELECT attributes_id

    FROM sensor_cleanup

    WHERE attributes_id IS NOT NULL
)

AND NOT EXISTS (
    SELECT 1

    FROM states

    WHERE states.attributes_id =
          state_attributes.attributes_id
);


/**********************************************************************
 * 9. CLEAN UP TEMP TABLES AND COMMIT
 **********************************************************************/

DROP TABLE sensor_cleanup;
DROP TABLE weather_backfill;

COMMIT;
