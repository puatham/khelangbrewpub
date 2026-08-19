# Ferment Agent — RAPT + Discord + n8n

ระบบดึงข้อมูลจาก RAPT API (Pill + Temperature Controller) มาวิเคราะห์เฟสการหมักเบียร์ด้วย AI แล้วแจ้งเตือน/รับคำสั่งผ่าน Discord

---

## 1. เป้าหมายของโปรเจกต์

สร้างระบบที่:
1. รับคำสั่งจาก Discord ว่ากำลังหมัก batch ไหน ใช้ Pill ตัวไหน จับคู่กับ Temperature Controller ตัวไหน
2. AI agent อ่านค่า gravity/temperature จาก Pill มาวิเคราะห์ว่าตอนนี้การหมักอยู่ช่วงไหน (lag, active ferment/hi krausen, slowing_ferment, ยีสต์กินเสร็จ, diacetyl rest, cold crash — 6 ช่วง เป็นมาตรฐานตายตัว ไม่มีช่วงไหน optional)
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

**Brewfather recipes/yeasts cache (เพิ่ม 18 ส.ค.)**: เพิ่ม 2 กิ่งขนานจาก trigger เดิม — `Build Brewfather Auth`(Code, สร้าง `Authorization: Basic <base64(userid:apikey)>` เอง เพราะ Brewfather ไม่มี native credential type และ HTTP node expression ไม่มี `Buffer` ให้ใช้ ต้องคำนวณใน Code node) → แตก 2 สาย:
- `Get Recipes`(GET `/v2/recipes?limit=50&complete=true`) → `Format Recipes` → `Save Recipes`(upsert ตาราง `recipes`)
- `Get Yeasts`(GET `/v2/inventory/yeasts?limit=50&complete=true`) → `Format Yeasts` → `Save Yeasts`(upsert ตาราง `yeasts`)

Auth: Basic (`userid:apikey` base64) จาก Brewfather app → Settings → API → GENERATE (เลือก scope `recipes.read` + `inventory.read`) เก็บเป็น `BREWFATHER_USER_ID`/`BREWFATHER_API_KEY` ใน `.env`

**ทดสอบกับ API จริงแล้ว** (curl ตรงๆ ก่อน deploy): 14 recipes, 3 yeasts ดึงมาครบ ยืนยัน field ที่ใช้ถูกต้อง (`og`, `fg`, `style.name`, `yeasts[0].{name,minTemp,maxTemp,attenuation,minAttenuation,maxAttenuation}`, `fermentation.steps[0].stepTemp`) limit เดียว (50) พอสำหรับ account นี้ ยังไม่ทำ pagination (`start_after`) เพราะไม่จำเป็น

**บั๊กที่เจอและแก้ก่อน deploy**: Brewfather บางฟิลด์ที่เป็น optional (เช่น `bestFor`, `productId`, `minAttenuation`) ไม่มีอยู่ใน object เลยแทนที่จะเป็น `null` ตรงๆ — ถ้าปล่อย `undefined` เข้า `queryReplacement` ตรงๆ n8n จะ stringify เป็น literal text `"undefined"` (ไม่ใช่ `"null"`) ทำให้ guard `NULLIF($n,'null')` ที่ใช้กันปัญหา null-stringification เดิมจับไม่ได้ แล้ว cast เป็น `numeric` พัง — แก้ด้วยฟังก์ชัน `n(v)` เล็กๆ ใน Code node ที่ coalesce `undefined` → `null` ให้ชัดเจนก่อนส่งเข้า SQL เสมอ; และพบว่าคอลัมน์ TEXT ที่ nullable (`product_id`, `best_for`, `laboratory`, `flocculation`, `style_name`, `yeast_name`) ก็ต้องครอบด้วย `NULLIF($n,'null')` เหมือนกัน (ไม่ใช่แค่คอลัมน์ numeric) ไม่งั้น insert literal string `"null"` แทนที่จะเป็น NULL จริง — ทดสอบ insert ข้อมูลจริงทั้ง 14 recipes + 3 yeasts ผ่าน transaction แบบ rollback บน VPS แล้วผ่านหมด ก่อน commit โค้ด

### 8.2 "Discord Command Intake" — 🔴 **เลิกใช้แล้ว (unpublish 15 ส.ค., เอาไฟล์ออกจาก repo 18 ส.ค.)** ถูกแทนที่ด้วย 8.5

คำสั่ง `!ferment start ...` / `!ferment stop ...` แบบ text ไม่ใช้แล้ว ให้ใช้ `/ferment_start` `/ferment_stop` `/ferment_status` (slash command, ข้อ 8.5) แทนทั้งหมด — workflow ตัวจริงบน n8n ยัง unpublish ค้างไว้เฉยๆ (ไม่มี CLI ลบ workflow ได้ ต้องลบผ่าน UI เอง ถ้าต้องการ) แต่ **เอาไฟล์ `workflows/Discord Command Intake.json` ออกจาก repo แล้ว** (18 ส.ค., decluttering) ไม่ track/backup ต่อ — เนื้อหาด้านล่างเก็บไว้เป็นบันทึกประวัติเฉยๆ ดูโค้ดจริงได้จาก git history ก่อน commit ที่ลบไฟล์นี้ออก

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

