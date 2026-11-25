"""Meituan tasks driven by the local Poki MCP and verified checkout state."""

from contextlib import closing
from dataclasses import dataclass
import base64
import fcntl
import hashlib
import hmac
from http import HTTPStatus as Status
import json
import re
import time
from urllib.parse import urlsplit
from urllib.request import build_opener, HTTPRedirectHandler, ProxyHandler, Request
from uuid import uuid4

APP_ID = 'com.meituan.imeituan'
TASK_PATH = re.compile(r'/api/delivery/tasks/([a-f0-9]{32})/decision')
PHONE_RESULT_PATH = re.compile(r'/api/delivery/tasks/([a-f0-9]{32})/phone-result')
VOICE_FEEDBACK_PATH = re.compile(r'/api/voice/delivery-tasks/([a-f0-9]{32})/feedback')
VOICE_FEEDBACK_TEXT_PATH = re.compile(r'/api/voice/delivery-tasks/([a-f0-9]{32}|latest)/feedback-text')
VOICE_PICKUP_CONFIRM_PATH = re.compile(r'/api/voice/delivery-tasks/([a-f0-9]{32})/confirm-pickup')
PICKUP_SUMMARY_FIELDS = ('store', 'item', 'quantity', 'total', 'pickup_address')
REQUEST_ID = re.compile(r'[A-Za-z0-9_-]{16,80}')
MAX_AGE = 300
QUOTE_AGE = 180
MONEY = r'[¥￥]?\s*(\d{1,6}(?:\.\d{1,2})?)\s*元?'
ELEMENT = re.compile(r'^([ +])(\d+) (\w+) "(.*)" \[(-?\d+),(-?\d+),(\d+),(\d+)\]$')
PURCHASE = re.compile(r'下单|支付|付款|立即购买|确认购买|提交订单|免密|授信')
CHECKOUT = frozenset(('去结算', '结算', '确认订单'))
TASK_FIELDS = ('query', 'quantity', 'merchant', 'options', 'budget_cents', 'pickup_destination')
PICKUP_TABS = ('到店自取', '到店自提', '自取', '自提')
PICKUP_ADDRESS = re.compile(r'(?:自取地址|自提地址|取餐地址|门店地址)\s*[：:]\s*(.+)')
DELIVERY_ADDRESS = re.compile(r'(?:收货地址|配送至|送至)(?:\s*[：:]\s*|\s+)(.+)')
STORE_LABEL = re.compile(r'(?:店铺|商家|门店)\s*[：:]\s*(.+)')
DESTINATION_LABEL = re.compile(r'(?:搜索范围|搜索位置|当前区域|当前定位|当前位置|附近位置)\s*[：:]\s*(.+)')
DISTANCE_SORT = ('距离优先', '距离最近', '距离从近到远', '离我最近')
SELECTED_SUFFIX = re.compile(r'\s*=\s*(?:已选中|已选择|已选|已开启|selected|true|1)$', re.IGNORECASE)
UNSELECTED_SUFFIX = re.compile(r'\s*=\s*(?:未选中|未选择|未开启|false|0)$', re.IGNORECASE)
STORE_DISTANCE = re.compile(r'(?:^|[，,；;·\s])(?:距离|距您|距搜索位置)?\s*(\d{1,6}(?:\.\d{1,3})?)\s*(km|公里|千米|m|米)(?=$|[，,；;·\s])', re.IGNORECASE)
CARD_SEPARATOR = re.compile(r'\s*[，,；;]|\s+·\s+|\s+=\s+')
INTERACTIVE = frozenset(('Button', 'Link', 'Cell'))


class DeliveryError(Exception):
    def __init__(self, status, code):
        super().__init__(code)
        self.status = status
        self.code = code


class ReviewRequired(Exception):
    pass


class InputUnknown(Exception):
    pass


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        return None


def initialize(db):
    db.execute('''CREATE TABLE IF NOT EXISTS delivery_tasks (
        id TEXT PRIMARY KEY, request_id TEXT NOT NULL, source TEXT NOT NULL,
        query TEXT NOT NULL, quantity INTEGER NOT NULL, merchant TEXT NOT NULL,
        options TEXT NOT NULL, budget_cents INTEGER NOT NULL, state TEXT NOT NULL,
        note TEXT NOT NULL DEFAULT '', quote TEXT, quote_key TEXT, quote_fingerprint TEXT, quoted_at INTEGER,
        created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, pickup_destination TEXT NOT NULL DEFAULT '',
        UNIQUE(source, request_id)
    )''')
    columns = {column[1] for column in db.execute('PRAGMA table_info(delivery_tasks)')}
    if 'quote_fingerprint' not in columns:
        db.execute('ALTER TABLE delivery_tasks ADD COLUMN quote_fingerprint TEXT')
    if 'pickup_destination' not in columns:
        db.execute("ALTER TABLE delivery_tasks ADD COLUMN pickup_destination TEXT NOT NULL DEFAULT ''")
    if 'phone_lease' not in columns:
        db.execute('ALTER TABLE delivery_tasks ADD COLUMN phone_lease TEXT')
    if 'pickup_navigation' not in columns:
        db.execute('ALTER TABLE delivery_tasks ADD COLUMN pickup_navigation TEXT')


def display(row):
    return {key: (json.loads(value) if key in {'quote', 'pickup_navigation'} and value else value)
            for key, value in dict(row).items() if key not in {'source', 'request_id', 'quote_fingerprint', 'phone_lease'}}


def task(db, task_id):
    row = db.execute('SELECT * FROM delivery_tasks WHERE id = ?', (task_id,)).fetchone()
    if row is None:
        raise DeliveryError(Status.NOT_FOUND, 'delivery_not_found')
    return row


def list_tasks(db):
    rows = db.execute('SELECT * FROM delivery_tasks ORDER BY rowid DESC LIMIT 15').fetchall()
    return {'tasks': [display(row) for row in rows]}


def text_field(payload, key, size):
    value = payload.get(key, '')
    if not isinstance(value, str) or len(value) > size or any(ord(ch) < 32 for ch in value):
        raise DeliveryError(Status.BAD_REQUEST, 'invalid_delivery_fields')
    return value.strip()


def expire_phone_tasks(db, now):
    db.execute("""UPDATE delivery_tasks SET state='needs_input', updated_at=?, note='手机执行已超时，请在美团核对购物车'
       WHERE pickup_destination<>'' AND (state='queued' OR (state='preparing' AND phone_lease IS NOT NULL)) AND created_at<=?""",
       (now, now - MAX_AGE))
    db.execute("""UPDATE delivery_tasks SET state='needs_input', updated_at=?, note='请在美团核对这笔结算'
       WHERE state='pickup_checkout' AND updated_at<=?""", (now, now - MAX_AGE))


