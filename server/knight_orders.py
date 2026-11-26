"""Knight's LAN test-order API. Runs independently of the HUD and workspace servers."""

import argparse
import base64
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
from functools import partial
import hmac
from http import HTTPStatus as Status
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import sqlite3
import subprocess
import time
import unicodedata
from tempfile import TemporaryDirectory
from threading import Event, Lock, Thread
from urllib.parse import urlsplit
from urllib.request import Request, build_opener
from uuid import uuid4

import knight_delivery as delivery


STATE_DIR = Path.home() / '.local/share/knight-orders'
MENU = {'hot-americano': ('驿站热美式', 1600)}
REQUEST_ID = re.compile(r'[a-zA-Z0-9_-]{16,80}')
INTENT_PATH = re.compile(r'/api/orders/intents/([a-f0-9]{32})/decision')
CYCLING_ROUTE_PATH = re.compile(r'/api/cycling/routes/([a-f0-9]{32})')
CYCLING_RESULT_PATH = re.compile(r'/api/cycling/routes/([a-f0-9]{32})/result')
CYCLING_HOLD_PICKUPS_PATH = re.compile(r'/api/cycling/routes/([a-f0-9]{32})/hold-pickups')
CYCLING_QUEUE_SECONDS = 90
CYCLING_START_SECONDS = 100
MAX_BODY = 4096
MAX_VOICE_AUDIO = 128 * 1024
VOICE_FEEDBACK_WAIT = 55
ORDER_VIEW = '''SELECT i.id, i.sku, i.item, i.quantity, i.unit_cents, i.state,
                       i.created_at, o.number AS order_number
                FROM intents i LEFT JOIN orders o ON o.intent_id = i.id'''


class APIError(Exception):
    def __init__(self, status, code):
        super().__init__(code)
        self.status = status
        self.code = code


def ai_pickup_fields(base, model, key, item, store):
    # The model edits the presentation order only. The server inserts the verified facts.
    content = {
        'model': model, 'temperature': 0, 'max_tokens': 100,
        'response_format': {'type': 'json_object'},
        'messages': [
            {'role': 'system', 'content': (
                '编排一条简洁的中文自提语音回执。只输出 JSON 对象，fields 数组包含字段的念出顺序。'
                '示例：{"fields":["store","item","quantity","total"]}。'
                'store、item、quantity、total 必须各出现一次，pickup_address 可选。'
                '把商品型号与规格合在 item 中处理。不要输出原文字段的值或其它内容。'
            )},
            {'role': 'user', 'content': json.dumps({'item': item, 'store': store}, ensure_ascii=False)},
        ],
    }
    if model.lower().startswith('deepseek-'):
        content['thinking'] = {'type': 'disabled'}
    try:
        request = Request(base + '/chat/completions', data=json.dumps(content).encode(),
                          headers={'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json'})
        with build_opener(delivery.NoRedirect()).open(request, timeout=8) as response:
            model_output = json.load(response)['choices'][0]['message']['content']
        model_output = model_output.strip()
        if model_output.startswith('```') and model_output.endswith('```'):
            model_output = '\n'.join(model_output.splitlines()[1:-1])
        order = json.loads(model_output)['fields']
        if not isinstance(order, list) or not all(isinstance(field, str) for field in order):
            return None
        allowed = set(delivery.PICKUP_SUMMARY_FIELDS)
        if len(order) == len(set(order)) and allowed - {'pickup_address'} <= set(order) <= allowed:
            return tuple(order)
    except (OSError, ValueError, TypeError, KeyError, IndexError, AttributeError):
        pass
    return None


def pickup_summarizer(path):
    if path is None:
        return None
    try:
        lines = path.read_text(encoding='utf-8').splitlines()
    except OSError:
        return None
    config = {key.strip(): value.strip() for key, value in
              (line.split('=', 1) for line in lines if '=' in line and not line.lstrip().startswith('#'))}
    base = config.get('LLM_BASE_URL', '').strip().rstrip('/')
    key = config.get('LLM_API_KEY', '').strip()
    model = config.get('LLM_MODEL', '').strip()
    if urlsplit(base).scheme != 'https' or not key or not model:
        return None
    invoke = partial(ai_pickup_fields, base if base.endswith('/v1') else base + '/v1', model, key)
    return invoke


def synthesize_feedback(text):
    ffmpeg = shutil.which('ffmpeg', path=os.defpath + ':/opt/homebrew/bin:/usr/local/bin')
    if not ffmpeg:
        raise APIError(Status.SERVICE_UNAVAILABLE, 'feedback_audio_unavailable')
    try:
        with TemporaryDirectory(prefix='knight-feedback-') as directory:
            wave = Path(directory) / 'feedback.aiff'
            subprocess.run(['/usr/bin/say', '-v', 'Tingting', '-o', str(wave), '--', text],
                           check=True, capture_output=True, timeout=12)
            audio = subprocess.run(
                [ffmpeg, '-hide_banner', '-loglevel', 'error', '-i', str(wave), '-map_metadata', '-1',
                 '-ar', '16000', '-ac', '1', '-c:a', 'libopus', '-b:a', '12k', '-frame_duration', '60',
                 '-f', 'ogg', 'pipe:1'],
                check=True, capture_output=True, timeout=8,
            ).stdout
        if not audio.startswith(b'OggS') or len(audio) >= MAX_VOICE_AUDIO:
            raise ValueError('invalid feedback audio')
        return audio
    except (OSError, subprocess.SubprocessError, ValueError) as error:
        raise APIError(Status.SERVICE_UNAVAILABLE, 'feedback_audio_unavailable') from error


