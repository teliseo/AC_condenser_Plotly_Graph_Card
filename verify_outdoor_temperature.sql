.headers on
.mode column
.width 10 19 17 11 14 17

SELECT
    s.state_id AS state_id,

    datetime(
        s.last_updated_ts,
        'unixepoch',
        'localtime'
    ) AS time,

    printf(
        '%.6f',
        s.last_updated_ts
    ) AS timestamp,

    s.state AS temperature,

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

FROM states AS s

JOIN states_meta AS sm
  ON sm.metadata_id = s.metadata_id

LEFT JOIN state_attributes AS sa
  ON sa.attributes_id = s.attributes_id

WHERE sm.entity_id = 'sensor.outdoor_temperature'

ORDER BY s.last_updated_ts;
