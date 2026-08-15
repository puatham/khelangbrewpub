# Ferment Agent — RAPT + Discord + n8n Project Knowledge

สรุปทุกอย่างที่ออกแบบ/ทำไปแล้วสำหรับโปรเจกต์ใหม่: ระบบดึงข้อมูลจาก RAPT API (Pill + Temperature Controller) มาวิเคราะห์เฟสการหมักเบียร์ด้วย AI แล้วแจ้งเตือน/รับคำสั่งผ่าน Discord ใช้เป็น context สำหรับ chat ใหม่ได้เลย

---

## 1. เป้าหมายของโปรเจกต์

สร้างระบบที่:
1. รับคำสั่งจาก Discord ว่ากำลังหมัก batch ไหน ใช้ Pill ตัวไหน จับคู่กับ Temperature Controller ตัวไหน
2. AI agent อ่านค่า gravity/temperature จาก Pill มาวิเคราะห์ว่าตอนนี้การหมักอยู่ช่วงไหน (lag, active ferment/hi krausen, slowing, ยีสต์กินเสร็จ, diacetyl rest, cold crash — 6 ช่วง เป็นมาตรฐานตายตัว ไม่มีช่วงไหน optional)
3. แจ้งเตือนใน Discord เมื่อเฟสเปลี่ยน พร้อมข้อเสนอ next action
4. รับคำสั่งกลับจาก Discord เพื่อสั่งปรับอุณหภูมิ Temperature Controller จริงผ่าน RAPT API
5. **เป็นโปรเจกต์แยกอิสระ ไม่พึ่งพา InfluxDB/Grafana stack เดิม (`rapt-stack`)** — ดึงข้อมูลจาก RAPT API ตรง เก็บเองใน Postgres ทั้งหมด

โปรเจกต์เดิม (`rapt-stack` ที่ root) ยังคงอยู่แยกต่างหาก ใช้สำหรับ dashboard/CSV export ไม่เกี่ยวกับโปรเจกต์นี้

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

**สถานะปัจจุบัน**: ย้ายไปใช้ **bind mount** แทน named volume แล้ว เพื่อให้ข้อมูลทั้งหมดอยู่ในโฟลเดอร์เดียว `/docker/ferment-agent/data/{n8n,postgres,traefik}/` ง่ายต่อการ backup (`tar czf backup.tar.gz /docker/ferment-agent`)

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

**n8n env var เพิ่มเติม** (สำหรับเรียก RAPT API): `RAPT_USERNAME`, `RAPT_API_SECRET` — ต้องเปิด `N8N_BLOCK_ENV_ACCESS_IN_NODE=false` ด้วย ไม่งั้น `{{$env.X}}` จะ error "access to env vars denied"

> ⚠️ **แก้จากที่เคยเข้าใจผิด**: เอกสารเวอร์ชันก่อนแนะนำว่าถ้า `$env` ใช้ไม่ได้ให้เปลี่ยนไปใช้ n8n **Variables** (`{{$vars.X}}`) แทน — **ใช้ไม่ได้** เพราะ Custom Variables เป็นฟีเจอร์ของแผนแบบเสียเงิน Community Edition ไม่มี บน CE จึงเหลือทางเดียวคือ `$env` + `N8N_BLOCK_ENV_ACCESS_IN_NODE=false` (ตั้งไว้ใน `docker-compose.yml` แล้ว)

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

## 5. Database Schema (Postgres) — สร้างครบแล้วบน VPS