def database(path):
    connection = sqlite3.connect(path, timeout=5, isolation_level='IMMEDIATE')
    connection.execute('PRAGMA foreign_keys = ON')
    connection.row_factory = sqlite3.Row
    return connection


def initialize(path):
    with closing(database(path)) as db:
        db.execute('PRAGMA journal_mode = WAL')
        db.executescript('''
            CREATE TABLE IF NOT EXISTS intents (
                id TEXT PRIMARY KEY, request_id TEXT NOT NULL UNIQUE,
                sku TEXT NOT NULL, item TEXT NOT NULL, quantity INTEGER NOT NULL,
                unit_cents INTEGER NOT NULL,
                state TEXT NOT NULL CHECK (state IN ('pending', 'confirmed', 'cancelled')),
                created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            );
            CREATE TABLE IF NOT EXISTS orders (
                intent_id TEXT PRIMARY KEY REFERENCES intents(id), number TEXT NOT NULL UNIQUE
            );
            CREATE TABLE IF NOT EXISTS cycling_routes (
                id TEXT PRIMARY KEY, request_id TEXT NOT NULL UNIQUE,
                destination TEXT NOT NULL, city TEXT NOT NULL, district TEXT NOT NULL,
                state TEXT NOT NULL, expires_at INTEGER NOT NULL,
                lease TEXT, note TEXT NOT NULL DEFAULT '', updated_at INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS recommendations (
                id TEXT PRIMARY KEY, request_id TEXT NOT NULL UNIQUE,
                category TEXT NOT NULL, city TEXT NOT NULL, district TEXT NOT NULL, destination TEXT NOT NULL,
                state TEXT NOT NULL, lease TEXT, expires_at INTEGER NOT NULL,
                store TEXT NOT NULL DEFAULT '', address TEXT NOT NULL DEFAULT '',
                dishes TEXT NOT NULL DEFAULT '[]', note TEXT NOT NULL DEFAULT ''
            );
        ''')
        with db:
            db.execute('BEGIN IMMEDIATE')
            delivery.initialize(db)


def order_view(db, intent_id):
    row = dict(db.execute(ORDER_VIEW + ' WHERE i.id = ?', (intent_id,)).fetchone())
    row['total_cents'] = row['quantity'] * row['unit_cents']
    return row


def cycling_text(body, field, limit, required=False):
    value = body.get(field, '')
    if not isinstance(value, str) or len(value) > limit or any(ord(char) < 32 or ord(char) == 127 for char in value):
        raise APIError(Status.BAD_REQUEST, 'invalid_cycling_route')
    value = value.strip()
    if required and not value:
        raise APIError(Status.BAD_REQUEST, 'invalid_cycling_route')
    return value


def expire_cycling_routes(db, now):
    db.execute("""UPDATE cycling_routes SET state='expired', note='导航任务已过期', updated_at=?
                  WHERE state IN ('queued', 'starting') AND expires_at<=?""", (now, now))
    resume_paused_deliveries(db, now)


def resume_paused_deliveries(db, now):
    db.execute("""UPDATE delivery_tasks SET state='queued', paused_for_route=NULL, phone_lease=NULL,
                  note='导航已结束，正在自动续办点单', rescheduled_at=?, updated_at=?
                  WHERE state='paused' AND paused_for_route IN
                  (SELECT id FROM cycling_routes WHERE state IN ('failed','ended','expired'))""", (now, now))


def pending_cycling_route(db):
    with db:
        expire_cycling_routes(db, int(time.time()))
        row = db.execute("SELECT id FROM cycling_routes WHERE state='queued' ORDER BY rowid LIMIT 1").fetchone()
        return (Status.OK, {'id': row['id']}) if row else (Status.NO_CONTENT, None)


def hold_pickups_for_cycling(db, route_id, body):
    lease = cycling_text(body, 'lease', 80, required=True)
    if not REQUEST_ID.fullmatch(lease):
        raise APIError(Status.BAD_REQUEST, 'invalid_cycling_lease')
    now = int(time.time())
    with db:
        db.execute('BEGIN IMMEDIATE')
        route = db.execute("SELECT state,lease FROM cycling_routes WHERE id=?", (route_id,)).fetchone()
        if not route or route['lease'] != lease or route['state'] != 'active':
            return Status.NO_CONTENT, None
        db.execute("""UPDATE delivery_tasks SET state='paused', paused_for_route=?, updated_at=?,
                      note='导航中，结束后自动续办点单'
                      WHERE state='queued' AND pickup_destination<>''
                        AND COALESCE(NULLIF(rescheduled_at,0),created_at)>?""",
                   (route_id, now, now - delivery.MAX_AGE))
        return Status.NO_CONTENT, None