def claim_phone_task(db, payload):
    lease = text_field(payload, 'lease', 80)
    if not REQUEST_ID.fullmatch(lease):
        raise DeliveryError(Status.BAD_REQUEST, 'invalid_phone_lease')
    now = int(time.time())
    with db:
        db.execute('BEGIN IMMEDIATE')
        expire_phone_tasks(db, now)
        row = db.execute("SELECT * FROM delivery_tasks WHERE state='preparing' AND phone_lease=?", (lease,)).fetchone()
        if row is None:
            row = db.execute("SELECT * FROM delivery_tasks WHERE state='queued' AND pickup_destination<>'' ORDER BY created_at, rowid LIMIT 1").fetchone()
            if row is None:
                return Status.OK, None
            db.execute("UPDATE delivery_tasks SET state='preparing', phone_lease=?, updated_at=?, note='iPhone 正在操控美团' WHERE id=?",
                       (lease, now, row['id']))
            row = task(db, row['id'])
        return Status.OK, {**display(row), 'expires_in': row['created_at'] + MAX_AGE - now,
                           'voice_request': row['source'] == 'device'}


def finish_phone_task(db, task_id, payload):
    lease = text_field(payload, 'lease', 80)
    state = payload.get('state')
    if not REQUEST_ID.fullmatch(lease) or state not in ('needs_input', 'pickup_checkout'):
        raise DeliveryError(Status.BAD_REQUEST, 'invalid_phone_result')
    now = int(time.time())
    with db:
        db.execute('BEGIN IMMEDIATE')
        row = task(db, task_id)
        if row['phone_lease'] != lease or row['created_at'] + MAX_AGE <= now:
            raise DeliveryError(Status.CONFLICT, 'phone_lease_expired')
        if row['state'] == state:
            return Status.OK, display(row)
        if row['state'] != 'preparing':
            raise DeliveryError(Status.CONFLICT, 'invalid_phone_state')
        quote = None
        navigation = None
        map_fields = payload.get('navigation')
        if map_fields is not None:
            if not isinstance(map_fields, dict) or not row['pickup_destination']:
                raise DeliveryError(Status.BAD_REQUEST, 'invalid_pickup_navigation')
            map_store = text_field(map_fields, 'store', 100)
            city = text_field(map_fields, 'city', 12)
            if not map_store or city and not re.fullmatch(r'[\u3400-\u9fff]{2,10}市', city):
                raise DeliveryError(Status.BAD_REQUEST, 'invalid_pickup_navigation')
            navigation = dict(store=map_store, city=city)
        if state == 'needs_input':
            note = text_field(payload, 'note', 180) or '请在美团核对本次自提任务'
        else:
            fields = payload.get('quote')
            if not isinstance(fields, dict):
                raise DeliveryError(Status.BAD_REQUEST, 'invalid_phone_quote')
            store = text_field(fields, 'store', 100)
            item = text_field(fields, 'item', 150)
            address = text_field(fields, 'pickup_address', 200)
            amount, quantity = fields.get('total_cents'), fields.get('quantity')
            if (not all((store, item, address)) or type(quantity) is not int or quantity != row['quantity'] or
                    type(amount) is not int or not 0 <= amount <= (row['budget_cents'] or 100000)):
                raise DeliveryError(Status.BAD_REQUEST, 'invalid_phone_quote')
            quote = json.dumps(dict(store=store, item=item, pickup_address=address, total_cents=amount, quantity=quantity, fees=[]), ensure_ascii=False)
            if navigation and navigation['store'] != store:
                raise DeliveryError(Status.BAD_REQUEST, 'invalid_pickup_navigation')
            navigation = {**(navigation or {}), 'store': store, 'address': address}
            note = 'iPhone 已停在美团自提结算页，请核对后付款'
        db.execute('UPDATE delivery_tasks SET state=?, note=?, quote=?, pickup_navigation=?, updated_at=? WHERE id=?',
                   (state, note, quote, json.dumps(navigation, ensure_ascii=False) if navigation else None, now, task_id))
        return Status.OK, display(task(db, task_id))


def latest_voice_pickup_id(db):
    row = db.execute("""SELECT id FROM delivery_tasks WHERE source='device' AND pickup_destination<>''
                      ORDER BY rowid DESC LIMIT 1""").fetchone()
    if row is None:
        raise DeliveryError(Status.NOT_FOUND, 'delivery_not_found')
    return row['id']


def pickup_voice_feedback(db, task_id):
    row = task(db, latest_voice_pickup_id(db) if task_id == 'latest' else task_id)
    if row['source'] != 'device' or not row['pickup_destination']:
        raise DeliveryError(Status.NOT_FOUND, 'delivery_not_found')
    return pickup_feedback_text(row, int(time.time()))


def pickup_feedback_text(row, now, field_order=PICKUP_SUMMARY_FIELDS):
    state = row['state']
    if state in ('queued', 'preparing'):
        if row['created_at'] + MAX_AGE > now:
            return None
        return '骑士自提任务处理超时。请打开骑士 App 或美团核对。'
    if state == 'pickup_checkout' and row['quote'] and row['phone_lease']:
        if row['updated_at'] + MAX_AGE <= now:
            return '这笔美团自提结算已过期，请打开美团核对当前状态。'
        quote = json.loads(row['quote'])
        yuan, cents = divmod(quote['total_cents'], 100)
        total = f'{yuan}.{cents:02d}元' if cents else f'{yuan}元'
        facts = dict(store=quote['store'], item=quote['item'], quantity=f'共{quote["quantity"]}杯',
                     total=f'应付{total}', pickup_address=f'取餐地址，{quote["pickup_address"]}')
        summary = '。'.join(facts[field] for field in field_order)
        return f'美团自提结算页已就绪。{summary}。请在美团核对后付款。'
    if state == 'cancelled':
        return '这笔美团自提任务已取消。'
    if state == 'reviewed':
        return '这笔骑士自提任务已结束。请在美团查看订单状态。'
    if state == 'needs_input':
        note = row['note'].strip('。')
        if note:
            return f'这笔美团自提还未完成。{note}。'
    return '骑士还未核对到美团自提结算页。请打开骑士 App 查看。'


def pickup_bluetooth_receipt(db, task_id, device_key, summarize=None):
    row = task(db, task_id)
    if row['source'] != 'device' or not row['pickup_destination'] or not row['phone_lease'] or row['state'] not in ('pickup_checkout', 'needs_input'):
        return None
    now = int(time.time())
    expires_at = row['updated_at'] + MAX_AGE
    if expires_at <= now:
        return None
    order = None
    if summarize and row['state'] == 'pickup_checkout' and row['quote']:
        order = summarize(json.loads(row['quote']))
    spoken = pickup_feedback_text(row, now, order or PICKUP_SUMMARY_FIELDS)
    body = b'K1' + task_id.encode('ascii') + expires_at.to_bytes(4, 'big') + spoken.encode('utf-8')
    signature = hmac.digest(device_key, body, 'sha256')
    return {'expires_at': expires_at, 'packet': base64.b64encode(body + signature).decode('ascii'),
            'summary_source': 'ai' if order else 'verified_fields'}


def confirm_voice_pickup(db, task_id):
    with db:
        db.execute('BEGIN IMMEDIATE')
        row = task(db, task_id)
        if row['source'] != 'device' or not row['pickup_destination']:
            raise DeliveryError(Status.NOT_FOUND, 'delivery_not_found')
        if row['state'] != 'pickup_checkout' or not row['phone_lease'] or not row['quote'] or (
            row['updated_at'] + MAX_AGE <= int(time.time())
        ):
            raise DeliveryError(Status.CONFLICT, 'pickup_checkout_unavailable')
        db.execute("UPDATE delivery_tasks SET note='用户已语音确认，请在美团核对并付款' WHERE id=?", (task_id,))
    return Status.OK, {'text': '已记录这笔自提的语音确认。请在手机美团核对并付款。'}


