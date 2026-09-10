-- =====================================================================
-- Ferment Agent - Database Schema (PostgreSQL)
-- รันด้วย: docker compose exec postgresql psql -U root -d rapt -f /path/to/schema.sql
-- หรือ copy เนื้อหาไปรันผ่าน psql -c ตรงๆ ก็ได้
-- =====================================================================

-- ---------------------------------------------------------------------
-- devices: ตาราง lookup กลาง เก็บ Pill + Temperature Controller ทั้งหมด
-- sync มาจาก RAPT GetHydrometers / GetTemperatureControllers
-- ---------------------------------------------------------------------
CREATE TABLE devices (
  device_id UUID PRIMARY KEY,
  device_name TEXT NOT NULL,
  device_type TEXT NOT NULL CHECK (device_type IN ('pill','temp_controller')),
  last_synced_at TIMESTAMPTZ DEFAULT now(),
  raw_data JSONB
);

-- ---------------------------------------------------------------------
-- recipes: cache ของ recipe จาก Brewfather (sync ผ่าน "Sync Devices")
-- ---------------------------------------------------------------------
CREATE TABLE recipes (
  recipe_id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  style_name TEXT,
  og NUMERIC,
  fg NUMERIC,
  yeast_name TEXT,
  fermentation_temp_c NUMERIC,
  last_synced_at TIMESTAMPTZ DEFAULT now(),
  raw_data JSONB
);

-- ---------------------------------------------------------------------
-- yeasts: cache ของ yeast inventory จาก Brewfather (sync ผ่าน "Sync Devices")
-- ---------------------------------------------------------------------
CREATE TABLE yeasts (
  yeast_id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  laboratory TEXT,
  product_id TEXT,
  min_temp_c NUMERIC,
  max_temp_c NUMERIC,
  attenuation NUMERIC,
  min_attenuation NUMERIC,
  max_attenuation NUMERIC,
  flocculation TEXT,
  best_for TEXT,
  last_synced_at TIMESTAMPTZ DEFAULT now(),
  raw_data JSONB
);

-- ---------------------------------------------------------------------
-- batches: batch การหมักที่กำลัง track อยู่ (ลงทะเบียนผ่าน Discord /ferment start)
-- ---------------------------------------------------------------------
CREATE TABLE batches (
  batch_id SERIAL PRIMARY KEY,
  pill_device_id UUID REFERENCES devices(device_id),
  temp_controller_device_id UUID REFERENCES devices(device_id),
  start_date TIMESTAMPTZ NOT NULL,
  -- ปิดขอบเวลาของ batch ตอน /ferment_stop (NULL = ยังหมักอยู่) จำเป็นเพราะ Pill/ตู้ถูก
  -- ใช้ซ้ำข้าม batch ได้ และตั้งแต่เปลี่ยนไป poll telemetry ต่อเนื่องไม่ผูกกับ batch
  -- ข้อมูลก็ยังไหลเข้ามาหลังหมักจบ — ไม่มีคอลัมน์นี้จะแยกไม่ออกว่า reading ไหนของ batch ไหน
  end_date TIMESTAMPTZ,
  -- ช่วงอุณหภูมิ "ของเบียร์ (Pill)" ที่ผู้หมักตั้งใจให้อยู่ในเฟสปัจจุบัน (NULL = ไม่ได้ตั้ง)
  -- ต่างจากช่วงของยีสต์ (yeasts.min_temp_c/max_temp_c) ซึ่งเป็นสเปกผู้ผลิตและกว้างมาก
  -- (Verdant IPA 18-25°C) — ช่วงนี้แคบกว่าและสะท้อนเจตนา เช่น 18.0-18.5 ตอน primary
  -- Temp Guard เตือนแบบ "เฝ้าดู" เมื่อหลุดช่วงนี้ และเตือนแรงกว่าเมื่อหลุดช่วงยีสต์
  -- ตั้ง/ล้างผ่าน /ferment_band — ไม่เลื่อนตามเฟสเอง ต้องสั่งใหม่เมื่อเปลี่ยนช่วงการหมัก
  beer_band_low_c NUMERIC,
  beer_band_high_c NUMERIC,
  target_fg NUMERIC,
  beer_name TEXT,
  current_phase TEXT DEFAULT 'lag',
  last_alert_at TIMESTAMPTZ,
  status TEXT DEFAULT 'active',
  -- กันสแปม "ใกล้จะเปลี่ยนเฟส" alert: ส่งครั้งเดียวต่อ next_phase ที่ AI เสนอ
  -- reset กลับเป็น NULL ทุกครั้งที่เฟสเปลี่ยนจริง (ดู Update Batch Phase)
  prep_alerted_for_phase TEXT,
  last_prep_alert_at TIMESTAMPTZ,
  -- recipe ที่ match จากชื่อตอน /ferment_start (optional, ดู recipes table)
  recipe_id TEXT REFERENCES recipes(recipe_id)
);