> ⚠️ **แก้จากที่เคยเข้าใจผิด** (15 ส.ค.): เอกสารเวอร์ชันก่อนบอกว่าสร้างครบ 7 ตารางแล้ว แต่เช็คของจริงบน VPS พบว่ามีแค่ 6 ตาราง — **`bot_state` ไม่เคยถูกสร้างจริง** (น่าจะตกหล่นตอน migrate หรือ session ก่อนไม่ได้รันจริง) สร้างให้แล้ววันนี้ด้วย DDL เดียวกับด้านล่าง
>
> พบเพิ่มอีกจุดตอนทดสอบ `Create Batch` node จริง — error `column "beer_name" of relation "batches" does not exist` เช็คด้วย `\d batches` พบว่าตารางจริงมีแค่ 8 คอลัมน์ ขาด `beer_name` ไปเฉยๆ เพิ่มด้วย `ALTER TABLE batches ADD COLUMN beer_name TEXT;` แล้ว
>
> เช็คตารางที่เหลือทั้งหมด (`devices`, `pill_readings`, `temp_controller_readings`, `phase_log`, `control_log`) เทียบกับ `schema.sql` ทีละคอลัมน์แล้ว **ตรงกันหมด ไม่มีจุดอื่นขาด** — ตอนนี้ database จริงตรงกับ `schema.sql` 100%

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
-- INSERT INTO bot_state (key, value) VALUES ('last_discord_message_id', '0');
```

ดู ER diagram เต็มที่ `er-diagram.mermaid` ในโฟลเดอร์เดียวกัน

**เหตุผลการออกแบบ**: `devices` เป็นตาราง lookup กลาง (ทุกตารางอ้าง `device_id` ไม่ใช้ text name ซ้ำๆ กันความเสี่ยงชื่อไม่ตรงจาก trailing-space bug) เก็บ `raw_data JSONB` ไว้ด้วยเผื่ออนาคตอยากได้ field ที่ตอนนี้ยังไม่ได้ใช้ (เช่น `connectionState`, `firmwareVersion`, `pidProportional`) — RAPT API response ของ Hydrometer/TemperatureController มี field เยอะมาก มีตัวอย่างจริงที่ดึงมาแล้วเก็บใน `raw_data` ของ Pill01/Pill02/Fridge/Fridge2

`pill_readings`/`temp_controller_readings` แยกจาก `phase_log`: อันแรกเก็บ raw telemetry ทุกจุด อันหลังเก็บแค่ผลสรุปตอน AI วิเคราะห์แต่ละรอบ (เบากว่ามาก)

---

## 6. Discord Bot — setup เสร็จแล้ว

- Application name: **นักหมัก**
- มี Bot Token, Application/Client ID, Server ID, Channel ID ครบแล้ว (เก็บไว้ที่ n8n credential + Variables)
- เปิด **Message Content Intent** แล้ว (จำเป็นเพราะใช้วิธี poll ข้อความ ไม่ใช่ slash command)
- Invite เข้า server ด้วย scope `bot` + `applications.commands`, permission: Send Messages, Read Message History, View Channels, Embed Links, Use Slash Commands

รูปแบบคำสั่งที่ออกแบบไว้ (พิมพ์เป็นข้อความธรรมดาในช่องที่กำหนด):
```
!ferment start pill=Pill01 controller=Fridge2 beer="Hazy IPA"
!ferment stop pill=Pill01
```
รองรับค่าที่มีเว้นวรรคด้วย `"..."` (parser ใช้ regex `/(\w+)=(?:"([^"]*)"|(\S+))/g`)

---

## 7. n8n Credentials — ตั้งครบแล้ว

1. **Postgres**: host `postgresql` (ชื่อ service ใน docker-compose), db `rapt`, user `root`
2. **Discord Bot API**: bot token ของ "นักหมัก"
3. **RAPT**: ไม่มี credential type สำเร็จรูป ใช้ env var/Variables แทน (`RAPT_USERNAME`, `RAPT_API_SECRET`)
4. **Claude/GPT**: Anthropic หรือ OpenAI credential (ใส่ API key ตรง)

---

## 7.5 วิธีสร้าง/ต่อ workflow ใน n8n (ทั่วไป — ใช้ได้กับทุก workflow ด้านล่าง)

