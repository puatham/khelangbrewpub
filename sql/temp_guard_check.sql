-- =====================================================================
-- temp_guard_check() — Temp Guard: ตรวจอุณหภูมิเบียร์ทุก 15 นาทีด้วยโค้ดล้วน ไม่ใช้ AI
--
-- ย้ายออกมาจาก node "Check Temp Bounds" ใน Telemetry Sync (10 ก.ย.) เหตุผล:
--   1. ใน workflow JSON มันคือสตริงบรรทัดเดียวยาว 9 พันตัวอักษร — git diff อ่านไม่รู้เรื่อง
--      เวลาแก้เกณฑ์สักตัวเดียวจะเห็นเป็น "ทั้งบรรทัดเปลี่ยน" ทุกครั้ง
--   2. อยู่ในไฟล์ .sql แล้วทดสอบด้วย psql ตรงๆ ได้ ไม่ต้องรอ cron
-- node เหลือแค่ `SELECT * FROM temp_guard_check();`
--
-- **VOLATILE จำเป็น** เพราะข้างในมี DELETE/INSERT ผ่าน data-modifying CTE — ถ้าปล่อยให้
-- Postgres มองว่า STABLE มันจะ inline function เข้าไปใน query ผู้เรียกแล้วพัง
-- =====================================================================
DROP FUNCTION IF EXISTS temp_guard_check();