-- ---------------------------------------------------------------------
-- pill_readings: raw telemetry ของ Pill (gravity, temp, battery, rssi)
-- ---------------------------------------------------------------------
CREATE TABLE pill_readings (
  id BIGSERIAL PRIMARY KEY,
  device_id UUID REFERENCES devices(device_id),
  time_utc TIMESTAMPTZ NOT NULL,
  temperature_c NUMERIC,
  gravity_sg NUMERIC,
  gravity_velocity_sg_per_day NUMERIC,
  battery_percent NUMERIC,
  rssi_dbm NUMERIC,
  paired_temp_controller TEXT,
  UNIQUE (device_id, time_utc)
);
CREATE INDEX idx_pill_readings_device_time ON pill_readings (device_id, time_utc DESC);

-- ---------------------------------------------------------------------
-- temp_controller_readings: raw telemetry ของ Temperature Controller
-- ---------------------------------------------------------------------
CREATE TABLE temp_controller_readings (
  id BIGSERIAL PRIMARY KEY,
  device_id UUID REFERENCES devices(device_id),
  time_utc TIMESTAMPTZ NOT NULL,
  temperature_c NUMERIC,
  target_temperature_c NUMERIC,
  rssi_dbm NUMERIC,
  UNIQUE (device_id, time_utc)
);
CREATE INDEX idx_temp_readings_device_time ON temp_controller_readings (device_id, time_utc DESC);

-- ---------------------------------------------------------------------
-- phase_log: ผลสรุปที่ AI วิเคราะห์เฟสการหมักในแต่ละรอบ cron
-- ---------------------------------------------------------------------
CREATE TABLE phase_log (
  log_id SERIAL PRIMARY KEY,
  batch_id INT REFERENCES batches(batch_id),
  checked_at TIMESTAMPTZ DEFAULT now(),
  gravity_sg NUMERIC,
  temperature_c NUMERIC,
  gravity_velocity NUMERIC,
  detected_phase TEXT,
  ai_reasoning TEXT,
  controller_temp_c NUMERIC,
  target_temperature_c NUMERIC,
  abv_percent NUMERIC,
  -- ผลการถกเถียงของสอง agent (เพิ่ม 10 ก.ย.) มีไว้ตอบด้วยข้อมูลจริงว่าชั้นตรวจสอบไขว้
  -- เปลี่ยนอะไรได้บ้าง ถ้า debate_revised เป็น false ทุกรอบก็ถอดทิ้งประหยัดไป 2 Claude call
  brewmaster_verdict  TEXT,      -- ok / watch / concern
  debate_stance       TEXT,      -- agree / revise / stand
  debate_revised      BOOLEAN,   -- ผู้เชี่ยวชาญยอมแก้เฟสตามข้อทักท้วงไหม
  debate_phase_before TEXT       -- ถ้าแก้ แก้มาจากเฟสอะไร
);