def navigation_speech_packet(body, device_key):
    session = cycling_text(body, 'session', 32, required=True)
    kind = body.get('kind')
    sequence = body.get('sequence')
    modes = {'start': b'S', 'keep': b'H', 'step': b'G', 'end': b'E'}
    if (not re.fullmatch(r'[a-f0-9]{32}', session) or not isinstance(kind, str) or kind not in modes or
            type(sequence) is not int or not 0 <= sequence <= 0xffffffff):
        raise APIError(Status.BAD_REQUEST, 'invalid_navigation_speech')
    text = ''
    if kind == 'step':
        turn = cycling_text(body, 'turn', 16, required=True)
        distance = cycling_text(body, 'distance', 12, required=True)
        directions = {'左转', '右转', '向左前', '向右前', '向左后', '向右后', '掉头', '直行',
                      '进环岛', '环岛左转', '环岛右转', '环岛直行', '环岛掉头', '出环岛',
                      '走天桥', '走地下通道', '到达终点', '按路线'}
        if turn not in directions or not re.fullmatch(r'(?:[0-9]{1,3}米|[0-9]{1,4}\.[0-9]公里)', distance):
            raise APIError(Status.BAD_REQUEST, 'invalid_navigation_instruction')
        text = f'前方{distance}，{turn}。'
    elif kind == 'end' and body.get('arrived') is True:
        text = '已到达骑行目的地。'
    expires = int(time.time()) + 12
    payload = b'N1' + session.encode('ascii') + expires.to_bytes(4, 'big')
    payload += modes[kind] + f'{sequence:08x}'.encode('ascii') + text.encode('utf-8')
    signed = payload + hmac.digest(device_key, payload, 'sha256')
    return Status.OK, {'packet': base64.b64encode(signed).decode('ascii'), 'expires_at': expires}


def enqueue_recommendation(db, body):
    request_id = cycling_text(body, 'request_id', 80, required=True)
    category = cycling_text(body, 'category', 32, required=True)
    city = cycling_text(body, 'city', 32, required=True)
    district = cycling_text(body, 'district', 32)
    destination = cycling_destination(cycling_text(body, 'destination', 96, required=True))
    if not REQUEST_ID.fullmatch(request_id):
        raise APIError(Status.BAD_REQUEST, 'invalid_recommendation_request')
    with db:
        db.execute('BEGIN IMMEDIATE')
        existing = db.execute('SELECT * FROM recommendations WHERE request_id=?', (request_id,)).fetchone()
        if existing:
            if tuple(existing[key] for key in ('category', 'city', 'district', 'destination')) != (
                    category, city, district, destination):
                raise APIError(Status.CONFLICT, 'recommendation_request_id_conflict')
            return Status.OK, {'id': existing['id']}
        job_id = uuid4().hex
        db.execute('''INSERT INTO recommendations (id,request_id,category,city,district,destination,state,expires_at)
                      VALUES (?,?,?,?,?,?,'queued',?)''',
                   (job_id, request_id, category, city, district, destination, int(time.time()) + 90))
        return Status.CREATED, {'id': job_id}


def claim_recommendation(db, body):
    lease = cycling_text(body, 'lease', 80, required=True)
    if not REQUEST_ID.fullmatch(lease):
        raise APIError(Status.BAD_REQUEST, 'invalid_recommendation_lease')
    now = int(time.time())
    with db:
        db.execute('BEGIN IMMEDIATE')
        row = db.execute("""SELECT id,category,city,district,destination,state,lease FROM recommendations
                            WHERE state IN ('queued','searching') AND expires_at>? ORDER BY rowid LIMIT 1""",
                         (now,)).fetchone()
        if not row or (row['state'] == 'searching' and row['lease'] != lease):
            return Status.NO_CONTENT, None
        if row['state'] == 'queued':
            db.execute("UPDATE recommendations SET state='searching',lease=?,expires_at=? WHERE id=?",
                       (lease, now + 120, row['id']))
        return Status.OK, {key: row[key] for key in ('id', 'category', 'city', 'district', 'destination')}


def finish_recommendation(db, body, device_key):
    job_id = cycling_text(body, 'id', 32, required=True)
    lease = cycling_text(body, 'lease', 80, required=True)
    store = cycling_text(body, 'store', 96)
    address = cycling_text(body, 'address', 150)
    note = cycling_text(body, 'note', 170)
    shown = body.get('shown')
    dishes = body.get('dishes', [])
    if (type(shown) is not bool or not isinstance(dishes, list) or len(dishes) > 3 or
            any(not isinstance(dish, str) or not dish.strip() or len(dish) > 48 or any(ord(c) < 32 for c in dish)
                for dish in dishes) or (shown and not store)):
        raise APIError(Status.BAD_REQUEST, 'invalid_recommendation_result')
    now = int(time.time())
    state = 'shown' if shown else 'failed'
    with db:
        db.execute('BEGIN IMMEDIATE')
        existing = db.execute('SELECT * FROM recommendations WHERE id=?', (job_id,)).fetchone()
        if not existing or existing['lease'] != lease or existing['expires_at'] <= now:
            raise APIError(Status.CONFLICT, 'recommendation_not_claimed')
        if existing['state'] == 'searching':
            db.execute('UPDATE recommendations SET state=?,store=?,address=?,dishes=?,note=?,expires_at=? WHERE id=?',
                       (state, store, address, json.dumps(dishes, ensure_ascii=False), note, now + 300, job_id))
        elif (existing['state'], existing['store'], existing['address'], json.loads(existing['dishes']), existing['note']) != (
                state, store, address, dishes, note):
            raise APIError(Status.CONFLICT, 'recommendation_result_conflict')
    joined = '、'.join(dishes)
    text = (f'美团门店推荐已显示。{store}。{note}。' + (f'菜品有{joined}。' if joined else '') + '要去这家店，请说开始导航。'
            if shown else f'美团门店推荐未完成。{note}。')
    expires = now + 90
    packet = b'K1' + job_id.encode('ascii') + expires.to_bytes(4, 'big') + text.encode()
    packet += hmac.digest(device_key, packet, 'sha256')
    return Status.OK, {'packet': base64.b64encode(packet).decode('ascii'), 'expires_at': expires}


