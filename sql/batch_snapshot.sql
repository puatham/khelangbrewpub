-- =====================================================================
-- batch_snapshot() — ภาพรวมของ batch หนึ่งใบ ณ เวลาหนึ่ง สำหรับป้อนให้ AI วิเคราะห์
--
-- **ทำไมต้องมี**: query ก้อนนี้เคยถูก copy ไว้ 3 ที่ (Phase Analysis Cron / Discord
-- Interactions Webhook / Phase Analysis Backtest) ต่างกันแค่วิธีระบุว่าเป็น batch ไหน
-- ทุกครั้งที่แก้ตรรกะต้องไล่แก้ให้ครบทั้งสาม — และพลาดมาแล้วจริง (ตอนเติมตัวกรอง
-- start_date ต้องตามไปแก้ที่สอง) ตอนตรวจระบบ 09/09 ยังพบว่ามัน diverge อยู่จริง:
-- cron คืน batch_id เป็น int ส่วน discord คืนเป็น text ทั้งที่ป้อนเข้า Engine ตัวเดียวกัน
--
-- p_as_of คือ "มองระบบ ณ เวลานี้" — ปกติคือ now() ส่วน Backtest ส่งเวลาย้อนหลังเข้ามา
-- เพื่อเล่นประวัติซ้ำ ตัวกรอง <= p_as_of ทุกจุดจึงไม่มีผลใดๆ กับการใช้งานปกติ
-- (ตรวจแล้วว่าไม่มี reading ที่ timestamp ล่วงหน้าอยู่เลยสักแถว)
--
-- คืนค่าเป็น TABLE ไม่ใช่ jsonb ตั้งใจ — n8n จะได้เห็นคอลัมน์หน้าตาเหมือนเดิมเป๊ะ
-- โค้ดปลายทางที่อ้าง $json.pill_series ฯลฯ จึงไม่ต้องแก้อะไรเลยสักบรรทัด
-- =====================================================================
-- ล้าง signature เก่าก่อนเสมอ — CREATE OR REPLACE แทนที่ได้เฉพาะตัวที่พารามิเตอร์เหมือนกันเป๊ะ
-- ถ้าเพิ่ม/ลดพารามิเตอร์มันจะสร้างตัวใหม่ซ้อนแทน แล้วเรียกทีหลังจะเจอ "is not unique"
DROP FUNCTION IF EXISTS batch_snapshot(int, timestamptz);
DROP FUNCTION IF EXISTS batch_snapshot(int, timestamptz, timestamptz);
DROP FUNCTION IF EXISTS batch_snapshot(int, timestamptz, timestamptz, text);