def enqueue(db, source, payload):
    request_id = text_field(payload, 'request_id', 80)
    query = text_field(payload, 'query', 48)
    merchant = text_field(payload, 'merchant', 40)
    options = text_field(payload, 'options', 48)
    destination = text_field(payload, 'pickup_destination', 80)
    quantity = payload.get('quantity', 1)
    budget = payload.get('budget_cents', 0)
    if not query or not REQUEST_ID.fullmatch(request_id) or type(quantity) is not int or not 1 <= quantity <= 5:
        raise DeliveryError(Status.BAD_REQUEST, 'invalid_delivery_fields')
    if type(budget) is not int or not 0 <= budget <= 100000:
        raise DeliveryError(Status.BAD_REQUEST, 'invalid_delivery_budget')
    fields = (query, quantity, merchant, options, budget, destination)
    with db:
        db.execute('BEGIN IMMEDIATE')
        expire_phone_tasks(db, int(time.time()))
        existing = db.execute('SELECT * FROM delivery_tasks WHERE request_id=? AND source=?', (request_id, source)).fetchone()
        if existing:
            if tuple(existing[field] for field in TASK_FIELDS) != fields:
                raise DeliveryError(Status.CONFLICT, 'request_id_reused')
            return Status.OK, display(existing)
        active = db.execute("SELECT 1 FROM delivery_tasks WHERE state IN ('queued','preparing','pickup_checkout','awaiting_confirmation','approved','submitting','unknown')").fetchone()
        if active:
            raise DeliveryError(Status.CONFLICT, 'delivery_busy')
        now, task_id = int(time.time()), uuid4().hex
        db.execute('''INSERT INTO delivery_tasks
            (id, request_id, source, query, quantity, merchant, options, budget_cents, pickup_destination, state, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'queued', ?, ?)''', (task_id, request_id, source, *fields, now, now))
        return Status.CREATED, display(task(db, task_id))


def decide(db, task_id, payload, allow_submit):
    operation = payload.get('decision')
    now = int(time.time())
    with db:
        db.execute('BEGIN IMMEDIATE')
        row = task(db, task_id)
        state = row['state']
        if operation == 'cancel' and state in ('queued', 'preparing', 'awaiting_confirmation', 'approved', 'needs_input', 'cancelled'):
            db.execute("UPDATE delivery_tasks SET state='cancelled', note='已取消', updated_at=? WHERE id=?", (now, task_id))
        elif operation == 'acknowledge' and state in ('unknown', 'pickup_checkout', 'reviewed'):
            note = '已结束骑士自提任务，请在美团查看订单' if row['pickup_destination'] else '已人工核查美团订单'
            db.execute("UPDATE delivery_tasks SET state='reviewed', note=?, updated_at=? WHERE id=?", (note, now, task_id))
        elif operation == 'approve':
            if row['pickup_destination'] or not allow_submit:
                raise DeliveryError(Status.CONFLICT, 'checkout_only')
            if payload.get('quote_key') != row['quote_key'] or not row['quote_key']:
                raise DeliveryError(Status.CONFLICT, 'quote_changed')
            if state in ('approved', 'submitting', 'submitted', 'unknown'):
                return Status.OK, display(row)
            if state != 'awaiting_confirmation' or now - row['quoted_at'] >= QUOTE_AGE:
                raise DeliveryError(Status.CONFLICT, 'quote_expired')
            db.execute("UPDATE delivery_tasks SET state='approved', note='已授权，正在复核结算页', updated_at=? WHERE id=?", (now, task_id))
        else:
            raise DeliveryError(Status.CONFLICT, 'invalid_delivery_decision')
        return Status.OK, display(task(db, task_id))


def control_label(raw):
    label, separator, value = raw.strip().partition(' = ')
    if not separator or label == value:
        return re.sub(r'[,，]按钮$', '', label)
    return raw.strip()


@dataclass(frozen=True)
class Control:
    ref: int
    role: str
    label: str


@dataclass(frozen=True)
class Screen:
    app: str
    controls: tuple[Control, ...]

    @classmethod
    def parse(cls, data):
        lines = data.splitlines()
        app = lines[0].split('   read: ', 1)[0].removeprefix('app: ') if lines and lines[0].startswith('app: ') else 'unknown'
        controls = {}
        for line in lines:
            match = ELEMENT.fullmatch(line)
            if not match or int(match[7]) <= 0 or int(match[8]) <= 0:
                continue
            control = Control(int(match[2]), match[3], control_label(match[4]))
            identity = (control.role, control.label, *match.groups()[4:])
            controls.setdefault(identity, control)
        return cls(app, tuple(controls.values()))

    def exact(self, *labels):
        return [c for c in self.controls if c.label in labels]

    def contains(self, text):
        return [c for c in self.controls if text in c.label]


def wda_is_ready(http, port, timeout):
    try:
        with http.open(f'http://127.0.0.1:{port}/status', timeout=timeout) as response:
            return json.load(response).get('value', {}).get('ready') is True
    except (OSError, ValueError):
        return False


def readiness_probe(state):
    http = build_opener(ProxyHandler({}), NoRedirect())
    expires, result = 0, False

    def ready():
        nonlocal expires, result
        now = time.monotonic()
        if now < expires:
            return result
        endpoint = state / 'poki-state' / 'mcp.json'
        port_file = state / 'wda-local-port'
        result = endpoint.is_file()
        if result and port_file.is_file():
            try:
                port = int(port_file.read_text().strip())
                result = 1024 <= port <= 65535 and wda_is_ready(http, port, 0.4)
            except (OSError, ValueError):
                result = False
        expires = now + 2
        return result

    return ready