def request_recommended_navigation(db, body):
    job_id = cycling_text(body, 'task_id', 32, required=True)
    row = db.execute("SELECT * FROM recommendations WHERE id=? AND state='shown' AND expires_at>?",
                     (job_id, int(time.time()))).fetchone()
    if not row:
        raise APIError(Status.CONFLICT, 'recommendation_not_shown')
    return enqueue_cycling_route(db, {'request_id': 'recommend-' + job_id, 'destination': row['store'],
                                     'city': row['city'], 'district': row['district']})


def relay_voice_request(db, envelope, device_key, delivery_wakeup):
    try:
        encoded = envelope['packet']
        if not isinstance(encoded, str) or len(encoded) > 1600:
            raise ValueError
        packet = base64.b64decode(encoded, validate=True)
        prefix = packet[:2]
        request_id = packet[2:34].decode('ascii')
        expires = int.from_bytes(packet[34:38], 'big')
        if (prefix not in (b'R1', b'P1', b'V1', b'Q1', b'L1') or not re.fullmatch(r'[a-f0-9]{32}', request_id)
                or not 71 <= len(packet) <= 1200
                or not 0 < expires - int(time.time()) <= 30
                or not hmac.compare_digest(hmac.digest(device_key, packet[:-32], 'sha256'), packet[-32:])):
            raise ValueError
        data = json.loads(packet[38:-32].decode('utf-8'))
        if not isinstance(data, dict) or data.get('request_id') != request_id:
            raise ValueError
    except (KeyError, ValueError, RecursionError):
        raise APIError(Status.BAD_REQUEST, 'invalid_voice_relay') from None

    try:
        if prefix == b'P1':
            status, result = delivery.enqueue(db, 'device', data)
            delivery_wakeup.set()
            task_id = result['id']
        elif prefix == b'V1':
            task_id = cycling_text(data, 'task_id', 32, required=True)
            if not re.fullmatch(r'[a-f0-9]{32}', task_id):
                raise APIError(Status.BAD_REQUEST, 'invalid_pickup_ride_task')
            status, _ = delivery.request_pickup_ride(db, task_id)
        elif prefix in (b'Q1', b'L1'):
            operation = enqueue_recommendation if prefix == b'Q1' else request_recommended_navigation
            status, result = operation(db, data)
            task_id = result['id']
        else:
            status, result = enqueue_cycling_route(db, data)
            task_id = result['id']
        ack = f'{int(status)}{task_id}'.encode('ascii')
    except (APIError, delivery.DeliveryError) as error:
        ack = str(int(error.status)).encode('ascii')
    expiry = int(time.time()) + 25
    response = b'A1' + packet[2:34] + expiry.to_bytes(4, 'big') + ack
    response += hmac.digest(device_key, response, 'sha256')
    return Status.OK, {'packet': base64.b64encode(response).decode('ascii'), 'expires_at': expiry}


def cycling_route(db, route_id):
    row = db.execute("""SELECT id,request_id,destination,city,district,state,expires_at,note,updated_at
                        FROM cycling_routes WHERE id=?""", (route_id,)).fetchone()
    if row is None:
        raise APIError(Status.NOT_FOUND, 'cycling_route_not_found')
    route = dict(row)
    request_id = route.pop('request_id')
    if request_id.startswith('recommend-'):
        store = db.execute('SELECT address FROM recommendations WHERE id=?', (request_id[10:],)).fetchone()
        route['recommendedStore'] = True
        route['address'] = store['address'] if store else ''
    return route


def cycling_destination(value):
    return re.sub(
        r'地铁(?:站口|站|口)?[\s,，、(（]*([A-Za-zＡ-Ｚａ-ｚ])[\s,，、]*(?:出)?口[)）]?$',
        lambda match: '地铁站' + unicodedata.normalize('NFKC', match[1]).upper() + '口',
        value,
    )


def enqueue_cycling_route(db, body):
    request_id = cycling_text(body, 'request_id', 80, required=True)
    destination = cycling_destination(cycling_text(body, 'destination', 96, required=True))
    city = cycling_text(body, 'city', 32, required=True)
    district = cycling_text(body, 'district', 32)
    if not REQUEST_ID.fullmatch(request_id):
        raise APIError(Status.BAD_REQUEST, 'invalid_cycling_route')
    now = int(time.time())
    with db:
        db.execute('BEGIN IMMEDIATE')
        expire_cycling_routes(db, now)
        existing = db.execute('SELECT id,destination,city,district FROM cycling_routes WHERE request_id=?',
                              (request_id,)).fetchone()
        if existing:
            if (cycling_destination(existing['destination']), existing['city'], existing['district']) != (
                    destination, city, district):
                raise APIError(Status.CONFLICT, 'cycling_request_id_conflict')
            return Status.OK, cycling_route(db, existing['id'])
        route_id = uuid4().hex
        db.execute("""INSERT INTO cycling_routes
                      (id,request_id,destination,city,district,state,expires_at,updated_at)
                      VALUES (?,?,?,?,?,'queued',?,?)""",
                   (route_id, request_id, destination, city, district, now + CYCLING_QUEUE_SECONDS, now))
        return Status.CREATED, cycling_route(db, route_id)