**สร้าง workflow ใหม่**
กดปุ่ม **+ Add workflow** (มุมขวาบนของหน้า Overview) → เปิด canvas เปล่าพร้อม node "When clicking 'Execute workflow'" (Manual Trigger) ให้อัตโนมัติ → เปลี่ยนชื่อ workflow มุมซ้ายบน

**เพิ่ม node ใหม่**
กดเครื่องหมาย **+** ที่ขอบขวาของ node ล่าสุด (หรือกด + กลาง canvas) → พิมพ์ค้นหาชื่อ node (เช่น `HTTP Request`, `Code`, `Postgres`, `IF`, `Discord`, `Schedule Trigger`) → คลิกเลือก

**ตั้งชื่อ node**
ดับเบิลคลิกชื่อ node ด้านบนกล่อง พิมพ์ชื่อใหม่ (ช่วยให้ expression อ้างอิง node อื่นด้วยชื่อได้ง่าย เช่น `$('Get Last Message Id')`)

**ใส่ค่าแบบ expression (อ้างอิงข้อมูลจาก node ก่อนหน้า)**
พิมพ์ `{{ ... }}` ในช่องได้เลยตรงๆ เช่น `{{$json.access_token}}` — **ถ้าเป็นข้อความผสม (static text + expression ปนกัน) และ n8n auto-switch เป็น expression mode ให้แล้ว ห้ามใส่ `=` นำหน้าซ้ำ** (จะกลายเป็น literal text ทำให้ค่าไม่ resolve เช่นตอน header Authorization พังเพราะใส่ `=Bearer {{...}}` ซ้อน `=` ที่ n8n ใส่ให้อยู่แล้ว) ถ้าไม่มั่นใจให้ดู preview เล็กๆ ใต้ช่อง input ว่า resolve ค่าถูกไหมก่อน

**ต่อ node เข้าด้วยกัน**
ลาก dot วงกลมด้านขวาของ node ต้นทาง ไปปล่อยที่ dot ซ้ายของ node ปลายทาง (หรือกด + ต่อจาก node เดิมจะลากเส้นให้อัตโนมัติ) ต่อได้หลายเส้นจาก node เดียวกัน (เช่น sync devices แตก 2 กิ่งจาก `Get RAPT Token`)

**ทดสอบทีละ node**
คลิก node แล้วกด **Execute step** (ปุ่มใต้พาเนลตั้งค่าด้านขวา) ดู output ว่าถูกไหมก่อนต่อ node ถัดไป ถ้า error จะขึ้นกรอบแดงพร้อมข้อความ error ให้ debug ทีละจุด

**ทดสอบทั้ง workflow**
กด **Save** (มุมขวาบน) แล้วกด **Execute Workflow** รันทั้งเส้น

**เปิดใช้งานจริง (ให้ trigger อัตโนมัติทำงานเองแม้ปิดหน้าจอ)**
กด toggle **Active** มุมขวาบน (ข้าง Save) — สำคัญมาก ถ้าลืมเปิด workflow จะรันแค่ตอนกด Execute เองเท่านั้น ไม่ทำงานตาม Schedule Trigger จริง

**Env var access ใน expression**
ถ้าใช้ `{{$env.X}}` แล้วเจอ error "access to env vars denied" ให้เปิด `N8N_BLOCK_ENV_ACCESS_IN_NODE=false` ใน `docker-compose.yml` แล้ว `docker compose up -d` ใหม่ — วิธีนี้ใช้กับทุก workflow ที่ต้องเรียก RAPT credential (**อย่าไปหา Settings → Variables** เป็นฟีเจอร์แบบเสียเงิน Community Edition ไม่มีให้ใช้)

---

## 8. n8n Workflows

### 8.1 "Sync Devices" — ✅ สร้างเสร็จ + ทดสอบผ่านแล้ว