-- ---------------------------------------------------------------------
-- control_log: audit การสั่งปรับค่า (เช่น SetTargetTemperature) จาก
-- Discord หรือเว็บในอนาคต
-- ---------------------------------------------------------------------
-- เหตุการณ์ที่ "เกิดขึ้นจริง" ของ batch (เพิ่ม 10 ก.ย.) — ต่างจากแผนในสูตรที่บอกแค่
-- ว่าตั้งใจจะทำวันไหน ตัวเลข Day ในสูตร Brewfather เป็นค่าประมาณของคนเขียน ใช้ตัดสิน
-- อะไรไม่ได้ ตารางนี้เก็บว่าทำจริงเมื่อไหร่
-- มีเพราะกฎ hop creep เขียนว่า "ถ้าเพิ่ง dry hop ไปไม่นาน ให้เฝ้า gravity ต่อ" แต่ระบบ
-- ไม่มีทางรู้ว่า "เพิ่ง" หรือเปล่า กฎจึงแทบไม่มีผลจนกว่าจะมีข้อมูลนี้
CREATE TABLE batch_events (
  event_id    SERIAL PRIMARY KEY,
  batch_id    INTEGER NOT NULL REFERENCES batches(batch_id),
  event_type  TEXT NOT NULL,          -- dry_hop | pitch | transfer | sample | other
  occurred_at TIMESTAMPTZ NOT NULL,   -- เวลาที่เกิดจริง ไม่ใช่เวลาที่พิมพ์คำสั่ง
  note        TEXT,
  created_by  TEXT,
  created_at  TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX idx_batch_events_batch_time ON batch_events (batch_id, occurred_at DESC);

CREATE TABLE control_log (
  log_id SERIAL PRIMARY KEY,
  device_id UUID REFERENCES devices(device_id),
  action TEXT NOT NULL,
  old_value TEXT,
  new_value TEXT,
  changed_by TEXT,
  -- เหตุผลของการปรับ (เช่น "adjust", "d rest") ที่ผู้ใช้กรอกผ่าน
  -- /ferment_set_temp — ส่งต่อไปประกอบ prompt วิเคราะห์เฟสของ AI ด้วย
  remark TEXT,
  changed_at TIMESTAMPTZ DEFAULT now()
);

-- ---------------------------------------------------------------------
-- temp_alert_state: กันเตือนซ้ำของ Temp Guard (ตรวจอุณหภูมิทุก 15 นาทีใน
-- Telemetry Sync) — 1 แถวต่อ 1 batch เก็บว่าเตือนเรื่องอะไรไปแล้วเมื่อไหร่
-- ที่ค่าเท่าไหร่ เตือนซ้ำเฉพาะเมื่อเปลี่ยนชนิด/แย่ลง >=0.5C/ครบ cooldown 6 ชม.
-- แถวถูกลบเมื่อสถานการณ์กลับเข้าเกณฑ์ เพื่อให้ครั้งหน้าที่หลุดเตือนได้ใหม่
-- (หลักการเดียวกับ batches.prep_alerted_for_phase)
-- ---------------------------------------------------------------------
CREATE TABLE temp_alert_state (
  batch_id INT PRIMARY KEY REFERENCES batches(batch_id),
  alert_kind TEXT NOT NULL,   -- sensor_stale | controller_lag | rapid_change | yeast_low | yeast_high | arrived
  alerted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  alerted_value NUMERIC
);

-- ---------------------------------------------------------------------
-- bot_state: key-value เก็บ state ของ Discord command intake workflow
-- (เช่น ID ข้อความล่าสุดที่ poll ไปแล้ว กันประมวลผลซ้ำ)
-- ---------------------------------------------------------------------
CREATE TABLE bot_state (
  key TEXT PRIMARY KEY,
  value TEXT
);
INSERT INTO bot_state (key, value) VALUES ('last_discord_message_id', '0');
