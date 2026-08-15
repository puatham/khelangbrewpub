# Ferment Agent — RAPT + Discord + n8n

ระบบดึงข้อมูลจาก RAPT API (Pill + Temperature Controller) มาวิเคราะห์เฟสการหมักเบียร์ด้วย AI แล้วแจ้งเตือน/รับคำสั่งผ่าน Discord

---

## 1. เป้าหมายของโปรเจกต์

สร้างระบบที่:
1. รับคำสั่งจาก Discord ว่ากำลังหมัก batch ไหน ใช้ Pill ตัวไหน จับคู่กับ Temperature Controller ตัวไหน
2. AI agent อ่านค่า gravity/temperature จาก Pill มาวิเคราะห์ว่าตอนนี้การหมักอยู่ช่วงไหน (lag, active ferment/hi krausen, slowing, ยีสต์กินเสร็จ, diacetyl rest, cold crash — 6 ช่วง เป็นมาตรฐานตายตัว ไม่มีช่วงไหน optional)
3. แจ้งเตือนใน Discord เมื่อเฟสเปลี่ยน พร้อมข้อเสนอ next action
4. รับคำสั่งกลับจาก Discord เพื่อสั่งปรับอุณหภูมิ Temperature Controller จริงผ่าน RAPT API
5. **เป็นโปรเจกต์แยกอิสระ ไม่พึ่งพา InfluxDB/Grafana stack เดิม (`rapt-stack`)** — ดึงข้อมูลจาก RAPT API ตรง เก็บเองใน Postgres ทั้งหมด

โปรเจกต์เดิม (`rapt-stack`) ยังคงอยู่แยกต่างหาก ใช้สำหรับ dashboard/CSV export ไม่เกี่ยวกับโปรเจกต์นี้

---

## 2. Infrastructure ที่ตัดสินใจใช้ (และเหตุผลที่ตัด option อื่นออก)