class Poki:
    def __init__(self, state, device, *, fast=False):
        entry = json.loads((state / 'poki-state' / 'mcp.json').read_text())
        parsed = urlsplit(entry['url'])
        if parsed.scheme != 'http' or parsed.hostname != '127.0.0.1' or parsed.path != '/mcp' or not entry.get('enabled'):
            raise ValueError('Poki endpoint needs to be loopback')
        self.url = entry['url']
        self.headers = {'Authorization': f"Bearer {entry['token']}", 'x-poki-mcp-session': uuid4().hex,
                        'Content-Type': 'application/json', 'Accept': 'application/json, text/event-stream'}
        self.http = build_opener(ProxyHandler({}), NoRedirect())
        self.sequence = 0
        self.device = device
        self.fast = fast and (state / 'poki-fast.enabled').is_file()
        port_file = state / 'wda-local-port'
        self.wda_port = int(port_file.read_text().strip()) if port_file.is_file() else None
        if self.wda_port is not None and not 1024 <= self.wda_port <= 65535:
            raise ValueError('Invalid local WDA port')

    def rpc(self, method, params, notification=False):
        self.sequence += 1
        payload = {'jsonrpc': '2.0', 'method': method, 'params': params}
        if not notification:
            payload['id'] = self.sequence
        request = Request(self.url, json.dumps(payload).encode(), self.headers)
        with self.http.open(request, timeout=25) as response:
            if notification:
                return {}
            result = json.loads(response.read(4 * 1024 * 1024))
        if 'result' not in result:
            raise InputUnknown('Poki 执行结果待核查')
        return result['result']

    def call(self, name, arguments):
        result = self.rpc('tools/call', {'name': name, 'arguments': arguments})
        if result.get('isError'):
            if name == 'do':
                raise InputUnknown('Poki 未确认动作结果，请查看手机')
            raise ReviewRequired('Poki 当前无法读取此 iPhone')
        return '\n'.join(item['text'] for item in result.get('content', []) if item.get('type') == 'text')

    def __enter__(self):
        if self.wda_port is not None and not wda_is_ready(self.http, self.wda_port, 1.5):
            raise ReviewRequired('iPhone 自动化连接已断开，请检查 USB 和测试运行器')
        result = self.rpc('initialize', {'protocolVersion': '2025-06-18', 'capabilities': {},
                                         'clientInfo': {'name': 'knight-delivery', 'version': '1'}})
        self.headers['MCP-Protocol-Version'] = result.get('protocolVersion', '2025-06-18')
        self.rpc('notifications/initialized', {}, notification=True)
        self.call('select_device', {'device': self.device})
        return self

    def __exit__(self, *_):
        try:
            close = self.url.removesuffix('/mcp') + '/session/close'
            with self.http.open(Request(close, b'', self.headers), timeout=5):
                pass
        except OSError:
            pass

    def foreground(self):
        if self.wda_port is not None:
            with self.http.open(f'http://127.0.0.1:{self.wda_port}/wda/activeAppInfo', timeout=8) as response:
                return json.load(response)['value'].get('bundleId')
        return json.loads(self.call('get_foreground_app', {})).get('bundle_id')

    def read(self, text):
        screen = Screen.parse(text)
        bundle = re.search(r'^bundle: ([A-Za-z0-9.-]{1,160})$', text, re.MULTILINE)
        return Screen((bundle[1] if self.fast and bundle else self.foreground()) or 'unknown', screen.controls)

    def evidence_options(self):
        return {'full': True, 'text_only': True} if self.fast else {'full': True}

    def look(self, *, full_evidence=False):
        options = {'full': True} if full_evidence else self.evidence_options()
        return self.read(self.call('look', options))

    def action(self, action):
        if 'launch' not in action and self.foreground() != APP_ID:
            raise ReviewRequired('美团已离开前台，请查看手机')
        data = self.call('do', {'actions': [action], **self.evidence_options()})
        if not any(re.search(r'\(sent, \d+ ms\)$', line) for line in data.splitlines() if line.startswith('did: ')):
            raise InputUnknown('Poki 未确认动作结果，请查看手机')
        return self.read(data)


def assert_app(screen):
    if screen.app != APP_ID:
        raise ReviewRequired('请保持美团在前台，并完成登录或系统权限提示')


def choose(controls, message):
    if len(controls) != 1:
        raise ReviewRequired(message)
    return controls[0]


def choose_optional(candidates):
    interactive = [control for control in candidates if control.role in ('Button', 'Link', 'SearchField', 'TextField')]
    selection = interactive or candidates
    return selection[0] if len(selection) == 1 else None


def item_matches(query, label):
    query = re.sub(r'[\s（）()]', '', query)
    label = re.sub(r'[\s（）()]', '', label)
    if query == '热美式':
        return '美式' in label and '热' in label and '冰' not in label and '白美式' not in label
    return bool(query) and query in label


def option_variants(value):
    if value in ('不加糖', '不另加糖'):
        return ('不加糖', '不另加糖', '无糖', '零糖')
    if value in ('无糖', '零糖'):
        return ('无糖', '零糖')
    if value in ('热', '热饮'):
        return ('热', '热饮', '热的')
    if value in ('冰', '冰饮'):
        return ('冰', '冰饮', '冰的')
    return (value,)


def options_match(options, label):
    selected = set(re.split(r'[,，、（）：:()·|/／\s]+', label))
    selected.update(re.findall(r'(?:^|[\s：:（(、])([热冰])(?:美式|拿铁)', label))
    requested = [value.strip() for value in re.split(r'[,，、]', options) if value.strip()]
    return all(selected.intersection(option_variants(value)) for value in requested)


def amount_cents(raw):
    yuan, _, fraction = raw.partition('.')
    return 100 * int(yuan) + int(fraction.ljust(2, '0') or '0')


def name_key(value):
    return re.sub(r'[\s（）()·]+', '', value).casefold()


def address_header(screen):
    return choose_optional([c for c in screen.controls if c.role == 'Button' and re.fullmatch(r'地址[：:]\s*.+', c.label)])


def matches_destination(screen, destination):
    areas = {name_key(match[1]) for c in screen.controls if (match := DESTINATION_LABEL.fullmatch(c.label))}
    if header := address_header(screen):
        areas.add(name_key(re.split('[：:]', header.label, maxsplit=1)[1]))
    return areas == {name_key(destination)}


def location_match(label, destination):
    heading, *details = CARD_SEPARATOR.split(label, maxsplit=1)
    name, requested = name_key(heading), name_key(destination)
    region = requested.removesuffix(name).rstrip('省市区县')
    if name and (name == requested or (details and region and requested.endswith(name) and region in name_key(details[0]))):
        return heading.strip()
    return None


def has_selected(screen, labels):
    return any(SELECTED_SUFFIX.search(c.label) and SELECTED_SUFFIX.sub('', c.label) in labels for c in screen.controls)


def choices(screen, labels):
    return [c for c in screen.controls if UNSELECTED_SUFFIX.sub('', c.label) in labels]


def pickup_mode(screen):
    return has_selected(screen, PICKUP_TABS) or bool(screen.exact('当前为到店自取', '当前为到店自提'))


def pickup_catalog(screen):
    return bool(screen.exact('自取好价') and screen.exact('奶茶咖啡') and screen.exact('自取'))


def pickup_catalog_cards(screen):
    cards = []
    for title, tag, distance in zip(screen.controls, screen.controls[1:], screen.controls[2:]):
        if tag.label != '自取好价' or title.role != 'StaticText' or not 2 <= len(title.label) <= 70:
            continue
        match = re.fullmatch(r'距您\s*(\d+(?:\.\d+)?)\s*(m|km|米|公里)', distance.label, re.IGNORECASE)
        if not match or not (title.ref + 2 == tag.ref + 1 == distance.ref):
            continue
        amount, units = match.groups()
        meters = round(float(amount) * (1 if units.lower() in ('m', '米') else 1000))
        cards.append((meters, title.label, tag))
    return cards


def native_pickup_checkout(screen):
    return bool(screen.contains('自取时间') and screen.contains('到店自取服务协议'))


def pickup_checkout(screen):
    addresses = {match[1].strip() for c in screen.controls if (match := PICKUP_ADDRESS.fullmatch(c.label))}
    if native_pickup_checkout(screen) and not addresses:
        distance_ref = min((c.ref for c in screen.controls if re.fullmatch(r'距您\s*[\d.]+\s*(?:km|m|公里|米)\+?', c.label)), default=0)
        addresses = {c.label.strip() for c in screen.controls if c.ref + 1 == distance_ref
                     and re.match(r'^[\u4e00-\u9fff]{2,10}市.+(?:区|县|镇|街道|路).+', c.label)
                     and not re.search('距您|自取时间|手机号|联系电话|联系人', c.label)}
    if (not pickup_mode(screen) and not native_pickup_checkout(screen)) or len(addresses) != 1 or any(DELIVERY_ADDRESS.fullmatch(c.label) for c in screen.controls):
        raise ReviewRequired('请在美团确认已选择到店自取，且结算页显示门店地址')
    return next(iter(addresses))