CREATE OR REPLACE FUNCTION batch_snapshot(
  p_batch_id        int,
  p_as_of           timestamptz DEFAULT now(),
  -- Backtest จำลองว่า "ถ้าเริ่มหมักวันนั้นแทน" จะวิเคราะห์ออกมาเป็นอย่างไร
  -- NULL = ใช้ start_date จริงของ batch ซึ่งเป็นกรณีของ cron และ Discord ทั้งหมด
  p_start_override  timestamptz DEFAULT NULL,
  -- Backtest ต้องปิดไม่ให้ AI เห็นเฟสปัจจุบัน ไม่งั้นมันลอกคำตอบแทนที่จะวิเคราะห์เอง
  -- NULL = ส่งเฟสจริงไป ซึ่งเป็นกรณีของ cron และ Discord ทั้งหมด
  p_phase_override  text DEFAULT NULL
)
RETURNS TABLE (
  batch_id                   integer,
  beer_name                  text,
  current_phase              text,
  prep_alerted_for_phase     text,
  beer_band_low_c            numeric,
  beer_band_high_c           numeric,
  controller_name            text,
  pill_id                    uuid,
  controller_id              uuid,
  start_date                 timestamptz,
  recipe_id                  text,
  pill_series                jsonb,
  controller_series          jsonb,
  control_series             jsonb,
  recipe_name                text,
  style_name                 text,
  recipe_og                  numeric,
  recipe_fg                  numeric,
  recipe_fermentation_temp_c numeric,
  fermentation_steps         jsonb,
  dry_hop_plan               jsonb,
  yeast_name                 text,
  yeast_min_temp_c           numeric,
  yeast_max_temp_c           numeric,
  yeast_attenuation          numeric,
  yeast_min_attenuation      numeric,
  yeast_max_attenuation      numeric,
  -- ทั้งสามตัวมีอยู่ใน raw_data ของ Brewfather อยู่แล้วแต่ไม่เคยถูกส่งต่อให้ AI:
  -- type บอกว่าเป็น lager หรือเปล่า (d-rest จำเป็นสำหรับ lager แต่ prompt เดิมให้ AI
  -- เดาจากชื่อสูตร), flocculation สูงทำให้ gravity ดูแบนก่อนหมักจบจริง (fg_stable หลอก),
  -- diastatic (เช่น Fermentis WB-06 ที่กิน dextrin ต่อได้เรื่อยๆ) ห้ามใช้เพดาน
  -- attenuation ปกติมาปิดเฟส เสี่ยงประกาศ fg_stable ทั้งที่ยังหมักซ้ำอยู่
  yeast_type                 text,
  yeast_flocculation         text,
  yeast_diastatic            boolean,
  pill_stale_hours           numeric,
  pill_last_at               timestamptz,
  pill_battery_percent       numeric,
  fallback_gap_c             numeric,
  fallback_gap_points        bigint,
  fallback_gap_sd            numeric,
  stable_gap_c               numeric,
  stable_gap_points          bigint,
  -- เหตุการณ์ที่ทำจริง (dry hop / ลงยีสต์ / ถ่ายถัง) ต่างจาก dry_hop_plan ที่เป็นแค่แผนในสูตร
  batch_events               jsonb
)
LANGUAGE sql
STABLE
AS $fn$
WITH b AS (
  -- ทุกอย่างที่เคยส่งเข้ามาเป็นพารามิเตอร์ ($1 pill, $2 controller, $3 start_date,
  -- $5 beer_name, ...) หาจาก batch_id ได้หมด ผู้เรียกจึงเหลือส่งแค่ตัวเดียว
  SELECT bt.batch_id, bt.beer_name,
         COALESCE(p_phase_override, bt.current_phase) AS current_phase,
         bt.prep_alerted_for_phase,
         bt.beer_band_low_c, bt.beer_band_high_c,
         COALESCE(p_start_override, bt.start_date) AS start_date, bt.recipe_id,
         bt.pill_device_id, bt.temp_controller_device_id,
         (SELECT device_name FROM devices d WHERE d.device_id = bt.temp_controller_device_id) AS controller_name
  FROM batches bt
  WHERE bt.batch_id = p_batch_id
),
pill_series AS (
  SELECT jsonb_agg(jsonb_build_object('t', time_utc, 'sg', gravity_sg, 'temp', temperature_c) ORDER BY time_utc ASC) AS series
  -- ต้องกรอง start_date ด้วย ไม่ใช่แค่ device_id — Pill ตัวเดียวถูกใช้ซ้ำหลาย batch ได้
  -- ถ้าไม่กรองจะส่งกราฟของ batch ก่อนหน้าไปให้ AI ด้วย (เจอจริง 08/09: batch 4 มี reading
  -- ของตัวเอง 23 จุด แต่ส่งไป 1,091 จุด — 98% เป็น batch เดือน ส.ค.ที่จบด้วย cold_crash
  -- ทำให้ /ferment_status ตอบ cold_crash ทั้งที่เพิ่งหมักมา 11 ชม.)
  FROM pill_readings, b
  WHERE device_id = b.pill_device_id AND time_utc >= b.start_date AND time_utc <= p_as_of
),
controller_series AS (
  SELECT jsonb_agg(jsonb_build_object('t', time_utc, 'temp', temperature_c, 'target', target_temperature_c) ORDER BY time_utc ASC) AS series
  FROM temp_controller_readings, b
  WHERE device_id = b.temp_controller_device_id AND time_utc >= b.start_date AND time_utc <= p_as_of
),
events AS (
  -- ตัด <= p_as_of เหมือนซีรีส์อื่น เพื่อให้ Backtest เล่นย้อนหลังแล้วไม่เห็นอนาคต
  SELECT jsonb_agg(jsonb_build_object('t', e.occurred_at, 'type', e.event_type, 'note', e.note)
                   ORDER BY e.occurred_at ASC) AS series
  FROM batch_events e, b
  WHERE e.batch_id = b.batch_id AND e.occurred_at <= p_as_of
),
control_series AS (
  SELECT jsonb_agg(jsonb_build_object('t', changed_at, 'old', old_value, 'new', new_value, 'by', changed_by, 'remark', remark) ORDER BY changed_at ASC) AS series
  FROM control_log, b
  WHERE device_id = b.temp_controller_device_id AND action = 'set_target_temperature'
    AND changed_at >= b.start_date AND changed_at <= p_as_of
),
recipe_info AS (
  SELECT r.name AS recipe_name, r.style_name, r.og AS recipe_og, r.fg AS recipe_fg,
         r.fermentation_temp_c AS recipe_fermentation_temp_c,
         r.raw_data->'fermentation'->'steps' AS fermentation_steps,
         (SELECT jsonb_agg(jsonb_build_object('day', dh->>'time', 'name', dh->>'name', 'amount_g', dh->>'amount') ORDER BY (dh->>'time')::numeric)
            FROM jsonb_array_elements(COALESCE(r.raw_data->'hops', '[]'::jsonb)) dh
            WHERE dh->>'use' ILIKE '%dry%') AS dry_hop_plan,
         y.name AS yeast_name, y.min_temp_c AS yeast_min_temp_c, y.max_temp_c AS yeast_max_temp_c,
         y.attenuation AS yeast_attenuation, y.min_attenuation AS yeast_min_attenuation, y.max_attenuation AS yeast_max_attenuation,
         y.raw_data->>'type' AS yeast_type,
         y.flocculation AS yeast_flocculation,
         (y.raw_data->>'fermentsAll')::boolean AS yeast_diastatic
  FROM recipes r
  LEFT JOIN yeasts y ON trim(lower(y.name)) = trim(lower(r.yeast_name))
  WHERE r.recipe_id = (SELECT recipe_id FROM b)
),
stale_calc AS (
  -- อายุของ Pill reading ล่าสุด — ใช้ตัดสินว่าเซ็นเซอร์ตาย/เงียบอยู่หรือไม่
  -- ไม่กรอง start_date ตั้งใจ: ความสดของเซ็นเซอร์เป็นเรื่องของตัวอุปกรณ์ ไม่ใช่ของ batch
  SELECT EXTRACT(EPOCH FROM (p_as_of - MAX(time_utc)))/3600 AS pill_stale_hours,
         MAX(time_utc) AS pill_last_at
  FROM pill_readings, b WHERE device_id = b.pill_device_id AND time_utc <= p_as_of
),
last_battery AS (
  SELECT battery_percent FROM pill_readings, b
  WHERE device_id = b.pill_device_id AND battery_percent IS NOT NULL AND time_utc <= p_as_of
  ORDER BY time_utc DESC LIMIT 1
),
fallback_gap AS (
  -- gap สำรองสำหรับ "ประมาณอุณหภูมิเบียร์จากตู้ควบคุม" เมื่อ Pill ตายกลางคัน — ต่างจาก gap_calc
  -- ที่ผูกกับ 12 ชม.ล่าสุด (ว่างทันทีที่ Pill เงียบ) โดยเลือกเฉพาะจุดที่เชื่อได้จริง 2 เงื่อนไข:
  --   (1) เบียร์นิ่งแล้ว — เปลี่ยนจากจุดก่อนหน้า < 0.15°C (ข้อมูลจริงชี้ว่าช่วงกำลังไล่อุณหภูมิ
  --       gap แกว่ง +2.9 ถึง -1.5 เชื่อไม่ได้เลย เพราะเบียร์มีมวลความร้อนตามตู้ไม่ทัน)
  --   (2) ตู้ตั้ง target เดียวกับตอนนี้ — gap แปรตามระดับอุณหภูมิ (ช่วงหมักคายความร้อน gap กว้าง,
  --       ช่วง cold crash แคบหรือติดลบ) ใช้ข้ามระดับไม่ได้
  -- ถ้าได้ไม่ถึง 3 จุดถือว่าประมาณไม่ได้ (เช่นเซ็นเซอร์ตายตอนกำลังไล่อุณหภูมิ ยังไม่ทันนิ่ง)
  SELECT AVG(gap) AS gap, COUNT(*) AS n_points, STDDEV(gap) AS gap_sd
  FROM (
    SELECT p.temperature_c - c.temp AS gap,
           p.temperature_c - LAG(p.temperature_c) OVER (ORDER BY p.time_utc) AS d,
           c.target
    FROM b
    CROSS JOIN pill_readings p
    JOIN LATERAL (
      SELECT temperature_c AS temp, target_temperature_c AS target
      FROM temp_controller_readings x
      WHERE x.device_id = b.temp_controller_device_id AND x.time_utc <= p_as_of
      ORDER BY abs(EXTRACT(EPOCH FROM (x.time_utc - p.time_utc))) LIMIT 1
    ) c ON true
    WHERE p.device_id = b.pill_device_id
      AND p.time_utc >= b.start_date
      AND p.time_utc <= p_as_of
      -- ตู้ต้องไล่ถึง target ได้จริงแล้วด้วย ไม่ใช่แค่ Pill นิ่ง — เกณฑ์ "|Δ Pill| < 0.15 ต่อจุด"
      -- อย่างเดียวหลวมเกินไป เบียร์ที่ค้างอยู่ยอดกราฟระหว่างที่ตู้ยังไล่ลงไม่ถึงเป้าก็ผ่านเกณฑ์ได้
      -- (เจอจริง 8 ก.ย.: 22 จาก 23 จุดที่ผ่านเกณฑ์เป็นช่วง Pill ค้าง 18-19.25°C ขณะตู้อยู่ 13.8-15.1
      -- ทั้งที่ target 15.5 → gap เพี้ยนเป็น 4.36 แล้วประมาณอุณหภูมิเบียร์ออกมา 19.46°C
      -- ทั้งที่ค่าจริงล่าสุดคือ 16.50°C) เทียบกับ batch 2 ที่เคยยืนยันว่าแม่น เกณฑ์นี้ตัดทิ้งแค่
      -- 163→142 จุด gap 1.79→1.75 (SD 0.24) ส่วนเคสเพี้ยนถูกตัดเหลือ 0 จุด → ตอบ "ประมาณไม่ได้"
      AND abs(c.temp - c.target) <= 0.3
      AND p.time_utc >= (SELECT MAX(time_utc) FROM pill_readings
                          WHERE device_id = b.pill_device_id AND time_utc <= p_as_of) - INTERVAL '48 hours'
  ) t
  WHERE abs(d) < 0.15
    AND round(target::numeric, 1) = round((
      SELECT target_temperature_c FROM temp_controller_readings, b
      WHERE device_id = b.temp_controller_device_id AND time_utc <= p_as_of
      ORDER BY time_utc DESC LIMIT 1
    )::numeric, 1)
),
last_change AS (
  SELECT COALESCE(MAX(changed_at), (SELECT start_date FROM b)) AS t
  FROM control_log, b
  WHERE device_id = b.temp_controller_device_id AND action = 'set_target_temperature'
    AND changed_at <= p_as_of
),
gap_window AS (
  -- ตัดช่วง transient หลังปรับ target ใหม่ๆ ออก (2 ชม.แรก) และไม่ย้อนไกลเกิน 12 ชม.
  -- (สภาพห้อง/ตู้อาจเปลี่ยนไปแล้ว) เพื่อเอาแค่ช่วงที่ระบบนิ่งจริงๆ มาเฉลี่ยส่วนต่าง
  SELECT GREATEST((SELECT t FROM last_change) + INTERVAL '2 hours', p_as_of - INTERVAL '12 hours') AS t
),
gap_calc AS (
  SELECT AVG(p.temperature_c - c.temperature_c) AS avg_gap, COUNT(*) AS n_points
  FROM b
  CROSS JOIN pill_readings p
  JOIN temp_controller_readings c
    ON c.device_id = b.temp_controller_device_id
    AND c.time_utc BETWEEN p.time_utc - INTERVAL '10 minutes' AND p.time_utc + INTERVAL '10 minutes'
  WHERE p.device_id = b.pill_device_id
    AND p.time_utc >= (SELECT t FROM gap_window)
    AND p.time_utc <= p_as_of
    AND c.time_utc <= p_as_of
)
SELECT
  b.batch_id,
  b.beer_name,
  b.current_phase,
  b.prep_alerted_for_phase,
  b.beer_band_low_c,
  b.beer_band_high_c,
  b.controller_name,
  b.pill_device_id            AS pill_id,
  b.temp_controller_device_id AS controller_id,
  b.start_date,
  b.recipe_id,
  COALESCE(ps.series,  '[]'::jsonb) AS pill_series,
  COALESCE(cs.series,  '[]'::jsonb) AS controller_series,
  COALESCE(ctl.series, '[]'::jsonb) AS control_series,
  ri.recipe_name, ri.style_name, ri.recipe_og, ri.recipe_fg, ri.recipe_fermentation_temp_c,
  COALESCE(ri.fermentation_steps, '[]'::jsonb) AS fermentation_steps,
  COALESCE(ri.dry_hop_plan, '[]'::jsonb) AS dry_hop_plan,
  ri.yeast_name, ri.yeast_min_temp_c, ri.yeast_max_temp_c,
  ri.yeast_attenuation, ri.yeast_min_attenuation, ri.yeast_max_attenuation,
  ri.yeast_type, ri.yeast_flocculation, ri.yeast_diastatic,
  sc.pill_stale_hours, sc.pill_last_at,
  lb.battery_percent AS pill_battery_percent,
  fg.gap AS fallback_gap_c, fg.n_points AS fallback_gap_points, fg.gap_sd AS fallback_gap_sd,
  gc.avg_gap AS stable_gap_c, gc.n_points AS stable_gap_points,
  COALESCE(ev.series, '[]'::jsonb) AS batch_events
FROM b
LEFT JOIN pill_series       ps  ON true
LEFT JOIN controller_series cs  ON true
LEFT JOIN control_series    ctl ON true
LEFT JOIN recipe_info       ri  ON true
LEFT JOIN stale_calc        sc  ON true
LEFT JOIN last_battery      lb  ON true
LEFT JOIN fallback_gap      fg  ON true
LEFT JOIN gap_calc          gc  ON true
LEFT JOIN events            ev  ON true;
$fn$;
