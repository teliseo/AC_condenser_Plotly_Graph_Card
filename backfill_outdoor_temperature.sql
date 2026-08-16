BEGIN IMMEDIATE;

DROP TABLE IF EXISTS temp.weather_backfill;

CREATE TEMP TABLE weather_backfill AS
WITH
target AS (
    SELECT metadata_id
    FROM states_meta
    WHERE entity_id = 'sensor.outdoor_temperature'
),

/*
 * Use the newest existing sensor attributes as our template.
 * The fallback corresponds to the YAML sensor we've defined, in case
 * Recorder has not yet written a row for it.
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
         * Numeric weather temperature becomes the sensor state.
         * Missing/non-numeric values are preserved as HA "unknown".
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
         * weather.forecast_home's state is the condition:
         * sunny, cloudy, clear-night, etc.
         */
        ws.state AS condition,

        /*
         * Start with the new sensor's normal attributes,
         * then substitute the condition and original source timestamp.
         */
        json_set(
            (SELECT attrs FROM base),
            '$.condition', ws.state,
            '$.source_ts', ws.last_updated_ts
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
       * Makes the backfill safely rerunnable:
       * don't insert a sensor row already present at this
       * exact source timestamp.
       */
      AND NOT EXISTS (
          SELECT 1
          FROM states AS existing
          WHERE existing.metadata_id = t.metadata_id
            AND existing.last_updated_ts = ws.last_updated_ts
      )
),

/*
 * Work out runs of identical temperature states so last_changed_ts
 * has HA's normal semantics.
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


/*
 * Each historical sample has a unique source_ts attribute, so its
 * attribute JSON is inherently unique. We therefore don't need
 * Recorder's normal attribute deduplication hash.
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


/*
 * Create the actual historical sensor states.
 */
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
     * For subsequent identical temperature values, retain the
     * timestamp at which that temperature state began.
     */
    CASE
        WHEN wb.source_ts = wb.run_start_ts
        THEN NULL
        ELSE wb.run_start_ts
    END,

    NULL,                       -- last_reported_ts
    wb.source_ts,               -- preserve original weather timestamp
    NULL,                       -- old_state_id

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


DROP TABLE weather_backfill;

COMMIT;