def order_quote(screen, plan, pickup_store=None):
    assert_app(screen)
    native = pickup_store is not None and native_pickup_checkout(screen)
    submit = choose([c for c in screen.exact('提交订单', '极速支付', '去支付', '立即支付', '确认支付') if c.role == 'Button']
                    if native else screen.exact('提交订单'), '请在美团打开订单结算页，确认提交按钮可见')
    totals = {amount_cents(match[1]) for c in screen.controls
              if (match := re.fullmatch(r'(?:应付|实付|合计|订单总价)\s*[:：]?\s*' + MONEY, c.label))}
    if native and not totals:
        currencies = {c.ref for c in screen.exact('¥', '￥') if 0 < submit.ref - c.ref <= 5}
        totals = {amount_cents(c.label) for c in screen.controls if (c.ref - 1 in currencies or c.ref + 1 in currencies)
                  and re.fullmatch(r'\d{1,6}(?:\.\d{1,2})?', c.label)}
    if len(totals) != 1:
        raise ReviewRequired('暂时无法核对美团实付金额，请查看结算页')
    total = next(iter(totals))
    if plan['budget_cents'] and total > plan['budget_cents']:
        raise ReviewRequired('实付金额超过语音给出的预算')
    stores = {match[1] for c in screen.controls if (match := STORE_LABEL.fullmatch(c.label))}
    addresses = {match[1] for c in screen.controls if (match := DELIVERY_ADDRESS.fullmatch(c.label))}
    lines = {(match[1].strip(), int(match[2])) for c in screen.controls
             if (match := re.fullmatch(r'(.+?)\s*[×xX]\s*(\d{1,2})\s*(?:件|份|杯)?', c.label))}
    if native and not lines:
        inline_price = r'(?:原价|单价|优惠价)\s*[¥￥]?\s*\d{1,6}(?:\.\d{1,2})?\s*元'
        lines = {(match[1].strip(), int(match[2])) for c in screen.controls
                 if (match := re.fullmatch(r'(.+?)(\d{1,2})\s*(?:份|杯|件)[，,]\s*' + inline_price + r'(?:\s*' + inline_price + r')?', c.label))}
    if pickup_store is not None:
        address = pickup_checkout(screen)
        if not stores and screen.exact(pickup_store):
            stores = {pickup_store}
        if len(stores) != 1 or name_key(next(iter(stores))) != name_key(pickup_store) or len(lines) != 1:
            raise ReviewRequired('自取结算页的门店或商品数量需要核对')
    elif len(stores) != 1 or len(addresses) != 1 or len(lines) != 1:
        raise ReviewRequired('结算页需清楚显示唯一店铺、商品数量和收货地址')
    else:
        address = next(iter(addresses))
    store = next(iter(stores))
    item, quantity = next(iter(lines))
    if (not item_matches(plan['query'], item) or quantity != plan['quantity'] or
            (plan['merchant'] and plan['merchant'] not in store) or
            not options_match(plan['options'], item)):
        raise ReviewRequired('结算页商品规格、数量或店铺与请求不一致')
    fees = sorted({c.label for c in screen.controls if re.fullmatch(r'(?:配送费|包装费)\s*[:：]?\s*' + MONEY, c.label)})
    summary = {'store': store, 'item': item, 'quantity': quantity, 'total_cents': total,
               'address': address[:4] + '…' + address[-2:], 'fees': fees}
    if pickup_store is not None:
        summary.update(pickup_address=address)
        summary.pop('address')
    quote_key = hashlib.sha256(json.dumps([store, item, quantity, total, address, fees], ensure_ascii=False).encode()).hexdigest()
    return summary, quote_key, submit


def address_search(screen, destination, tap, step, refresh):
    if screen.exact('热门城市'):
        screen = tap(screen, choose(screen.exact('返回'), '请退出上一次的城市选择页'))
    if not screen.exact('选择收货地址', '搜索地址') and (header := address_header(screen)):
        screen = tap(screen, header)
        if not screen.exact('选择收货地址', '搜索地址'):
            screen = refresh()
    query = destination
    if screen.exact('选择收货地址', '搜索地址'):
        entry = choose_optional(screen.exact('搜索您的收货地址'))
        city = choose_optional([c for c in screen.controls if entry and c.role == 'Button' and
                                c.ref == entry.ref - 1 and re.fullmatch(r'[\u4e00-\u9fff]{2,9}', c.label) and
                                c.label not in ('返回', '取消')])
        if city:
            current = city.label.removesuffix('市')
            if destination.startswith(current):
                query = destination[len(current):].lstrip('市') or destination
            else:
                screen = tap(screen, city)
                if not screen.exact('热门城市'):
                    screen = refresh()
                if not screen.exact('热门城市'):
                    raise ReviewRequired('美团城市选择页未打开，请核对自提目的地')
                def city_results(frame):
                    candidates = {}
                    for control in frame.controls:
                        label = control.label.strip()
                        if control.role != 'Button' or not re.fullmatch(r'[\u4e00-\u9fff]{2,8}市', label):
                            continue
                        prefix = label.removesuffix('市')
                        suffix = destination.removeprefix(prefix)
                        if suffix != destination and (suffix.startswith('市') or len(suffix) >= 3):
                            candidates.setdefault(label, (control, suffix.lstrip('市')))
                    return candidates

                candidates = city_results(screen)
                if not candidates:
                    screen = refresh()
                    candidates = city_results(screen)
                if candidates:
                    selected_city, query = choose(list(candidates.values()), '语音中的城市名对应多个美团选项')
                    screen = tap(screen, selected_city)
                    if not screen.exact(selected_city.label, selected_city.label.removesuffix('市')):
                        screen = refresh()
                    if not screen.exact(selected_city.label, selected_city.label.removesuffix('市')):
                        raise ReviewRequired('美团未切换到语音目的地所在城市')
                else:
                    screen = tap(screen, choose(screen.exact('返回'), '请核对美团当前城市'))
        if not screen.exact('搜索地址') and (entry := choose_optional([c for c in screen.exact('搜索您的收货地址') if c.role == 'Button'])):
            screen = tap(screen, entry)
    else:
        location = choose_optional(screen.exact('切换位置', '更换位置', '更换定位', '选择其他位置', '选择位置'))
        if location is None:
            location = choose_optional([c for c in screen.controls if c.role in INTERACTIVE and DESTINATION_LABEL.fullmatch(c.label)])
        if location:
            screen = tap(screen, location)

    def fields(frame):
        return [c for c in frame.controls if c.role in ('TextField', 'TextView', 'SearchField') and
                any(label in c.label for label in ('搜索您的收货地址', '搜索地点', '搜索地标', '搜索地址', '输入地址', '小区/写字楼/学校'))]

    if not fields(screen) and screen.exact('搜索地址'):
        screen = refresh()
    field = choose(fields(screen), '请在美团打开位置搜索，核对语音中的自提目的地')
    screen = step(screen, {'type': query, 'ref': field.ref, 'clear': True})

    def locations(frame):
        options = [(c, name) for c in frame.controls if c.role in INTERACTIVE and (name := location_match(c.label, destination))]
        return [(c, name) for c, name in options if name_key(name) == name_key(destination)] or options

    if not locations(screen):
        screen = refresh()
    place, selected = choose(locations(screen), '无法唯一匹配自提目的地，请补充城市、区或完整名称')
    screen = tap(screen, place)
    if not matches_destination(screen, selected):
        screen = refresh()
    if not matches_destination(screen, selected):
        raise ReviewRequired('美团未显示搜索位置已切换到目标地点，请在手机上核对')
    return screen, selected