Node structure: `Manual Trigger → Get RAPT Token (HTTP POST token endpoint)` แตก 2 กิ่ง:
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
- ลืมเปลี่ยน `device_type` ใน Code node กิ่ง Temp Controller (ยังเป็น `'pill'`) — แก้แล้ว
- Query ON CONFLICT ตอนแรกไม่ได้ update `device_type` — เพิ่มเข้าไปแล้ว
- Header `Authorization` ใน HTTP Request node **ห้ามมี `=` นำหน้า** ถ้า field เป็น expression mode อยู่แล้ว (ใส่ซ้อนจะกลายเป็น literal text ทำให้ 401) — เจอและแก้แล้ว

**⚠️ ไฟล์ export ที่ได้มาขาด node `Save Pills` — แต่ตัวจริงไม่ได้ขาด** (15 ส.ค.)

`workflows/Sync Devices.json` ที่ export ออกมามีแค่ 7 node กิ่ง Pill จบที่ `Format Pills` แล้วตัน ไม่ต่อไป Postgres แต่พอไปเช็คฐานข้อมูลจริงบน VPS:

```
 device_name |   device_type
-------------+-----------------
 Pill01      | pill
 Pill02      | pill
 Fridge      | temp_controller
 Fridge2     | temp_controller
(4 rows)
```

ได้ครบ 4 แถว = **workflow ตัวจริงบน n8n มี `Save Pills` อยู่แล้ว ทำงานถูกต้อง** ปัญหาอยู่ที่ไฟล์ export ไม่สมบูรณ์เท่านั้น (น่าจะ export ตอนยังต่อ node ไม่เสร็จ)

ไฟล์ใน repo ถูกเติม node `Save Pills` ให้ครบ 8 node แล้ว (Postgres, query + credential ชุดเดียวกับ `Save Temp Controllers` เพราะ `device_type` ถูกกำหนดมาตั้งแต่ Code node) — แต่เป็นการ**สร้างขึ้นใหม่ให้เดาตรงกับของจริง ไม่ใช่ของจริง** ถ้าจะให้ไฟล์ตรงกับ n8n เป๊ะๆ ควร export ใหม่ด้วย `backup-workflows.sh`

**อย่า import ไฟล์นี้ทับตัวจริง** โดยไม่จำเป็น — ตัวจริงทำงานอยู่แล้ว การ import ทับมีแต่ความเสี่ยงว่าจะเขียนทับสิ่งที่แก้ไว้แล้วแต่ไม่ได้อยู่ในไฟล์

### 8.2 "Discord Command Intake" — 🔧 ออกแบบไว้แล้ว กำลังสร้าง (ยังไม่ทดสอบจบ)

ต้องมีตาราง `bot_state` เก็บ `last_discord_message_id` (สร้างแล้ว)

**⚠️ บั๊กที่เจอตอน import (15 ส.ค.) และแก้แล้ว**: node `Get New Messages` / `Send Confirmation` ตั้ง `authentication: predefinedCredentialType` + `nodeCredentialType: discordApi` ไว้ แต่พอ import เข้า n8n จริง ช่อง "Credential Type" ขึ้นเป็น `discordApi` ตัวพิมพ์เล็กดิบๆ (ไม่ใช่ชื่อสวยแบบ "Postgres" ที่ n8n ปกติแสดง) และไม่มีช่องให้เลือก credential โผล่มาเลย → error "Credentials not found"

**ชื่อ credential type ที่ถูกต้องจริงๆ คือ `discordBotApi`** (ไม่ใช่ `discordApi` ที่ผมเดาผิดตอนแรก) — ยืนยันแล้วว่าใช้ได้จริง หลังเปลี่ยนไปใช้ `nodeCredentialType: discordBotApi` ช่องเลือก credential โผล่มาปกติ เลือก "Discord Bot account" ที่มีอยู่แล้วได้เลย ไม่ต้องสร้าง Header Auth เพิ่ม (ทางเลือก Header Auth ที่แนะนำไว้ก่อนหน้ายังใช้ได้เป็น fallback ถ้าไปเจอ n8n instance อื่นที่ไม่มี `discordBotApi` เป็นตัวเลือก) ไฟล์ `Discord Command Intake.json` ใน repo แก้เป็น `discordBotApi` แล้ว