def claim_cycling_route(db, body):
    lease = cycling_text(body, 'lease', 80, required=True)
    if not REQUEST_ID.fullmatch(lease):
        raise APIError(Status.BAD_REQUEST, 'invalid_cycling_lease')
    now = int(time.time())
    with db:
        db.execute('BEGIN IMMEDIATE')
        expire_cycling_routes(db, now)
        current = db.execute("SELECT id,lease FROM cycling_routes WHERE state='starting' LIMIT 1").fetchone()
        if current:
            return (Status.OK, cycling_route(db, current['id'])) if current['lease'] == lease else (Status.NO_CONTENT, None)
        next_route = db.execute("SELECT id FROM cycling_routes WHERE state='queued' ORDER BY rowid LIMIT 1").fetchone()
        if next_route is None:
            return Status.NO_CONTENT, None
        route_id = next_route['id']
        db.execute("""UPDATE cycling_routes SET state='starting', lease=?, expires_at=?, updated_at=?
                      WHERE id=?""", (lease, now + CYCLING_START_SECONDS, now, route_id))
        return Status.OK, cycling_route(db, route_id)


def finish_cycling_route(db, route_id, body):
    lease = cycling_text(body, 'lease', 80, required=True)
    state = cycling_text(body, 'state', 8, required=True)
    note = cycling_text(body, 'note', 160)
    if not REQUEST_ID.fullmatch(lease) or state not in ('active', 'failed', 'ended'):
        raise APIError(Status.BAD_REQUEST, 'invalid_cycling_result')
    now = int(time.time())
    with db:
        db.execute('BEGIN IMMEDIATE')
        expire_cycling_routes(db, now)
        current = cycling_route(db, route_id)
        owner = db.execute('SELECT lease FROM cycling_routes WHERE id=?', (route_id,)).fetchone()['lease']
        if owner != lease:
            raise APIError(Status.CONFLICT, 'cycling_lease_mismatch')
        if current['state'] == state and current['note'] == note:
            return Status.OK, current
        allowed = {'starting': ('active', 'failed'), 'active': ('active', 'ended')}
        if state not in allowed.get(current['state'], ()):
            raise APIError(Status.CONFLICT, 'cycling_route_state_changed')
        db.execute('UPDATE cycling_routes SET state=?,note=?,updated_at=? WHERE id=?', (state, note, now, route_id))
        if state in ('failed', 'ended'):
            resume_paused_deliveries(db, now)
        return Status.OK, cycling_route(db, route_id)


def submit(db, payload):
    request_id = payload.get('request_id')
    sku = payload.get('sku')
    quantity = payload.get('quantity')
    if not isinstance(request_id, str) or not REQUEST_ID.fullmatch(request_id):
        raise APIError(Status.BAD_REQUEST, 'invalid_request_id')
    if not isinstance(sku, str) or sku not in MENU:
        raise APIError(Status.BAD_REQUEST, 'unknown_item')
    if type(quantity) is not int or not 1 <= quantity <= 5:
        raise APIError(Status.BAD_REQUEST, 'invalid_quantity')
    item, unit_cents = MENU[sku]
    with db:
        db.execute('BEGIN IMMEDIATE')
        existing = db.execute('SELECT id, sku, quantity FROM intents WHERE request_id = ?', (request_id,)).fetchone()
        if existing:
            if existing['sku'] != sku or existing['quantity'] != quantity:
                raise APIError(Status.CONFLICT, 'request_id_reused')
            return Status.OK, order_view(db, existing['id'])
        intent_id = uuid4().hex
        db.execute('''INSERT INTO intents (id, request_id, sku, item, quantity, unit_cents, state)
                      VALUES (?, ?, ?, ?, ?, ?, 'pending')''',
                   (intent_id, request_id, sku, item, quantity, unit_cents))
        return Status.CREATED, order_view(db, intent_id)


def decide(db, intent_id, payload):
    decision = payload.get('decision')
    if decision not in ('confirm', 'cancel'):
        raise APIError(Status.BAD_REQUEST, 'invalid_decision')
    state = 'confirmed' if decision == 'confirm' else 'cancelled'
    with db:
        db.execute('BEGIN IMMEDIATE')
        intent = db.execute('SELECT state FROM intents WHERE id = ?', (intent_id,)).fetchone()
        if not intent:
            raise APIError(Status.NOT_FOUND, 'order_not_found')
        if intent['state'] == 'pending':
            db.execute('UPDATE intents SET state = ? WHERE id = ?', (state, intent_id))
            if state == 'confirmed':
                # The generated row ID is durable and unique in this local order database.
                number = db.execute('SELECT coalesce(max(rowid), 0) + 1 FROM orders').fetchone()[0]
                db.execute('INSERT INTO orders VALUES (?, ?)', (intent_id, f'TEST-{number:06d}'))
        elif intent['state'] != state:
            raise APIError(Status.CONFLICT, 'already_decided')
        return Status.OK, order_view(db, intent_id)