def pickup_store_for(screen, plan, tap, step, refresh):
    destination = plan['pickup_destination']
    if not address_header(screen) and (takeout := choose_optional(screen.exact('外卖'))) and not matches_destination(screen, destination):
        screen = tap(screen, takeout)
    if not address_header(screen) and not pickup_mode(screen) and (pickup := choose_optional(choices(screen, PICKUP_TABS))):
        screen = tap(screen, pickup)

    if not matches_destination(screen, destination):
        screen, destination = address_search(screen, destination, tap, step, refresh)

    if not pickup_mode(screen) and not pickup_catalog(screen):
        if (filters := choose_optional(screen.exact('筛选'))) and not choices(screen, PICKUP_TABS):
            screen = tap(screen, filters)
        screen = tap(screen, choose(choices(screen, PICKUP_TABS), '请打开美团到店自取筛选'))
        if (apply := choose_optional(screen.exact('完成', '确认筛选', '查看结果'))):
            screen = tap(screen, apply)
        if not pickup_catalog(screen) and not pickup_mode(screen):
            screen = refresh()
    real_catalog = pickup_catalog(screen)
    if real_catalog and (category := choose_optional(screen.exact('奶茶咖啡'))):
        screen = tap(screen, category)
        if not pickup_catalog(screen):
            screen = refresh()
    distance_tapped = False
    if not has_selected(screen, DISTANCE_SORT) and not (real_catalog and screen.exact(*DISTANCE_SORT)):
        if (sorting := choose_optional(screen.exact('综合排序', '排序'))) and not choices(screen, DISTANCE_SORT):
            screen = tap(screen, sorting)
            if not choices(screen, DISTANCE_SORT) and not has_selected(screen, DISTANCE_SORT):
                screen = refresh()
    if not has_selected(screen, DISTANCE_SORT):
        screen = tap(screen, choose(choices(screen, DISTANCE_SORT), '请在美团选择按距离排序'))
        distance_tapped = True

    def ranked(frame):
        if not matches_destination(frame, destination):
            return False
        if not real_catalog:
            return pickup_mode(frame) and has_selected(frame, DISTANCE_SORT)
        cards = pickup_catalog_cards(frame)
        distances = [card[0] for card in cards]
        return pickup_catalog(frame) and (has_selected(frame, DISTANCE_SORT) or
                (distance_tapped or frame.exact(*DISTANCE_SORT)) and len(distances) >= 2 and distances == sorted(distances))

    if not ranked(screen):
        screen = refresh()
    if not ranked(screen):
        raise ReviewRequired('需要核对目的地、自取筛选和距离排序后才能选店')

    candidates = pickup_catalog_cards(screen) if real_catalog else []
    if not real_catalog:
        for control in screen.controls:
            if control.role not in INTERACTIVE:
                continue
            distances = list(STORE_DISTANCE.finditer(control.label))
            if len(distances) != 1:
                continue
            heading = CARD_SEPARATOR.split(control.label[:distances[0].start()], maxsplit=1)[0].strip(' ，,；;·')
            title = STORE_LABEL.fullmatch(heading)
            name = title[1].strip() if title else heading
            distance, units = distances[0].groups()
            meters = round(float(distance) * (1 if units.lower() in ('m', '米') else 1000))
            candidates.append((meters, name, control))
    if plan['merchant']:
        candidates = [card for card in candidates if name_key(plan['merchant']) in name_key(card[1])]
    else:
        candidates = [card for card in candidates if re.search(r'咖啡|coffee|星巴克|瑞幸|库迪|挪瓦|幸运咖|Manner|M Stand', card[1], re.IGNORECASE)]
    candidates.sort(key=lambda candidate: candidate[0])
    if not candidates or (len(candidates) > 1 and candidates[0][0] == candidates[1][0]):
        raise ReviewRequired('当前美团列表无法确认唯一最近的自取咖啡门店')
    _, name, control = candidates[0]
    screen = tap(screen, control)

    def store_visible(frame):
        if real_catalog:
            return bool(frame.exact('WMRestaurantView') and not pickup_catalog(frame))
        return any(c.label == name or ((match := STORE_LABEL.fullmatch(c.label)) and name_key(match[1]) == name_key(name))
                   for c in frame.controls)

    if not store_visible(screen):
        screen = refresh()
    if not store_visible(screen):
        raise ReviewRequired('请核对美团是否打开了选中的自取门店')
    return screen, name


def native_pickup_product(screen, query, tap, step, refresh):
    search = choose([c for c in screen.exact('搜索') if c.role == 'Other'], '请核对当前门店的店内搜索入口')
    screen = tap(screen, search)

    def submit_search(frame, text):
        fields = [c for c in frame.controls if c.role == 'TextField' and '请输入商品名' in c.label]
        if not fields:
            frame = refresh()
            fields = [c for c in frame.controls if c.role == 'TextField' and '请输入商品名' in c.label]
        field = choose(fields, '美团未打开店内商品搜索')
        frame = step(frame, {'type': text, 'ref': field.ref, 'clear': True})
        if not any(c.role == 'TextField' and text in c.label for c in frame.controls):
            frame = refresh()
        if not any(c.role == 'TextField' and text in c.label for c in frame.controls):
            raise ReviewRequired('请核对美团店内搜索商品名称')
        if (button := choose_optional(frame.exact('搜索'))):
            frame = tap(frame, button)
        return frame if frame.exact('选规格') else refresh()

    screen = submit_search(screen, query)
    titles = set()
    for control in screen.controls:
        if control.role != 'StaticText' or len(control.label) > 40:
            continue
        if query == '美式':
            if not re.fullmatch(r'(?:超大杯)?(?:经典|标准|原味|现磨|浓萃)?美式(?:咖啡)?(?:[（(](?:中|中杯|大|大杯|小|小杯)[）)])?', control.label):
                continue
        elif not item_matches(query, control.label):
            continue
        titles.add(control.label)
    exact = {title for title in titles if name_key(title) == name_key(query)}
    size_family = {re.sub(r'[（(][中大小]杯?[）)]$', '', title.removeprefix('超大杯')) for title in titles}
    medium = {title for title in titles if re.search(r'[（(]中杯?[）)]$', title)} if len(size_family) == 1 else set()
    name = choose(list(exact or medium or titles), '店内未找到唯一匹配的标准咖啡，请指定商品或杯型')
    if name_key(name) != name_key(query):
        screen = submit_search(screen, name)
    title = choose(screen.exact(name), '请核对店内搜索的目标商品')
    spec = choose([c for c in screen.exact('选规格', '选择规格') if 0 < c.ref - title.ref <= 12], '请核对目标咖啡的规格按钮')
    screen = tap(screen, spec)
    if not screen.exact('加入购物车', '加入购物袋'):
        screen = refresh()
    if not screen.exact('加入购物车', '加入购物袋') or not screen.exact(name):
        raise ReviewRequired('美团未打开目标咖啡的规格页')
    return screen