CREATE OR REPLACE FUNCTION temp_guard_check()
RETURNS TABLE (
  batch_id       integer,
  beer_name      text,
  alert_kind     text,
  current_phase  text,
  pill_c         numeric,
  ctrl_c         numeric,
  target_c       numeric,
  ctrl_dev_c     numeric,
  pill_move_1h_c numeric,
  tgt_stable_h   numeric,
  pill_age_h     numeric,
  ctrl_age_h     numeric,
  yeast_min      numeric,
  yeast_max      numeric,
  band_low       numeric,
  band_high      numeric,
  rate_c_per_h   numeric,
  hours_to_floor numeric,
  hours_to_ceil  numeric,
  floor_c        numeric,
  ceil_c         numeric,
  dry_hop_age_h  numeric,
  is_fresh_alert boolean,
  -- ให้ Build Temp Alert แปะลิงก์กราฟ Grafana ตรงเข้า Pill ตัวนี้ได้ (var-pill) โดยไม่ต้อง
  -- ไป join batches ซ้ำอีกรอบใน n8n
  pill_device_id uuid
)
LANGUAGE sql
VOLATILE
AS $fn$
-- Temp Guard — ตรวจอุณหภูมิเบียร์ทุก 15 นาทีด้วยโค้ดล้วน ไม่ใช้ AI
-- เกณฑ์ทุกตัวมาจากการวัดพฤติกรรมจริงของตู้ (8 ก.ย.) ไม่ได้เดา:
--   ตู้เบี่ยงจาก target หลัง target นิ่งเกิน 6 ชม. p50=0.10 p95=1.63 p99=2.75 → ตั้ง 2.5
--   Pill เปลี่ยน p95=0.75 p99=1.49 °C/ชม. → ตั้ง 1.5
-- **ทุกอย่างอิง target ที่บันทึกใน temp_controller_readings ไม่ใช่ control_log** เพราะ control_log
-- มีแค่การปรับที่ผ่านบอท (5 จาก 14 ครั้ง) อีก 9 ครั้งผู้ใช้ปรับตรงในแอป RAPT
WITH act AS (
  SELECT b.batch_id, b.beer_name, b.pill_device_id, b.temp_controller_device_id, b.current_phase,
         y.min_temp_c AS yeast_min, y.max_temp_c AS yeast_max,
         b.beer_band_low_c AS band_low, b.beer_band_high_c AS band_high
  FROM batches b
  LEFT JOIN recipes rc ON rc.recipe_id = b.recipe_id
  LEFT JOIN yeasts y ON trim(lower(y.name)) = trim(lower(rc.yeast_name))
  WHERE b.status = 'active'
),
dry_hop AS (
  -- dry hop ล่าสุดของแต่ละ batch จาก /ferment_event (สิ่งที่ทำจริง ไม่ใช่ Day ในสูตร)
  SELECT a.batch_id,
         (SELECT max(e.occurred_at) FROM batch_events e
           WHERE e.batch_id = a.batch_id AND e.event_type = 'dry_hop') AS last_at
  FROM act a
),
pill_now AS (
  SELECT a.batch_id,
         (SELECT p.temperature_c FROM pill_readings p WHERE p.device_id=a.pill_device_id ORDER BY p.time_utc DESC LIMIT 1) AS pill,
         (SELECT p.time_utc FROM pill_readings p WHERE p.device_id=a.pill_device_id ORDER BY p.time_utc DESC LIMIT 1) AS pill_at,
         (SELECT p.temperature_c FROM pill_readings p WHERE p.device_id=a.pill_device_id
            AND p.time_utc <= now() - INTERVAL '1 hour' ORDER BY p.time_utc DESC LIMIT 1) AS pill_1h
  FROM act a
),
drift AS (
  -- slope จาก linear regression ของ 3 ชม.ล่าสุด — ใช้ทุกจุดในช่วง ไม่ใช่หัวท้าย 2 จุด
  -- เพราะ Pill อ่านเป็นขั้น 1/16°C จุดเดียวที่กระโดดจะทำให้ slope เพี้ยนไปทั้งเส้น
  SELECT a.batch_id,
         regr_slope(p.temperature_c, EXTRACT(EPOCH FROM p.time_utc)/3600) AS rate_h,
         count(*) AS n_points
  FROM act a
  JOIN pill_readings p ON p.device_id = a.pill_device_id
   AND p.time_utc >= now() - INTERVAL '3 hours'
  GROUP BY a.batch_id
),
ctrl_now AS (
  SELECT a.batch_id,
         (SELECT c.temperature_c FROM temp_controller_readings c WHERE c.device_id=a.temp_controller_device_id ORDER BY c.time_utc DESC LIMIT 1) AS ctrl,
         (SELECT c.target_temperature_c FROM temp_controller_readings c WHERE c.device_id=a.temp_controller_device_id ORDER BY c.time_utc DESC LIMIT 1) AS tgt,
         -- เวลาที่ target เปลี่ยนค่าล่าสุด อ่านจาก readings เอง
         (SELECT max(x.time_utc) FROM (
            SELECT c.time_utc, c.target_temperature_c,
                   LAG(c.target_temperature_c) OVER (ORDER BY c.time_utc) AS prev
            FROM temp_controller_readings c WHERE c.device_id=a.temp_controller_device_id) x
          WHERE x.prev IS NOT NULL AND round(x.target_temperature_c::numeric,2) IS DISTINCT FROM round(x.prev::numeric,2)) AS tgt_changed_at,
         -- ค่าเบี่ยงเมื่อ 1 ชม.ก่อน ใช้ดูว่ากำลังไล่เข้าเป้าอยู่หรือค้าง
         (SELECT abs(c.temperature_c - c.target_temperature_c) FROM temp_controller_readings c
           WHERE c.device_id=a.temp_controller_device_id AND c.time_utc <= now() - INTERVAL '1 hour'
           ORDER BY c.time_utc DESC LIMIT 1) AS dev_1h,
         (SELECT max(c.time_utc) FROM temp_controller_readings c WHERE c.device_id=a.temp_controller_device_id) AS ctrl_at
  FROM act a
),
m AS (
  SELECT a.*, p.pill, p.pill_at, p.pill_1h, c.ctrl, c.tgt, c.tgt_changed_at, c.dev_1h,
         abs(c.ctrl - c.tgt) AS dev,
         abs(p.pill - p.pill_1h) AS pill_move_1h,
         EXTRACT(EPOCH FROM (now() - COALESCE(c.tgt_changed_at, now() - INTERVAL '99 hours')))/3600 AS tgt_stable_h,
         EXTRACT(EPOCH FROM (now() - p.pill_at))/3600 AS pill_age_h,
         EXTRACT(EPOCH FROM (now() - c.ctrl_at))/3600 AS ctrl_age_h,
         dh.last_at AS dry_hop_at,
         EXTRACT(EPOCH FROM (now() - dh.last_at))/3600 AS dry_hop_age_h
  FROM act a JOIN pill_now p ON p.batch_id=a.batch_id JOIN ctrl_now c ON c.batch_id=a.batch_id
             LEFT JOIN dry_hop dh ON dh.batch_id=a.batch_id
),
m2 AS (
  -- ขอบที่จะชนก่อนเมื่อไหลลง/ขึ้น = ขอบที่ "ใกล้กว่า" ระหว่างช่วงที่ตั้งเองกับช่วงยีสต์
  SELECT m.*, d.rate_h, d.n_points AS drift_points,
         GREATEST(m.band_low, m.yeast_min) AS floor_c,
         LEAST(m.band_high, m.yeast_max) AS ceil_c
  FROM m LEFT JOIN drift d ON d.batch_id = m.batch_id
),
m3 AS (
  SELECT *,
    -- clamp ที่ 0 ไม่ใช้ pill > floor_c เพราะเคสที่เบียร์อยู่ "ตรงขอบพอดี" แล้วยังไหลลงต่อ
    -- คือเคสที่ต้องเตือนที่สุด แต่เงื่อนไข > จะเป็นเท็จแล้วเงียบไป (เจอจริงตอนทดสอบ 8 ก.ย.:
    -- เบียร์ 18.00 = ขีดล่างยีสต์ 18 พอดี อัตรา -0.121°C/ชม. แต่ไม่มีอะไรเตือนเลย)
    -- ถ้าหลุดไปแล้วจริงๆ band_low/yeast_low อยู่ก่อนใน CASE จึงคว้าไปก่อนอยู่แล้ว
    CASE WHEN rate_h < 0 AND floor_c IS NOT NULL
         THEN GREATEST((pill - floor_c) / (-rate_h), 0) END AS hours_to_floor,
    CASE WHEN rate_h > 0 AND ceil_c IS NOT NULL
         THEN GREATEST((ceil_c - pill) / rate_h, 0) END AS hours_to_ceil
  FROM m2
),
decided AS (
  SELECT m3.*,
    CASE
      -- เซ็นเซอร์เงียบ = ทุกค่าด้านล่างเชื่อไม่ได้ ต้องแจ้งตัวนี้ก่อนเป็นอันดับแรก
      -- เกณฑ์ 2 ชม.ตรงกับ PILL_STALE_THRESHOLD_H ที่ Phase Analysis Engine ใช้อยู่แล้ว
      -- (ตัวนี้มาแทน Check Sensor Freshness ในรอบ cron 4 ชม. ที่เกณฑ์ 6 ชม.และไม่มี dedupe เลย)
      WHEN pill IS NULL OR pill_age_h > 2 OR ctrl_age_h IS NULL OR ctrl_age_h > 2 THEN 'sensor_stale'
      -- C ตู้คุมไม่อยู่: เบี่ยงเกิน 2.5°C (สูงกว่า p99 ของตู้ที่นิ่งแล้ว) ต่อเนื่อง 1 ชม.
      --   และ "ไม่ได้กำลังไล่เข้าเป้า" (เบี่ยงไม่ลดลงอย่างน้อย 0.3°C ใน 1 ชม.) — เงื่อนไขหลังนี้
      --   คือตัวแยก "ตู้พัง" ออกจาก "กำลัง ramp ตามคำสั่ง" ซึ่ง cold crash ใช้เวลา 8 ชม.+
      WHEN dev > 2.5 AND dev_1h IS NOT NULL AND dev_1h > 2.5 AND dev > dev_1h - 0.3 THEN 'controller_lag'
      -- D เปลี่ยนเร็วผิดปกติ: >1.5°C/ชม. (p99=1.49) ทั้งที่ target ไม่ได้เพิ่งเปลี่ยน
      WHEN pill_move_1h > 1.5 AND tgt_stable_h > 1 THEN 'rapid_change'
      -- E hop creep: กำลังลด target ลงไปช่วง cold crash ทั้งที่เพิ่ง dry hop
      --   เอนไซม์จากฮอปย่อยเดกซ์ทรินให้เป็นน้ำตาลที่ยีสต์กินได้ การหมักจึงกลับมาได้อีก
      --   หลัง dry hop กราฟ gravity ที่ดูแบนแล้วอาจลงต่อ — ถ้า crash แล้วบรรจุตอนนั้น
      --   จะได้คาร์บอเนชันเกินหรือขวดระเบิด (BA Hop Creep Technical Brief)
      --   เตือน "ตอนลงมือ" ไม่ใช่ตอนครบเวลา เพราะการเตือนตามนาฬิกาจะกลายเป็นเสียงรบกวน
      --   ส่วนคำเตือนแบบเบากว่าอยู่ใน prompt ของรอบวิเคราะห์ 4 ชม.อยู่แล้ว
      WHEN dry_hop_at IS NOT NULL AND dry_hop_age_h <= 72 AND tgt <= 10 THEN 'hop_creep_watch'
      -- B หลุดช่วงยีสต์: เผื่อ 0.2°C กันแกว่งไปมาตรงขอบพอดี
      WHEN yeast_min IS NOT NULL AND pill < yeast_min - 0.2 THEN 'yeast_low'
      WHEN yeast_max IS NOT NULL AND pill > yeast_max + 0.2 THEN 'yeast_high'
      -- ช่วงที่ผู้หมักตั้งเอง (/ferment_band) — แคบกว่าช่วงยีสต์และสะท้อนเจตนาของเฟสนั้น
      -- อยู่ท้ายกว่า yeast_low/high เพราะหลุดสเปกยีสต์รุนแรงกว่าหลุดแผนที่ตั้งไว้เอง
      -- เผื่อ 0.1°C กันแกว่งตรงขอบ (แคบกว่าของยีสต์ที่ 0.2 เพราะช่วงนี้แคบกว่ามาก)
      WHEN band_low IS NOT NULL AND pill < band_low - 0.1 THEN 'band_low'
      WHEN band_high IS NOT NULL AND pill > band_high + 0.1 THEN 'band_high'
      -- กำลังไหลไปหาขอบ แต่ยังไม่หลุด — เตือนล่วงหน้าเพื่อให้แก้ทัน
      -- ต้องเคลื่อนจริง (|อัตรา| >= 0.08°C/ชม. ต่ำกว่านี้เป็น noise) และมีจุดพอ (>=4)
      WHEN rate_h <= -0.08 AND drift_points >= 4 AND hours_to_floor IS NOT NULL AND hours_to_floor <= 3 THEN 'drifting_low'
      WHEN rate_h >=  0.08 AND drift_points >= 4 AND hours_to_ceil  IS NOT NULL AND hours_to_ceil  <= 3 THEN 'drifting_high'
      -- A ถึงเป้าแล้ว: เบียร์นิ่ง (<0.15°C/ชม.) หลัง target เปลี่ยนมาแล้ว 2-12 ชม.
      --   ไม่ต้องรู้ gap เลย เพราะ "นิ่ง" คือนิยามของการถึงที่หมายอยู่แล้ว
      WHEN pill_move_1h < 0.15 AND tgt_stable_h BETWEEN 2 AND 12 THEN 'arrived'
      ELSE NULL
    END AS kind
  FROM m3
),
cleared AS (
  -- เงื่อนไขหายแล้ว → ล้าง state เพื่อให้ครั้งหน้าที่หลุดเตือนได้ใหม่
  DELETE FROM temp_alert_state s USING decided d
  WHERE s.batch_id = d.batch_id AND d.kind IS NULL RETURNING s.batch_id
),
sent AS (
  INSERT INTO temp_alert_state (batch_id, alert_kind, alerted_at, alerted_value)
  -- sensor_stale ส่ง alerted_value เป็น NULL เพื่อให้ dedupe อาศัย cooldown 6 ชม.อย่างเดียว
  -- ไม่งั้นอายุที่เพิ่มขึ้นเรื่อยๆ จะทำให้เข้าเงื่อนไข "แย่ลง ≥0.5" แล้วเตือนซ้ำทุกครึ่งชั่วโมง
  SELECT batch_id, kind, now(), CASE WHEN kind = 'sensor_stale' THEN NULL ELSE pill END FROM decided WHERE kind IS NOT NULL
  ON CONFLICT (batch_id) DO UPDATE
    SET alert_kind = EXCLUDED.alert_kind, alerted_at = now(), alerted_value = EXCLUDED.alerted_value
    -- เตือนซ้ำเฉพาะเมื่อเปลี่ยนชนิด / แย่ลง ≥0.5°C / ครบ cooldown 6 ชม.
    WHERE temp_alert_state.alert_kind IS DISTINCT FROM EXCLUDED.alert_kind
       OR abs(COALESCE(temp_alert_state.alerted_value,0) - COALESCE(EXCLUDED.alerted_value,0)) >= 0.5
       OR temp_alert_state.alerted_at < now() - INTERVAL '6 hours'
  RETURNING batch_id
)
SELECT d.batch_id, d.beer_name, COALESCE(d.kind, 'ok') AS alert_kind, d.current_phase,
       round(d.pill::numeric,2) AS pill_c, round(d.ctrl::numeric,2) AS ctrl_c, round(d.tgt::numeric,2) AS target_c,
       round(d.dev::numeric,2) AS ctrl_dev_c, round(d.pill_move_1h::numeric,2) AS pill_move_1h_c,
       round(d.tgt_stable_h::numeric,1) AS tgt_stable_h,
       round(d.pill_age_h::numeric,1) AS pill_age_h, round(d.ctrl_age_h::numeric,1) AS ctrl_age_h,
       d.yeast_min, d.yeast_max, d.band_low, d.band_high,
       round(d.rate_h::numeric, 3) AS rate_c_per_h,
       round(d.hours_to_floor::numeric, 1) AS hours_to_floor,
       round(d.hours_to_ceil::numeric, 1) AS hours_to_ceil,
       round(d.floor_c::numeric, 2) AS floor_c, round(d.ceil_c::numeric, 2) AS ceil_c,
       round(d.dry_hop_age_h::numeric, 1) AS dry_hop_age_h,
       -- แถวนี้ผ่าน dedupe มาจริง หรือถูกกลืนแล้วโผล่มาเพราะโหมดแจ้งทุกรอบ
       -- Build Temp Alert ใช้แยก "เตือนครั้งแรก" ออกจาก "แจ้งซ้ำ" จะได้ไม่อ่านเหมือน
       -- มีเหตุใหม่เกิดซ้ำทุก 15 นาที
       (s.batch_id IS NOT NULL) AS is_fresh_alert,
       d.pill_device_id