24 nodes (โครงสร้างหลัง task #59 — เดิมแยก 3 สายขนานจาก `Get Latest Readings` เปลี่ยนเป็นสายเดียวเรียงลำดับ): `Schedule Trigger` (cron `0 8,12,16,20 * * *` — วันละ 4 รอบ 08:00/12:00/16:00/20:00 เวลาไทย, ปรับจากทุก 30 นาทีเดิม 17 ส.ค. เพื่อลดความถี่การแจ้งเตือน) → `Get RAPT Token` → `Get Active Batches` (Postgres, เฉพาะ `status='active'`) → `Get Pill Telemetry`→`Format Pill Readings`→`Insert Pill Readings` → `Reload Batches` → `Get Controller Telemetry`→`Format Controller Readings`→`Insert Controller Readings` → `Reload Batches 2` → **`Get Latest Readings`** (อ่าน DB หลัง insert เสร็จแล้ว) → แยก 2 สาย: (1) `Add Analysis Time`→`Call Phase Analysis` (sub-workflow ข้อ 8.7) → แยก 4 สายขนาน: `Insert Phase Log`, `Phase Changed?`(IF, true→`Update Batch Phase`), `Approaching Transition?`(IF, true→`Update Prep Alert State`), `Split Message Into Sections`→`Send Routine Update` (2) `Check Sensor Freshness`→`Build Sensor Alert`→`Send Sensor Alert` (ข้อ 8.8)

**รวมข้อความ Discord เหลือทางเดียว (เพิ่ม 18 ส.ค.)**: เดิมมี 3 message แยก (`Send Discord Alert` ตอนเฟสเปลี่ยน, `Send Prep Alert` ตอนใกล้เปลี่ยนเฟส, `Send Routine Update` ทุกรอบ) เนื้อหาซ้ำกันเกือบหมดเพราะ `Send Routine Update` เดิมก็มี reasoning + 🔜 prep guidance ครบอยู่แล้ว — ตัด `Send Discord Alert`/`Send Prep Alert` ออก (โหนดที่มันเคยพ่วงไว้คือ `Update Batch Phase`/`Update Prep Alert State` ยังเก็บไว้เหมือนเดิม แค่ต่อตรงจาก IF โหนดแทน) เหลือ `Send Routine Update` ยิงข้อความเดียวต่อรอบ พร้อมเพิ่มตัวบอกเฟสเปลี่ยน (`🔔 (เปลี่ยนจาก X)`) ต่อท้ายชื่อเฟสแทนที่จะแยกข้อความ

**ไทม์ไลน์การหมัก (เพิ่ม 18 ส.ค.)**: `Build AI Prompt` ขอให้ AI ประมาณช่วงเวลาของแต่ละเฟสที่ผ่านมาแล้วจากกราฟทั้งเส้น (field ใหม่ `phase_timeline` — เอาแค่วันที่ไม่มีเวลา เรียงจาก `lag` ไล่ลงมา แยก `high_krausen` ออกจาก `active_ferment` เป็นคนละรายการ) `Parse AI Response` render เป็น `phase_timeline_text` (`• <phase>: <from> - <to> | <summary>`) แล้ว `Send Routine Update` แทรกเป็นส่วน `⏱️ ไทม์ไลน์การหมัก` ต่อจากหัวข้อสถานะ ก่อนถึง reasoning — ไม่ได้บันทึกลง DB (ส่งต่อผ่าน item flow อย่างเดียวเหมือน `next_phase`/`prep_actions_text`) เพิ่ม field เดียวกันใน `Discord Interactions Webhook`'s `Build Status Analysis Prompt`/`Parse Status Analysis`/`Build Status Message` ด้วยเพื่อให้ `/ferment_status` แสดงไทม์ไลน์เหมือนกัน

**แนะนำ target + ปุ่มยืนยันปรับอุณหภูมิจริง (เพิ่ม 18 ส.ค., task #38)**: เมื่อ batch ผูก recipe ไว้ (ข้อ 8.1) `Get Latest Readings` จะดึงแผนขั้นตอนอุณหภูมิหมัก (`fermentation_steps` จาก `recipes.raw_data`) + ช่วงอุณหภูมิของยีสต์ (`yeasts.min_temp_c`/`max_temp_c`) ส่งเข้า `Build AI Prompt` เป็น context เสริม พร้อมคำนวณ **"ส่วนต่างอุณหภูมิ Pill-ตู้ควบคุมช่วงที่นิ่งแล้ว"** (`stable_gap_c`) — เฉลี่ย `Pill_temp - Controller_temp` จากช่วง **หลังปรับ target ล่าสุด + 2 ชม. (กันช่วง transient) ถึงตอนนี้ แต่ไม่ย้อนเกิน 12 ชม.** (กันข้อมูลเก่าที่สภาพห้องอาจเปลี่ยนไปแล้ว)

หลักการสำคัญที่ย้ำไว้ใน prompt ชัดเจน: **แผนจาก Brewfather ใช้ตอบแค่ "ควรตั้ง target เท่าไหร่" เท่านั้น ห้ามใช้จำนวนวัน/ลำดับ step ตัดสินว่า "ถึงเวลาเปลี่ยนเฟสหรือยัง"** — การตัดสินเฟส/`approaching_transition` ยังต้องดูจากอุณหภูมิ Pill และกราฟ gravity จริงเหมือนเดิมทุกประการ เพราะการหมักจริงเสร็จเร็ว/ช้ากว่าแผนได้เสมอ (คนละบทบาทกับ gate ที่ Pill เป็นคนตัดสิน)

AI ตอบ field ใหม่ `recommended_pill_temp_c` (อุณหภูมิ **Pill** ที่อยากให้ถึง ไม่ใช่ target ตู้ควบคุม) เฉพาะตอน `approaching_transition=true` และ `next_phase` เป็น `diacetyl_rest`/`cold_crash` — อ้างอิง `stepTemp` ของ step ที่ตรงในแผน recipe ถ้ามี ไม่งั้น fallback เป็นเกณฑ์เดิม (baseline+2~+4°C / 0-4°C) `Parse AI Response` แปลงเป็น **target ตู้ควบคุมจริง**: `recommended_controller_target_c = recommended_pill_temp_c - stable_gap_c` (ปัดทศนิยม 1 ตำแหน่ง, เป็น `null` ถ้าไม่มีข้อมูล gap พอ) แล้ว `Send Routine Update` เปลี่ยนเป็น raw JSON body (แทน Body Parameters ตามบั๊กที่เจอมาก่อนใน 8.5) แนบ **ปุ่ม Discord message component** ต่อท้ายข้อความเมื่อมีค่าแนะนำ — `custom_id` เข้ารหัส `settemp|<batch_id>|<target>|<next_phase>`

กดปุ่มแล้ว `Discord Interactions Webhook` จะรับ interaction type 3 (MESSAGE_COMPONENT) สาขาใหม่: `Is Component?` → `Respond Deferred (Component)` (type 6 = DEFERRED_UPDATE_MESSAGE แก้ข้อความเดิมแทนที่จะส่งใหม่) → `Parse Component Interaction` (decode custom_id) → `Get Batch By Id` → `Is Batch Found (Component)?` → `Get RAPT Token (Component)` → `Call Set Target Temperature (Component)` (ยิง RAPT จริง) → `Log Control Action (Component)` (insert `control_log`, `remark` = next_phase ที่กดตอนนั้น) → `Build Component Confirm Message` → `Send Followup` (reuse node เดิม)

ทดสอบ SQL/logic ทั้งหมดด้วยข้อมูลจริงก่อน deploy: gap calc กับ batch Hazy DIPA จริง (ได้ 1.74°C จาก 3 จุด), prompt render กับ recipe/yeast/fermentation steps จริงครบ, custom_id encode/decode, `Get Batch By Id`/`Log Control Action` ผ่าน transaction rollback บน VPS, JSON payload ของปุ่ม (`components`) ตรง shape ที่ Discord ต้องการ

**แก้บั๊ก content เกิน 2000 ตัวอักษร (เพิ่ม 18 ส.ค.)**: หลัง deploy ครั้งแรกเจอ `Send Routine Update` ตอบ 400 "Invalid Form Body" จาก Discord จริง — เพราะ content เดิมต่อรวมทุกส่วน (สถานะ + ไทม์ไลน์ + reasoning + prep guidance + คำแนะนำ target) เป็นข้อความเดียว เกินลิมิต 2000 ตัวอักษรของ Discord message content ได้ง่ายเมื่อ batch หมักมานานและ timeline ยาวขึ้นเรื่อยๆ แก้โดยเพิ่ม node `Split Message Into Sections` (Code) แทรกก่อน `Send Routine Update` — หั่น content ตามขอบเขต section ที่มีความหมาย (สถานะ → ไทม์ไลน์ → reasoning → prep guidance → คำแนะนำ+ปุ่ม) แทนที่จะตัดตามจำนวนตัวอักษรดิบ ได้ 3-5 ข้อความต่อรอบขึ้นกับว่ามีไทม์ไลน์/ใกล้ transition/มีคำแนะนำ target หรือไม่ พร้อม fallback hard-split (1900 ตัวอักษร/ชิ้น) เผื่อ section เดียวยาวเกินลิมิตเอง — `is_last` ทำเครื่องหมายเฉพาะ item สุดท้ายให้ `Send Routine Update` แนบปุ่มยืนยันปรับ target ไว้ที่ข้อความสุดท้ายเท่านั้น ทดสอบด้วย Node harness จำลองข้อมูลจริงครบ 3 เคส (ไม่มี recipe/ไม่ใกล้ transition → 3 ข้อความ, ใกล้ transition แต่ยังไม่มี gap data → 4 ข้อความ, ครบทุกส่วน → 5 ข้อความ) ยืนยัน `is_last` ตกที่ item ท้ายสุดถูกต้องทุกเคส

**แก้บั๊ก `claude-sonnet-5` ใช้ thinking token หมด max_tokens ไม่เหลือให้ตอบ (เพิ่ม 18 ส.ค.)**: เจอจริงจาก execution log — `Call Claude` ตอบกลับมาแค่ content block เดียวเป็น `type: "thinking"` (ว่างเปล่า) `stop_reason: "max_tokens"`, `usage.output_tokens_details.thinking_tokens` เท่ากับ `max_tokens` (8192) พอดี ทำให้ `Parse AI Response` หา `text` block ไม่เจอ ได้ error `SyntaxError: "undefined" is not valid JSON` (เพราะ `JSON.parse(undefined)`) แล้ว fallback คงเฟสเดิมไว้ ไม่วิเคราะห์อะไรเลยรอบนั้น — สาเหตุคือ `claude-sonnet-5` เปิด extended thinking เป็นค่า default และ thinking tokens นับรวมใน `max_tokens` เดียวกับคำตอบ พอ prompt ใหญ่ขึ้น (พบ 35,256 input tokens ตอนที่เจอบั๊ก) โมเดลใช้ thinking กินโควตาจนไม่เหลือให้เขียน JSON คำตอบเลย แก้โดยเพิ่ม `"thinking": {"type": "disabled"}` เข้า request body (syntax ตาม [Anthropic docs](https://platform.claude.com/docs/en/build-with-claude/thinking#turning-thinking-off) สำหรับปิด thinking บน Sonnet 5 โดยเฉพาะ) ทั้ง `Call Claude` (node นี้) และ `Call Claude (Status)` ในข้อ 8.5 (`/ferment_status` ใช้ pattern เดียวกันเป๊ะ เสี่ยงบั๊กเดียวกัน) — งานนี้เป็น structured JSON output ที่ prompt ออกแบบให้มี reasoning สั้นๆ อยู่ในคำตอบเองอยู่แล้ว ไม่ได้พึ่ง extended thinking มาก ปิดไปตัดความเสี่ยงไปเลยดีกว่าแค่เพิ่ม `max_tokens` ซึ่งยังเสี่ยงซ้ำได้ถ้า prompt ยาวขึ้นอีกในอนาคต

**แก้บั๊กร้ายแรง: มีมากกว่า 1 batch active พร้อมกันแล้ววิเคราะห์แค่ตัวเดียว (เพิ่ม 18 ส.ค.)**: ผู้ใช้ start batch ที่ 2 (Hazy DIPA #2) แล้วสังเกตว่า routine update ยังมาแค่ batch เดียว — สาเหตุคือตอนแก้บั๊ก content เกิน 2000 ตัวอักษรก่อนหน้านี้ เขียน `Split Message Into Sections` ด้วย `$input.first().json` (อ่านแค่ item แรก) ทั้งที่ node import มา default โหมด **"Run Once for All Items"** และ node นี้รับ 1 item ต่อ 1 batch active (มาจาก `Get Active Batches` ไล่ผ่าน `Parse AI Response` มา) — พอมี batch ที่ 2 เข้ามา item ที่ 2 เป็นต้นไปถูกมองข้ามเงียบๆ ไม่มี error ให้เห็นเลย (**เจอ pattern เดียวกันนี้ตอนแก้บั๊ก `Phase Analysis Backtest` เมื่อครู่ด้วย — ดูข้อ 8.6 — เป็นสัญญาณว่าเป็นความผิดพลาดที่เกิดซ้ำได้ง่ายเวลาลืมว่า Code node default ประมวลผลทุก item รวมครั้งเดียว ไม่ใช่ทีละ item**) ตรวจสอบไฟล์ทั้งหมดในโปรเจกต์ (`Phase Analysis Cron`, `Discord Interactions Webhook`, `Sync Devices`, `Phase Analysis Backtest`) หา `$input.first()`/`$input.item` ทุกจุดอีกรอบ เจอ 6 จุด แต่อีก 5 จุดปลอดภัยเพราะ query ต้นทางออกแบบให้ได้ 1 row เสมอ (pattern `FROM (SELECT 1) AS anchor` หรือ `jsonb_agg` รวมเป็นแถวเดียว) มีแค่จุดนี้จุดเดียวที่เป็นบั๊กจริง แก้โดยห่อ logic เดิมทั้งหมดด้วย `items.forEach()` ไล่ทุก batch แยก `chunks`/`is_last` เป็นของใครของมัน ทดสอบด้วย Node harness จำลอง 2 batch พร้อมกัน (batch มี recommendation + ไม่มี) ยืนยันได้ครบ 7 ข้อความ (5+2) แยก `batch_id`/`is_last` ถูกต้องทั้งคู่

**แก้ข้อความมาไม่เรียงลำดับ + ปรับ format ตัวเลข/วันที่/ความกระชับ (เพิ่ม 18 ส.ค.)**: ทดสอบจริงพบข้อความ 3-5 ชิ้นจาก `Send Routine Update` มาถึง Discord ไม่เรียงตามลำดับที่ตั้งใจ — สาเหตุคือ HTTP Request node ของ n8n เมื่อได้ input หลาย item จะยิง request ออกพร้อมกัน (parallel, ไม่รอทีละอันตามลำดับ โดย default) พอ latency แต่ละ request ไม่เท่ากันจึงมาถึง Discord สลับกัน แก้โดยเปิด `options.batching` (`batchSize: 1, batchInterval: 500`) บังคับให้ยิงทีละข้อความตามลำดับ item เข้า พร้อมกันนี้ปรับ 3 อย่างตามที่ขอเพิ่ม: (1) ปัดเลข gravity เหลือ 3 ตำแหน่ง/อุณหภูมิเหลือ 2 ตำแหน่งใน `Parse AI Response` (helper `round()`) ก่อน insert `phase_log` และก่อนส่งต่อไปแสดงผล กันปัญหาเลขทศนิยมยาวจาก sensor (เช่น `17.3434753417969°C`) แล้วใช้ `toFixed()` ใน `Split Message Into Sections`/ปุ่มใน `Send Routine Update` ให้แสดงจำนวนหลักคงที่เสมอ (เช่น `20.00°C` ไม่ใช่ `20°C`) (2) เพิ่มคำสั่งใน prompt ของ `Build AI Prompt` ให้ AI เขียนวันที่เป็น `dd/mm/yyyy` เท่านั้น (ห้ามชื่อเดือนอังกฤษ/ISO) ทั้งใน `phase_timeline` และ reasoning/prep_actions พร้อมจำกัดความยาวแต่ละข้อ/summary ให้กระชับขึ้น (3) เพิ่ม `ใกล้ <next_phase>` ต่อท้ายชื่อเฟสในข้อความสถานะเมื่อ `approaching_transition=true` (เช่น `เฟส: fg_stable ใกล้ diacetyl_rest`) ทดสอบด้วย Node harness จำลองทั้ง pipeline (`Build AI Prompt` → `Parse AI Response` → `Split Message Into Sections`) ด้วยข้อมูลจริงจาก batch Hazy DIPA ยืนยัน output ตรงตาม mockup ที่ confirm ไว้ก่อนแก้ทุกจุด

**ประมาณเวลาที่จะถึง target แนะนำ (ETA, เพิ่ม 18 ส.ค., task #42)**: ต่อยอดจากปุ่มแนะนำ target (ย่อหน้าข้างบน) — นอกจากบอกว่าควรตั้ง target เท่าไหร่ ยังคำนวณ "อีกกี่ชั่วโมง/ประมาณวันเวลาไหน" ที่ Pill จะไปถึงอุณหภูมิเป้าหมายด้วย คำนวณด้วยเลขล้วนๆ ใน `Build AI Prompt`/`Parse AI Response` (ไม่ให้ AI ทายเวลา กันเพี้ยน): `Build AI Prompt` หา `pill_ramp_rate_c_per_hour` จาก slope 2 จุด (เก่าสุด-ล่าสุดในหน้าต่าง) ของ `pill_series` ช่วง 6 ชม.ล่าสุด (ต้องมีช่วงห่างกัน ≥1 ชม.ถึงจะคิด กันเคส 2 จุดห่างกันไม่กี่นาทีทำให้ extrapolate เพี้ยน) ส่งต่อพร้อม `analysis_time_iso` (เวลาอ้างอิงตอนวิเคราะห์ — แยกจาก `Date.now()` ตรงๆ เพื่อให้ backtest tool ในข้อ 8.6 ใช้ `cutoff` จำลองแทนได้โดยไม่ต้องซ้ำโค้ด) ไปให้ `Parse AI Response` คิด ETA: ถ้าอัตราที่ได้มีทิศทางตรงกับที่ต้องการปรับ (ขึ้นสำหรับ d-rest / ลงสำหรับ cold crash) และไม่นิ่งเกินไป (`|rate| ≥ 0.05°C/ชม.`) จะคำนวณ `ชั่วโมงที่เหลือ = |เป้าหมาย-ปัจจุบัน| / |rate|` แล้วแปลงเป็นวันเวลาโดยประมาณ (dd/mm/yyyy HH:mm ไทย) ต่อท้ายบรรทัดแนะนำ target ในข้อความ Discord ด้วย `⏱️` — ถ้าอัตราไม่ชัดหรือทิศทางไม่ตรง (เช่น อยาก d-rest แต่ Pill กำลังลดอยู่) จะบอกตรงๆ ว่า "ยังไม่เห็นแนวโน้มอุณหภูมิ Pill ขยับชัดเจนพอจะประมาณเวลาได้" แทนที่จะโชว์เลขมั่ว เผื่อกรณี Pill นิ่งจริง (พบจริงตอนออกแบบ: batch Hazy DIPA ตอนนั้น Pill นิ่งที่ 20°C มา 6 ชม.เต็ม, rate=0 พอดี) — โค้ด `Build AI Prompt`/`Parse AI Response` ยังคง verbatim เหมือนกันระหว่าง `Phase Analysis Cron` กับ `Phase Analysis Backtest` (มีแค่ 1 บรรทัดเบี่ยงเจตนา `nowForAnalysis` ตามเดิม — ดูข้อ 8.6) และ `Split Message Into Sections`/`Build Test Summary Message` ต่อ `⏱️ <eta text>` ต่อท้ายบรรทัดแนะนำ target ทั้งคู่ ทดสอบด้วย Node harness จำลองทั้ง 2 เคส (Pill นิ่ง/Pill กำลังไต่ขึ้นตามแนวโน้ม) ยืนยัน output ตรงตาม mockup ที่ confirm ไว้ก่อนแก้

**"ใกล้จะเปลี่ยนเฟส เตรียมตัว" alert** (เพิ่ม 15 ส.ค.): AI ประเมินเพิ่มว่า batch มีสัญญาณใกล้เข้าเฟสถัดไปหรือไม่ (`approaching_transition`/`next_phase`/`prep_actions` ใน JSON response) ถ้าใช่จะส่ง Discord alert แยกต่างหาก บอกสิ่งที่ควรเตรียม (เช่น ใกล้ diacetyl_rest → เตรียมยกอุณหภูมิ 16-18°C) กันสแปมด้วย `batches.prep_alerted_for_phase` — ส่งครั้งเดียวต่อ `next_phase` หนึ่งค่า จนกว่า AI จะเปลี่ยนใจเป็น next_phase อื่น หรือเฟสเปลี่ยนจริง (reset เป็น `NULL` อัตโนมัติใน `Update Batch Phase`)

**AI ที่ใช้**: Claude (Anthropic Messages API, `claude-sonnet-5`, `max_tokens=4096`) ไม่ใช้ web search — เกณฑ์ 7 เฟส bake เป็น context ตายตัวในทุก prompt (ดูข้อ 9) เพราะเป็นความรู้ที่นิ่งแล้ว ไม่ต้องเสียเวลา/เงินค้นเว็บซ้ำทุกรอบ

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

### 8.4 "รับคำสั่งปรับอุณหภูมิ" — 🟡 สร้างเสร็จ รอทดสอบจริงผ่าน Discord (task #33, 16 ส.ค.)

เพิ่มเป็น slash command `/ferment_set_temp` ในโครง 8.5 (ไม่ใช่ workflow แยก) รับ param `pill` (required), `target` (number, required), `remark` (optional เช่น `adjust`, `d rest`, `cold crash`) — สั่งตรงผ่าน RAPT `POST /api/TemperatureControllers/SetTargetTemperature?temperatureControllerId=...&target=...` แล้ว log ผลลง `control_log` (คอลัมน์ `remark` เพิ่มใหม่)

Node เพิ่มใน `Discord Interactions Webhook`: `Is Status?`(false) → `Is Set Temp?` → `Get Batch For Set Temp`(หา controller ที่จับคู่กับ pill + target ปัจจุบันจาก `temp_controller_readings` ล่าสุด) → `Is Batch Found (Set Temp)?` → `Has Controller (Set Temp)?` → `Get RAPT Token (Set Temp)` → `Call Set Target Temperature` → `Log Control Action`(insert `control_log`) → `Build Set Temp Message` → `Send Followup` (มีสาย error แยกสำหรับ "ไม่พบ batch" กับ "batch ยังไม่มี controller จับคู่")

**เอา `control_log` เข้าไปประกอบ prompt วิเคราะห์เฟสของ AI ด้วย**: ทั้ง `Phase Analysis Cron` (`Get Latest Readings`) และ `Discord Interactions Webhook` (`Get Batch For Analysis`) เพิ่ม CTE `control_series` ดึงประวัติ `set_target_temperature` ของ controller ตัวนั้นตั้งแต่ `start_date` ของ batch ส่งเป็น "ประวัติการปรับ target ด้วยมือ" ต่อท้ายกราฟ gravity/อุณหภูมิใน prompt พร้อมกำกับให้ AI ตีความ remark (เช่น "d rest") เป็นหลักฐานสนับสนุนสำคัญ — ไม่ใช่แค่ inference จากอุณหภูมิเพียงอย่างเดียว เพราะสะท้อนเจตนาจริงของผู้ควบคุม

**ปัดทศนิยม/format ตัวเลขให้ครบทุกข้อความ (เพิ่ม 18 ส.ค.)**: ตามที่เจอบั๊ก raw float (`17.3434753417969°C`) ใน `Phase Analysis Cron` มาก่อน (ข้อ 8.3) เช็คไล่ทั้งไฟล์นี้ซ้ำแล้วเจอจุดเดียวกันอีก 4 ที่ที่ยังไม่ได้ปัด — แก้ครบแล้ว: `Build Status Message` (`/ferment_status`, เพิ่ม helper `fmt(v,n)` ปัด gravity 3 หลัก/อุณหภูมิ 2 หลัก), `Build Set Temp Message` และ `Build Component Confirm Message` (ปัด `current_target`/`target_temp` เป็น 2 หลักตอนแสดงผล เฉพาะข้อความเท่านั้น ค่าที่ส่งเข้า RAPT/DB ยังเป็นตัวเต็มเหมือนเดิม), `Build Followup Message` (ปัด OG/FG จาก recipe เป็น 3 หลัก) ทดสอบด้วย Node harness ทั้ง 3 node ยืนยัน output ตรงรูปแบบเดียวกับที่ใช้ใน `Phase Analysis Cron` แล้ว

**Autocomplete สำหรับ `/ferment_start recipe` (เพิ่ม 18 ส.ค., task #40)**: เปลี่ยนจากพิมพ์ชื่อ recipe เองล้วนๆ เป็น dropdown ที่ดึงจาก `recipes` table สดๆ ขณะพิมพ์ — เปิด `"autocomplete": true` บน option `recipe` ใน `Register Slash Commands.json` (ต้องรัน Manual Trigger ใหม่ให้ Discord รู้จัก) เพิ่มสาขาใหม่รับ Discord interaction type 4 (APPLICATION_COMMAND_AUTOCOMPLETE) ใน `Discord Interactions Webhook`: `Is Ping?`(false) → `Is Autocomplete?`(type===4) → `Parse Autocomplete Request` (หา option ที่ `focused: true` แล้วดึง partial text ที่พิมพ์มา) → `Search Recipes For Autocomplete` (`ILIKE '%...%'` + `LIMIT 25` ตามลิมิต Discord) → `Build Autocomplete Choices` → `Respond Autocomplete` (**response type 8 พร้อม `data.choices` ในคำตอบเดียวจบ ไม่ใช่ deferred-then-followup แบบ command ปกติ** — ต้องตอบภายใน 3 วิเหมือนกันแต่เป็น final response เลย ไม่มี "กำลังคิด") ถ้าไม่ใช่ ping/autocomplete ค่อยไปต่อ `Is Command?` เหมือนเดิม รวม node ทั้งไฟล์ตอนนี้ 60 ตัว ทดสอบ SQL จริงบน VPS (ค้นหา "haz" ได้ "Hazy DIPA") + Node harness ทั้ง parse/build choices แล้ว

**บั๊กที่ระวังไว้ล่วงหน้า** (จากประสบการณ์ 8.3/8.5): `remark` เป็น free text จากผู้ใช้ ถ้ามี comma จะไปเลื่อนตำแหน่ง positional parameter ใน `queryReplacement` เหมือนที่เจอกับ AI reasoning text มาก่อน — sanitize comma → full-width `，` ตั้งแต่ตอน parse ใน `Parse Interaction Command`; `old_value`/`remark` อาจเป็น `null` (ยังไม่เคยมี target reading มาก่อน หรือไม่ได้กรอก remark) ซึ่ง n8n จะแปลงเป็น literal text `"null"` ใน `queryReplacement` ต้องครอบด้วย `NULLIF($n, 'null')`

**`/ferment_recipes` — list ชื่อ recipe จาก Brewfather cache (เพิ่ม 18 ส.ค., task #39)**: command ใหม่ ไม่ต้องผูก batch/pill ใดๆ ใส่ optional param `search` กรองด้วย `ILIKE` — `Is Set Temp?`(false) → `Is Recipes?` → `Get Recipes List` (query `recipes` table, รวมผลเป็น `jsonb_agg` แถวเดียวกันแบบเดียวกับ pattern อื่นๆ ในไฟล์นี้ เพื่อให้ Code node ต่อท้ายได้ item เดียว) → `Build Recipes Message` → `Send Followup` (reuse) ตอบแบบ public (ไม่ ephemeral — เพราะ `Respond Deferred` เป็น node กลางที่ใช้ร่วมกับทุก command ก่อนรู้ด้วยซ้ำว่าเป็น command ไหน จะทำ ephemeral เฉพาะ command นี้ต้องปรับ flow ให้ parse ชื่อ command ก่อน defer ซึ่งเกินความจำเป็นสำหรับ use case นี้) แสดงชื่อ+style เรียงตามตัวอักษร พร้อมวันที่ sync ล่าสุด (format dd/mm/yyyy ให้ตรงกับที่ใช้ทั้งโปรเจกต์ — ระวัง `toLocaleDateString('th-TH')` เริ่มต้นจะได้ปี พ.ศ. ต้อง format เองด้วยมือ) ทดสอบ SQL จริงบน VPS ได้ 14 recipes ไม่กรอง และกรอง `search: "DIPA"` ได้ 1 รายการถูกต้อง

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
- `PATCH .../messages/@original` ยังโผล่ "Unknown Webhook" (404) แบบสุ่มๆ ได้อีกแบบ (เพิ่ม 18 ส.ค.) แม้ payload/ack/endpoint ถูกหมดแล้ว — เจอจริงตอนกดปุ่มยืนยันปรับ target (task #38): เช็ค `Respond Deferred (Component)` ส่ง `{"type":6}` ถูกต้อง, `custom_id`/token/application_id ถูกทุกจุด แต่ followup ยัง 404 เป็นครั้งคราว ตรงกับ bug ที่ Discord เองยังไม่ปิด ([discord-api-docs#7220](https://github.com/discord/discord-api-docs/issues/7220)) ว่าบางครั้งหลัง defer สำเร็จ เรียก followup ทันทีจะโดน 404 แบบสุ่ม แต่ retry หลังรอ 2-3 วิมักผ่าน — แก้โดยเปิด **Retry On Fail** (node Settings) บน `Send Followup`: `maxTries: 3, waitBetweenTries: 2000` (reuse node เดียวกันทั้ง slash command flow และ component-button flow เลยได้ผลทั้งสองทาง)
- reset `bot_state` เป็น `'0'` ตอนเคลียร์ DB ทำให้ Discord Command Intake (workflow แบบ polling เดิม) replay ข้อความเก่าซ้ำ — ไม่เกี่ยวกับ slash command แต่กระทบ batch ซ้อนกันถ้าเผลอรันทั้งสอง workflow พร้อมกันตอน DB ว่าง ระวังจุดนี้เวลาเคลียร์ข้อมูลอีก

**รับปุ่มยืนยันปรับอุณหภูมิ (เพิ่ม 18 ส.ค., task #38)**: สาขาใหม่รับ Discord message component (ดูรายละเอียดเต็มในข้อ 8.3) — `Is Command?`(false) → `Is Component?`(type===3) → `Respond Deferred (Component)`(type 6) → `Parse Component Interaction` → `Get Batch By Id` → `Is Batch Found (Component)?` → `Get RAPT Token (Component)` → `Call Set Target Temperature (Component)` → `Log Control Action (Component)` → `Build Component Confirm Message` → `Send Followup` (reuse node เดิมจาก slash command flow)

**บั๊กใหญ่ที่เจอตอน test จริง (18 ส.ค.): reimport/save ไม่พอ ต้อง Deactivate+Activate ใหม่** — หลัง reimport ไฟล์ กดปุ่มจริงบน Discord ยัง "didn't respond in time" ซ้ำๆ ทั้งที่ manual execute ในหน้า editor ผ่านทุกครั้ง — ตรวจ `n8nEventLog.log` บน VPS โดยตรงเจอว่า live webhook execution ยัง dead-end ที่ `Is Command?` (ไม่ไปต่อ `Is Component?`) ทั้งที่ `n8n export:workflow` ยืนยันว่า DB มี node ใหม่ครบแล้ว — สาเหตุคือ **n8n แยก "เวอร์ชันที่บันทึกล่าสุด" กับ "กราฟที่ webhook route จริงชี้ไปใช้" ออกจากกัน** พอ workflow active อยู่แล้วแก้ branch ใหม่ๆ แล้ว save เฉยๆ ไม่พอ ต้อง **toggle Deactivate แล้ว Activate ใหม่** ให้ runtime router ผูกกราฟใหม่จริงๆ (manual execute ในหน้า editor ไม่ผ่าน path นี้เลยเข้าใจผิดว่า "ใช้ได้แล้ว" มาตลอด) — วินิจฉัยได้จาก `data/n8n/n8nEventLog.log` (มี `n8n.node.started`/`finished` ทุก node พร้อม timestamp ms) เทียบกับ `n8n export:workflow --id=<id>` ตรงๆ

**ผลข้างเคียงจากการ debug (18 ส.ค.)**: ตอนไล่ debug ปัญหาข้างต้น เคยให้ manual execute node ไล่ไปถึง `Send Followup` เพื่อดู timing จริง — ดันไปยิง RAPT `SetTargetTemperature`จริง + insert `control_log` ซ้ำโดยไม่ตั้งใจ (`changed_at` ใหม่) ทำให้ `stable_gap_c`/`stable_gap_points` (ข้อ 8.3) รีเซ็ตนาฬิกา 2 ชม. ที่กันช่วง transient — ผลคือ cron รอบถัดไปหา gap data ไม่เจอเลย (0 จุด) เพราะหน้าต่างเวลาที่คำนวณได้ล้ำหน้ากว่า `now()` ตอนนั้น ปุ่มแนะนำ target เลยหายไปชั่วคราวจนกว่าจะผ่าน 2 ชม. จริง — ไม่ใช่บั๊ก เป็น safety logic ทำงานถูกต้องตามออกแบบ แค่โดน trigger จากการทดสอบ ระวังอย่า manual execute ยาวไปถึง node ที่มี side effect จริง (RAPT call / DB insert) โดยไม่จำเป็น

รวม node ทั้งไฟล์ตอนนี้ 55 ตัว

**เพิ่ม param `recipe` ใน `/ferment_start` (18 ส.ค.)**: optional, ผูก batch กับ recipe ที่ sync มาจาก Brewfather (ดูข้อ 8.1) — `Create Batch` เพิ่ม CTE `matched_recipe` match ชื่อแบบ `trim(lower(...))` (กัน case/whitespace ไม่ตรง) แล้ว set `batches.recipe_id` ถ้าเจอ `Build Followup Message` โชว์ชื่อ recipe/style/OG-FG ตามสูตรกลับไปถ้า match ได้ หรือเตือนว่าไม่พบ recipe (พร้อมชื่อที่พิมพ์มา) ถ้าใส่ชื่อมาแต่หาไม่เจอ — ไม่ block การสร้าง batch แม้ recipe จะหาไม่เจอหรือไม่ได้ใส่มาเลย ทดสอบ query จริงกับข้อมูล Brewfather ที่ sync มาแล้วผ่าน transaction rollback บน VPS (match "khelang brew weizen" ตัวพิมพ์เล็ก/มีช่องว่างนำหน้า-ท้ายเจอ record "Khelang Brew Weizen" ถูกต้อง)

**`/ferment_status` เปลี่ยนไปเรียก `Phase Analysis Engine` แทนสำเนา logic ของตัวเอง (เพิ่ม 18 ส.ค.)**: audit ทั้งระบบหา token/component ที่ไม่จำเป็น พบว่า `/ferment_status` มี pipeline วิเคราะห์แยกของตัวเอง (`Build Status Analysis Prompt`→`Call Claude (Status)`→`Parse Status Analysis`) เป็น**สำเนา logic เดียวกับ Engine** ที่ไม่เคยได้รับ fix ใดๆ ที่ทำกับ Engine เลยตั้งแต่สร้าง sub-workflow ขึ้นมา (JSON parse robustness, prompt-logic guard, ลด prompt size 54%) — ยัง dump กราฟดิบเต็มรูปแบบเดิมทุกอย่าง (prompt ~100k ตัวอักษรต่อครั้งสำหรับ batch อายุ 9 วัน) และ schema ยังสั่งวันที่แบบ `YYYY-MM-DD` (ไม่ตรง convention dd/mm/yyyy ที่ใช้ทั้งโปรเจกต์) — ย้ายไปเรียก `Phase Analysis Engine` ผ่าน Execute Workflow เหมือน Cron/Backtest แทน:
- ตัด node `Build Status Analysis Prompt`, `Call Claude (Status)`, `Parse Status Analysis`, `Insert Analysis Log`, `Update Batch Phase (Status)` ออก (5 node) — `Insert Analysis Log`/`Update Batch Phase (Status)` เขียน DB ทุกครั้งที่มีคนกดดูสถานะ ทั้งที่ cron อัปเดตอยู่แล้ว 4 รอบ/วัน ตัดออกทำให้ `/ferment_status` กลายเป็น read-only จริงๆ ไปด้วย (ไม่ได้ตั้งใจแค่ลด node แต่เป็นผลดีที่ตามมา)
- เพิ่ม `Add Analysis Time (Status)` (stamp `analysis_time_iso` เป็นเวลาจริงเสมอ เหมือน Cron) → `Call Phase Analysis (Status)` (Execute Workflow → Phase Analysis Engine)
- `Build Status Message` แก้ไปอ่านจาก `$('Call Phase Analysis (Status)')` แทน `$('Parse Status Analysis')` และคำนวณ `phase_changed` เองจาก `detected_phase !== previous_phase` (Engine ไม่มี field นี้ตรงๆ)
- Engine เพิ่ม field `pill_time_utc`/`controller_time_utc` (เวลาของจุดล่าสุดใน pill/controller series) ที่ `Build Status Message` ต้องใช้แสดง "ณ เวลา..." — ไม่กระทบ Cron/Backtest เพราะเป็น field เสริมที่ไม่ได้ใช้อยู่แล้ว
- ลด `max_tokens` ของ `Call Claude` (Engine) จาก 8192 → 4096 (output จริงวัดได้ ~1,450 tokens เผื่อ 2.8 เท่าเพียงพอ)

รวม node ไฟล์นี้ลดจาก 60 → 57 ตัว ทดสอบด้วย Node harness จำลอง `Build Status Message` ด้วย mock ของ `luxon` และ Engine output จริง ยืนยัน render ถูกต้องทั้ง 2 เคส (phase เปลี่ยน/ไม่เปลี่ยน)

---

### 8.6 "Phase Analysis Backtest" — 🟡 สร้างเสร็จ ทดสอบ pipeline เต็มแล้ว รอรันจริงผ่าน Discord (task #41, 18 ส.ค.)

เครื่องมือทดสอบ ไม่ใช่ production feature — ไฟล์แยก `workflows/Phase Analysis Backtest.json`, **ไม่ active ไม่มี trigger จริง** รันเองผ่าน Manual Trigger เท่านั้น ไม่แตะ/ไม่เขียนกลับ batch จริง (ไม่มี `Insert Phase Log`/`Update Batch Phase` เหมือน `Phase Analysis Cron`)

**โจทย์**: อยากรู้ว่าถ้า batch Hazy DIPA (ข้อมูล Pill/Controller/recipe จริงที่มีอยู่แล้วใน DB) สมมติว่า start วันที่ที่กำหนดเอง (ไม่ใช่ `start_date` จริงของ batch) ระบบจะวิเคราะห์/ตอบอะไรบ้างในแต่ละวันที่ผ่านไป จนถึงวันนี้ — โดยใช้ logic วิเคราะห์ **ชุดเดียวกับ `Phase Analysis Cron` เป๊ะๆ** (copy `Build AI Prompt`/`Parse AI Response` jsCode มาตรงๆ กันความคลาดเคลื่อนจากการเขียนใหม่)

**Pipeline**: `Manual Trigger` → `Generate Simulated Days` (Code — สร้าง item ละ 1 วันจำลอง จาก `OVERRIDE_START_DATE`/`BATCH_ID` ที่แก้ค่าได้ตรงหัวไฟล์ ถึงวันนี้) → `Get Simulated Readings` (Postgres — ดัดแปลงจาก `Get Latest Readings` ของ cron จริง แต่ตัด pill/controller/control series ให้เห็นแค่ข้อมูลที่ **`time_utc <= cutoff` ของวันนั้นจริงๆ** และใช้ `start_date`/`cutoff` ที่ override แทนของจริงทั้งหมด) → `Build AI Prompt` → `Call Claude` (config เดียวกับตัวจริงรวม `thinking: disabled` ที่เพิ่งแก้) → `Parse AI Response` → `Build Test Summary Message` (Code ใหม่ — สรุปเป็น **ข้อความเดียวต่อวัน** ไม่แยก section เหมือน production กันสแปมช่อง ขึ้นต้นด้วย `🧪 TEST BACKTEST | จำลองผ่านไปถึงวันที่ dd/mm/yyyy`) → `Send Test Update` (POST เข้าช่อง Discord เดียวกับที่ใช้จริง)

**จุดที่ต้องเบี่ยงจากโค้ดจริงของ `Phase Analysis Cron` (จงใจ ไม่ใช่ bug)**:
- `Build AI Prompt` คำนวณ `hoursSinceStart` จาก `Date.now()` เดิม (เวลาจริงตอนรัน) — สำหรับ backtest ต้องใช้ "เวลาปัจจุบันจำลอง" (`cutoff` ของวันนั้น) แทน ไม่งั้นทุกวันจำลองจะเห็น `hoursSinceStart` เป็นของวันนี้จริงเหมือนกันหมด แก้จุดเดียวเป็น `new Date(batch.cutoff).getTime()` มี comment กำกับไว้ในไฟล์ชัดเจนว่าเบี่ยงจากต้นฉบับตรงไหน
- `current_phase` ใส่ placeholder `'ไม่ทราบ (backtest mode)'` คงที่ทุกวัน แทนที่จะ track เฟสที่ตรวจจับได้ของวันก่อนหน้าต่อเนื่องกัน (การทำแบบนั้นต้องให้แต่ละวัน "จำ" ผลวันก่อนซึ่งซับซ้อนเกินความจำเป็นสำหรับเครื่องมือทดสอบครั้งเดียว) — ไม่กระทบการตัดสินเฟสหลัก เพราะ prompt ให้ AI ดูกราฟทั้งเส้นเป็นหลักอยู่แล้ว ไม่ได้พึ่ง `current_phase` เป็นหลักฐานตัดสิน
- `simulated_day_label` (วันที่จำลองไว้แสดงในข้อความ) ต้องส่งผ่าน column จริงใน SQL แล้วอ้างอิงกลับด้วย `$('Get Simulated Readings').first().json` ใน `Build Test Summary Message` แทนที่จะหวังให้ `Parse AI Response` (copy จาก production, output field ตายตัว) ส่งต่อให้ — เจอจาก test จริงว่าค่าหายไปเป็น `-` ตอนแรก
- `nowForAnalysis` (เพิ่ม 18 ส.ค. พร้อมฟีเจอร์ ETA ในข้อ 8.3): จุดเดียวที่ `Build AI Prompt` เบี่ยงจาก production คือใช้ `new Date(batch.cutoff).getTime()` แทน `Date.now()` — ทั้ง `hoursSinceStart` และหน้าต่าง 6 ชม.สำหรับคำนวณ `pill_ramp_rate_c_per_hour` (ETA) ต้องอิงจากตัวแปรนี้ตัวเดียวกัน ไม่งั้น ETA ที่คำนวณใน backtest จะอิงเวลาจริงปนกับข้อมูลจำลอง ทำให้เพี้ยน

ทดสอบก่อน deploy ครบ: `Generate Simulated Days` ให้ 9 วันถูกต้อง (10-18 ส.ค.), SQL จริงบน VPS ยืนยัน `pill_series` โตขึ้นตามวันจำลอง (9 จุดวันแรก → 487 จุดวันสุดท้าย) และ `start_date`/`stable_gap_c` เปลี่ยนตาม cutoff ถูกต้อง, ทดสอบทั้ง pipeline (`Build AI Prompt` → mock Claude response → `Parse AI Response` → `Build Test Summary Message`) ด้วยข้อมูลจริงจาก DB ได้ข้อความสุดท้ายถูกต้องครบ (เฟส, ตัวเลขปัดทศนิยม, วันที่จำลองแสดงถูก) — ยังไม่ได้ยิง Claude API จริงเพราะมีค่าใช้จ่าย รอรันจริงผ่าน Discord ครั้งแรกพร้อมกัน

**บั๊กที่เจอตอนรันจริงครั้งแรก (18 ส.ค.)**: ยิงมาแค่ 1 ข้อความ (ควรได้ 9) แถมวันที่คลาดเคลื่อนไป 1 วัน (โชว์ 09/08 แทน 10/08) — เช็ค execution data บน VPS โดยตรงเจอว่า `Parse AI Response` มี 9 item ถูกต้อง แต่ `Build Test Summary Message` เหลือ 1 item เพราะ Code node import มา default โหมด **"Run Once for All Items"** แล้วโค้ดดันใช้ `$input.first().json` (อ่านแค่ item แรก) แทนที่จะ loop `$input.all()` เหมือน `Build AI Prompt`/`Parse AI Response` — item ที่เหลือหายไปเงียบๆ ไม่ error ให้เห็น (ตรงกับ gotcha ที่เคยจดไว้แล้วเรื่อง default mode ของ Code node ที่ import มา แต่คราวนี้พลาดพลั้งไปเขียนโค้ดผิด pattern เอง) ส่วนวันที่เพี้ยนเพราะ `cursor.getDate()/getMonth()/getFullYear()` อ่าน timezone ท้องถิ่นของ process (n8n container รันเป็น UTC ไม่ใช่ Asia/Bangkok) แก้ทั้งสองจุด: เปลี่ยนเป็น loop `$input.all()` + `$('Get Simulated Readings').itemMatching(idx)` ให้แต่ละวันจับคู่ label ถูกต้อง, บวก offset +7 ชม. ก่อนอ่านวันที่กัน timezone ผิด (ทดสอบแล้วได้ผลเหมือนกันไม่ว่า process จะตั้ง `TZ=UTC`/`Asia/Bangkok`/`America/New_York`)

---

### 8.7 "Phase Analysis Engine" — sub-workflow กลาง (task #43, 18 ส.ค.)

**เหตุผล**: `Build AI Prompt`→`Call Claude`→`Parse AI Response` (การวิเคราะห์เฟสด้วย AI) ต้อง copy วางแบบ verbatim ระหว่าง `Phase Analysis Cron` (production) กับ `Phase Analysis Backtest` (เครื่องมือทดสอบ) มาตั้งแต่สร้าง — เสี่ยง code สองไฟล์เพี้ยนออกจากกันถ้าแก้จุดใดจุดหนึ่งแล้วลืมอีกจุด (ต้องคอย diff เทียบมือทุกครั้งที่แก้ ดูข้อ 8.3/8.6) ย้ายมาเป็น sub-workflow กลางไฟล์เดียว เรียกผ่าน n8n **Execute Workflow** node แทน กำจัดความเสี่ยงนี้ไปเลย

**ไฟล์ใหม่ `workflows/Phase Analysis Engine.json`** (4 nodes, ไม่ active — เรียกได้เฉพาะผ่าน Execute Workflow เท่านั้น ไม่มี trigger ของตัวเอง): `Execute Workflow Trigger` (node type `executeWorkflowTrigger`) → `Build AI Prompt` → `Call Claude` → `Parse AI Response` — code ทั้ง 3 node ยกมาจาก `Phase Analysis Cron` ตรงๆ มีแก้จุดเดียว: `Build AI Prompt` เดิมมี branch แยก `Date.now()` (cron) vs `batch.cutoff` (backtest) เอาออก เปลี่ยนเป็นอ่านจาก field `analysis_time_iso` ที่ผู้เรียกต้อง stamp มาให้เสมอแทน — ทำให้ sub-workflow นี้ generic จริงๆ ไม่ต้องรู้ว่าใครเรียก

**ฝั่งผู้เรียก (`Phase Analysis Cron`/`Phase Analysis Backtest`) เหมือนกันทั้งคู่**: node ใหม่ `Add Analysis Time` (Code) แทรกก่อนเรียก sub-workflow — stamp `analysis_time_iso` ลงทุก item: `Phase Analysis Cron` ใช้ `new Date().toISOString()` (เวลาจริงเสมอ), `Phase Analysis Backtest` ใช้ `it.json.cutoff` (เวลาจำลองของวันนั้น) — **นี่คือจุดเบี่ยงเจตนาจุดเดียวที่เหลืออยู่ระหว่างสองไฟล์ ย้ายมาอยู่นอก sub-workflow แล้ว ไม่ปนกับ logic วิเคราะห์เฟสอีกต่อไป** → node ใหม่ `Call Phase Analysis` (Execute Workflow, `mode: "once"` — เรียก sub-workflow ครั้งเดียวพร้อมทุก item/batch ที่ active พร้อมกัน เหมือน `Build AI Prompt`/`Parse AI Response` เดิมที่ออกแบบให้ loop `items.forEach()` รับหลาย batch ในการรันเดียวอยู่แล้ว ไม่ใช่เรียกแยกทีละ batch) — output ของ `Call Phase Analysis` มี shape เดียวกับที่ `Parse AI Response` เคย output ทุกประการ โหนดปลายทางที่เคยต่อจาก `Parse AI Response` (`Insert Phase Log`, `Phase Changed?`, `Approaching Transition?`, `Split Message Into Sections` ใน Cron / `Build Test Summary Message` ใน Backtest) ต่อจาก `Call Phase Analysis` แทนโดยไม่ต้องแก้อะไรข้างในเลย — ยกเว้น `Update Batch Phase`/`Update Prep Alert State` ที่อ้างอิง `$('Parse AI Response').itemMatching(...)` ตรงๆ ต้องเปลี่ยนเป็น `$('Call Phase Analysis')`

**⚠️ ขั้นตอน bootstrap ที่ต้องทำเองผ่าน n8n UI (ลำดับสำคัญ)**:
1. Import `Phase Analysis Engine.json` เป็น workflow ใหม่ก่อน (ยังไม่ต้อง active — ไม่มี trigger ให้ active อยู่แล้ว)
2. คัดลอก workflow id ที่ n8n สร้างให้ (ดูใน URL หรือหน้า workflow list)
3. แก้ node **"Call Phase Analysis"** ทั้งใน `Phase Analysis Cron.json` และ `Phase Analysis Backtest.json` — เปลี่ยนค่า `workflowId.value` จาก `REPLACE_WITH_SHARED_WORKFLOW_ID` เป็น id จริงที่ได้ **⚠️ ต้องแก้ในไฟล์ JSON โดยตรงแล้ว commit เท่านั้น ห้ามแก้แค่ในหน้า editor ของ n8n** (ดูบั๊กด้านล่างว่าทำไม)
4. Reimport `Phase Analysis Cron.json` (Deactivate/Activate ใหม่ตามเดิม — ดูบั๊กในข้อ 8.5) และ `Phase Analysis Backtest.json`
5. เติม id ของ `Phase Analysis Engine` ลง `.allowed-ids` (มี TODO รออยู่แล้ว)

**✅ bootstrap สำเร็จ + ทดสอบผ่านจริงแล้ว (18 ส.ค.)**: import + ตั้ง `workflowId` + reimport ตามขั้นตอนข้างบนแล้ว ยืนยันจาก `n8nEventLog.log` บน VPS ว่า `Phase Analysis Cron` เรียก `Call Phase Analysis` แล้ว spawn execution แยกของ `Phase Analysis Engine` (`Execute Workflow Trigger` → `Build AI Prompt` → `Call Claude` → `Parse AI Response`) สำเร็จจริง ครบ loop กลับมาที่ `Insert Phase Log`/`Update Batch Phase` ของ Cron จนจบ workflow แบบ success — node type `executeWorkflow`/`executeWorkflowTrigger` ที่ตอนแรกยังไม่เคยทดสอบจริง ตอนนี้ยืนยันว่าใช้งานได้ตามที่ออกแบบไว้

**แก้บั๊ก reimport ทับ `workflowId` กลับเป็น placeholder จนพัง (เพิ่ม 18 ส.ค.)**: หลัง bootstrap สำเร็จ (ย่อหน้าบน) ผู้ใช้แก้ `workflowId.value` ของ node "Call Phase Analysis" เป็น id จริงตรงในหน้า n8n editor โดยตรง (ไม่ได้แก้ในไฟล์ JSON) ทำงานได้ปกติจนกระทั่ง reimport `Phase Analysis Cron.json` รอบถัดไป (ตอนแก้บั๊ก rate limit) — reimport ไปทับค่า `workflowId.value` กลับเป็น `REPLACE_WITH_SHARED_WORKFLOW_ID` เดิมที่ยังค้างอยู่ในไฟล์ (เพราะไฟล์ไม่เคยถูกอัปเดตด้วย id จริงเลย) ทำให้ `Call Phase Analysis` error `"Workflow does not exist."` ทันที — สาเหตุคือไฟล์ JSON กับ live workflow บน n8n ไม่ sync กัน ตอนแก้อะไรตรงในหน้า editor เฉยๆ โดยไม่ย้อนกลับมาแก้ไฟล์ด้วย ครั้งต่อไปที่ reimport ไฟล์เดิมจะทับค่านั้นทิ้งเสมอ แก้โดย hardcode id จริง (`wdd07vd16VnMw2de`) ลงในไฟล์ JSON ทั้ง `Phase Analysis Cron.json`/`Phase Analysis Backtest.json` ตรงๆ แล้ว commit ไว้ (ดู `.allowed-ids` ที่บันทึก id นี้ไว้ด้วย) — **กฎที่ต้องจำ: ทุกครั้งที่แก้ parameter ของ node ใดๆ ตรงในหน้า n8n editor โดยตรง (ไม่ผ่านการแก้ไฟล์ JSON ก่อน) ต้องย้อนกลับมาแก้ไฟล์ JSON ในโปรเจกต์ให้ตรงกันด้วยเสมอ ไม่งั้น reimport ครั้งถัดไปจะทับค่านั้นหายไป**

ทดสอบด้วย Node harness ก่อน deploy: จำลอง `Build AI Prompt` → mock Claude response → `Parse AI Response` ผ่าน `analysis_time_iso` ที่ stamp มาแบบ cron (เวลาจริง) ได้ output ตรงกับก่อน refactor ทุกประการ (เฟส, ETA fallback text ถูกต้องตอนไม่มีข้อมูลเทรนด์พอ)

**แก้บั๊ก Claude เขียนคำอธิบายนำหน้า JSON ทำให้ parse พัง (เพิ่ม 18 ส.ค.)**: เจอจริงตอนทดสอบ batch Weizen จริงหลัง deploy sub-workflow — Discord ขึ้น `⚠️ กู้ phase จาก JSON ที่ไม่สมบูรณ์ (regex fallback, SyntaxError: Unexpected token 'ว', "วิเคราะห์ก"... is not valid JSON)` ดึง execution data จาก SQLite บน VPS ตรงๆ (`Call Claude`'s output) เจอว่า Claude ตอบข้อความอธิบายภาษาไทยเต็มๆ ("วิเคราะห์กราฟ: SG เริ่มที่...") **นำหน้า** ` ```json ` ทั้งที่ prompt สั่งห้ามข้อความอื่นปนไว้แล้ว (ดูข้อ 8.3 บรรทัดที่สั่ง "ตอบกลับเป็น JSON เท่านั้น") — โค้ดเดิมตัด code fence ด้วย regex ที่ยึดตำแหน่งต้น string (`^```json`) เท่านั้น พอ fence ไม่ได้อยู่ต้น string (มีคำอธิบายนำหน้า) เลยตัดไม่ออก ทำให้ `JSON.parse()` ไปสะดุดตัวอักษรตัวแรกของคำอธิบายแทน — ระบบ regex fallback (ดักจับ `"phase": "..."` ตรงๆ) กู้ phase ได้เลยไม่ถึงกับพังทั้งหมด แต่ reasoning/timeline/prep_actions/recommendation หายไปทั้งชุดสำหรับ batch นั้น — แก้โดยเปลี่ยนวิธีตัด JSON ออกจากข้อความ จากเดิม "ตัด fence จากต้น/ท้าย string" เป็น **"หาตำแหน่ง `{` ตัวแรกสุด ถึง `}` ตัวสุดท้ายสุด แล้วตัดมาแค่ช่วงนั้น"** (ทำต่อจาก fence-strip เดิม ไม่ได้แทนที่ ป้องกันซ้อนสองชั้น) ครอบคลุมทุกเคส (มี/ไม่มี fence, มี/ไม่มีคำนำ) แก้ทั้ง 2 จุดที่มี pattern เดียวกัน: `Phase Analysis Engine`'s `Parse AI Response` (ใช้ทั้ง cron และ backtest) และ `Discord Interactions Webhook`'s `Parse Status Analysis` (ใช้กับ `/ferment_status` — ตรวจแล้วมี pattern เดียวกันเป๊ะ เสี่ยงบั๊กเดียวกัน) ทดสอบด้วย Node harness ป้อน raw response ตัวจริงที่ทำให้พัง (ดึงมาจาก execution data จริงบน VPS) ยืนยันว่า parse ผ่านสมบูรณ์ครบทุก field (phase, reasoning, prep_actions, phase_timeline, recommendation) แทนที่จะ fallback เหมือนก่อนแก้

**แก้บั๊ก Discord rate limit ตอนมีข้อความหลายชิ้นสะสม (เพิ่ม 18 ส.ค.)**: เจอจริงตอนมีหลาย batch active พร้อมกัน — `Send Routine Update` ตอบ `429 "You are being rate limited"` ที่ item ที่ 8 (ข้อความชิ้นที่ 9) เพราะ `batchInterval` เดิมตั้งไว้แค่ 500ms (2 ข้อความ/วิ) ในขณะที่ Discord จำกัดการโพสต์ข้อความต่อ channel ไว้ประมาณ 5 ข้อความ/5 วิ (~1 ข้อความ/วิ) พอมีข้อความสะสมเกิน 8 ชิ้นในรอบเดียว (หลาย batch × หลาย section ต่อ batch) ก็ชนลิมิต แก้ 2 ทาง: (1) เพิ่ม `batchInterval` เป็น 1100ms ให้ต่ำกว่าลิมิตจริงพร้อม margin (2) เปิด **Retry On Fail** (`maxTries: 3, waitBetweenTries: 2000`, pattern เดียวกับที่แก้ `Send Followup` ในข้อ 8.5) เผื่อโดน rate limit อยู่ดีจากข้อความช่องอื่นที่ไม่เกี่ยวกัน — แก้ทั้ง `Send Routine Update` (`Phase Analysis Cron`) และ `Send Test Update` (`Phase Analysis Backtest`) เพราะมี pattern เดียวกัน

**แก้ prompt: ข้อความแนะนำ target ขัดแย้งกับคำแนะนำให้รอ + phase misclassification (เพิ่ม 18 ส.ค.)**: ผู้ใช้รายงาน 2 เคสจริงจาก Discord — (1) batch Hazy DIPA: prep_actions บอก "คง Pill ที่ ~20-22°C ต่ออีก 1-2 วันให้ครบ diacetyl rest" แต่ในข้อความเดียวกันมีปุ่มแนะนำให้ปรับ target ไปยัง cold_crash ทันที ขัดแย้งกันเอง (2) batch Weizen: หัวข้อขึ้น "เฟส: cold_crash ใกล้ cold_crash" (next_phase ซ้ำกับ phase ปัจจุบัน) พร้อมปุ่มแนะนำ target 1.68°C ทั้งที่ target ตู้ควบคุมตอนนั้นตั้งไว้ 1.67°C อยู่แล้ว (ต่างกันแค่ 0.01°C จาก noise การคำนวณ `stable_gap_c` ใหม่ทุกรอบ) — ตรวจข้อมูลจริงพบว่า Pill ยังอยู่ 20.06°C ห่างจากเกณฑ์ cold_crash (0-4°C) มาก แต่ AI ตัดสิน `phase=cold_crash` ไปแล้วเพราะเห็นว่า **target ตู้ควบคุมถูกปรับลง** ทั้งที่กติกาเดิม (เหมือน diacetyl_rest) กำหนดให้ใช้อุณหภูมิ Pill จริงตัดสิน ไม่ใช่ target ตู้ควบคุม — แก้ 3 จุดใน prompt (`Build AI Prompt`):
1. เกณฑ์ cold_crash เพิ่มคำเตือนแบบเดียวกับ diacetyl_rest: ห้ามใช้แค่ target ตู้ที่ถูกปรับลงมาสรุปว่าเข้าเฟส cold_crash แล้ว ถ้า Pill ยังไม่ถึง 0-4°C จริงให้ถือว่ายังไม่เข้าเต็มตัว
2. เพิ่มกฎ: `next_phase` ห้ามเป็นค่าเดียวกับ `phase` ที่ตอบเด็ดขาด (เข้าเฟสนั้นแล้วจริงต้อง `approaching_transition=false, next_phase=null`)
3. `recommended_pill_temp_c` ห้ามใส่ค่า (ต้องเป็น null) ถ้า prep_actions บอกให้คงอุณหภูมิ/รอต่อไปก่อน — ใส่เฉพาะตอนที่ควรปรับ target ตอนนี้เลยเท่านั้น ไม่ใช่แค่ "กำลังจะถึง"

ทดสอบ syntax ผ่าน Node harness แล้ว ยังไม่ได้ยิง Claude API จริงเพราะเป็นการแก้ข้อความ prompt ล้วนๆ (ไม่กระทบ JS logic ที่ทดสอบแยกได้) รอดูผลจริงหลัง reimport รอบถัดไป

**ลด prompt size ~54% (เพิ่ม 18 ส.ค.)**: ดึง prompt จริงจาก execution ล่าสุดบน VPS มา audit ทีละส่วนเทียบขนาดจริง พบว่า**กราฟ pill/controller ที่ dump ทุกจุดดิบกิน 85-97% ของ prompt** และโตไม่มีเพดานตามอายุ batch (Weizen 9 วัน = 1,384 จุดรวม, prompt ยาว 100,250 ตัวอักษร) ส่วน static instructions/recipe/schema มีแค่ไม่กี่เปอร์เซ็นต์ — เจอความฟุ่มเฟือย 3 จุดในบรรทัดกราฟ: timestamp เต็มรูปแบบ ISO (29 ตัวอักษร), ทศนิยม sensor ดิบไม่ปัด (เช่น `17.3636474609375°C`), และ `target=` พิมพ์ซ้ำค่าเดิมทุกบรรทัดทั้งที่แทบไม่เปลี่ยน (มี control_series แยกบอกประวัติการปรับด้วยมืออยู่แล้ว) แก้ใน `Build AI Prompt` โดย**ไม่ตัดข้อมูลจุดไหนออกเลย เก็บทุกจุดครบเหมือนเดิม** (ทดลอง downsample จุดที่เก่ากว่า 72 ชม. ไปก่อน แต่ผู้ใช้ให้เอากลับมาเป็นข้อมูลครบทุกจุด ไม่ downsample) แค่ย่อ format:
- ย่อ timestamp เป็น `dd/mm hh:mm`, ปัดทศนิยม gravity 4 ตำแหน่ง/อุณหภูมิ 2 ตำแหน่งตาม convention เดิม
- พิมพ์ `target→` เฉพาะบรรทัดที่ค่าเปลี่ยนจากก่อนหน้า

array เต็ม (`pillSeries`/`controllerSeries`) ที่ใช้คำนวณ baseline/velocity/ETA/stable_gap ไม่ถูกแตะเลย เปลี่ยนแค่ตอน render เป็น text ส่งเข้า prompt เท่านั้น ทดสอบด้วย Node harness ป้อนข้อมูลจริงจาก execution เดียวกันที่ใช้ audit (2 batch, 2,182 จุดรวม) ยืนยันผลจริง: **157,310 → 72,639 ตัวอักษร (-54%)** โดยไม่เสียข้อมูลจุดไหนเลย — ยืนยันผลจริงบน production แล้ว (execution 436, 18 ส.ค.): Weizen 43,003 + Hazy DIPA 31,487 = 74,490 ตัวอักษร (ลด ~53% เทียบ baseline เดิม) format ถูกต้อง parse ผ่านสะอาดทั้ง 2 batch

**เพิ่ม code-level guard กัน AI ฝ่าฝืน prompt logic ซ้ำ (เพิ่ม 18 ส.ค.)**: เช็ค execution 436 (รันจริงหลัง reimport prompt-logic fix ข้อบน) พบว่า Sonnet 5 **ยังฝ่าฝืนกฎที่สั่งไว้ในprompt อยู่ดี** ทั้งที่ข้อความคำสั่งอยู่ใน prompt จริงที่ส่งไปแล้ว — batch Weizen ตอบ `phase: cold_crash` พร้อม `next_phase: cold_crash` (ค่าเดียวกัน ทั้งที่สั่งห้ามแล้ว) และ reasoning เขียนเองว่า "ยังไม่เข้า cold_crash เต็มตัว" แต่ตอบ `phase: cold_crash` ขัดกับเหตุผลตัวเอง พร้อมแนะนำ target ใหม่ 1.62°C ทั้งที่ target ปัจจุบันตั้งไว้ 1.67°C อยู่แล้ว (ต่างกันแค่ 0.05°C) — สรุปว่า**แก้แค่ prompt ไม่พอสำหรับกฎที่ AI มีเหตุผลอื่นโน้มน้าวให้ฝ่าฝืนได้** จึงเพิ่ม guard ระดับโค้ดใน `Parse AI Response` เป็นชั้นกันอีกที (defense-in-depth แบบเดียวกับที่ทำกับบั๊ก JSON parse ไปแล้ว):
- ถ้า `next_phase` ที่ AI ตอบมาซ้ำกับ `phase` ปัจจุบัน → บังคับ `next_phase = null` ในโค้ดทันที ไม่ต้องเชื่อ AI
- ถ้า target ที่แนะนำใหม่ต่างจาก target ปัจจุบัน (`src.target_temperature_c`) **น้อยกว่า 2.5°C** → ไม่แนะนำ (`recommended_pill_temp_c`/`recommended_controller_target_c` เป็น `null`) เพราะไม่มีอะไรใหม่ให้ action จริง — ตัวเลข 2.5°C กำหนดโดยผู้ใช้เอง

ทดสอบด้วย Node harness ป้อนข้อมูลจริงจาก execution 436 ที่เจอบั๊ก (Weizen, target 1.67→1.62, phase==next_phase) ยืนยันทั้ง 2 guard ทำงานถูกต้อง (suppress ทั้งคู่) และทดสอบเคสบวก (diacetyl_rest แนะนำ target ต่างจากเดิม 2.6°C ≥ เกณฑ์) ยืนยันว่ายังผ่านได้ปกติ ไม่ suppress คำแนะนำที่จำเป็นจริง

**เพิ่ม downsample แบบ delta+heartbeat (เพิ่ม 18 ส.ค.)**: ตรวจต่อจากการลด prompt size ~54% ข้อบน หา token ที่ยังลดได้อีก — เกณฑ์ grid เวลาล้วนๆ (ตัดทุก X ชม.) ที่เคยลองแล้ว rollback ไปก่อนหน้า มีข้อเสียคือตัดความละเอียดช่วงกราฟชัน (high krausen, ไล่อุณหภูมิ d-rest/cold crash) เท่าๆ กับช่วงแบนราบ ทั้งที่ข้อมูล fermentation จริงมีลักษณะ "ชันแรงไม่กี่วัน + แบนยาวๆ" เปลี่ยนมาใช้ **delta+heartbeat** แทน: เก็บจุดเมื่อ SG เปลี่ยน ≥0.001 หรืออุณหภูมิเปลี่ยน ≥0.2°C จากจุดที่เก็บล่าสุด (ช่วงชันเก็บเกือบทุกจุดเองอัตโนมัติ) หรือไม่มีจุดไหนถูกเก็บมาเกิน **heartbeat 3 ชม.** (กันช่วงแบนราบหายไปจนดูไม่ออกว่านิ่งมานานแค่ไหน — เป็นหลักฐานตัดสิน fg_stable) target ที่เปลี่ยนใน controller series เก็บเสมอ จุดแรก/สุดท้ายของเส้นเก็บเสมอ และ**เก็บเต็มความละเอียดเสมอในช่วง 6 ชม.ล่าสุด** (ตรงกับหน้าต่างที่ใช้คำนวณ ETA/เทรนด์ปัจจุบัน กันไม่ให้ downsample กระทบตัวเลขที่คำนวณจริง) — ทดสอบเทียบกับข้อมูลจริง 2 batch ก่อนใช้ (ดึงจาก VPS ตรงๆ) ยืนยันว่าจุดที่เก็บกระจายตามกิจกรรมจริง (10-11/08 high krausen เก็บ 21/86 และ 17/60 จุด, 13-18/08 fg_stable เหลือ ~11-15 จุด/วันแต่ยังเห็นชัดว่าแบน, ช่วงยกอุณหภูมิ d-rest เห็นครบทุก step) ผลจริงบน production data: **74,490 → 25,174 ตัวอักษร (-66% เพิ่มเติม, สะสมจากต้นฉบับ ~157k คือ -84%)** array เต็มที่ใช้คำนวณ baseline/velocity/ETA/stable_gap ไม่ถูกแตะเหมือนเดิม

**ยืนยันผลจริงหลัง reimport (18 ส.ค.)**: (1) Cron จริง execution 446/447 — input tokens เหลือ 10,761/9,635 ต่อ batch (จาก baseline เดิม 36,676/59,591 = ลด ~73-84%), parse ผ่านสะอาด, Discord ส่งครบ 6/6 ไม่ชน rate limit, guard `next_phase==phase` จับการฝ่าฝืนของ AI ได้จริง 1 ครั้ง (Claude ยังตอบ cold_crash ซ้ำมา โค้ดบังคับ null ก่อนถึง Discord) (2) Backtest 9 วันจำลอง — phase progression ต่อเนื่องสมเหตุสมผลตลอดเส้น (lag→active→slowing→fg_stable พร้อมเตือน stuck fermentation ช่วง attenuation ต่ำ→รอ Pill ถึงจริงก่อนตัดสิน d-rest→diacetyl_rest→ใกล้ cold_crash), AI จับ sensor spike ผิดปกติเองได้ (`SG=1.0713/25.38°C` ช่วง 15 นาที — delta-based เก็บ spike ไว้ ไม่กลบแบบ grid), ไม่มีปุ่มแนะนำ target มั่วสักวัน — สรุป downsample ไม่กระทบคุณภาพการวิเคราะห์

**เพิ่มกฎ reasoning ต้องสอดคล้องกับ approaching_transition (เพิ่ม 18 ส.ค., task #51)**: จาก Backtest ข้างบน วันที่ 11/08 ตอบ "เฟส: active_ferment ใกล้ slowing_ferment" แต่ reasoning ข้อสุดท้ายเขียน "ยังไม่มีสัญญาณกราฟแบนหรือชะลอ ยังอยู่ในช่วง active fermentation หนัก" — ขัดกับ flag ที่ตอบ (การตัดสินเองอาจถูก เพราะ bullet ก่อนหน้าบอกอุณหภูมิพีค high krausen ผ่านไปแล้ว ซึ่งสนับสนุน "ใกล้ slowing" ได้ แต่ข้อความตีกันเองทำให้คนอ่านงง) — guard ระดับโค้ดตรวจไม่ได้เพราะต้องตีความข้อความอิสระ แก้เป็น prompt rule ใน `Build AI Prompt`: ถ้า `approaching_transition=true` ห้ามมีข้อความปฏิเสธเด็ดขาดใน reasoning ถ้าหลักฐานก้ำกึ่งให้เขียนระบุทั้งสองด้าน (เช่น "พีคผ่านแล้วแต่กราฟยังชัน") หรือตอบ false ไปเลย — ตั้งใจไม่ห้ามแรงกว่านี้ (เช่น บังคับ false เมื่อไม่แน่ใจ) เพราะจะเสียการแจ้งเตือนล่วงหน้าที่ถูกต้อง (แบบ 13-16/08 ที่เตือน "ใกล้ diacetyl_rest" ตั้งแต่ fg_stable นิ่ง ซึ่งเป็นฟีเจอร์หลัก) — ยืนยันผลจาก Backtest รอบถัดมา (22:12): วันที่ 11/08 หายขัดแย้งแล้ว flag กับ reasoning ไปทางเดียวกัน ("เฟส: active_ferment" ไม่มี "ใกล้" + "ยังไม่เห็นกราฟโค้งผ่อนความชันลง จึงยังไม่เข้า slowing_ferment")

**เพิ่ม `high_krausen` เป็นเฟสที่ 7 + เตือน dry hop ตามแผนสูตร (เพิ่ม 18 ส.ค., task #52)**: ผู้ใช้ต้องการให้ระบบเตือน dry hop — เดิม `high_krausen` เป็นแค่รายการใน `phase_timeline` ไม่ใช่เฟสที่ AI ตอบเป็น `phase` ได้ (จึงไม่มีทางแจ้งเตือนตอนเข้าเฟส) ยกขึ้นเป็นเฟสจริงลำดับที่ 3 (active_ferment → **high_krausen** → slowing_ferment) เพราะสูตรใน Brewfather มีแผน dry hop พร้อมวันระบุอยู่แล้ว (เช่น Hazy DIPA: day 3 = biotransformation charge ซึ่งตรงช่วง high krausen พอดี, day 10 = รอบหลังหมัก) การแก้:
- `Build AI Prompt` (Engine): แยกเกณฑ์ active_ferment (เริ่มแรง ยังไม่ถึงพีค) กับ high_krausen (ช่วงชันสุด+ผลต่างอุณหภูมิกว้างสุด ตอบเฉพาะตอนยังอยู่ในพีคจริง) + อัปเดต JSON schema enum ทั้ง `phase`/`next_phase` + render แผน dry hop จากสูตร (จัดกลุ่มตามวัน) พร้อมคำสั่งให้เตือนใน prep_actions เมื่อใกล้ถึงกำหนดภายใน ~1 วัน
- `Get Latest Readings` (Cron) + `Get Simulated Readings` (Backtest): เพิ่มคอลัมน์ `dry_hop_plan` — subquery จาก `recipes.raw_data->'hops'` เฉพาะ `use ILIKE '%dry%'` (ทดสอบ SQL จริงบน VPS: Hazy DIPA ได้ครบทั้ง 2 รอบ, recipe ที่ไม่มี dry hop ได้ `[]` ไม่พัง)
- กลไกแจ้งเตือนใช้ของเดิมทั้งหมด ไม่มี node ใหม่: "ใกล้ high_krausen" → prep alert (ตัวเตือน dry hop ล่วงหน้า), เข้าเฟสจริง → 🔔 phase change

ข้อจำกัดที่รู้ไว้: high krausen สั้น (~ชม.ถึง 1 วัน) cron 4 รอบ/วันอาจจับ "เข้าเฟสแล้ว" ช้าไปหลาย ชม. แต่ prep alert ล่วงหน้าช่วยชดเชย ทดสอบด้วย Node harness: phase list/schema/dry hop section render ถูกต้อง ทั้งเคสมีและไม่มี dry hop ในสูตร

---

### 8.8 "Error Alert" — แจ้งเตือนเมื่อ workflow พัง (task #53, 19 ส.ค.)

ตลอดที่ผ่านมาทุกบั๊ก production ผู้ใช้เป็นคนเจอเองจาก Discord (ข้อความหาย/ข้อความแปลก) — ระบบไม่เคยบอกเองว่าตัวเองพัง ไฟล์ใหม่ `workflows/Error Alert.json` (3 nodes): `Error Trigger` → `Build Error Message` (Code — ชื่อ workflow, node ที่พัง, error message, execution id, ตัดที่ 1900 ตัวอักษรกันเกินลิมิต Discord) → `Send Error Alert` (HTTP เข้า Discord channel เดิม พร้อม Retry On Fail) — Error Trigger ส่ง 1 item ต่อ 1 execution ที่พังเสมอ `$input.first()` จึงปลอดภัย (มี comment กำกับตามกฎ)

**⚠️ bootstrap หลัง import**: n8n ไม่ได้ผูก error workflow ให้อัตโนมัติ ต้องเปิด **Settings (ของแต่ละ workflow) > Error Workflow** แล้วเลือก "Error Alert" ใน `Phase Analysis Cron`, `Discord Interactions Webhook`, `Sync Devices` เอง (Engine/Backtest ไม่ต้อง — Engine พังจะสะท้อนเป็น Cron พังอยู่แล้ว, Backtest รันมือเห็น error เองในหน้า editor) + เติม id ลง `.allowed-ids` (มี TODO) — การตั้ง Error Workflow ใน UI เป็น setting ที่ reimport อาจทับได้เหมือน workflowId เดิม ถ้า reimport แล้วแจ้งเตือนหาย ให้เช็ค setting นี้ก่อน

**Sensor watchdog (task #54, อยู่ใน `Phase Analysis Cron` ไม่ใช่ไฟล์นี้)**: branch ใหม่ท้ายสุดของ `Get Latest Readings` — `Check Sensor Freshness` (Postgres: อายุ reading ล่าสุดของ Pill/ตู้ควบคุมต่อ batch active) → `Build Sensor Alert` (Code: เฉพาะตัวที่เงียบเกิน **6 ชม.** = ขาดข้อมูลเกิน 1 รอบ cron เต็มๆ ตั้งสูงกัน false positive จากจังหวะ fetch) → `Send Sensor Alert` (HTTP Discord) — ถ้าไม่มีตัวไหนเงียบ Build คืน [] แล้ว HTTP ไม่ยิงอะไรเลย ทดสอบ SQL จริงบน VPS แล้วเจอของจริงทันที: Pill02 (Weizen) เงียบมา 7.2 ชม. ณ เวลาที่ทดสอบ (19 ส.ค. ~00:00)

---

### 8.9 แก้บั๊ก "AI วิเคราะห์ข้อมูลตามหลัง 1 รอบ cron" (task #59, 19 ส.ค.)

**อาการ**: การวิเคราะห์เฟสใช้ข้อมูลเก่ากว่าความจริงถึง ~4 ชม. (1 รอบ cron เต็ม) ทุกครั้ง — กระทบ gating ของ diacetyl_rest/cold_crash โดยตรง เพราะเกณฑ์พวกนี้ตัดสินจาก "อุณหภูมิ Pill ล่าสุด" แต่ค่าที่ AI เห็นไม่ใช่ค่าล่าสุดจริง

**สาเหตุ**: โครงสร้างเดิม `Get Active Batches` แตกเป็น 3 สายขนาน โดย `Get Latest Readings` (อ่าน DB) เป็นสายหนึ่งที่รัน**ก่อน** อีก 2 สายที่ fetch+insert telemetry จะทำงานเสร็จ — snapshot ที่ส่งให้ AI จึงไม่มีข้อมูลที่เพิ่ง insert ในรอบเดียวกันเลย ยืนยันจาก execution 461 จริง (รัน 12:00 น.): `Get Latest Readings` ที่ +1.31s, `Insert Pill Readings` ที่ +2.59s, `Insert Controller Readings` ที่ +5.67s, `Call Phase Analysis` ที่ +6.90s — เทียบข้อมูลจริงพบ Hazy DIPA: AI เห็นถึง 07:52 แต่รอบนั้น insert ถึง 11:53 = **หายไป 4.0 ชม.พอดี** (Weizen ไม่เห็น gap เพราะ Pill02 offline อยู่ ไม่มีข้อมูลใหม่ให้ตกหล่นตั้งแต่แรก)

**การแก้**: เปลี่ยนจาก 3 สายขนานเป็น**สายเดียวเรียงลำดับ** ให้ DB read เกิดหลัง insert เสร็จทั้งคู่ (ดูผังใน 8.3) — เช็คแล้วว่า `Get Latest Readings` ต้องการเฉพาะ field ที่ `Get Active Batches` มีครบอยู่แล้ว จึงย้ายได้โดยไม่ต้องแก้ SQL เลย เพิ่ม Code node `Reload Batches` / `Reload Batches 2` (`return $('Get Active Batches').all()...`) คั่นหลัง INSERT แต่ละตัวเพื่อกู้ item context กลับมา — จำเป็นเพราะ Postgres INSERT ที่ไม่มี `RETURNING` จะทับ `$json` ด้วยผลลัพธ์เปล่าและทำให้ pairedItem หลุด (บั๊กที่เคยเจอในข้อ 8.3) การอ้าง `$('Get Active Batches').all()` ตรงๆ ปลอดภัยเพราะอ้างอิงด้วยชื่อ node ไม่พึ่ง pairedItem และได้ item ครบทุก batch เรียงลำดับเดิมเสมอ พร้อมกันนั้น `Format Pill/Controller Readings` ต้องเปลี่ยน node ที่อ้างอิง (จาก `Get Latest Readings` ที่ย้ายไปอยู่ท้ายสุดแล้ว) เป็นต้นทาง item ของ telemetry node ที่ต่อตรงเข้ามา: `Format Pill Readings` → `$('Get Active Batches').itemMatching(idx)`, `Format Controller Readings` → `$('Reload Batches').itemMatching(idx)`

**⚠️ บั๊กที่ทำพังระหว่างแก้ (แก้แล้ว, บันทึกไว้กันซ้ำ)**: ตอนแรกเปลี่ยน `Format Pill/Controller Readings` เป็น `$('Get Active Batches').all()[idx]` (index ตรงๆ) ด้วยเหตุผลว่าจะได้ไม่ต้องพึ่ง pairedItem ที่เคยเปราะ — **ผิดทันทีและ production พังรอบถัดไป** (`TypeError: Cannot read properties of undefined (reading 'json')` ที่ `Format Pill Readings`) เพราะ **HTTP telemetry node กระจาย array response ออกเป็น 1 item ต่อ 1 reading ไม่ใช่ต่อ 1 batch** — execution จริงเห็น `Get Active Batches` ออก 2 items แต่ `Get Pill Telemetry` ออก **1,069 items** พอ `idx` เกิน 2 ก็ได้ `undefined` ทันที `itemMatching` จึงไม่ใช่ของฟุ่มเฟือยตรงนี้ แต่เป็นกลไกที่ map แต่ละ reading กลับไปหา batch ต้นทางที่ถูกตัว (ทดสอบ harness จำลอง fan-out 1,069 items จาก 2 batch ยืนยัน mapping ถูกต้อง 600/469 ไม่มี undefined ไม่สลับ batch) — **บทเรียน: ห้ามสมมติว่า item count ของ node ปลายทางเท่ากับต้นทาง โดยเฉพาะหลัง HTTP node ที่ตอบ array**

ทดสอบด้วย Node harness จำลอง 2 batch พร้อมกัน ยืนยัน `device_id`/`paired_temp_controller` ของแต่ละ reading ผูกกับ batch ที่ถูกต้อง ไม่สลับกัน + ตรวจอัตโนมัติทุก `$('...')` reference ในไฟล์ว่าชี้ไป node ที่รันก่อนหน้าเสมอตามลำดับใหม่

**เจอเพิ่มระหว่างตรวจ (ยังไม่แก้)**: `Get Pill/Controller Telemetry` อ่าน `$json.pill_time_utc`/`controller_time_utc` เพื่อดึงเฉพาะข้อมูลใหม่ (adaptive fetch ตามที่ 8.3 เคยระบุ) แต่ `Get Latest Readings` **ไม่เคย return field พวกนี้** → เป็น `undefined` เสมอ → fallback ไปใช้ `start_date` ทุกครั้ง = ดึงประวัติทั้ง batch ใหม่หมดทุกรอบแล้ว insert ทับ (รอบที่ตรวจได้ 1,064 จุด ตั้งแต่วันเริ่ม batch) ยังทำงานถูกเพราะ insert เป็น idempotent แต่เปลือง RAPT API/DB และจะแย่ลงตามอายุ batch — แยกเป็นงานถัดไป

---

## 9. กรอบ 7 เฟสการหมัก (ใช้เป็น prompt ให้ AI จำแนก)

อ้างอิงจาก BJCP Yeast & Fermentation guide, John Palmer "How to Brew", Brew Your Own Fermentation Timeline, และเอกสาร RAPT เอง (ไม่ได้อ้างอิงจากประสบการณ์ทำเบียร์ก่อนหน้าของโปรเจกต์นี้ — ตั้งใจ research จากแหล่งกลางเพื่อความแม่นยำ)

1. **lag** — 0-24 ชม.แรกหลัง pitch ยีสต์ปรับตัว ยังไม่มี krausen ชัดเจน gravity แทบไม่ขยับ (apparent attenuation ~0%) แทบไม่มีผลต่างอุณหภูมิ pill-ตู้ควบคุม
2. **active_ferment** — วันที่ 1-4 การหมักเริ่มแรงชัดเจน gravity เริ่มลาดลงต่อเนื่องแต่ยังไม่ถึงช่วงชันสุด, apparent attenuation เริ่มไต่ขึ้น, pill เริ่มอุ่นกว่าตู้ควบคุมจากปฏิกิริยาคายความร้อน (exothermic)
3. **high_krausen** — ช่วงพีคของการหมัก (มักอยู่ใน 48-72 ชม.แรก) gravity ลดเร็ว**ที่สุด**ของทั้งเส้น ผลต่างอุณหภูมิ pill-ตู้ควบคุมกว้างสุด (2-5°C) — เดิมเป็นแค่รายการใน phase_timeline ยกขึ้นเป็นเฟสจริง 18 ส.ค. (task #52) เพื่อใช้เตือน dry hop รอบ biotransformation (day 2-3 ตามสูตร) — AI ตอบเฟสนี้เฉพาะตอนที่ยังอยู่ในช่วงชันสุดจริง ถ้าพีคผ่านแล้วเป็น slowing_ferment
4. **slowing_ferment** — krausen เริ่มยุบ อัตราลด gravity ผ่อนลงจากจุดสูงสุดแต่ยัง "ลบชัดเจน" attenuation มักอยู่แถว 60-80% แล้วแต่ยังไม่นิ่ง ผลต่างอุณหภูมิ pill-ตู้ควบคุมเริ่มแคบลง
5. **fg_stable** — gravity velocity ใกล้ 0 ต่อเนื่อง 24-48 ชม. (RAPT เองแนะนำให้เริ่ม cold crash ได้เมื่อ velocity แตะ 0) attenuation ควรอยู่ 65-80% ตามเกณฑ์ BJCP ผลต่างอุณหภูมิ pill-ตู้ควบคุมควรใกล้ 0 — ⚠️ ถ้านิ่งเร็วผิดปกติหรือ attenuation ต่ำกว่า ~60% ให้สงสัยว่าเป็น stuck fermentation
6. **diacetyl_rest** — ต้องผ่าน fg_stable ก่อน แล้วยกอุณหภูมิตู้ควบคุมเป็น 16-18°C ค้าง 2-3 วัน (จำเป็นสำหรับ lager, แนะนำสำหรับ ale ส่วนใหญ่)
7. **cold_crash** — ต้องผ่าน fg_stable (และปกติ diacetyl_rest) ก่อน แล้วลดอุณหภูมิตู้ควบคุมเหลือ 0-4°C ค้าง 1-3 วัน (ale ~1-2 วัน, lager ~2-3 วัน)

---

## 10. Task list สถานะล่าสุด

- #27 สร้างตาราง Postgres — ✅ เสร็จ (7 ตารางครบ, `bot_state` เพิ่งสร้างจริง 15 ส.ค. ดูข้อ 5)
- #28 ตั้งค่า Discord bot — ✅ เสร็จ
- #29 ใส่ credential ใน n8n — ✅ เสร็จ
- #30 workflow sync devices — ✅ เสร็จ ทดสอบผ่าน
- #31 workflow Discord command intake — 🔴 เลิกใช้แล้ว (unpublish 15 ส.ค.) ถูกแทนที่ด้วย #35 — ดูข้อ 8.2
- #32 workflow cron วิเคราะห์เฟส — ✅ เสร็จ ทดสอบผ่าน + **publish/active จริงแล้ว** (เพิ่งพบว่าไม่เคย publish มาก่อน แก้ 15 ส.ค.)
- #33 workflow รับคำสั่งปรับอุณหภูมิ (`/ferment_set_temp` + remark เข้า AI prompt) — 🟡 สร้างเสร็จ รอทดสอบจริง — 16 ส.ค.
- #34 ทดสอบระบบจริงกับ Pill01/Pill02 — 🟡 DB เพิ่งเคลียร์ล่าสุด 15 ส.ค. รอผู้ใช้เริ่มลงทะเบียน batch ใหม่ผ่าน `/ferment_start`
- #35 Discord slash command (`/ferment_start`, `/ferment_stop`) — ✅ เสร็จ ทดสอบผ่าน — 15 ส.ค.
- #36 `/ferment_status` + auto-resolve controller จาก RAPT pairing — ✅ เสร็จ ทดสอบผ่าน — 15 ส.ค.
- #37 Brewfather recipes/yeasts cache (`Sync Devices` เพิ่ม fetch, `/ferment_start` param `recipe`) — 🟡 สร้างเสร็จ ทดสอบ SQL/API จริงแล้ว รอ reimport + ทดสอบผ่าน Discord จริง — 18 ส.ค.
- #38 แนะนำ target ตู้ควบคุมจากแผน recipe + ปุ่ม Discord ยืนยันปรับอุณหภูมิจริง — 🟡 สร้างเสร็จ ทดสอบ SQL/logic/payload ครบแล้ว เจอ+แก้บั๊ก ordering/format/retry/deactivate-reactivate ครบแล้ว รอกดปุ่มจริงยืนยันรอบสุดท้ายหลัง reimport+reactivate — 18 ส.ค.
- #39 `/ferment_recipes` list ชื่อ recipe จาก Brewfather cache พร้อม search — 🟡 สร้างเสร็จ ทดสอบ SQL จริงบน VPS แล้ว รอ reimport (ทั้ง `Register Slash Commands` รันใหม่ + `Discord Interactions Webhook` reimport แล้ว **Deactivate/Activate ใหม่**) — 18 ส.ค.
- #40 Autocomplete `/ferment_start recipe` (dropdown ดึงจาก DB สดๆ) — 🟡 สร้างเสร็จ ทดสอบ SQL/logic จริงแล้ว รอ reimport ทั้งสองไฟล์ + **Deactivate/Activate ใหม่** — 18 ส.ค.
- #41 `Phase Analysis Backtest` เครื่องมือจำลองวิเคราะห์ทีละวัน — 🟡 สร้างเสร็จ ทดสอบ pipeline เต็มด้วยข้อมูลจริง (ยกเว้นยิง Claude API จริง) รอ import + รันมือครั้งแรก — 18 ส.ค.
- #42 ประมาณเวลาที่จะถึง target แนะนำ (ETA จากอัตราไต่อุณหภูมิ Pill 6 ชม.ล่าสุด) — ✅ เสร็จ ทดสอบผ่านจริง (ยิงขึ้น Discord จริงแล้ว) — 18 ส.ค.
- #43 `Phase Analysis Engine` sub-workflow กลาง (ย้าย `Build AI Prompt`/`Call Claude`/`Parse AI Response` ออกจาก Cron/Backtest มาไว้ที่เดียว) — ✅ เสร็จ bootstrap + ทดสอบผ่านจริงบน VPS แล้ว (ยืนยันจาก execution log) — 18 ส.ค.
- #44 แก้บั๊ก Claude เขียนคำอธิบายนำหน้า JSON ทำให้ parse พัง (`Parse AI Response`/`Parse Status Analysis`) — ✅ เสร็จ ทดสอบด้วย raw response จริงที่เคยพัง ยืนยัน parse ผ่านครบทุก field แล้ว รอ reimport `Phase Analysis Engine` + `Discord Interactions Webhook` — 18 ส.ค.
- #45 แก้บั๊ก Discord rate limit (429) ตอนมีข้อความสะสมหลายชิ้น (`Send Routine Update`/`Send Test Update`) — ✅ เสร็จ เพิ่ม batchInterval 1100ms + Retry On Fail แล้ว รอ reimport `Phase Analysis Cron` + `Phase Analysis Backtest` — 18 ส.ค.
- #46 แก้ prompt: คำแนะนำ target ขัดแย้งกับคำแนะนำให้รอ + phase misclassification (`next_phase == phase`, cold_crash ตัดสินจาก target แทน Pill) — ✅ เสร็จ ทดสอบ syntax แล้ว รอผลจริงหลัง reimport `Phase Analysis Engine` — 18 ส.ค.
- #47 ลด prompt size ~54% (ย่อ timestamp/ทศนิยม + ไม่พิมพ์ target ซ้ำ, ไม่ downsample ข้อมูล เก็บทุกจุดครบ) — ✅ เสร็จ ยืนยันผลจริงบน production แล้ว (execution 436: 74,490 ตัวอักษร 2 batch, ลด ~53%, parse ผ่านสะอาด) — 18 ส.ค.
- #48 เพิ่ม code-level guard ใน `Parse AI Response` (next_phase==phase → null, target ต่างจากปัจจุบัน <2.5°C → ไม่แนะนำ) หลังพบ AI ฝ่าฝืน prompt logic แม้แก้ prompt แล้ว — ✅ เสร็จ ทดสอบด้วยข้อมูลจริงจาก execution 436 ทั้งเคสบั๊ก (suppress ถูกต้อง) และเคสบวก (ไม่ over-suppress) รอ reimport `Phase Analysis Engine` — 18 ส.ค.
- #49 `/ferment_status` เปลี่ยนไปเรียก `Phase Analysis Engine` แทนสำเนา logic ของตัวเอง (ตัด 5 node, ลด token 54% อัตโนมัติ, เลิกเขียน DB ทุกครั้งที่กดดู) + ลด `max_tokens` ของ `Call Claude` เหลือ 4096 — ✅ เสร็จ ทดสอบด้วย Node harness แล้ว รอ reimport `Phase Analysis Engine` + `Discord Interactions Webhook` แล้ว **Deactivate/Activate ใหม่** (โครงสร้าง node เปลี่ยน) — 18 ส.ค.
- #50 downsample กราฟแบบ delta+heartbeat (SG≥0.001/temp≥0.2°C/heartbeat 3 ชม./เต็มความละเอียด 6 ชม.ล่าสุด) — ✅ เสร็จ ยืนยันผลจริงครบทั้ง token (execution 447: input เหลือ 10,761/9,635 tokens ต่อ batch, ลด ~73-84%) และคุณภาพ (Backtest 9 วันจำลอง phase progression ต่อเนื่องสมเหตุสมผลตลอดเส้น lag→active→slowing→fg_stable→d-rest→ใกล้ cold_crash, จับ sensor spike ได้เอง, guard 2.5°C กันปุ่มมั่วได้ทุกวัน) — 18 ส.ค.
- #51 เพิ่มกฎ prompt: reasoning กับ approaching_transition ต้องสอดคล้องกัน (ห้าม flag true พร้อมเขียนปฏิเสธเด็ดขาดว่ายังไม่มีสัญญาณ) — พบจาก Backtest 11/08 ตอบ "ใกล้ slowing_ferment" แต่ reasoning ข้อสุดท้ายเขียน "ยังไม่มีสัญญาณกราฟแบนหรือชะลอ" ขัดกันเอง (การตัดสินอาจถูก เพราะ bullet อื่นบอกพีคผ่านแล้ว แต่ข้อความตีกันทำให้คนอ่านงง) — ✅ เสร็จ ยืนยันผลจริงจาก Backtest รอบถัดมา (11/08 หายขัดแย้ง flag กับ reasoning ไปทางเดียวกัน) — 18 ส.ค.
- #52 เพิ่ม `high_krausen` เป็นเฟสที่ 7 + เตือน dry hop ตามแผนสูตร Brewfather (`dry_hop_plan` จาก raw_data->hops เข้า prompt, prep alert "ใกล้ high_krausen" = ตัวเตือน dry hop biotransformation) — ✅ เสร็จ ทดสอบ SQL จริงบน VPS + Node harness ครบ รอ reimport `Phase Analysis Engine` + `Phase Analysis Cron` + `Phase Analysis Backtest` (SQL เปลี่ยนทั้ง 3 ไฟล์) — 18 ส.ค.
- #53 workflow `Error Alert` — ดัก execution ที่ fail จากทุก workflow (n8n Error Trigger) แจ้ง Discord ทันที เลิกพึ่งผู้ใช้สังเกตเองว่าข้อความหาย — 🟡 สร้างเสร็จ รอ import ครั้งแรก + ตั้ง Settings > Error Workflow ของ workflow หลักทั้ง 3 ตัวให้ชี้มา + เติม id ใน `.allowed-ids` (มี TODO) — 19 ส.ค.
- #54 sensor watchdog ใน `Phase Analysis Cron` — เช็คอายุ reading ล่าสุดของ Pill/ตู้ควบคุมทุก batch active หลัง insert telemetry (threshold 6 ชม. = ขาดเกิน 1 รอบ cron) แจ้ง Discord ถ้าเซ็นเซอร์เงียบ — ✅ เสร็จ ทดสอบ SQL จริง (เจอจริงทันที: Pill02/Weizen เงียบ 7.2 ชม. ณ ตอนทดสอบ) รอ reimport — 19 ส.ค.
- #55 `batch_ready_to_package` — AI ตอบ field ใหม่เมื่อ cold_crash ครบช่วงตามเกณฑ์ → ข้อความ "🎉 พร้อมบรรจุ + สั่ง /ferment_stop" ใน routine update (มี code guard บังคับ false ถ้า phase ไม่ใช่ cold_crash) — ✅ เสร็จ ทดสอบ harness 3 เคสผ่าน รอ reimport `Phase Analysis Engine` + `Phase Analysis Cron` + `Phase Analysis Backtest` — 19 ส.ค.
- #56 batch summary ตอน `/ferment_stop` — `Stop Batch` เปลี่ยนเป็น UPDATE+summary query เดียว (OG→FG, ABV, จำนวนวัน, ไทม์ไลน์เฟสจาก phase_log, จำนวนปรับ target) + แจ้ง "ไม่พบ batch active" ถ้าไม่มีอะไรให้หยุด (เดิมตอบว่าหยุดแล้วเสมอแม้ไม่มี batch) — ✅ เสร็จ ทดสอบ SQL จริงผ่าน transaction rollback รอ reimport `Discord Interactions Webhook` + Deactivate/Activate — 19 ส.ค.
- #57 กันสร้าง batch ซ้ำ — `/ferment_start` กับ Pill ที่มี batch active อยู่แล้วจะไม่ insert แต่เตือนพร้อมชื่อ/วันเริ่มของ batch เดิม (เคยเกิดจริง: Hazy DIPA ถูก start ซ้ำ 18 ส.ค.) — ✅ เสร็จ ทดสอบ SQL จริงผ่าน rollback (Pill01 ติด Hazy DIPA → ไม่ insert + คืนข้อมูล batch เดิมถูกต้อง) รอ reimport `Discord Interactions Webhook` + Deactivate/Activate — 19 ส.ค.
- #58 sync ค่า Backtest ที่แก้ manual ในหน้า editor กลับเข้าไฟล์ (BATCH_ID 1→2 ตาม live n8n, comment ที่ล้าสมัยแก้แล้ว) + เพิ่มชื่อ batch ใน header ข้อความ TEST BACKTEST กันสับสนว่ากำลัง test batch ไหน + เติม id `Lm8O1NyDrB3gnwXf` ของ Backtest ลง `.allowed-ids` — ✅ เสร็จ — 19 ส.ค.
- #59 แก้บั๊ก AI วิเคราะห์ข้อมูลตามหลัง 1 รอบ cron (~4 ชม.) — เปลี่ยน `Phase Analysis Cron` จาก 3 สายขนานเป็นสายเดียวเรียงลำดับ ให้ `Get Latest Readings` อ่าน DB หลัง insert telemetry เสร็จ + เพิ่ม `Reload Batches` กู้ item context หลัง INSERT — ✅ เสร็จ ยืนยันบั๊กจาก execution 461 จริง (Hazy DIPA หายไป 4.0 ชม.พอดี) **เจอบั๊กซ้อนตอน deploy: เผลอเปลี่ยน `Format Pill/Controller Readings` เป็น index ตรงๆ แล้วพัง (HTTP node กระจาย 1,069 items ไม่ใช่ 2) แก้กลับเป็น itemMatching ชี้ต้นทางที่ถูกแล้ว** รอ reimport `Phase Analysis Cron` — 19 ส.ค.
- #60 (ค้าง) telemetry ดึงประวัติทั้ง batch ใหม่ทุกรอบ — `$json.pill_time_utc`/`controller_time_utc` เป็น undefined เสมอเพราะ `Get Latest Readings` ไม่ return field นี้ ทำให้ adaptive fetch ไม่ทำงานจริง fallback ไป `start_date` ตลอด (พบ 1,064 จุด/รอบ) ยังทำงานถูกเพราะ insert idempotent แต่เปลือง API/DB และแย่ลงตามอายุ batch — 🔵 ยังไม่แก้ พบ 19 ส.ค.

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
- `schema.sql` — DDL 9 ตารางครบ รันได้เลย (มี index ของ readings + seed `bot_state`)
- `er-diagram.mermaid` — ER diagram schema เต็ม
- `backup-workflows.sh` — export workflow จาก n8n ลง `workflows/` แล้ว commit ให้ (ดูข้อ 13)
- `clear-data.sh` — เคลียร์ข้อมูลทดสอบทั้งหมดใน Postgres กลับเป็น DB ว่างเปล่า (ใช้ระหว่าง dev/test เท่านั้น) รันจากเครื่อง **local** ได้เลย (`./clear-data.sh` — ssh ไปเคลียร์บน VPS ให้ ผ่าน ssh host `ferment-vps`, ถามยืนยันก่อนเสมอ นอกจากใส่ `--yes`) หรือรันตรงบน VPS เองก็ได้ด้วย `--local` — **ไม่แตะ `recipes`/`yeasts`** โดย default (ข้อมูลอ้างอิงจาก Brewfather ไม่ใช่ข้อมูลทดสอบต่อรอบ) ใส่ `--with-recipes` ถ้าต้องการเคลียร์ด้วยจริงๆ
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
4. **"Phase Analysis Cron" รันอัตโนมัติวันละ 4 รอบอยู่แล้ว** (08:00/12:00/16:00/20:00 เวลาไทย, publish/active แล้ว) ไม่ต้องทำอะไรเพิ่ม รอบแรกอาจจำแนกเป็น `lag` หรือ apparent attenuation ไม่แม่นยำนักถ้าเพิ่งเริ่มเก็บ telemetry (ดูหมายเหตุ OG proxy ในข้อ 8.3) จะแม่นขึ้นเมื่อมีข้อมูลสะสมข้าม cycle
5. **เช็คสถานะได้ทุกเมื่อ**: พิมพ์ `/ferment_status pill:Pill01` (ใส่ชื่อ Pill ไม่ใช่ชื่อเบียร์) จะได้ผลวิเคราะห์ล่าสุดจาก cron รอบที่ผ่านมา (เฟส, gravity, อุณหภูมิ, เหตุผลจาก AI) โดยไม่ต้องรอ alert
6. **หยุด batch เมื่อหมักเสร็จ**: พิมพ์ `/ferment_stop pill:Pill01`

> `!ferment start/stop` แบบ text (ข้อ 8.2) **เลิกใช้แล้ว** ให้ใช้ `/ferment_start`/`/ferment_stop`/`/ferment_status` เท่านั้น