def pickup_product_plan(plan):
    normalized = dict(plan)
    if (style := re.fullmatch(r'([热冰黑])(美式(?:咖啡)?|拿铁)', plan['query'])):
        normalized['query'] = style[2].removesuffix('咖啡')
        normalized['options'] = '、'.join(dict.fromkeys(
            filter(None, ('无奶' if style[1] == '黑' else style[1], *re.split('[,，、]', plan['options'])))))
    return normalized


def prepare(poki, plan, active, allow_checkout):
    pickup = bool(dict(plan).get('pickup_destination'))
    checkout_enabled = lambda: pickup or allow_checkout()

    def step(screen, action):
        if not active():
            raise ReviewRequired('任务已取消或超时')
        assert_app(screen)
        frame = poki.action(action)
        assert_app(frame)
        return frame

    def tap(screen, control):
        if control is None or PURCHASE.search(control.label) or (control.label in CHECKOUT and not checkout_enabled()):
            raise ReviewRequired('找不到可以安全执行的页面控件，请查看美团')
        return step(screen, {'tap': control.ref})

    def refresh():
        frame = poki.look(full_evidence=True)
        assert_app(frame)
        return frame

    screen = poki.look()
    if screen.app != APP_ID:
        if not active():
            raise ReviewRequired('任务已取消或超时')
        screen = poki.action({'launch': APP_ID})
    assert_app(screen)
    if screen.exact('提交订单') or (pickup and native_pickup_checkout(screen)):
        if pickup:
            raise ReviewRequired('美团已打开其他结算页，请先返回外卖首页')
        if not allow_checkout():
            raise ReviewRequired('本次任务只执行搜索和加购，请先返回美团商品页')
        return order_quote(screen, plan)
    search_entries = ('搜索入口', '搜索外卖、商家或商品', '搜索商家、商品', '搜索美食', '搜索')

    def reread(frame, known):
        if poki.fast is True and not known(frame):
            frame = poki.look(full_evidence=True)
            assert_app(frame)
        return frame

    def search_fields(frame):
        return [c for c in frame.controls if c.role in ('TextField', 'TextView') and ('搜索' in c.label or not c.label)]

    def focused_search(frame):
        return bool(frame.exact('搜索') and (frame.contains('猜你想搜') or
                    (frame.exact('历史搜索') and frame.contains('下一个键盘'))))

    def products(frame):
        return [c for c in frame.controls if c.role in ('Button', 'Cell', 'Link', 'StaticText')
                and len(c.label) <= 42 and not c.label.startswith(('(#', '搜索')) and not PURCHASE.search(c.label)
                and item_matches(plan['query'], c.label)]

    def cart_count(frame):
        counts = {int(match[1]) for control in frame.controls
                  if (match := re.search(r'已添加\s*(\d+)\s*件商品', control.label))}
        return next(iter(counts)) if len(counts) == 1 else None

    if cart_count(screen):
        raise ReviewRequired('当前店铺购物车已有商品，请在美团核对，避免重复加购')
    pickup_store = None
    native_menu = False
    if pickup:
        screen, pickup_store = pickup_store_for(screen, plan, tap, step, refresh)
        plan = pickup_product_plan(plan)
        native_menu = bool(screen.exact('WMRestaurantView'))
        if native_menu:
            screen = native_pickup_product(screen, plan['query'], tap, step, refresh)
        if not native_menu and not products(screen):
            screen = refresh()
        if not native_menu and not products(screen):
            raise ReviewRequired('当前自取门店未找到明确匹配的咖啡，请在美团核对')
    if not native_menu and not products(screen):
        screen = reread(screen, lambda frame: frame.exact(*search_entries) or search_fields(frame) or focused_search(frame))
        candidates = screen.exact(*search_entries)
        if not candidates and not search_fields(screen) and (home := choose_optional(screen.exact('首页'))):
            screen = tap(screen, home)
        takeout = choose_optional(screen.exact('外卖'))
        if takeout and screen.exact('搜索入口', '搜索外卖、商家或商品'):
            screen = tap(screen, takeout)
        if screen.exact('定位失败', '定位服务未开启'):
            raise ReviewRequired('请在美团选择收货地址并关闭遮挡搜索框的定位提示')
        field = choose_optional(search_fields(screen))
        if not field and not focused_search(screen):
            entry = next((choice for label in search_entries if (choice := choose_optional(screen.exact(label)))), None)
            if not entry:
                raise ReviewRequired('无法定位美团搜索入口')
            screen = tap(screen, entry)
            screen = reread(screen, lambda frame: search_fields(frame) or focused_search(frame))
            field = choose_optional(search_fields(screen))
        if not field and not focused_search(screen):
            raise ReviewRequired('请确认美团搜索框处于输入状态')
        search_query = ' '.join(filter(None, (plan['merchant'], plan['query'])))
        action = {'type': search_query, 'ref': field.ref, 'clear': True} if field else {'type': search_query}
        screen = step(screen, action)
        if not any(search_query in c.label for c in screen.controls if c.role in ('TextField', 'TextView', 'SearchField')):
            raise ReviewRequired('请核对美团搜索框中的输入')
        screen = step(screen, {'key': 'return'})
        if not products(screen):
            screen = poki.look(full_evidence=True)
            assert_app(screen)
    if not screen.exact('加入购物车', '加入购物袋'):
        product = choose(products(screen), '美团搜索结果不唯一，请指定店铺或商品')
        selectors = [c for c in screen.exact('选规格', '选择规格') if 0 < c.ref - product.ref <= 12]
        if not selectors:
            screen = tap(screen, product)
            product = choose(products(screen), '请在美团核对商品名称') if not screen.exact('加入购物车', '加入购物袋') else product
            selectors = [c for c in screen.exact('选规格', '选择规格') if 0 < c.ref - product.ref <= 12]
        if selectors:
            screen = tap(screen, choose(selectors, '请在美团核对对应商品的规格按钮'))
            if not screen.exact('加入购物车', '加入购物袋'):
                screen = poki.look(full_evidence=True)
                assert_app(screen)
    for option in filter(None, (part.strip() for part in re.split(r'[,，、]', plan['options']))):
        selected = [c.label for c in screen.controls if c.label.startswith('已选规格')]
        if not any(options_match(option, label) for label in selected):
            targets = screen.exact(*option_variants(option))
            if native_menu and not targets and option in ('热', '冰'):
                targets = [c for c in screen.controls if re.search(rf'[/／]{option}[）)]$', c.label)]
            screen = tap(screen, choose(targets, '请核对商品规格选项'))
            if native_menu and not any(options_match(option, c.label) for c in screen.controls if c.label.startswith('已选规格')):
                screen = refresh()
    if plan['options'] and not any(options_match(plan['options'], c.label) for c in screen.controls if c.label.startswith('已选规格')):
        raise ReviewRequired('请确认所选规格与语音需求一致')
    if plan['merchant'] and not native_menu and not screen.contains(plan['merchant']):
        raise ReviewRequired('请确认页面店铺与语音需求一致')
    if plan['quantity'] != 1:
        raise ReviewRequired('当前商品页需核对多份数量后继续')
    if cart_count(screen):
        raise ReviewRequired('当前店铺购物车已有商品，请在美团核对，避免重复加购')
    screen = tap(screen, choose(screen.exact('加入购物车', '加入购物袋'), '请检查商品是否可加购'))
    if not checkout_enabled():
        if cart_count(screen) != plan['quantity']:
            screen = poki.look()
            assert_app(screen)
        if cart_count(screen) != plan['quantity']:
            raise ReviewRequired('请查看美团购物车，确认商品是否已加购')
        return None
    screen = tap(screen, choose(screen.exact('去结算', '结算'), '请核对购物车后进入结算页'))
    if pickup:
        if native_menu and not native_pickup_checkout(screen) and not screen.exact('提交订单'):
            screen = refresh()
            if not native_pickup_checkout(screen) and (checkout := choose_optional(screen.exact('去结算', '结算'))):
                screen = tap(screen, checkout)
                if not native_pickup_checkout(screen) and not screen.exact('提交订单'):
                    screen = refresh()
        if native_pickup_checkout(screen):
            return order_quote(screen, plan, pickup_store)
        if not pickup_mode(screen):
            if not choices(screen, PICKUP_TABS) or not screen.exact('提交订单'):
                screen = refresh()
            if not pickup_mode(screen):
                if not screen.exact('提交订单'):
                    raise ReviewRequired('美团还未显示结算页，请在手机上核对')
                screen = tap(screen, choose(choices(screen, PICKUP_TABS), '当前门店结算页未显示到店自取'))
        if not pickup_mode(screen) or not screen.exact('提交订单') or not any(PICKUP_ADDRESS.fullmatch(c.label) for c in screen.controls):
            screen = refresh()
    return order_quote(screen, plan, pickup_store)