FROM decided d
-- โหมด 'alerts' (ค่าตั้งต้น): ออกเฉพาะแถวผิดปกติที่ผ่าน dedupe
-- โหมด 'always': ออกทุกแถวเสมอ ทั้งปกติและผิดปกติ โดยไม่ให้ dedupe กรองออก
--   เดิมเขียนเป็น (d.kind IS NULL AND mode='always') ซึ่งครอบแค่แถว "ปกติ" — พอมี alert
--   ค้างอยู่ แถวปกติก็ไม่ออก (เพราะ kind ไม่ NULL) และแถว alert ก็โดน dedupe กลืน
--   = เงียบสนิททั้งที่สั่งให้แจ้งทุกรอบ (เจอจริง 9 ก.ย.: ระหว่างค้างสถานะ arrived
--   คืน 00:00-07:45 ส่งไปแค่ 7 ครั้งจาก 31 รอบ)
--   dedupe ยังทำงานครบเหมือนเดิมทุกอย่าง แค่เลิกใช้มันเป็นตัวกรองแถวในโหมดนี้
LEFT JOIN sent s ON s.batch_id = d.batch_id
WHERE (d.kind IS NOT NULL AND s.batch_id IS NOT NULL)
   OR COALESCE((SELECT value FROM bot_state WHERE key = 'temp_guard_report_mode'), 'alerts') = 'always';
$fn$;