**แก้โดยเปลี่ยนไปใช้ Generic Credential Type → Header Auth แทน** (เรียก Discord REST API ตรงๆ ด้วย header `Authorization: Bot <TOKEN>` ซึ่งใช้ได้แน่นอนไม่ต้องพึ่ง credential type เฉพาะของ Discord):

1. สร้าง credential ใหม่: Credentials → Add Credential → **Header Auth** → Name: `Authorization`, Value: `Bot <BOT_TOKEN>` (มีเว้นวรรคหลัง `Bot`) → ตั้งชื่อ credential เช่น `Discord Bot Header`
2. ใน node `Get New Messages` และ `Send Confirmation`: Authentication → **Generic Credential Type** → Generic Auth Type → **Header Auth** → เลือก credential ที่สร้างไว้

**⚠️ บั๊กที่ 2 เจอตอนทดสอบจริง (15 ส.ค.) และแก้แล้ว**: node `Parse Commands` error `messages is not iterable [line 6]` — โค้ดเดิมเขียน `const messages = $input.first().json;` โดยสมมติว่า `Get New Messages` ส่งมาเป็น **1 item ที่ข้างในเป็น array ข้อความทั้งหมด** (แบบเดียวกับที่ RAPT HTTP call ทำใน workflow Sync Devices) แต่ของจริง n8n เวอร์ชันนี้ (2.34.6 self-hosted) **แยก array ที่ Discord ส่งกลับมาเป็นคนละ item ให้อัตโนมัติ** (1 ข้อความ Discord = 1 item ไม่ใช่ 1 item ที่มี array ข้างใน) — ยืนยันจาก input panel ตอน debug เห็น field `content`/`id`/`channel_id` อยู่ตรงๆ ไม่ได้ห่อด้วย array

แก้โดยเปลี่ยนไปวนลูปทีละ **item** ด้วย `$input.all()` แทนที่จะพยายามวนลูปทีละ element ใน array ที่ `$input.first().json`:
```javascript
const items = $input.all();
const results = [];
let maxId = $('Get Last Message Id').first().json.value;
const paramRegex = /(\w+)=(?:"([^"]*)"|(\S+))/g;

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
    results.push({ json: { action, ...params, message_id: m.id } });
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

ไฟล์ `Discord Command Intake.json` ใน repo แก้ตามนี้แล้ว

ไฟล์ `Discord Command Intake.json` ใน repo แก้ตามนี้แล้ว (`authentication: genericCredentialType`, `genericAuthType: httpHeaderAuth`) — ถ้า import ใหม่จะไม่เจอปัญหานี้อีก แต่ credential ยังต้องเลือกเองหลัง import เสมอ (ผมไม่มีทางรู้ credential id ล่วงหน้า)

Node structure:
1. **Schedule Trigger** — ทุก 1 นาที
2. **Postgres "Get Last Message Id"** — `SELECT value FROM bot_state WHERE key = 'last_discord_message_id'`
3. **HTTP Request "Get New Messages"** — GET `https://discord.com/api/v10/channels/<CHANNEL_ID>/messages` — Authentication: Predefined Credential Type → Discord API — query param `after={{$json.value}}&limit=50`
4. **Code "Parse Commands"**:
```javascript
const messages = $input.first().json;
const results = [];
let maxId = $('Get Last Message Id').first().json.value;
const paramRegex = /(\w+)=(?:"([^"]*)"|(\S+))/g;

for (const m of messages) {
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
    results.push({ json: { action, ...params, message_id: m.id } });
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
5. **IF** — แยกตาม `action` (`start` / `stop` / อื่นๆ ปล่อยผ่าน)
6a. **Postgres "Create Batch"** (เส้น start):
```sql
INSERT INTO batches (pill_device_id, temp_controller_device_id, start_date, beer_name, status)
SELECT
  (SELECT device_id FROM devices WHERE trim(device_name) = trim($1) AND device_type = 'pill' LIMIT 1),
  (SELECT device_id FROM devices WHERE trim(device_name) = trim($2) AND device_type = 'temp_controller' LIMIT 1),
  now(),
  $3,
  'active'