def run_worker(db_path, connect, state, device, allow_submit, allow_checkout, wakeup=None):
    with (state / 'delivery-worker.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        dispatch_worker(db_path, connect, state, device, allow_submit, allow_checkout, wakeup)


def dispatch_worker(db_path, connect, state, device, allow_submit, allow_checkout=lambda: False, wakeup=None):
    def active(task_id, expected):
        with closing(connect(db_path)) as db:
            row = task(db, task_id)
            return row['state'] == expected and int(time.time()) - row['created_at'] < MAX_AGE

    def update(task_id, expected, state, note, quote=None, fingerprint=None):
        with closing(connect(db_path)) as db, db:
            db.execute('''UPDATE delivery_tasks SET state=?, note=?, quote=?, quote_key=coalesce(?,quote_key), quote_fingerprint=?,
                          quoted_at=coalesce(?,quoted_at), updated_at=?
                          WHERE id=? AND state=?''', (state, note, json.dumps(quote, ensure_ascii=False) if quote else None,
                          uuid4().hex if state == 'awaiting_confirmation' else None, fingerprint,
                          int(time.time()) if state == 'awaiting_confirmation' else None, int(time.time()), task_id, expected))

    with closing(connect(db_path)) as db, db:
        db.execute("UPDATE delivery_tasks SET state='unknown', note='服务重启，请先人工核查美团订单' WHERE state='submitting'")
        db.execute("UPDATE delivery_tasks SET state='needs_input', note='服务重启，请手动检查购物车' WHERE state='preparing'")
    while True:
        if wakeup is not None:
            wakeup.clear()
        with closing(connect(db_path)) as db, db:
            db.execute('BEGIN IMMEDIATE')
            now = int(time.time())
            db.execute("UPDATE delivery_tasks SET state='needs_input', note='任务已过期，请核对美团购物车' WHERE state IN ('queued','awaiting_confirmation','approved') AND created_at<=?", (now - MAX_AGE,))
            db.execute("UPDATE delivery_tasks SET state='needs_input', note='自提结算待核对已超时，请在美团查看结算页或订单', updated_at=? WHERE state='pickup_checkout' AND updated_at<=?", (now, now - MAX_AGE))
            row = db.execute("SELECT * FROM delivery_tasks WHERE state IN ('queued','approved') ORDER BY rowid LIMIT 1").fetchone()
            if row and row['state'] == 'queued':
                db.execute("UPDATE delivery_tasks SET state='preparing', note='正在操控美团', updated_at=? WHERE id=?", (now, row['id']))
        if not row:
            if wakeup is None:
                time.sleep(0.45)
            else:
                wakeup.wait(0.45)
            continue
        task_id = row['id']
        preparing = row['state'] == 'queued'
        current = 'preparing' if preparing else 'approved'
        if not preparing and row['pickup_destination']:
            update(task_id, current, 'needs_input', '请在美团核对自取订单并提交付款')
            continue
        if not preparing and (not allow_checkout() or not allow_submit()):
            update(task_id, current, 'awaiting_confirmation', '当前仅搜索和加购',
                   json.loads(row['quote']), row['quote_fingerprint'])
            continue
        try:
            with Poki(state, device, fast=preparing) as poki:
                if preparing:
                    result = prepare(poki, row, lambda: active(task_id, 'preparing'), allow_checkout)
                    if result is None:
                        update(task_id, current, 'cart_prepared', '已加购，请在美团查看购物车')
                    else:
                        quote, key, _ = result
                        if row['pickup_destination']:
                            update(task_id, current, 'pickup_checkout', '请在美团核对门店、商品和实付金额后提交付款', quote)
                        else:
                            update(task_id, current, 'awaiting_confirmation', '请核对美团结算摘要', quote, key)
                    continue
                screen = poki.look()
                if screen.app != APP_ID and active(task_id, 'approved'):
                    screen = poki.action({'launch': APP_ID})
                quote, key, submit = order_quote(screen, row)
                if key != row['quote_fingerprint'] or now - row['quoted_at'] >= QUOTE_AGE:
                    update(task_id, current, 'awaiting_confirmation', '结算金额或订单信息变化，请重新确认', quote, key)
                    continue
                if not allow_checkout() or not allow_submit():
                    update(task_id, current, 'awaiting_confirmation', '首轮联调停在结算页', quote, key)
                    continue
                with closing(connect(db_path)) as db, db:
                    changed = db.execute('''UPDATE delivery_tasks SET state='submitting', note='正在提交', updated_at=?
                      WHERE id=? AND state='approved' AND quote_key=? AND quoted_at>? AND created_at>?''',
                      (int(time.time()), task_id, row['quote_key'], int(time.time()) - QUOTE_AGE, int(time.time()) - MAX_AGE)).rowcount
                if not changed:
                    continue
                current = 'submitting'
                after = poki.action({'tap': submit.ref})
                assert_app(after)
                if after.exact('下单成功', '订单已提交', '支付成功', '请在规定时间内完成支付', '等待支付'):
                    update(task_id, current, 'submitted', '美团已显示订单结果，请在美团查看', quote, key)
                else:
                    update(task_id, current, 'unknown', '请在美团订单页核查，系统不会重复提交', quote, key)
        except (ReviewRequired, InputUnknown, OSError, ValueError, KeyError) as error:
            if current == 'submitting':
                update(task_id, current, 'unknown', '提交结果待核查，请在美团查看订单', json.loads(row['quote']), row['quote_fingerprint'])
            else:
                message = str(error) if isinstance(error, (ReviewRequired, InputUnknown)) else '本地 Poki 或 iPhone 暂不可用'
                update(task_id, current, 'needs_input', message)