class OrdersHandler(BaseHTTPRequestHandler):
    def setup(self):
        self.request.settimeout(8)
        super().setup()

    def reply(self, status, payload):
        self.send_response(status)
        if status == Status.NO_CONTENT:
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            return
        if isinstance(payload, bytes):
            body = payload
            self.send_header('Content-Type', 'audio/ogg')
        else:
            body = json.dumps(payload, ensure_ascii=False, separators=(',', ':')).encode('utf-8')
            self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body)

    def authorize(self, role):
        expected = b'Bearer ' + self.server.tokens[role]
        provided = self.headers.get('Authorization', '').encode('utf-8')
        if not hmac.compare_digest(expected, provided):
            raise APIError(Status.UNAUTHORIZED, 'unauthorized')

    def body(self):
        if self.headers.get_content_type() != 'application/json':
            raise APIError(Status.UNSUPPORTED_MEDIA_TYPE, 'expected_json')
        try:
            length = int(self.headers.get('Content-Length', '0'))
        except ValueError:
            raise APIError(Status.BAD_REQUEST, 'invalid_body') from None
        if length > MAX_BODY:
            raise APIError(Status.REQUEST_ENTITY_TOO_LARGE, 'body_too_large')
        if length <= 0 or self.headers.get('Transfer-Encoding'):
            raise APIError(Status.BAD_REQUEST, 'invalid_body')
        try:
            parsed = json.loads(self.rfile.read(length).decode('utf-8'))
        except (UnicodeError, ValueError, RecursionError):
            raise APIError(Status.BAD_REQUEST, 'invalid_body') from None
        if not isinstance(parsed, dict):
            raise APIError(Status.BAD_REQUEST, 'invalid_body')
        return parsed

    def dispatch(self, method):
        url = urlsplit(self.path)
        path = url.path
        decision_path = INTENT_PATH.fullmatch(path)
        delivery_path = delivery.TASK_PATH.fullmatch(path)
        phone_result_path = delivery.PHONE_RESULT_PATH.fullmatch(path)
        voice_feedback_path = delivery.VOICE_FEEDBACK_PATH.fullmatch(path)
        voice_feedback_text_path = delivery.VOICE_FEEDBACK_TEXT_PATH.fullmatch(path)
        voice_pickup_confirm_path = delivery.VOICE_PICKUP_CONFIRM_PATH.fullmatch(path)
        voice_pickup_continue_path = delivery.VOICE_PICKUP_CONTINUE_PATH.fullmatch(path)
        voice_ride_path = delivery.VOICE_RIDE_PATH.fullmatch(path)
        phone_ride_result_path = delivery.PHONE_RIDE_RESULT_PATH.fullmatch(path)
        cycling_route_path = CYCLING_ROUTE_PATH.fullmatch(path)
        cycling_result_path = CYCLING_RESULT_PATH.fullmatch(path)
        cycling_hold_pickups_path = CYCLING_HOLD_PICKUPS_PATH.fullmatch(path)
        spoken_feedback = None
        try:
            with closing(database(self.server.db_path)) as db:
                if method == 'GET' and path == '/api/health':
                    db.execute('SELECT 1 FROM intents LIMIT 1').fetchone()
                    result = Status.OK, {'status': 'ok', 'db': 'connected', 'service': 'knight-orders'}
                elif method == 'POST' and path == '/api/cycling/routes':
                    self.authorize('device')
                    result = enqueue_cycling_route(db, self.body())
                elif method == 'GET' and cycling_route_path:
                    self.authorize('device')
                    with db:
                        expire_cycling_routes(db, int(time.time()))
                        result = Status.OK, cycling_route(db, cycling_route_path[1])
                elif method == 'POST' and path == '/api/cycling/phone/claim':
                    self.authorize('phone')
                    result = claim_cycling_route(db, self.body())
                elif method == 'POST' and path == '/api/cycling/phone/pending':
                    self.authorize('phone')
                    self.body()
                    result = pending_cycling_route(db)
                elif method == 'POST' and path == '/api/cycling/phone/navigation-speech':
                    self.authorize('phone')
                    result = navigation_speech_packet(self.body(), self.server.tokens['device'])
                elif method == 'POST' and path == '/api/voice/phone/relay':
                    self.authorize('phone')
                    result = relay_voice_request(db, self.body(), self.server.tokens['device'], self.server.delivery_wakeup)
                elif method == 'POST' and path == '/api/recommendations/phone/claim':
                    self.authorize('phone')
                    result = claim_recommendation(db, self.body())
                elif method == 'POST' and path == '/api/recommendations/phone/result':
                    self.authorize('phone')
                    result = finish_recommendation(db, self.body(), self.server.tokens['device'])
                elif method == 'POST' and path == '/api/voice/recommendations':
                    self.authorize('device')
                    result = enqueue_recommendation(db, self.body())
                elif method == 'POST' and path == '/api/voice/recommendations/navigation':
                    self.authorize('device')
                    result = request_recommended_navigation(db, self.body())
                elif method == 'POST' and cycling_result_path:
                    self.authorize('phone')
                    result = finish_cycling_route(db, cycling_result_path[1], self.body())
                elif method == 'POST' and cycling_hold_pickups_path:
                    self.authorize('phone')
                    result = hold_pickups_for_cycling(db, cycling_hold_pickups_path[1], self.body())
                elif method == 'GET' and path == '/api/orders/intents':
                    self.authorize('phone')
                    rows = db.execute(ORDER_VIEW + " ORDER BY i.state != 'pending', i.created_at DESC, i.rowid DESC LIMIT 50")
                    intents = [dict(row) for row in rows]
                    for intent in intents:
                        intent['total_cents'] = intent['quantity'] * intent['unit_cents']
                    result = Status.OK, {'intents': intents}
                elif method == 'POST' and path == '/api/voice/order-intents':
                    self.authorize('device')
                    result = submit(db, self.body())
                elif method == 'POST' and decision_path:
                    self.authorize('phone')
                    result = decide(db, decision_path[1], self.body())
                elif method == 'GET' and path == '/api/delivery/tasks':
                    self.authorize('phone')
                    result = Status.OK, {**delivery.list_tasks(db), 'allow_submit': self.server.allow_submit(), 'allow_checkout': self.server.allow_checkout(),
                                         'ready': self.server.delivery_ready()}
                elif method == 'POST' and path == '/api/voice/delivery-tasks':
                    self.authorize('device')
                    result = delivery.enqueue(db, 'device', self.body())
                    self.server.delivery_wakeup.set()
                elif method == 'GET' and voice_feedback_path:
                    self.authorize('device')
                    spoken_feedback = delivery.pickup_voice_feedback(db, voice_feedback_path[1])
                    result = Status.NO_CONTENT, None
                elif method == 'GET' and voice_feedback_text_path:
                    self.authorize('device')
                    task_id = voice_feedback_text_path[1]
                    wait = VOICE_FEEDBACK_WAIT if url.query == 'wait=1' and task_id != 'latest' else 0
                    if task_id == 'latest':
                        task_id = delivery.latest_voice_pickup_id(db)
                    deadline = time.monotonic() + wait
                    while True:
                        feedback = delivery.pickup_voice_feedback(db, task_id)
                        remaining = deadline - time.monotonic()
                        if feedback is not None or remaining <= 0:
                            break
                        time.sleep(min(0.35, remaining))
                    result = (Status.NO_CONTENT, None) if feedback is None else (
                        Status.OK, {'id': task_id, 'text': feedback, 'state': delivery.task(db, task_id)['state']})
                elif method == 'POST' and voice_pickup_confirm_path:
                    self.authorize('device')
                    result = delivery.confirm_voice_pickup(db, voice_pickup_confirm_path[1])
                elif method == 'POST' and voice_pickup_continue_path:
                    self.authorize('device')
                    result = delivery.continue_voice_pickup(db, voice_pickup_continue_path[1], self.body())
                    self.server.delivery_wakeup.set()
                elif voice_ride_path:
                    self.authorize('device')
                    task_id = voice_ride_path[1]
                    if method == 'POST':
                        result = delivery.request_pickup_ride(db, task_id)
                    else:
                        deadline = time.monotonic() + (VOICE_FEEDBACK_WAIT if url.query == 'wait=1' else 0)
                        while True:
                            feedback = delivery.pickup_ride_feedback(db, task_id)
                            remaining = deadline - time.monotonic()
                            if feedback is not None or remaining <= 0:
                                break
                            time.sleep(min(0.35, remaining))
                        result = (Status.NO_CONTENT, None) if feedback is None else (Status.OK, feedback)
                elif method == 'POST' and path == '/api/delivery/phone/ride-claim':
                    self.authorize('phone')
                    result = delivery.claim_pickup_ride(db, self.body())
                elif method == 'POST' and phone_ride_result_path:
                    self.authorize('phone')
                    result = delivery.finish_pickup_ride(db, phone_ride_result_path[1], self.body())
                elif method == 'POST' and path == '/api/delivery/tasks':
                    self.authorize('phone')
                    result = delivery.enqueue(db, 'phone', self.body())
                    self.server.delivery_wakeup.set()
                elif method == 'POST' and path == '/api/delivery/phone/claim':
                    self.authorize('phone')
                    result = delivery.claim_phone_task(db, self.body())
                    claimed = result[1]
                    if claimed and self.server.pickup_summarizer and claimed.get('voice_request'):
                        with self.server.pickup_summary_lock:
                            summaries = self.server.pickup_summaries
                            if claimed['id'] not in summaries:
                                if len(summaries) >= 8:
                                    summaries.pop(next(iter(summaries)))
                                summaries[claimed['id']] = self.server.pickup_summary_pool.submit(
                                    self.server.pickup_summarizer, claimed['query'], claimed['merchant'])
                elif method == 'POST' and phone_result_path:
                    self.authorize('phone')
                    task_id = phone_result_path[1]
                    status, receipt = delivery.finish_phone_task(db, task_id, self.body())
                    with self.server.pickup_summary_lock:
                        summary = self.server.pickup_summaries.get(task_id)
                    order = summary.result() if summary and summary.done() and not summary.cancelled() else None
                    packet = delivery.pickup_bluetooth_receipt(db, task_id, self.server.tokens['device'],
                                                              (lambda _: order) if order else None)
                    if packet:
                        self.log_message('Pickup Bluetooth packet %s source=%s', task_id, packet['summary_source'])
                    result = status, {**receipt, 'bluetooth_receipt': packet} if packet else receipt
                elif method == 'POST' and delivery_path:
                    self.authorize('phone')
                    result = delivery.decide(db, delivery_path[1], self.body(), self.server.allow_submit())
                    self.server.delivery_wakeup.set()
                else:
                    raise APIError(Status.NOT_FOUND, 'not_found')
            if spoken_feedback is not None:
                result = Status.OK, synthesize_feedback(spoken_feedback)
        except (APIError, delivery.DeliveryError) as error:
            result = error.status, {'error': error.code}
        except TimeoutError:
            result = Status.REQUEST_TIMEOUT, {'error': 'request_timeout'}
        except sqlite3.Error as error:
            self.log_error('Database operation: %s', type(error).__name__)
            result = Status.SERVICE_UNAVAILABLE, {'error': 'database_unavailable'}
        try:
            self.reply(*result)
        except (ConnectionError, TimeoutError):
            pass

    def do_GET(self):
        self.dispatch('GET')

    def do_POST(self):
        self.dispatch('POST')