RETURNING batch_id;
```
Params: `{{$json.pill}}, {{$json.controller}}, {{$json.beer || null}}`

6b. **Postgres "Stop Batch"** (เส้น stop):
```sql
UPDATE batches SET status = 'done'
WHERE pill_device_id = (SELECT device_id FROM devices WHERE trim(device_name) = trim($1) AND device_type = 'pill' LIMIT 1)
AND status = 'active';
```
Params: `{{$json.pill}}`

7. **Discord "Send Confirmation"** — Send Message กลับ channel เดิม
8. **Postgres "Update Last Message Id"** — `UPDATE bot_state SET value = $1 WHERE key = 'last_discord_message_id'` (ต่อท้ายทุกเส้นรวม `none`)

### 8.3 "Cron วิเคราะห์เฟส" — ❌ ยังไม่ได้สร้าง (task #32)

แผนคร่าวๆ: cron ทุก 30-60 นาที → หา batch ที่ `status='active'` → ดึง `GetTelemetry` ของ pill+controller → insert เข้า `pill_readings`/`temp_controller_readings` → ส่ง prompt ให้ AI จำแนกเฟส (ใช้กรอบ 6 เฟสด้านบน) → insert `phase_log` → เทียบกับ `batches.current_phase` เดิม ถ้าเปลี่ยนค่อยส่ง Discord alert + update `batches.current_phase`/`last_alert_at`

### 8.4 "รับคำสั่งปรับอุณหภูมิ" — ❌ ยังไม่ได้สร้าง (task #33)

แผนคร่าวๆ: ต่อยอดจาก workflow 8.2 เพิ่มคำสั่งแบบ `!ferment settemp pill=Pill01 target=20.5` → เรียก `SetTargetTemperature` → insert `control_log` → ยืนยันกลับ Discord

---

## 9. กรอบ 6 เฟสการหมัก (ใช้เป็น prompt ให้ AI จำแนก)

1. **Lag phase** — 6-24 ชม.แรก ยีสต์ปรับตัว gravity แทบไม่ขยับ
2. **Active ferment / hi krausen** — วันที่ 1-3 อัตราลด gravity สูงสุด
3. **Slowing down** — อัตราลดค่อยๆ ผ่อน
4. **ยีสต์กินเสร็จ / FG นิ่ง** — gravity คงที่ต่อเนื่อง 1-2 วัน
5. **Diacetyl rest** — ยกอุณหภูมิ +2 ถึง +4°C ค้าง 2-3 วัน (**บังคับทุก batch ไม่ใช่ optional**)
6. **Cold crash** — ลดอุณหภูมิใกล้ 0-4°C 1-3 วัน

ตัวอย่างการวิเคราะห์จริงที่เคยทำ (ใช้เป็น reference ว่า logic ควรตัดสินใจยังไง): Pill02 (batch เริ่ม 10 ส.ค.) อยู่ step 4 หลัง gravity นิ่ง >24 ชม. (velocity ใกล้ 0), Pill01 (batch เริ่ม 12 ส.ค.) กำลังผ่านพ้น step 2 เข้า step 3 (velocity ลดจาก -0.047 เหลือ -0.005 SG/day)

---

## 10. Task list สถานะล่าสุด (อ้างอิงเลข task ใน session เดิม)

- #27 สร้างตาราง Postgres — ✅ เสร็จ (7 ตารางครบ — `bot_state` เพิ่งสร้างจริง 15 ส.ค. ของเดิมมีแค่ 6 ตาราง ดูข้อ 5)
- #28 ตั้งค่า Discord bot — ✅ เสร็จ
- #29 ใส่ credential ใน n8n — ✅ เสร็จ
- #30 workflow sync devices — ✅ เสร็จ ทดสอบผ่าน
- #31 workflow Discord command intake — 🔧 กำลังทำ (ออกแบบ node ครบแล้ว รอต่อ/ทดสอบจริงใน n8n)
- #32 workflow cron วิเคราะห์เฟส — ❌ ยังไม่เริ่ม
- #33 workflow รับคำสั่งปรับอุณหภูมิ — ❌ ยังไม่เริ่ม
- #34 ทดสอบระบบจริงกับ Pill01/Pill02 — ❌ รอ workflow อื่นเสร็จก่อน

---

## 11. Batch ที่กำลัง track อยู่จริง (ข้อมูล ณ 14 ส.ค. 2026)

- **Pill01** (จับคู่ Fridge2): เริ่ม 12 ส.ค. — ล่าสุดกำลังชะลอจาก hi krausen เข้า step 3
- **Pill02** (จับคู่ Fridge): เริ่ม 10 ส.ค. — ล่าสุดใกล้ step 4 (FG นิ่ง) แนะนำให้ยกอุณหภูมิเป็น 20-21°C ทำ diacetyl rest

---

## 12. ไฟล์ในโปรเจกต์ (repo `khelangbrewpub`)

โปรเจกต์ย้ายเข้า git แล้ว: `github.com/puatham/khelangbrewpub` (private)
ของเดิมที่ `rapt-stack/ferment-agent-vps/` ถือเป็นสำเนาเก่า ให้ยึดไฟล์ใน repo เป็นหลัก

- `docker-compose.yml` — compose file ที่ deploy จริงบน VPS (traefik + n8n + postgres, bind mount ที่ `./data/`)
- `.env` — ค่า config จริง **อยู่ใน `.gitignore` ไม่ขึ้น git**
- `.env.example` — โครงเปล่าไว้ให้ก๊อปไปทำ `.env`
- `schema.sql` — DDL 7 ตารางครบ รันได้เลย (มี index ของ readings + seed `bot_state`)
- `er-diagram.mermaid` — ER diagram schema เต็ม
- `backup-workflows.sh` — export workflow จาก n8n ลง `workflows/` แล้ว commit ให้ (ดูข้อ 13)
- `workflows/` — n8n workflow ที่ export ไว้ เป็นตัว backup
- `PROJECT_KNOWLEDGE.md` — ไฟล์นี้

---

## 13. Backup workflow ขึ้น git

n8n มีฟีเจอร์ **Source Control** ที่ sync กับ Git repo ได้ในตัว (push/pull workflow + stub ของ credential) แต่**อยู่ในแผน Business ขึ้นไป** Community Edition ที่ใช้อยู่ไม่มีให้ ทางเลือกที่ใช้ได้จริงคือ export ผ่าน n8n CLI ซึ่งมีทุก edition

รันบน VPS (เครื่องที่มี container อยู่ ต้อง clone repo นี้ไว้ด้วย):

```bash
./backup-workflows.sh          # export + commit
./backup-workflows.sh --push   # export + commit + push
./backup-workflows.sh --dry-run # export มาดูเฉยๆ
```

สคริปต์ export ลง `/tmp` ใน container ก่อน ถ้าสำเร็จค่อยเขียนทับ `workflows/` เพื่อไม่ให้ export พังแล้วไฟล์ backup เดิมหายไปด้วย และ commit เฉพาะตอนมีอะไรเปลี่ยนจริง

ตั้ง cron ให้ backup เองทุกวัน:

```cron
0 3 * * * /docker/ferment-agent/backup-workflows.sh --push >> /var/log/n8n-backup.log 2>&1
```

**ปลอดภัยไหม**: export ของ n8n เก็บ credential แค่ `id` กับ `name` ไม่มีค่า secret จริง จึงขึ้น git ได้ — แต่ **ห้ามรัน `n8n export:credentials --decrypted`** เด็ดขาด อันนั้นพ่นค่าจริงออกมาหมด
