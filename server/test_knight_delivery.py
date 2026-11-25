import base64
import contextlib
import hmac
import json
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

import knight_delivery as delivery
from knight_orders import database, initialize


PLAN = dict(query='热美式', merchant='示例咖啡', options='不加糖', quantity=1, budget_cents=2000)
DESTINATION = '深圳海上世界'
PICKUP_PLAN = dict(PLAN, merchant='', pickup_destination=DESTINATION)


def checkout(total='￥16.50', address='深圳测试地点'):
    controls = ('提交订单', '商家：示例咖啡', '美式咖啡（热、无糖） ×1', f'收货地址：{address}', f'实付 {total}', '配送费 ￥2')
    raw = 'app: 美团   read: now\n' + '\n'.join(f' {i} Button "{text}" [0,0,4,4]' for i, text in enumerate(controls, 1))
    return delivery.Screen(delivery.APP_ID, delivery.Screen.parse(raw).controls)


def pickup_frame(*labels):
    return delivery.Screen(delivery.APP_ID, tuple(delivery.Control(i, 'Button', label) for i, label in enumerate(labels, 1)))


class PickupTests(unittest.TestCase):
    def test_pickup_ride_requires_verified_checkout_and_explicit_request(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'orders.sqlite3'
            initialize(path)
            with contextlib.closing(database(path)) as db:
                _, order = delivery.enqueue(db, 'device', dict(PICKUP_PLAN, request_id='voice_ride_order_a'))
                task_id = order['id']
                order_lease = 'pickup-ride-order-lease'
                phone_lease = 'pickup-ride-phone-lease'
                delivery.claim_phone_task(db, {'lease': order_lease})
                with self.assertRaisesRegex(delivery.DeliveryError, 'verified_pickup_required'):
                    delivery.request_pickup_ride(db, task_id)
                place = dict(store='示例咖啡（测试店）', city='深圳市')
                quote = dict(store=place['store'], pickup_address='深圳市南山区示例路1号',
                             item='热美式（不加糖）', quantity=1, total_cents=830)
                delivery.finish_phone_task(db, task_id, dict(state='pickup_checkout', lease=order_lease,
                                                             navigation=place, quote=quote, cart_added=True))
                self.assertIn('请说开始导航', delivery.pickup_voice_feedback(db, task_id))
                self.assertIsNone(delivery.claim_pickup_ride(db, {'lease': phone_lease})[1])
                delivery.confirm_voice_pickup(db, task_id)
                self.assertIsNone(delivery.claim_pickup_ride(db, {'lease': phone_lease})[1])
                self.assertEqual(delivery.request_pickup_ride(db, task_id)[0], 201)
                self.assertEqual(delivery.request_pickup_ride(db, task_id)[0], 200)
                _, claimed = delivery.claim_pickup_ride(db, {'lease': phone_lease})
                self.assertEqual(claimed['place'], {**place, 'address': quote['pickup_address']})
                self.assertIsNone(delivery.pickup_ride_feedback(db, task_id))
                self.assertIsNone(delivery.claim_pickup_ride(db, {'lease': 'another-iphone-lease'})[1])
                with self.assertRaisesRegex(delivery.DeliveryError, 'pickup_ride_lease_invalid'):
                    delivery.finish_pickup_ride(db, task_id, {'lease': 'another-iphone-lease', 'state': 'active'})
                failed = dict(lease=phone_lease, state='failed', note='无法定位')
                delivery.finish_pickup_ride(db, task_id, failed)
                self.assertIn('未启动', delivery.pickup_ride_feedback(db, task_id)['text'])
                self.assertEqual(delivery.request_pickup_ride(db, task_id)[0], 201)
                delivery.claim_pickup_ride(db, {'lease': phone_lease})
                delivery.finish_pickup_ride(db, task_id, {'lease': phone_lease, 'state': 'active'})
                self.assertEqual(delivery.pickup_ride_feedback(db, task_id)['state'], 'active')
                self.assertIn('GPS 骑行导航已启动', delivery.list_tasks(db)['tasks'][0]['ride_note'])

    def test_cart_only_receipt_does_not_offer_navigation_or_payment(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'orders.sqlite3'
            initialize(path)
            with contextlib.closing(database(path)) as db:
                _, order = delivery.enqueue(db, 'device', dict(PICKUP_PLAN, request_id='voice_ride_cart_only'))
                lease = 'cart-before-checkout-lease'
                delivery.claim_phone_task(db, {'lease': lease})
                delivery.finish_phone_task(db, order['id'], dict(state='needs_input', lease=lease, cart_added=True,
                                                                  note='购物车页面待核对'))
                text = delivery.pickup_voice_feedback(db, order['id'])
                self.assertIn('商品已加购', text)
                self.assertNotIn('请说开始导航', text)
                self.assertNotIn('请在美团核对后付款', text)
                with self.assertRaisesRegex(delivery.DeliveryError, 'verified_pickup_required'):
                    delivery.request_pickup_ride(db, order['id'])

    def test_phone_claim_is_exclusive_and_reports_manual_checkout(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'orders.sqlite3'
            initialize(path)
            db = database(path)
            self.addCleanup(db.close)
            _, task = delivery.enqueue(db, 'device', dict(PICKUP_PLAN, request_id='phone_case_request01'))
            self.assertIsNone(delivery.pickup_voice_feedback(db, task['id']))
            lease = 'iphone-first-lease-123'
            _, claimed = delivery.claim_phone_task(db, {'lease': lease})
            self.assertEqual(claimed['id'], task['id'])
            self.assertEqual(claimed['state'], 'preparing')
            self.assertIsNone(delivery.pickup_voice_feedback(db, task['id']))
            self.assertNotIn('phone_lease', claimed)
            self.assertEqual(delivery.claim_phone_task(db, {'lease': lease})[1]['id'], task['id'])
            self.assertIsNone(delivery.claim_phone_task(db, {'lease': 'iphone-other-lease-99'})[1])
            quote = dict(store='示例咖啡', item='无糖热美式', pickup_address='示例路 1 号', total_cents=690, quantity=1)
            result = dict(lease=lease, state='pickup_checkout', quote=quote,
                          navigation={'store': '示例咖啡', 'city': '深圳市'})
            with self.assertRaisesRegex(delivery.DeliveryError, 'phone_lease_expired'):
                delivery.finish_phone_task(db, task['id'], dict(result, lease='iphone-other-lease-99'))
            with self.assertRaisesRegex(delivery.DeliveryError, 'invalid_phone_quote'):
                delivery.finish_phone_task(db, task['id'], dict(result, quote=dict(quote, total_cents=2001)))
            with self.assertRaisesRegex(delivery.DeliveryError, 'invalid_phone_result'):
                delivery.finish_phone_task(db, task['id'], dict(result, state='submitted'))
            with self.assertRaisesRegex(delivery.DeliveryError, 'invalid_pickup_navigation'):
                delivery.finish_phone_task(db, task['id'], dict(result, navigation={'store': '其他分店'}))
            _, finished = delivery.finish_phone_task(db, task['id'], result)
            self.assertEqual(finished['state'], 'pickup_checkout')
            self.assertEqual(finished['quote']['total_cents'], 690)
            self.assertEqual(finished['pickup_navigation'],
                             {'store': '示例咖啡', 'city': '深圳市', 'address': '示例路 1 号'})
            self.assertEqual(delivery.finish_phone_task(db, task['id'], result)[1], finished)
            speech = delivery.pickup_voice_feedback(db, task['id'])
            for detail in ('示例咖啡', '无糖热美式', '共1杯', '6.90元', '示例路 1 号', '请在美团核对后付款'):
                self.assertIn(detail, speech)
            self.assertNotIn('已下单', speech)
            key = b'board-test-key'
            envelope = delivery.pickup_bluetooth_receipt(
                db, task['id'], key, lambda _: ('item', 'store', 'quantity', 'total'))
            self.assertEqual(envelope['summary_source'], 'ai')
            packet = base64.b64decode(envelope['packet'])
            body, signature = packet[:-32], packet[-32:]
            self.assertEqual(signature, hmac.digest(key, body, 'sha256'))
            self.assertEqual(body[:34], b'K1' + task['id'].encode('ascii'))
            self.assertEqual(int.from_bytes(body[34:38], 'big'), envelope['expires_at'])
            bluetooth_text = body[38:].decode('utf-8')
            self.assertIn('无糖热美式。示例咖啡。共1杯。应付6.90元', bluetooth_text)
            self.assertNotIn('示例路', bluetooth_text)
            _, confirmation = delivery.confirm_voice_pickup(db, task['id'])
            self.assertIn('在手机美团核对并付款', confirmation['text'])
            confirmed = delivery.task(db, task['id'])
            self.assertEqual(confirmed['state'], 'pickup_checkout')
            self.assertEqual(confirmed['updated_at'], finished['updated_at'])
            self.assertIn('已语音确认', confirmed['note'])
            with patch('knight_delivery.time.time', return_value=finished['updated_at'] + delivery.MAX_AGE):
                self.assertIn('结算已过期', delivery.pickup_voice_feedback(db, task['id']))
                self.assertIsNone(delivery.pickup_bluetooth_receipt(db, task['id'], key))
                with self.assertRaisesRegex(delivery.DeliveryError, 'pickup_checkout_unavailable'):
                    delivery.confirm_voice_pickup(db, task['id'])

    def test_pickup_feedback_reports_a_stop_and_is_restricted_to_voice_orders(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'orders.sqlite3'
            initialize(path)
            db = database(path)
            self.addCleanup(db.close)
            _, task = delivery.enqueue(db, 'device', dict(PICKUP_PLAN, request_id='voice_feedback_stop01'))
            lease = 'voice-test-phone-lease'
            delivery.claim_phone_task(db, {'lease': lease})
            delivery.finish_phone_task(db, task['id'], {
                'state': 'needs_input', 'lease': lease, 'note': '门店未显示到店自取',
            })
            self.assertEqual(delivery.pickup_voice_feedback(db, task['id']),
                             '这笔美团自提还未完成。门店未显示到店自取。')
            _, manual = delivery.enqueue(db, 'phone', dict(PICKUP_PLAN, request_id='manual_feedback_case'))
            with self.assertRaisesRegex(delivery.DeliveryError, 'delivery_not_found'):
                delivery.pickup_voice_feedback(db, manual['id'])
            self.assertIsNone(delivery.pickup_bluetooth_receipt(db, manual['id'], b'board-test-key'))
            with self.assertRaisesRegex(delivery.DeliveryError, 'delivery_not_found'):
                delivery.confirm_voice_pickup(db, manual['id'])
            self.assertEqual(delivery.pickup_voice_feedback(db, 'latest'),
                             delivery.pickup_voice_feedback(db, task['id']))

    def test_verified_pickup_can_navigate_while_order_needs_input(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'orders.sqlite3'
            initialize(path)
            with contextlib.closing(database(path)) as db:
                _, task = delivery.enqueue(db, 'phone', dict(PICKUP_PLAN, request_id='pickup_navigation_test'))
                lease = 'navigation-test-phone-lease'
                delivery.claim_phone_task(db, {'lease': lease})
                result = dict(state='needs_input', lease=lease, note='请确认甜度')
                with self.assertRaisesRegex(delivery.DeliveryError, 'invalid_pickup_navigation'):
                    delivery.finish_phone_task(db, task['id'], dict(result, navigation={'store': '示例咖啡', 'city': 'invalid'}))
                place = {'store': '示例咖啡', 'city': '深圳市'}
                _, finished = delivery.finish_phone_task(db, task['id'], dict(result, navigation=place))
                self.assertEqual(finished['pickup_navigation'], place)
                self.assertIsNone(finished['quote'])

    def test_voice_clarification_resumes_once_with_original_pickup_details(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'orders.sqlite3'
            initialize(path)
            with database(path) as db:
                original_fields = dict(PICKUP_PLAN, query='橙C咖啡', merchant='库迪',
                                       options='无糖、加冰、大杯', request_id='voice_clarification_a')
                _, original = delivery.enqueue(db, 'device', original_fields)
                lease = 'phone-voice-lease-a'
                delivery.claim_phone_task(db, {'lease': lease})
                place = {'store': '库迪咖啡（测试店）', 'city': '深圳市'}
                result = {'state': 'needs_input', 'lease': lease, 'navigation': place,
                          'note': '请说出糖度', 'clarification': 'no_added_sugar'}
                with self.assertRaisesRegex(delivery.DeliveryError, 'invalid_pickup_clarification'):
                    delivery.finish_phone_task(db, original['id'], {**result, 'navigation': None})
                delivery.finish_phone_task(db, original['id'], result)
                self.assertIn('你接受不额外加糖吗', delivery.pickup_voice_feedback(db, original['id']))
                reply = {'request_id': 'voice_clarification_reply', 'selection': '不额外加糖'}
                with self.assertRaisesRegex(delivery.DeliveryError, 'invalid_pickup_selection'):
                    delivery.continue_voice_pickup(db, original['id'], {**reply, 'selection': '同意'})
                status, resumed = delivery.continue_voice_pickup(db, original['id'], reply)
                self.assertEqual(status, 201)
                self.assertNotEqual(resumed['id'], original['id'])
                self.assertEqual(resumed['state'], 'queued')
                self.assertEqual(resumed['options'], '不额外加糖、加冰、大杯')
                for field in ('query', 'merchant', 'quantity', 'budget_cents', 'pickup_destination'):
                    self.assertEqual(resumed[field], original_fields[field])
                self.assertEqual(resumed['resumed_from'], original['id'])
                self.assertTrue(resumed['voice_request'])
                self.assertEqual(delivery.continue_voice_pickup(db, original['id'], reply)[1]['id'], resumed['id'])
                with self.assertRaisesRegex(delivery.DeliveryError, 'pickup_clarification_unavailable'):
                    delivery.continue_voice_pickup(db, original['id'], {**reply, 'request_id': 'voice_clarification_other'})
                _, claimed = delivery.claim_phone_task(db, {'lease': 'phone-voice-lease-b'})
                self.assertEqual(claimed['expected_pickup_store'], place['store'])
                self.assertIsNone(claimed['quote'])
                self.assertEqual(delivery.task(db, original['id'])['state'], 'reviewed')

    def test_voice_clarification_expires_and_legacy_stop_never_resumes(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'orders.sqlite3'
            initialize(path)
            with database(path) as db:
                _, original = delivery.enqueue(db, 'device', dict(PICKUP_PLAN, request_id='voice_clarification_expire'))
                lease = 'phone-voice-lease-c'
                delivery.claim_phone_task(db, {'lease': lease})
                result = {'state': 'needs_input', 'lease': lease, 'navigation': {'store': '测试店', 'city': '深圳市'}}
                delivery.finish_phone_task(db, original['id'], result)
                reply = {'request_id': 'voice_clarification_expired', 'selection': '不额外加糖'}
                with self.assertRaisesRegex(delivery.DeliveryError, 'pickup_clarification_unavailable'):
                    delivery.continue_voice_pickup(db, original['id'], reply)
                with db:
                    db.execute("UPDATE delivery_tasks SET clarification='no_added_sugar', updated_at=0 WHERE id=?",
                               (original['id'],))
                self.assertIn('已过期', delivery.pickup_voice_feedback(db, original['id']))
                with self.assertRaisesRegex(delivery.DeliveryError, 'pickup_clarification_unavailable'):
                    delivery.continue_voice_pickup(db, original['id'], reply)

    def test_native_address_picker_switches_city_and_confirms_the_exact_poi(self):
        def frame(*controls):
            return delivery.Screen(delivery.APP_ID, controls)

        home = pickup_frame('地址:原位置')
        pick_city = frame(delivery.Control(1, 'StaticText', '选择收货地址'),
                          delivery.Control(2, 'Button', '广州'), delivery.Control(3, 'Button', '搜索您的收货地址'))
        cities = frame(delivery.Control(1, 'StaticText', '热门城市'), delivery.Control(2, 'Button', '深圳市'),
                       delivery.Control(4, 'Button', '深圳市'))
        chosen_city = frame(delivery.Control(1, 'StaticText', '选择收货地址'), delivery.Control(2, 'Button', '深圳市'),
                            delivery.Control(3, 'Button', '搜索您的收货地址'))
        query = frame(delivery.Control(1, 'StaticText', '搜索地址'), delivery.Control(2, 'Button', '深圳市'),
                      delivery.Control(3, 'TextField', '搜索您的收货地址'))
        results = pickup_frame('海上世界文化艺术中心，广东省深圳市南山区', '深圳海上世界，广东省深圳市南山区')
        selected = pickup_frame('地址:深圳海上世界')
        with patch('knight_delivery.Poki') as factory:
            phone = factory.return_value
            phone.action.side_effect = [pick_city, cities, chosen_city, query, results, selected]
            final, place = delivery.address_search(home, DESTINATION,
                lambda _, control: phone.action({'tap': control.ref}), lambda _, action: phone.action(action), phone.look)
        self.assertEqual(place, DESTINATION)
        self.assertTrue(delivery.matches_destination(final, DESTINATION))
        self.assertIn({'type': '海上世界', 'ref': 3, 'clear': True}, [call.args[0] for call in phone.action.call_args_list])

    def test_native_pickup_cards_use_the_price_tag_from_the_matching_row(self):
        screen = delivery.Screen(delivery.APP_ID, (
            delivery.Control(30, 'StaticText', '奶茶咖啡'), delivery.Control(31, 'StaticText', '自取'),
            delivery.Control(40, 'StaticText', '示例茶饮（深圳海上世界店）'),
            delivery.Control(41, 'StaticText', '自取好价'), delivery.Control(42, 'StaticText', '距您109m'),
            delivery.Control(66, 'StaticText', '示例咖啡（南山海上世界店）'),
            delivery.Control(67, 'StaticText', '自取好价'), delivery.Control(68, 'StaticText', '距您402m'),
        ))
        self.assertTrue(delivery.pickup_catalog(screen))
        self.assertEqual([(distance, link.ref) for distance, _, link in delivery.pickup_catalog_cards(screen)], [(109, 41), (402, 67)])
        self.assertTrue(delivery.options_match('热、无糖', '已选规格：浓萃美式（中/热）、无糖、无奶'))

    def test_native_checkout_quotes_manual_payment_from_pickup_summary(self):
        branch = '示例咖啡（海上世界店）'
        screen = delivery.Screen(delivery.APP_ID, (
            delivery.Control(9, 'Other', '深圳市南山区示例路一楼'), delivery.Control(10, 'Other', '距您99km+'),
            delivery.Control(14, 'Other', '自取时间23:28'), delivery.Control(24, 'Button', '《到店自取服务协议》'),
            delivery.Control(25, 'Other', branch + '，浓萃美式，1份,原价16元优惠价6.9元，商品原价，¥，16'),
            delivery.Control(29, 'StaticText', branch),
            delivery.Control(30, 'Other', '浓萃美式（中）,浓萃美式（中/冰），无糖，无奶1份,原价16元优惠价6.9元'),
            delivery.Control(121, 'StaticText', '6.9'), delivery.Control(122, 'StaticText', '¥'),
            delivery.Control(123, 'StaticText', '共减¥9.1'), delivery.Control(124, 'Button', '极速支付'),
        ))
        plan = delivery.pickup_product_plan(dict(PICKUP_PLAN, query='黑美式', options='无糖'))
        quote, _, payment = delivery.order_quote(screen, plan, branch)
        self.assertEqual(quote['pickup_address'], '深圳市南山区示例路一楼')
        self.assertEqual(quote['total_cents'], 690)
        self.assertTrue(delivery.PURCHASE.search(payment.label))
        with self.assertRaisesRegex(delivery.ReviewRequired, '超过'):
            delivery.order_quote(screen, dict(plan, budget_cents=600), branch)

    def test_destination_nearest_store_and_manual_checkout(self):
        store = '示例咖啡（海上世界店）'
        purpose = '当前定位：海上世界'
        sorted_nearby = pickup_frame(purpose, '到店自取 = 1', '距离优先 = 1',
                                     '样本咖啡（滨海店），距离700m', f'{store}，距离0.4公里')
        start = pickup_frame('外卖')
        address_search = delivery.Screen(delivery.APP_ID, (delivery.Control(1, 'SearchField', '搜索地点'),))
        final = pickup_frame('提交订单', '到店自取 = 已选中', f'门店：{store}', '自取地址：海上世界东门一楼',
                             '美式咖啡（热、无糖） ×1', '实付 ￥16.50')
        with patch('knight_delivery.Poki') as factory:
            phone = factory.return_value
            phone.look.return_value = start
            phone.action.side_effect = [pickup_frame('到店自取'), pickup_frame('切换位置'), address_search,
                                        pickup_frame('海上世界，广东省深圳市南山区'),
                                        pickup_frame(purpose, '到店自取 = 已选中', '距离优先'), sorted_nearby,
                                        pickup_frame(f'店铺：{store}', '美式咖啡', '选规格'),
                                        pickup_frame('加入购物车', '已选规格：热、无糖'), pickup_frame('去结算'),
                                        pickup_frame('提交订单', '到店自取 = 0', '收货地址：原地址'), final]
            quote, _, _ = delivery.prepare(phone, PICKUP_PLAN, lambda: True, lambda: False)
        self.assertEqual(quote['store'], store)
        self.assertEqual(quote['pickup_address'], '海上世界东门一楼')
        self.assertEqual(quote['total_cents'], 1650)
        self.assertNotIn('address', quote)
        self.assertEqual(phone.action.call_args_list[6].args, ({'tap': 5},))
        self.assertEqual(phone.action.call_args_list[-1].args, ({'tap': 2},))
        self.assertEqual(phone.action.call_count, 11)

    def test_no_nearest_when_destination_is_ambiguous(self):
        screen = delivery.Screen(delivery.APP_ID, (delivery.Control(1, 'SearchField', '搜索地点'),))
        with patch('knight_delivery.Poki') as factory:
            phone = factory.return_value
            phone.look.return_value = screen
            phone.action.return_value = pickup_frame(f'{DESTINATION}，深圳市南山区', f'{DESTINATION}，另一个区')
            with self.assertRaisesRegex(delivery.ReviewRequired, '无法唯一匹配'):
                delivery.prepare(phone, PICKUP_PLAN, lambda: True, lambda: False)
            self.assertEqual(phone.action.call_count, 1)

    def test_pickup_quote_requires_selected_mode_and_correct_branch(self):
        controls = ['提交订单', '到店自取 = 已选中', '门店：示例咖啡（滨海店）', '自取地址：滨海路',
                    '美式咖啡（热、无糖） ×1', '实付 ￥16.50']
        with self.assertRaisesRegex(delivery.ReviewRequired, '门店或商品'):
            delivery.order_quote(pickup_frame(*controls), PICKUP_PLAN, '示例咖啡（海上世界店）')
        controls[1] = '到店自取'
        with self.assertRaisesRegex(delivery.ReviewRequired, '已选择到店自取'):
            delivery.order_quote(pickup_frame(*controls), PICKUP_PLAN, '示例咖啡（滨海店）')

    def test_worker_leaves_manual_checkout_even_when_submit_enabled(self):
        class Idle(Exception):
            pass

        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            path = folder / 'orders.sqlite3'
            initialize(path)
            with database(path) as db:
                _, record = delivery.enqueue(db, 'device', dict(PICKUP_PLAN, request_id='pickup_reference_123'))
                self.assertEqual(record['pickup_destination'], DESTINATION)
                quote = {'store': '示例咖啡（海上世界店）', 'pickup_address': '海上世界东门一楼'}
                with patch('knight_delivery.Poki') as factory, patch('knight_delivery.prepare', return_value=(quote, 'key', None)), \
                     patch('knight_delivery.time.sleep', side_effect=Idle):
                    with self.assertRaises(Idle):
                        delivery.dispatch_worker(path, database, folder, 'fixture', lambda: True, lambda: True)
                task_id = record['id']
                self.assertEqual(delivery.task(db, task_id)['state'], 'pickup_checkout')
                factory.return_value.__enter__.return_value.action.assert_not_called()
                with self.assertRaisesRegex(delivery.DeliveryError, 'checkout_only'):
                    delivery.decide(db, task_id, {'decision': 'approve', 'quote_key': 'key'}, True)
                _, result = delivery.decide(db, task_id, {'decision': 'acknowledge'}, True)
                self.assertEqual(result['state'], 'reviewed')


class CheckoutTests(unittest.TestCase):
    def setUp(self):
        self.storage = tempfile.TemporaryDirectory()
        self.addCleanup(self.storage.cleanup)
        path = Path(self.storage.name) / 'orders.sqlite3'
        initialize(path)
        self.db = database(path)
        self.addCleanup(self.db.close)
        _, record = delivery.enqueue(self.db, 'device', dict(PLAN, request_id='request_reference_123'))
        self.task_id = record['id']

    def assert_error(self, code, operation):
        with self.assertRaises(delivery.DeliveryError) as error:
            operation()
        self.assertEqual(error.exception.code, code)

    def set_quote(self, approval_id='current', quoted_at=None):
        quote, fingerprint, _ = delivery.order_quote(checkout(), PLAN)
        with self.db:
            self.db.execute('''UPDATE delivery_tasks SET state='awaiting_confirmation', quote=?, quote_key=?,
                 quote_fingerprint=?, quoted_at=? WHERE id=?''',
                 (json.dumps(quote), approval_id, fingerprint, quoted_at or int(time.time()), self.task_id))

    def test_quote_matches_amount_and_checkout(self):
        summary, key, submit = delivery.order_quote(checkout(), PLAN)
        self.assertEqual(summary['total_cents'], 1650)
        self.assertEqual(submit.label, '提交订单')
        self.assertNotEqual(key, delivery.order_quote(checkout('￥17.50'), PLAN)[1])
        self.assertNotEqual(key, delivery.order_quote(checkout(address='深圳另一个测试地点'), PLAN)[1])
        with self.assertRaises(delivery.ReviewRequired):
            delivery.order_quote(checkout('￥25'), PLAN)
        with self.assertRaises(delivery.ReviewRequired):
            delivery.order_quote(delivery.Screen('other', checkout().controls), PLAN)

    def test_sugar_preferences_do_not_match_opposites(self):
        self.assertTrue(delivery.options_match('大杯、不加糖', '已选规格：大杯、无糖、热'))
        self.assertFalse(delivery.options_match('加糖', '已选规格：大杯、不加糖'))
        self.assertFalse(delivery.options_match('不加糖', '已选规格：大杯、加糖'))
        self.assertFalse(delivery.options_match('无糖', '已选规格：大杯、热'))

    def test_existing_items_do_not_add_again(self):
        with patch('knight_delivery.Poki') as factory:
            phone = factory.return_value
            phone.look.return_value = delivery.Screen(delivery.APP_ID, (
                delivery.Control(1, 'Other', '购物车，已添加1件商品，点击查看'),))
            with self.assertRaises(delivery.ReviewRequired):
                delivery.prepare(phone, PLAN, lambda: True, lambda: False)
            phone.action.assert_not_called()

    def test_cart_only_stops_before_checkout(self):
        def frame(*controls):
            return delivery.Screen(delivery.APP_ID, controls)
        start = frame(delivery.Control(1, 'TextField', '搜索框'))
        result = frame(delivery.Control(2, 'Button', '热美式'))
        product = frame(delivery.Control(3, 'Button', '加入购物车'))
        cart = frame(delivery.Control(4, 'Other', '购物车，已添加1件商品，点击查看'),
                     delivery.Control(5, 'Button', '去结算'))
        with patch('knight_delivery.Poki') as factory:
            phone = factory.return_value
            phone.look.return_value = start
            phone.action.side_effect = [frame(delivery.Control(1, 'TextField', '热美式')), result, product, cart]
            self.assertIsNone(delivery.prepare(phone, dict(PLAN, merchant='', options=''), lambda: True, lambda: False))
            self.assertEqual(phone.action.call_args_list[-1].args, ({'tap': 3},))
            self.assertEqual(len(phone.action.call_args_list), 4)

    def test_checkout_hold_and_single_confirmation(self):
        self.set_quote()
        approve = {'decision': 'approve', 'quote_key': 'current'}
        self.assert_error('checkout_only', lambda: delivery.decide(self.db, self.task_id, approve, False))
        self.assert_error('quote_changed', lambda: delivery.decide(self.db, self.task_id,
                          {'decision': 'approve', 'quote_key': 'stale'}, True))
        self.assertEqual(delivery.decide(self.db, self.task_id, approve, True)[1]['state'], 'approved')
        self.assertEqual(delivery.decide(self.db, self.task_id, approve, True)[1]['state'], 'approved')
        self.assertEqual(delivery.decide(self.db, self.task_id, {'decision': 'cancel'}, True)[1]['state'], 'cancelled')
        self.assert_error('quote_expired', lambda: delivery.decide(self.db, self.task_id, approve, True))

    def test_expiry_and_request_id(self):
        self.set_quote(quoted_at=int(time.time()) - delivery.QUOTE_AGE - 1)
        self.assert_error('quote_expired', lambda: delivery.decide(self.db, self.task_id,
                          {'decision': 'approve', 'quote_key': 'current'}, True))
        self.assertEqual(delivery.enqueue(self.db, 'device', dict(PLAN, request_id='request_reference_123'))[1]['id'], self.task_id)
        self.assert_error('request_id_reused', lambda: delivery.enqueue(self.db, 'device',
                          dict(PLAN, request_id='request_reference_123', quantity=2)))
        self.assert_error('delivery_busy', lambda: delivery.enqueue(self.db, 'phone',
                          dict(PLAN, request_id='different_example_123')))

    def process_approval(self, frame, result, allow_submit=True):
        approval = {'decision': 'approve', 'quote_key': 'current'}
        self.set_quote()
        delivery.decide(self.db, self.task_id, approval, True)
        class Idle(Exception):
            pass
        folder = Path(self.storage.name)
        with patch('knight_delivery.Poki') as factory, patch('knight_delivery.time.sleep', side_effect=Idle):
            phone = factory.return_value.__enter__.return_value
            phone.look.return_value = frame
            if isinstance(result, Exception):
                phone.action.side_effect = result
            else:
                phone.action.return_value = result
            with self.assertRaises(Idle):
                delivery.dispatch_worker(folder/'orders.sqlite3', database, folder, 'fixture', lambda: allow_submit, lambda: allow_submit)
            return delivery.task(self.db, self.task_id), phone.action.call_args_list

    def test_amount_changed_before_dispatch_requires_new_approval(self):
        row, actions = self.process_approval(checkout('￥17.50'), None)
        self.assertEqual(row['state'], 'awaiting_confirmation')
        self.assertNotEqual(row['quote_key'], 'current')
        self.assertEqual(actions, [])

    def test_disabled_submit_performs_no_action(self):
        row, actions = self.process_approval(checkout(), None, allow_submit=False)
        self.assertEqual(row['state'], 'awaiting_confirmation')
        self.assertEqual(actions, [])

    def test_success_sends_single_submission(self):
        result = delivery.Screen(delivery.APP_ID, (delivery.Control(2, 'Text', '订单已提交'),))
        row, actions = self.process_approval(checkout(), result)
        self.assertEqual(row['state'], 'submitted')
        self.assertEqual([action.args for action in actions], [({'tap': 1},)])
        self.assertEqual(delivery.decide(self.db, self.task_id,
                         {'decision': 'approve', 'quote_key': 'current'}, True)[1]['state'], 'submitted')

    def test_unknown_submit_blocks_next_task(self):
        row, actions = self.process_approval(checkout(), delivery.InputUnknown('timeout'))
        self.assertEqual(row['state'], 'unknown')
        self.assertEqual(len(actions), 1)
        self.assert_error('delivery_busy', lambda: delivery.enqueue(self.db, 'phone',
                          dict(PLAN, request_id='different_example_999')))


if __name__ == '__main__':
    unittest.main()