def configure(state, host, port, iphone_host):
    if not re.fullmatch(r'[A-Za-z0-9-]+\.local|\d{1,3}(?:\.\d{1,3}){3}', host):
        raise SystemExit('Client host must be the Mac local hostname or IPv4 address.')
    if iphone_host is not None and not ipaddress.IPv4Address(iphone_host).is_private:
        raise SystemExit('iPhone override must use a private IPv4 address.')
    tokens = {}
    for role in ('phone', 'device'):
        path = state / f'{role}.token'
        try:
            with path.open('x', encoding='ascii') as file:
                file.write(secrets.token_hex(32) + '\n')
        except FileExistsError:
            pass
        tokens[role] = path.read_text(encoding='ascii').strip()
        if not re.fullmatch(r'[a-f0-9]{64}', tokens[role]):
            raise SystemExit(f'Invalid {role} credential file.')
    (state / 'iPhone.xcconfig').write_text(
        f'KNIGHT_ORDERS_HOST = {iphone_host or host}\nKNIGHT_ORDERS_PORT = {port}\n'
        f'KNIGHT_ORDERS_TOKEN = {tokens["phone"]}\n', encoding='ascii')
    (state / 'knight_order_build.h').write_text(
        '#pragma once\n'
        f'#define KNIGHT_ORDERS_ENDPOINT "http://{host}:{port}/api/voice/order-intents"\n'
        f'#define KNIGHT_DELIVERY_ENDPOINT "http://{host}:{port}/api/voice/delivery-tasks"\n'
        f'#define KNIGHT_ORDERS_DEVICE_TOKEN "{tokens["device"]}"\n', encoding='ascii')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--state', type=Path, default=STATE_DIR)
    parser.add_argument('--port', type=int, default=8012)
    parser.add_argument('--iphone-host', help='Override iPhone LAN IPv4 when using --configure.')
    parser.add_argument('--delivery-device', help='Enable worker for this iPhone identifier.')
    parser.add_argument('--summary-config', type=Path, help='Use the project LLM configuration for pickup summaries.')
    command = parser.add_mutually_exclusive_group()
    command.add_argument('--configure', metavar='CLIENT_HOST')
    command.add_argument('--interface', help='Use the primary IPv4 address of this Mac interface.')
    args = parser.parse_args()
    if not 1 <= args.port <= 65535:
        parser.error('port is outside 1–65535')
    os.umask(0o077)
    args.state.mkdir(mode=0o700, parents=True, exist_ok=True)
    if args.configure:
        configure(args.state, args.configure, args.port, args.iphone_host)
        return
    host = '127.0.0.1'
    if args.interface:
        host = subprocess.check_output(['/usr/sbin/ipconfig', 'getifaddr', args.interface], text=True).strip()
        if not ipaddress.IPv4Address(host).is_private:
            raise SystemExit('Use a private IPv4 interface for this LAN service.')
    db_path = args.state / 'orders.sqlite3'
    tokens = {role: (args.state / f'{role}.token').read_bytes().strip() for role in ('phone', 'device')}
    if tokens['phone'] == tokens['device'] or any(not re.fullmatch(rb'[a-f0-9]{64}', token) for token in tokens.values()):
        raise SystemExit('Initialize separate phone and device credentials with --configure.')
    initialize(db_path)
    with (ThreadingHTTPServer((host, args.port), OrdersHandler) as server,
          ThreadPoolExecutor(max_workers=2, thread_name_prefix='pickup-summary') as summary_pool):
        server.db_path = db_path
        server.tokens = tokens
        server.pickup_summarizer = pickup_summarizer(args.summary_config)
        server.pickup_summary_pool = summary_pool
        server.pickup_summary_lock = Lock()
        server.pickup_summaries = {}
        server.delivery_wakeup = Event()
        server.delivery_ready = delivery.readiness_probe(args.state) if args.delivery_device else lambda: False
        server.allow_checkout = lambda: bool(args.delivery_device) and (args.state / 'allow-delivery-checkout').is_file()
        server.allow_submit = lambda: server.allow_checkout() and (args.state / 'allow-delivery-submit').is_file()
        if args.delivery_device:
            Thread(target=delivery.run_worker, args=(db_path, database, args.state, args.delivery_device,
                                                       server.allow_submit, server.allow_checkout, server.delivery_wakeup), daemon=True).start()
        print(f'Knight Orders listening on http://{host}:{args.port}', flush=True)
        server.serve_forever()


if __name__ == '__main__':
    main()
