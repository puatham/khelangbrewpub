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
-- batches: batch การหมักที่กำลัง track อยู่ (ลงทะเบียนผ่าน Discord /ferment start)
-- ---------------------------------------------------------------------
CREATE TABLE batches (
  batch_id SERIAL PRIMARY KEY,
  pill_device_id UUID REFERENCES devices(device_id),
  temp_controller_device_id UUID REFERENCES devices(device_id),
  start_date TIMESTAMPTZ NOT NULL,
  target_fg NUMERIC,
  beer_name TEXT,
  current_phase TEXT DEFAULT 'lag',
  last_alert_at TIMESTAMPTZ,
  status TEXT DEFAULT 'active',
  -- กันสแปม "ใกล้จะเปลี่ยนเฟส" alert: ส่งครั้งเดียวต่อ next_phase ที่ AI เสนอ
  -- reset กลับเป็น NULL ทุกครั้งที่เฟสเปลี่ยนจริง (ดู Update Batch Phase)
  prep_alerted_for_phase TEXT,
  last_prep_alert_at TIMESTAMPTZ
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
  abv_percent NUMERIC
);

-- ---------------------------------------------------------------------
-- control_log: audit การสั่งปรับค่า (เช่น SetTargetTemperature) จาก
-- Discord หรือเว็บในอนาคต
-- ---------------------------------------------------------------------
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
-- bot_state: key-value เก็บ state ของ Discord command intake workflow
-- (เช่น ID ข้อความล่าสุดที่ poll ไปแล้ว กันประมวลผลซ้ำ)
-- ---------------------------------------------------------------------
CREATE TABLE bot_state (
  key TEXT PRIMARY KEY,
  value TEXT
);
INSERT INTO bot_state (key, value) VALUES ('last_discord_message_id', '0');