- **Hosting**: Hostinger VPS (`srv1783485.hstgr.cloud`) — ตัดสินใจไม่ใช้ Google Cloud (Cloud Run/Firestore/Cloud Scheduler) เพราะซับซ้อนเกินจำเป็นและต้องเขียนโค้ด verify Discord signature เอง
- **Orchestration**: n8n self-hosted (Community Edition, ฟรี) — ตัดสินใจไม่ใช้ n8n Cloud เพราะไม่มี free tier ถาวรแล้ว (เริ่ม ~€24/เดือน)
- **Database**: PostgreSQL 17 (Docker container บน VPS เดียวกัน)
- **Reverse proxy**: Traefik (มาพร้อม Hostinger n8n template อยู่แล้ว จัดการ HTTPS/Let's Encrypt อัตโนมัติ)
- **AI**: Claude API และ/หรือ GPT API เรียกผ่าน n8n HTTP Request/OpenAI node
- **Messaging**: Discord bot ชื่อ "นักหมัก" — ใช้วิธี **poll ข้อความธรรมดา** (ไม่ใช่ slash command จริง) เพราะ n8n ไม่มี native slash command trigger ในตัว (ต้อง verify Ed25519 signature เองถ้าจะทำ webhook-based interactions)

---

## 3. VPS Setup — ประวัติการ migrate

เริ่มแรก Hostinger deploy n8n และ Postgres เป็น **2 Docker Compose project แยกกัน** ผ่าน "Docker Manager" UI (`/docker/n8n/docker-compose.yml` และ `/docker/postgresql-xwzm/docker-compose.yml`) ทำให้อยู่คนละ Docker network กัน

**ตัดสินใจ**: รวมเป็น 1 compose project เดียว ชื่อ `ferment-agent` อยู่ที่ `/docker/ferment-agent/` บน VPS (ไม่ใช้วิธี `docker network connect` แบบต่อมือ เพราะไม่ทนต่อการ rebuild)

**บั๊กที่เจอระหว่าง migrate (สำคัญ ถ้าทำซ้ำต้องระวัง)**:
- Volume ของ postgres เดิม **ไม่ได้ mark `external: true`** ทำให้ Docker ตั้งชื่อ volume จริงเป็น `postgresql-xwzm_postgres_data` (มี prefix ชื่อ project) ไม่ใช่ `postgres_data` เฉยๆ — ตอน merge ไฟล์ compose ใหม่ต้องใช้ `name: postgresql-xwzm_postgres_data` ใน top-level volumes block ไม่งั้นข้อมูลเดิมจะหายไปมองไม่เห็น (สร้าง volume เปล่าใหม่แทน)
- ต้อง `docker compose down` (ห้าม `-v`) 2 project เดิมก่อน แล้วค่อย `up` project ใหม่

**สถานะปัจจุบัน**: ใช้ **bind mount** แทน named volume แล้ว เพื่อให้ข้อมูลทั้งหมดอยู่ในโฟลเดอร์เดียว `/docker/ferment-agent/data/{n8n,postgres,traefik}/` ง่ายต่อการ backup (`tar czf backup.tar.gz /docker/ferment-agent`)

**ค่า config จริงที่ใช้อยู่** (ใน `/docker/ferment-agent/.env` บน VPS — ดูโครงเต็มที่ `.env.example`):
```
SSL_EMAIL=user@srv1783485.hstgr.cloud
SUBDOMAIN=n8n
DOMAIN_NAME=srv1783485.hstgr.cloud
GENERIC_TIMEZONE=Asia/Bangkok
POSTGRES_USER=root
POSTGRES_PASSWORD=<ดูในไฟล์ .env — ห้ามเขียนลงเอกสารที่ขึ้น git>
POSTGRES_DB=rapt
RAPT_USERNAME=<ดูในไฟล์ .env>
RAPT_API_SECRET=<ดูในไฟล์ .env>
```
รหัส Postgres ตัวจริงมีอักขระ `;` `@` `,` ปนอยู่ — **ต้องครอบ `'...'` ในไฟล์ `.env`** ไม่งั้น parser ตัดค่ากลางทาง

n8n เข้าได้ที่ `https://n8n.srv1783485.hstgr.cloud`

**n8n env var เพิ่มเติม** (สำหรับเรียก RAPT API): `RAPT_USERNAME`, `RAPT_API_SECRET` — ต้องเปิด `N8N_BLOCK_ENV_ACCESS_IN_NODE=false` ด้วย ไม่งั้น `{{$env.X}}` จะ error "access to env vars denied" (ตั้งไว้ใน `docker-compose.yml` แล้ว)

> ⚠️ **อย่าใช้ n8n Variables** (`{{$vars.X}}`) แทน `$env` — Custom Variables เป็นฟีเจอร์ของแผนแบบเสียเงิน Community Edition ไม่มี บน CE เหลือทางเดียวคือ `$env` + `N8N_BLOCK_ENV_ACCESS_IN_NODE=false`

---

## 4. RAPT API — endpoint ที่ต้องใช้จริง

Auth: `POST https://id.rapt.io/connect/token` (form-urlencoded: `client_id=rapt-user`, `grant_type=password`, `username`, `password`=API secret)

| Endpoint | ใช้ทำอะไร |
|---|---|
| `GET /api/Hydrometers/GetHydrometers` | รายชื่อ Pill ทั้งหมด (มี `pairedDeviceId` ติดมาด้วย) |
| `GET /api/Hydrometers/GetTelemetry` | ดึง gravity/temp/battery/rssi ย้อนหลัง |
| `GET /api/TemperatureControllers/GetTemperatureControllers` | รายชื่อ controller ทั้งหมด (มี `targetTemperature`, `pidEnabled` ฯลฯ ติดมาด้วย) |
| `GET /api/TemperatureControllers/GetTelemetry` | ดึง temp/target temp ย้อนหลัง |
| `POST /api/TemperatureControllers/SetTargetTemperature` | สั่งปรับอุณหภูมิ (params: `temperatureControllerId`, `target`) |

**ไม่ใช้**: `SetPIDEnabled`/`SetPID` (ไม่จำเป็นสำหรับ v1), กลุ่ม `BondedDevices/BrewZillas/CanFillers/ExternalDevices/FermentationChambers/Profiles/Stills` (อุปกรณ์/ฟีเจอร์คนละส่วน)

**ข้อจำกัดสำคัญ**: RAPT API **ไม่มี endpoint ให้ "set" ค่า Pill เลย** (Pill เป็นเซนเซอร์อ่านอย่างเดียว ตั้งค่าได้ผ่าน Bluetooth+แอปทางการเท่านั้น) ถ้าจะทำหน้าเว็บ "ตั้งค่า Pill" ในอนาคต ทำได้แค่ระดับ metadata ในระบบเราเอง (เช่น target_fg, beer_name) ไม่ใช่สั่งงานตัว Pill จริง

**บั๊กที่ต้องรู้**: ชื่อ device จาก RAPT อาจมี trailing space (เช่น `"Fridge "` มีช่องว่างท้าย ส่วน `"Fridge2"` ไม่มี) — query ที่เทียบชื่อต้องใช้ `trim()` หรือ regex เสมอ อย่าใช้ `=` ตรงๆ

---

## 5. Database Schema (Postgres)

DDL เต็มอยู่ที่ [`schema.sql`](schema.sql) — รันได้เลย (มี index ของ readings + seed `bot_state`) ดู ER diagram เต็มที่ [`er-diagram.mermaid`](er-diagram.mermaid)

```sql
CREATE TABLE devices (
  device_id UUID PRIMARY KEY,
  device_name TEXT NOT NULL,
  device_type TEXT NOT NULL CHECK (device_type IN ('pill','temp_controller')),
  last_synced_at TIMESTAMPTZ DEFAULT now(),
  raw_data JSONB
);

CREATE TABLE batches (
  batch_id SERIAL PRIMARY KEY,
  pill_device_id UUID REFERENCES devices(device_id),
  temp_controller_device_id UUID REFERENCES devices(device_id),
  start_date TIMESTAMPTZ NOT NULL,
  target_fg NUMERIC,
  beer_name TEXT,
  current_phase TEXT DEFAULT 'lag',
  last_alert_at TIMESTAMPTZ,
  status TEXT DEFAULT 'active'
);

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

CREATE TABLE temp_controller_readings (
  id BIGSERIAL PRIMARY KEY,
  device_id UUID REFERENCES devices(device_id),
  time_utc TIMESTAMPTZ NOT NULL,
  temperature_c NUMERIC,
  target_temperature_c NUMERIC,
  rssi_dbm NUMERIC,
  UNIQUE (device_id, time_utc)
);

CREATE TABLE phase_log (
  log_id SERIAL PRIMARY KEY,
  batch_id INT REFERENCES batches(batch_id),
  checked_at TIMESTAMPTZ DEFAULT now(),
  gravity_sg NUMERIC,
  temperature_c NUMERIC,
  gravity_velocity NUMERIC,
  detected_phase TEXT,
  ai_reasoning TEXT
);

CREATE TABLE control_log (
  log_id SERIAL PRIMARY KEY,
  device_id UUID REFERENCES devices(device_id),
  action TEXT NOT NULL,
  old_value TEXT,
  new_value TEXT,
  changed_by TEXT,
  changed_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE bot_state (
  key TEXT PRIMARY KEY,
  value TEXT
);
INSERT INTO bot_state (key, value) VALUES ('last_discord_message_id', '0');
```

**เหตุผลการออกแบบ**: `devices` เป็นตาราง lookup กลาง (ทุกตารางอ้าง `device_id` ไม่ใช้ text name ซ้ำๆ กันความเสี่ยงชื่อไม่ตรงจาก trailing-space bug) เก็บ `raw_data JSONB` ไว้ด้วยเผื่ออนาคตอยากได้ field ที่ตอนนี้ยังไม่ได้ใช้ (เช่น `connectionState`, `firmwareVersion`, `pidProportional`) — RAPT API response ของ Hydrometer/TemperatureController มี field เยอะมาก

`pill_readings`/`temp_controller_readings` แยกจาก `phase_log`: อันแรกเก็บ raw telemetry ทุกจุด อันหลังเก็บแค่ผลสรุปตอน AI วิเคราะห์แต่ละรอบ (เบากว่ามาก)

> ⚠️ **เคยเจอ database จริงไม่ตรงกับ schema.sql 2 จุด (15 ส.ค.)**: `bot_state` ไม่เคยถูกสร้างจริง (ตกหล่นตอน migrate) และ `batches.beer_name` หายไปเฉยๆ — เจอตอนทดสอบ workflow จริงแล้วขึ้น error ทั้งคู่ แก้ด้วย `CREATE TABLE`/`ALTER TABLE` ตรงๆ แล้ว ตอนนี้ database จริงตรงกับ `schema.sql` 100% แล้ว แต่เป็นเครื่องเตือนว่า **ก่อนเชื่อว่า schema พร้อมใช้ ให้เช็ค `\d <table>` จริงบน VPS ก่อนเสมอ** อย่าเชื่อแค่เอกสาร

---

## 6. Discord Bot

- Application name: **นักหมัก**
- มี Bot Token, Application/Client ID, Server ID, Channel ID ครบแล้ว (เก็บไว้ที่ n8n credential)
- เปิด **Message Content Intent** แล้ว (จำเป็นเพราะใช้วิธี poll ข้อความ ไม่ใช่ slash command)
- Invite เข้า server ด้วย scope `bot` + `applications.commands`, permission: Send Messages, Read Message History, View Channels, Embed Links, Use Slash Commands

รูปแบบคำสั่งที่ใช้งานจริง (พิมพ์เป็นข้อความธรรมดาในช่องที่กำหนด):
```
!ferment start pill=Pill01 controller=Fridge2 beer="Hazy IPA"
!ferment start pill=Pill01 controller=Fridge2 beer="Hazy IPA" date="10/8/2026 14:41"
!ferment stop pill=Pill01
```
รองรับค่าที่มีเว้นวรรคด้วย `"..."` (parser ใช้ regex `/(\w+)=(?:"([^"]*)"|(\S+))/g`)

`date=` (optional) ใช้ **ลงทะเบียนย้อนหลัง** สำหรับ batch ที่เริ่มหมักไปแล้วก่อนตั้งระบบ — รูปแบบ **`D/M/YYYY HH:mm`** (วัน/เดือน/ปี ค.ศ. แบบไทย เวลา 24 ชม.) ไม่ใส่หรือใส่ผิดรูปแบบจะ fallback เป็นเวลาปัจจุบันเงียบๆ

---

## 7. n8n Credentials

1. **Postgres**: host `postgresql` (ชื่อ service ใน docker-compose), db `rapt`, user `root`
2. **Discord**: credential type ที่ถูกต้องคือ **`discordBotApi`** (ไม่ใช่ `discordApi`) — bot token ของ "นักหมัก"
3. **RAPT**: ไม่มี credential type สำเร็จรูป ใช้ env var แทน (`RAPT_USERNAME`, `RAPT_API_SECRET`, ดูข้อ 3)
4. **Claude/GPT**: Anthropic หรือ OpenAI credential (ใส่ API key ตรง)

---

## 7.5 วิธีสร้าง/ต่อ workflow ใน n8n (ทั่วไป — ใช้ได้กับทุก workflow ด้านล่าง)

**สร้าง workflow ใหม่**
กดปุ่ม **+ Add workflow** (มุมขวาบนของหน้า Overview) → เปิด canvas เปล่าพร้อม node "When clicking 'Execute workflow'" (Manual Trigger) ให้อัตโนมัติ → เปลี่ยนชื่อ workflow มุมซ้ายบน

**เพิ่ม node ใหม่**
กดเครื่องหมาย **+** ที่ขอบขวาของ node ล่าสุด (หรือกด + กลาง canvas) → พิมพ์ค้นหาชื่อ node (เช่น `HTTP Request`, `Code`, `Postgres`, `IF`, `Schedule Trigger`) → คลิกเลือก

**ตั้งชื่อ node**
ดับเบิลคลิกชื่อ node ด้านบนกล่อง พิมพ์ชื่อใหม่ (ช่วยให้ expression อ้างอิง node อื่นด้วยชื่อได้ง่าย เช่น `$('Get Last Message Id')`)

**ใส่ค่าแบบ expression (อ้างอิงข้อมูลจาก node ก่อนหน้า)**
พิมพ์ `{{ ... }}` ในช่องได้เลยตรงๆ เช่น `{{$json.access_token}}` — **ถ้าเป็นข้อความผสม (static text + expression ปนกัน) และ n8n auto-switch เป็น expression mode ให้แล้ว ห้ามใส่ `=` นำหน้าซ้ำ** (จะกลายเป็น literal text ทำให้ค่าไม่ resolve) ถ้าไม่มั่นใจให้ดู preview เล็กๆ ใต้ช่อง input ว่า resolve ค่าถูกไหมก่อน

**ต่อ node เข้าด้วยกัน**
ลาก dot วงกลมด้านขวาของ node ต้นทาง ไปปล่อยที่ dot ซ้ายของ node ปลายทาง ต่อได้หลายเส้นจาก node เดียวกัน (เช่น sync devices แตก 2 กิ่งจาก `Get RAPT Token`)

**ทดสอบทีละ node**
คลิก node แล้วกด **Execute step** ดู output ว่าถูกไหมก่อนต่อ node ถัดไป ถ้า error จะขึ้นกรอบแดงพร้อมข้อความ error ให้ debug ทีละจุด

**ทดสอบทั้ง workflow**
กด **Save** แล้วกด **Execute Workflow** รันทั้งเส้น

**เปิดใช้งานจริง**
กด toggle **Active** มุมขวาบน — สำคัญมาก ถ้าลืมเปิด workflow จะรันแค่ตอนกด Execute เองเท่านั้น ไม่ทำงานตาม Schedule Trigger จริง

**⚠️ Import from File ระวังทับผิด workflow**: import จะ **เขียนทับ workflow ที่เปิดอยู่ ณ ตอนนั้นเสมอ** ไม่เช็คว่าไฟล์เป็นของ workflow ไหน เคยพลาดเปิด workflow ผิดอันค้างไว้แล้ว import ทับจนข้อมูล Sync Devices หายไป (15 ส.ค. — กู้คืนได้จาก git backup ไม่มีข้อมูลสูญหาย) **เช็คชื่อ/URL ของ workflow ที่เปิดอยู่ทุกครั้งก่อนกด Import from File**

---

## 8. n8n Workflows

### 8.1 "Sync Devices" — ✅ สร้างเสร็จ + ทดสอบผ่านแล้ว

Node structure (8 node): `Manual Trigger → Get RAPT Token (HTTP POST token endpoint)` แตก 2 กิ่ง:
- กิ่ง Pill: `Get Hydrometers (HTTP GET)` → `Format Pills (Code node)` → `Save Pills (Postgres upsert)`
- กิ่ง Temp Controller: `Get Temperature Controllers (HTTP GET)` → `Format Temp Controllers (Code node)` → `Save Temp Controllers (Postgres upsert)`

**Code node "Format Pills"** (Temp Controller ใช้แบบเดียวกันแค่เปลี่ยน `device_type`):
```javascript
const items = $input.all();
let data;
if (items.length === 1 && Array.isArray(items[0].json)) {
  data = items[0].json;
} else {
  data = items.map(i => i.json);
}
return data.map(d => ({
  json: {
    device_id: d.id,
    device_name: d.name,
    device_type: 'pill', // เปลี่ยนเป็น 'temp_controller' ในกิ่งนั้น
    raw_data: d
  }
}));
```

**Postgres upsert query** (ใช้ Query Parameters ไม่ฝัง `{{ }}` ตรงๆ ใน SQL string เพื่อความปลอดภัย):
```sql
INSERT INTO devices (device_id, device_name, device_type, raw_data, last_synced_at)
VALUES ($1, $2, $3, $4, now())
ON CONFLICT (device_id) DO UPDATE
SET device_name = EXCLUDED.device_name,
    device_type = EXCLUDED.device_type,
    raw_data = EXCLUDED.raw_data,
    last_synced_at = now();
```
Query Parameters: `{{$json.device_id}}, {{$json.device_name}}, {{$json.device_type}}, {{JSON.stringify($json.raw_data)}}`

**ผลทดสอบล่าสุด**: sync สำเร็จ ได้ 4 devices ครบ (Pill01, Pill02, Fridge, Fridge2) พร้อม raw_data เต็ม ยืนยัน `pairedDeviceId` มาด้วยในตัว (Pill01 ↔ Fridge2, Pill02 ↔ Fridge)

**บั๊กที่เจอและแก้แล้ว**:
- ลืมเปลี่ยน `device_type` ใน Code node กิ่ง Temp Controller (ยังเป็น `'pill'`)
- Query ON CONFLICT ตอนแรกไม่ได้ update `device_type`
- Header `Authorization` ใน HTTP Request node **ห้ามมี `=` นำหน้า** ถ้า field เป็น expression mode อยู่แล้ว (ใส่ซ้อนจะกลายเป็น literal text ทำให้ 401)

### 8.2 "Discord Command Intake" — 🔴 **เลิกใช้แล้ว (unpublish 15 ส.ค.)** ถูกแทนที่ด้วย 8.5

คำสั่ง `!ferment start ...` / `!ferment stop ...` แบบ text ไม่ใช้แล้ว ให้ใช้ `/ferment_start` `/ferment_stop` `/ferment_status` (slash command, ข้อ 8.5) แทนทั้งหมด — workflow นี้ unpublish ไว้แล้ว (ไม่ได้ลบ เผื่อต้องอ้างอิงโค้ดย้อนหลัง) เนื้อหาด้านล่างเก็บไว้เป็นบันทึกประวัติ

✅ สร้างเสร็จ + ทดสอบผ่านแล้ว (start / stop / backdate ครบ) — ตอนที่ยังใช้งานอยู่

ต้องมีตาราง `bot_state` เก็บ `last_discord_message_id`

Node structure (10 node):
1. **Schedule Trigger** — ทุก 1 นาที
2. **Postgres "Get Last Message Id"** — `SELECT value FROM bot_state WHERE key = 'last_discord_message_id'`
3. **HTTP Request "Get New Messages"** — GET `https://discord.com/api/v10/channels/<CHANNEL_ID>/messages` — Authentication: Predefined Credential Type → **`discordBotApi`** — query param `after={{$json.value}}&limit=50`
4. **Code "Parse Commands"**:
```javascript
const items = $input.all();
const results = [];
let maxId = $('Get Last Message Id').first().json.value;
const paramRegex = /(\w+)=(?:"([^"]*)"|(\S+))/g;

function parseStartDate(str) {
  if (!str) return new Date().toISOString();
  const m = str.match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})\s+(\d{1,2}):(\d{2})$/);
  if (!m) return new Date().toISOString();
  const day = Number(m[1]), month = Number(m[2]), year = Number(m[3]), hour = Number(m[4]), minute = Number(m[5]);
  if (month < 1 || month > 12 || day < 1 || day > 31 || hour > 23 || minute > 59) return new Date().toISOString();
  const pad = (n) => String(n).padStart(2, '0');
  return `${year}-${pad(month)}-${pad(day)}T${pad(hour)}:${pad(minute)}:00+07:00`;
}

for (const item of items) {
  const m = item.json;
  const text = (m.content || '').trim();
  const match = text.match(/^!ferment\s+(start|stop)\s+(.*)$/i);
  if (match) {
    const action = match[1].toLowerCase();
    const params = {};
    let pm;
    paramRegex.lastIndex = 0;
    while ((pm = paramRegex.exec(match[2])) !== null) {
      params[pm[1]] = pm[2] !== undefined ? pm[2] : pm[3];
    }
    results.push({
      json: { action, ...params, start_date: parseStartDate(params.date), message_id: m.id }
    });
  }
  if (BigInt(m.id) > BigInt(maxId)) maxId = m.id;
}

if (results.length === 0) {
  results.push({ json: { action: 'none', maxId } });
} else {
  results.forEach(r => r.json.maxId = maxId);
}
return results;
```
5. **IF "Is Start?"** — `{{$json.action}}` equals `start` → true: `Create Batch`, false: ต่อ `IF "Is Stop?"`
6. **IF "Is Stop?"** — `{{$json.action}}` equals `stop` → true: `Stop Batch`, false: ข้าม Discord ไป `Update Last Message Id` ตรงๆ (ไม่มีคำสั่งให้ทำ)
7. **Postgres "Create Batch"**:
```sql
INSERT INTO batches (pill_device_id, temp_controller_device_id, start_date, beer_name, status)
SELECT
  (SELECT device_id FROM devices WHERE trim(device_name) = trim($1) AND device_type = 'pill' LIMIT 1),
  (SELECT device_id FROM devices WHERE trim(device_name) = trim($2) AND device_type = 'temp_controller' LIMIT 1),
  $4,
  $3,
  'active'
RETURNING batch_id;
```
Query Parameters: `{{$json.pill}}, {{$json.controller}}, {{$json.beer || null}}, {{$json.start_date}}`
8. **Postgres "Stop Batch"**:
```sql
UPDATE batches SET status = 'done'
WHERE pill_device_id = (SELECT device_id FROM devices WHERE trim(device_name) = trim($1) AND device_type = 'pill' LIMIT 1)
AND status = 'active';
```
Query Parameters: `{{$json.pill}}`
9. **HTTP Request "Send Confirmation"** — POST ช่องเดิม, body `content`:
```
{{ $('Parse Commands').item.json.action === 'start' ? ('✅ เริ่ม batch: ' + ($('Parse Commands').item.json.beer || '(ไม่ระบุชื่อเบียร์)') + '\nPill: ' + $('Parse Commands').item.json.pill + ' ↔ Controller: ' + $('Parse Commands').item.json.controller + '\nเริ่มหมักเมื่อ: ' + DateTime.fromISO($('Parse Commands').item.json.start_date).setZone('Asia/Bangkok').toFormat('d/M/yyyy HH:mm')) : ('⏹️ หยุด batch ของ Pill: ' + $('Parse Commands').item.json.pill) }}
```
10. **Postgres "Update Last Message Id"** — `UPDATE bot_state SET value = $1 WHERE key = 'last_discord_message_id'` params `{{$('Parse Commands').item.json.maxId}}` (รันทุกเส้นรวม `none`)

**ผลทดสอบล่าสุด**: `start` และ `stop` ผ่านครบ ยืนยันด้วย query ตรง — batch สร้างถูก, `device_id` resolve ถูกทั้งคู่, Discord ตอบกลับถูก, `bot_state` เลื่อน pointer ถูก ทดสอบ backdate ด้วย `date="10/8/2026 14:41"` ได้ `start_date = 2026-08-10 07:41:00+00` (แปลง timezone ถูกต้อง)

**บั๊กที่เจอและแก้แล้ว** (เก็บไว้อ้างอิงถ้าต้อง debug คล้ายกันอีก):
- Credential type ที่ถูกต้องคือ `discordBotApi` ไม่ใช่ `discordApi` (เดาผิดตอนแรก → error "Credentials not found" เพราะ n8n ไม่รู้จัก type นั้นสำหรับ HTTP Request node)
- n8n เวอร์ชันนี้ (2.34.6 self-hosted) **แยก JSON array ที่ HTTP node ได้รับเป็นคนละ item ให้อัตโนมัติ** (ไม่เหมือนที่ RAPT call ใน Sync Devices สมมติไว้ว่าเป็น 1 item ที่มี array ข้างใน) — ต้องวนลูปด้วย `$input.all()` ไม่ใช่ `$input.first().json`
- `Send Confirmation`/`Update Last Message Id` ต้องอ้างอิงข้อมูลผ่าน `$('Parse Commands').item.json.xxx` ไม่ใช่ `$json.xxx` ตรงๆ เพราะ Postgres UPDATE/INSERT ไม่ได้ pass field เดิมต่อมาให้เสมอ

### 8.3 "Cron วิเคราะห์เฟส" — ✅ เสร็จ ทดสอบผ่าน (task #32, 15 ส.ค.)

20 nodes: `Schedule Trigger` (ทุก 30 นาที) → `Get RAPT Token` → `Get Active Batches` (Postgres, เฉพาะ `status='active'`) → แยก 3 สาย: (1) `Get Pill Telemetry`→`Format Pill Readings`→`Insert Pill Readings`, (2) `Get Controller Telemetry`→`Format Controller Readings`→`Insert Controller Readings`, (3) `Get Latest Readings`→`Build AI Prompt`→`Call Claude`→`Parse AI Response` → แยกเป็น 3 สายขนาน: `Insert Phase Log`, `Phase Changed?`(IF, true→`Send Discord Alert`→`Update Batch Phase`), `Approaching Transition?`(IF, true→`Send Prep Alert`→`Update Prep Alert State`)

**"ใกล้จะเปลี่ยนเฟส เตรียมตัว" alert** (เพิ่ม 15 ส.ค.): AI ประเมินเพิ่มว่า batch มีสัญญาณใกล้เข้าเฟสถัดไปหรือไม่ (`approaching_transition`/`next_phase`/`prep_actions` ใน JSON response) ถ้าใช่จะส่ง Discord alert แยกต่างหาก บอกสิ่งที่ควรเตรียม (เช่น ใกล้ diacetyl_rest → เตรียมยกอุณหภูมิ 16-18°C) กันสแปมด้วย `batches.prep_alerted_for_phase` — ส่งครั้งเดียวต่อ `next_phase` หนึ่งค่า จนกว่า AI จะเปลี่ยนใจเป็น next_phase อื่น หรือเฟสเปลี่ยนจริง (reset เป็น `NULL` อัตโนมัติใน `Update Batch Phase`)

**AI ที่ใช้**: Claude (Anthropic Messages API, `claude-sonnet-5`, `max_tokens=4096`) ไม่ใช้ web search — เกณฑ์ 6 เฟส bake เป็น context ตายตัวในทุก prompt (ดูข้อ 9) เพราะเป็นความรู้ที่นิ่งแล้ว ไม่ต้องเสียเวลา/เงินค้นเว็บซ้ำทุก 30 นาที

**ตัวชี้วัดที่ส่งให้ AI ต่อ batch**: เวลาที่ผ่านไปตั้งแต่ `start_date`, gravity ปัจจุบัน, **gravity velocity ที่คำนวณเอง** (Δgravity_sg / วัน จากข้อมูล ~24 ชม.ล่าสุดที่เราเก็บเอง แม่นยำกว่าเชื่อ field `gravityVelocity` ดิบจาก RAPT เพราะ unit ไม่ยืนยันชัด), **apparent attenuation %** (เทียบ OG จริงที่ Pill วัดได้กับ gravity ปัจจุบัน ตามเกณฑ์ BJCP 65-80%), ผลต่างอุณหภูมิ Pill-ตู้ควบคุม (exothermic heat ช่วง active fermentation), target temperature ของตู้ควบคุม

**ผลทดสอบล่าสุด**: batch 4 (Double Hazy IPA/Pill01, 91.5 ชม.) → `active_ferment`, batch 3 (Weizen/Pill02, 139.5 ชม.) → `fg_stable` ทั้งคู่ผ่าน AI parse สำเร็จ (ไม่ fallback), `batches.current_phase`/`last_alert_at` อัปเดตถูก, Discord alert ยิงออก

**บั๊กที่เจอและแก้แล้ว** (เก็บไว้อ้างอิงถ้าต้อง debug คล้ายกันอีก):
- `max_tokens` ต้องส่งเป็น expression ตัวเลข (`={{ 4096 }}`) ไม่ใช่ literal string เฉยๆ ไม่งั้น Anthropic API ปฏิเสธ
- โมเดลนี้เปิด extended thinking โดย default — `content[]` ของ response อาจมี `type: "thinking"` block มาก่อน `type: "text"` เสมอ ต้อง `.find(c => c.type === 'text')` ไม่ใช่เดา `content[0]` ตรงๆ และต้องเผื่อ `max_tokens` ให้พอทั้ง thinking+ข้อความจริง (300 ไม่พอ, ใช้ 4096)
- RAPT `gravity` field เป็น SG×1000 ไม่ใช่ SG ตรงๆ ต้องหาร 1000
- Postgres INSERT ที่ไม่มี `RETURNING` จะไม่ pass field เดิมของ item ต่อไปให้ node ถัดไป (`$json` จะว่างเปล่า) — ต้อง route จาก node ต้นทางตรงๆ (ในที่นี้คือให้ `Parse AI Response` แยกสายไป `Phase Changed?` ขนานกับ `Insert Phase Log` แทนที่จะให้ไหลผ่าน Postgres node ก่อน)
- pairedItem tracking หลุดผ่าน Postgres INSERT (ไม่มี RETURNING) ทำให้ `.item`/`itemMatching()` ที่ต้องย้อนอ้างอิงผ่าน node นั้น error "Multiple matching items" เมื่อมีมากกว่า 1 item วิ่งพร้อมกัน — แก้ด้วยการ wiring ใหม่ (ข้างบน) ไม่ใช่แก้ expression
- n8n แปลง JS `null` เป็น literal text `"null"` ตอนแทรกลง Postgres `queryReplacement` (comma-separated string) ทำให้ cast เป็น `numeric` fail ต้องครอบด้วย `NULLIF($n, 'null')::numeric`
- OG ที่ใช้คำนวณ apparent attenuation % ต้องเช็คว่า reading แรกที่มีอยู่ใกล้ `start_date` จริงแค่ไหน (ภายใน 24 ชม.) ถ้าห่างเกินไป (เช่นเพิ่งเริ่มเก็บ telemetry หลัง batch เริ่มไปแล้วหลายวัน) ต้อง flag ให้ AI รู้ว่าเลขนี้ไม่น่าเชื่อถือ ไม่งั้น AI จะเข้าใจผิดว่ายังอยู่เฟส lag ทั้งที่ผ่านมาเป็นร้อยชั่วโมงแล้ว
- `Update Prep Alert State` เจอบั๊กเดียวกับ `Update Batch Phase`: อยู่หลัง `Send Prep Alert` (HTTP node ที่ทับ `$json` ด้วย response ของ Discord) จึงอ่าน `$json.next_phase`/`$json.batch_id` ตรงๆ ไม่ได้ ต้องอ้างอิง `$('Parse AI Response').itemMatching($itemIndex).json.xxx` เหมือนกัน
- reset `bot_state.last_discord_message_id` เป็น `'0'` ตอนเคลียร์ข้อมูลทดสอบ **ทำให้ Discord Command Intake replay ข้อความเก่าทั้งหมดในแชทซ้ำ** (สร้าง batch ซ้อนกันหลายสิบแถว) วิธีที่ถูกต้องคือตั้งเป็น Discord snowflake ของเวลาปัจจุบันแทน (`(now_ms - 1420070400000) << 22`) เพื่อให้ intake ไม่ไปอ่านข้อความที่เก่ากว่าตอนเคลียร์

### 8.4 "รับคำสั่งปรับอุณหภูมิ" — ❌ ยังไม่ได้สร้าง (task #33)

แผนคร่าวๆ: ต่อยอดจาก workflow 8.2 เพิ่มคำสั่งแบบ `!ferment settemp pill=Pill01 target=20.5` → เรียก `SetTargetTemperature` → insert `control_log` → ยืนยันกลับ Discord

### 8.5 "Discord Interactions Webhook" (slash commands) — ✅ เสร็จ ทดสอบผ่าน (task #35, 15 ส.ค.)

`/ferment_start` และ `/ferment_stop` เป็น native Discord slash command (typed params, autocomplete) แทนที่การพิมพ์ `!ferment start ...` เป็น text — คนละ workflow กับ 8.2 (Discord Command Intake ยังอยู่ ไม่ได้ลบ ใช้ polling แบบเดิมคู่ขนานกันได้)

**สถาปัตยกรรม**: Discord ยิง HTTP POST มาที่ n8n Webhook โดยตรง (ต่างจาก workflow อื่นที่ n8n ไป poll Discord) ต้อง:
- **Public "Interactions Endpoint URL"** — ตั้งใน Discord Developer Portal → General Information ชี้มาที่ n8n Webhook node's Production URL
- **Verify ลายเซ็น Ed25519** ทุก request (Discord บังคับ ไม่งั้น endpoint ถูกปิดอัตโนมัติ) ด้วย Node `crypto` — ต้องเปิด `NODE_FUNCTION_ALLOW_BUILTIN=crypto` ใน docker-compose.yml ก่อน (n8n บล็อก built-in module ใน Code node โดย default)
- **Deferred response**: ตอบ `{"type":5}` ภายใน 3 วินาทีก่อน (Discord โชว์ "กำลังคิด...") แล้วค่อยทำงานจริงเบื้องหลัง จบด้วย `PATCH /webhooks/{app_id}/{interaction_token}/messages/@original` แก้ข้อความเป็นผลจริง
- **Register command แบบ guild-scoped ครั้งเดียว** ผ่าน workflow แยก `Register Slash Commands` (`PUT /applications/{id}/guilds/{guild_id}/commands`) — รันครั้งเดียวจบ ลบทิ้งได้ (ลบไปแล้ว)

Node หลัก: `Webhook`(rawBody) → `Verify Signature`(Code) → `Signature Valid?` → `Is Ping?`/`Is Command?` → `Respond Deferred` → `Parse Interaction Command` → `Is Start?`/`Is Stop?` → `Create Batch`/`Stop Batch` (**reuse query เดิมจาก 8.2 เป๊ะๆ**) → `Build Followup Message` → `Send Followup`

**บั๊กที่เจอและแก้แล้ว**:
- Code node ที่ import มา default เป็นโหมด **"Run Once for All Items"** ซึ่งตัวแปรลัด `$json`/`$binary` (แบบ bare ไม่ระบุ node) ใช้ไม่ได้ในโหมดนี้ ต้องใช้ `$input.first().json`/`$input.first().binary` แทน (แต่ `$('NodeName').first()` แบบระบุชื่อ node ใช้ได้ปกติ)
- raw body ของ Webhook (`rawBody: true` option) เก็บอยู่ที่ `binary.data.data` (base64) ไม่ใช่ parse เป็น JSON ธรรมดา — ต้อง `Buffer.from(..., 'base64').toString('utf8')` เอง
- `PATCH .../messages/@original` ตอบ "Unknown Webhook" ทั้งที่ token/application_id ถูกทุกอย่าง — สาเหตุจริงคือ body mode "Using Fields Below" ของ HTTP Request node ไม่ได้ serialize เป็น JSON จริง (ไม่มี `Content-Type: application/json`, request ออกไปแบบ `json:false`) ต้องเปลี่ยนเป็น **Body Content Type: Raw + `application/json`** พร้อม `JSON.stringify(...)` เอง ถึงจะผ่าน
- reset `bot_state` เป็น `'0'` ตอนเคลียร์ DB ทำให้ Discord Command Intake (workflow แบบ polling เดิม) replay ข้อความเก่าซ้ำ — ไม่เกี่ยวกับ slash command แต่กระทบ batch ซ้อนกันถ้าเผลอรันทั้งสอง workflow พร้อมกันตอน DB ว่าง ระวังจุดนี้เวลาเคลียร์ข้อมูลอีก

---

## 9. กรอบ 6 เฟสการหมัก (ใช้เป็น prompt ให้ AI จำแนก)

อ้างอิงจาก BJCP Yeast & Fermentation guide, John Palmer "How to Brew", Brew Your Own Fermentation Timeline, และเอกสาร RAPT เอง (ไม่ได้อ้างอิงจากประสบการณ์ทำเบียร์ก่อนหน้าของโปรเจกต์นี้ — ตั้งใจ research จากแหล่งกลางเพื่อความแม่นยำ)

1. **lag** — 0-24 ชม.แรกหลัง pitch ยีสต์ปรับตัว ยังไม่มี krausen ชัดเจน gravity แทบไม่ขยับ (apparent attenuation ~0%) แทบไม่มีผลต่างอุณหภูมิ pill-ตู้ควบคุม
2. **active_ferment** — วันที่ 1-4 (หนักสุดมักอยู่ใน 48-72 ชม.แรก) high krausen, gravity ลดเร็วที่สุด, apparent attenuation ไต่ขึ้นเร็วจนใกล้ 50-75%, pill มักอุ่นกว่าตู้ควบคุม 2-5°C จากปฏิกิริยาคายความร้อน (exothermic)
3. **slowing** — krausen เริ่มยุบ อัตราลด gravity ผ่อนลงจากจุดสูงสุดแต่ยัง "ลบชัดเจน" attenuation มักอยู่แถว 60-80% แล้วแต่ยังไม่นิ่ง ผลต่างอุณหภูมิ pill-ตู้ควบคุมเริ่มแคบลง
4. **fg_stable** — gravity velocity ใกล้ 0 ต่อเนื่อง 24-48 ชม. (RAPT เองแนะนำให้เริ่ม cold crash ได้เมื่อ velocity แตะ 0) attenuation ควรอยู่ 65-80% ตามเกณฑ์ BJCP ผลต่างอุณหภูมิ pill-ตู้ควบคุมควรใกล้ 0 — ⚠️ ถ้านิ่งเร็วผิดปกติหรือ attenuation ต่ำกว่า ~60% ให้สงสัยว่าเป็น stuck fermentation
5. **diacetyl_rest** — ต้องผ่าน fg_stable ก่อน แล้วยกอุณหภูมิตู้ควบคุมเป็น 16-18°C ค้าง 2-3 วัน (จำเป็นสำหรับ lager, แนะนำสำหรับ ale ส่วนใหญ่)
6. **cold_crash** — ต้องผ่าน fg_stable (และปกติ diacetyl_rest) ก่อน แล้วลดอุณหภูมิตู้ควบคุมเหลือ 0-4°C ค้าง 1-3 วัน (ale ~1-2 วัน, lager ~2-3 วัน)

---

## 10. Task list สถานะล่าสุด

- #27 สร้างตาราง Postgres — ✅ เสร็จ (7 ตารางครบ, `bot_state` เพิ่งสร้างจริง 15 ส.ค. ดูข้อ 5)
- #28 ตั้งค่า Discord bot — ✅ เสร็จ
- #29 ใส่ credential ใน n8n — ✅ เสร็จ
- #30 workflow sync devices — ✅ เสร็จ ทดสอบผ่าน
- #31 workflow Discord command intake — 🔴 เลิกใช้แล้ว (unpublish 15 ส.ค.) ถูกแทนที่ด้วย #35 — ดูข้อ 8.2
- #32 workflow cron วิเคราะห์เฟส — ✅ เสร็จ ทดสอบผ่าน + **publish/active จริงแล้ว** (เพิ่งพบว่าไม่เคย publish มาก่อน แก้ 15 ส.ค.)
- #33 workflow รับคำสั่งปรับอุณหภูมิ — ❌ ยังไม่เริ่ม
- #34 ทดสอบระบบจริงกับ Pill01/Pill02 — 🟡 DB เพิ่งเคลียร์ล่าสุด 15 ส.ค. รอผู้ใช้เริ่มลงทะเบียน batch ใหม่ผ่าน `/ferment_start`
- #35 Discord slash command (`/ferment_start`, `/ferment_stop`) — ✅ เสร็จ ทดสอบผ่าน — 15 ส.ค.
- #36 `/ferment_status` + auto-resolve controller จาก RAPT pairing — ✅ เสร็จ ทดสอบผ่าน — 15 ส.ค.

---

## 11. Batch การหมักจริง

> ⚠️ **DB เพิ่งถูกเคลียร์ทั้งหมด (15 ส.ค.)** ระหว่างพัฒนา/ทดสอบ #32 และ #35 — ทุกตาราง (`devices`, `batches`, `pill_readings`, `temp_controller_readings`, `phase_log`, `control_log`) ว่างเปล่า มีแค่ `bot_state` ที่ seed ค่า cursor ไว้ (ตั้งเป็น Discord snowflake ของเวลาที่เคลียร์ ไม่ใช่ `'0'` — ดูเหตุผลในข้อ 8.5) **ต้องรัน Sync Devices ก่อน แล้วค่อยลงทะเบียน batch Pill01 (Double Hazy IPA, จับคู่ Fridge2)/Pill02 (Weizen, จับคู่ Fridge) ใหม่ผ่าน `/ferment_start`** พร้อม `date=` backdate ให้ตรงวันเริ่มจริง ก่อนจะกลับไปทดสอบ #32/#34 ต่อ

---

## 12. ไฟล์ในโปรเจกต์

Repo: `github.com/puatham/khelangbrewpub` (private)
ของเดิมที่ `rapt-stack/ferment-agent-vps/` ถือเป็นสำเนาเก่า ให้ยึดไฟล์ใน repo นี้เป็นหลัก

- `docker-compose.yml` — compose file ที่ deploy จริงบน VPS (traefik + n8n + postgres, bind mount ที่ `./data/`)
- `.env` — ค่า config จริง **อยู่ใน `.gitignore` ไม่ขึ้น git**
- `.env.example` — โครงเปล่าไว้ให้ก๊อปไปทำ `.env`
- `schema.sql` — DDL 7 ตารางครบ รันได้เลย (มี index ของ readings + seed `bot_state`)
- `er-diagram.mermaid` — ER diagram schema เต็ม
- `backup-workflows.sh` — export workflow จาก n8n ลง `workflows/` แล้ว commit ให้ (ดูข้อ 13)
- `workflows/` — n8n workflow ที่ export ไว้ **เป็นแหล่งจริง (source of truth)** ตรงกับของบน n8n เป๊ะทุกครั้งที่ backup — **ห้ามแก้ไฟล์ในนี้ด้วยมือ** ให้แก้ที่ n8n แล้วรัน backup แทน
- `README.md` — ไฟล์นี้

---

## 13. Backup workflow ขึ้น git

n8n มีฟีเจอร์ **Source Control** ที่ sync กับ Git repo ได้ในตัว (push/pull workflow + stub ของ credential) แต่**อยู่ในแผน Business ขึ้นไป** Community Edition ที่ใช้อยู่ไม่มีให้ ทางเลือกที่ใช้ได้จริงคือ export ผ่าน n8n CLI ซึ่งมีทุก edition

รันบน VPS (เครื่องที่มี container อยู่ ต้อง clone repo นี้ไว้ที่ `/docker/ferment-agent/repo/`):

```bash
./backup-workflows.sh          # export + commit
./backup-workflows.sh --push   # export + commit + push
./backup-workflows.sh --dry-run # export มาดูเฉยๆ
```

สคริปต์ export ลง `/tmp` ใน container ก่อน ถ้าสำเร็จค่อยเขียนทับ `workflows/` เพื่อไม่ให้ export พังแล้วไฟล์ backup เดิมหายไปด้วย, กรองเหลือเฉพาะ workflow ของโปรเจกต์นี้ตาม `workflows/.allowed-ids`, ตั้งชื่อไฟล์ตาม field `"name"` ให้อัตโนมัติ (ไม่ใช่ opaque n8n id), และ commit เฉพาะตอนมีอะไรเปลี่ยนจริง

ตั้ง cron ให้ backup เองทุกวันตี 3 (ตั้งไว้แล้วบน VPS):
```cron
0 3 * * * /docker/ferment-agent/repo/backup-workflows.sh --push >> /var/log/n8n-backup.log 2>&1
```

**ปลอดภัยไหม**: export ของ n8n เก็บ credential แค่ `id` กับ `name` ไม่มีค่า secret จริง จึงขึ้น git ได้ — แต่ **ห้ามรัน `n8n export:credentials --decrypted`** เด็ดขาด อันนั้นพ่นค่าจริงออกมาหมด

---

## 14. วิธีเริ่มใช้งานตั้งแต่ DB ว่างเปล่า (Quick Start)

หลัง DB ถูกเคลียร์ (`devices`/`batches`/telemetry/`phase_log` ว่างหมด) ลำดับที่ต้องทำ:

1. **รัน "Sync Devices"** (n8n → workflow นี้ → Execute workflow) — ดึงรายชื่อ Pill/Temperature Controller จาก RAPT เข้า `devices` table เป็นครั้งแรกหลังเคลียร์ ต้องทำก่อนเสมอ เพราะขั้นต่อไปอ้างอิง device ที่มีอยู่ใน DB
2. **เช็คว่า Pill จับคู่ (pair) กับ Controller ไว้แล้วในแอป/เว็บ RAPT เอง** — ระบบเราดึง pairing นี้มาใช้อัตโนมัติ (`devices.raw_data->>'pairedDeviceId'`) ไม่ต้องระบุ controller เองตอนสั่ง start ถ้ายังไม่ได้ pair ต้องไปตั้งใน RAPT ก่อน แล้วรัน Sync Devices ใหม่อีกรอบให้ดึง pairing ล่าสุดมา
3. **ลงทะเบียน batch ผ่าน Discord**: พิมพ์ `/ferment_start` เลือก `pill` (เช่น `Pill01`), `beer` (ชื่อเบียร์, บังคับใส่), `date` (วันเวลาเริ่มหมักจริง เช่น `12/8/2026 00:00`, บังคับใส่ — ถ้าหมักไปแล้วก่อนหน้าให้ใส่วันจริงย้อนหลังได้เลย ไม่ต้องรอ) — Controller จะ resolve ให้อัตโนมัติจากข้อ 2 บอทจะตอบยืนยันกลับพร้อมชื่อ Controller ที่ resolve ได้
4. **"Phase Analysis Cron" รันอัตโนมัติทุก 30 นาทีอยู่แล้ว** (publish/active แล้ว — เพิ่งแก้ 15 ส.ค. ก่อนหน้านี้ไม่เคย publish จริง) ไม่ต้องทำอะไรเพิ่ม รอบแรกอาจจำแนกเป็น `lag` หรือ apparent attenuation ไม่แม่นยำนักถ้าเพิ่งเริ่มเก็บ telemetry (ดูหมายเหตุ OG proxy ในข้อ 8.3) จะแม่นขึ้นเมื่อมีข้อมูลสะสมข้าม cycle
5. **เช็คสถานะได้ทุกเมื่อ**: พิมพ์ `/ferment_status pill:Pill01` (ใส่ชื่อ Pill ไม่ใช่ชื่อเบียร์) จะได้ผลวิเคราะห์ล่าสุดจาก cron รอบที่ผ่านมา (เฟส, gravity, อุณหภูมิ, เหตุผลจาก AI) โดยไม่ต้องรอ alert
6. **หยุด batch เมื่อหมักเสร็จ**: พิมพ์ `/ferment_stop pill:Pill01`

> `!ferment start/stop` แบบ text (ข้อ 8.2) **เลิกใช้แล้ว** ให้ใช้ `/ferment_start`/`/ferment_stop`/`/ferment_status` เท่านั้น
