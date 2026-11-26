#include "phone_pointer.h"
#include "knight_order.h"

#include "sdkconfig.h"

#if CONFIG_BT_BLE_ENABLED && CONFIG_BT_BLUEDROID_ENABLED
#include "mcp_server.h"

#include <esp_bt.h>
#include <esp_bt_main.h>
#include <esp_gap_ble_api.h>
#include <esp_hidd.h>
#include <esp_hidd_gatts.h>
#include <esp_log.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cstdint>
#include <mutex>
#include <stdexcept>
#include <vector>

namespace {
constexpr char kTag[] = "PhonePointer";
constexpr char kDeviceName[] = "Knight Pointer";
constexpr uint32_t kReadyToAdvertise = 0b111;
constexpr uint32_t kHidStarted = 0b001;
constexpr uint32_t kAdvertisingDataReady = 0b010;
constexpr uint32_t kScanResponseReady = 0b100;
constexpr uint8_t kLeftButton = 1;

// Mouse input report: three button bits and padding, followed by signed X/Y and wheel.
constexpr uint8_t kMouseReportMap[] = {
    0x05, 0x01, 0x09, 0x02, 0xa1, 0x01, // Generic desktop, mouse, application
    0x09, 0x01, 0xa1, 0x00,             // Pointer, physical collection
    0x05, 0x09, 0x19, 0x01, 0x29, 0x03,
    0x15, 0x00, 0x25, 0x01, 0x95, 0x03, 0x75, 0x01, 0x81, 0x02,
    0x95, 0x01, 0x75, 0x05, 0x81, 0x03, // Five constant padding bits
    0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x09, 0x38,
    0x15, 0x81, 0x25, 0x7f, 0x75, 0x08, 0x95, 0x03, 0x81, 0x06,
    0xc0, 0xc0,
};
esp_hid_raw_report_map_t mouse_map{.data = kMouseReportMap, .len = sizeof(kMouseReportMap)};
uint8_t hid_service_uuid[] = {
    0xfb, 0x34, 0x9b, 0x5f, 0x80, 0x00, 0x00, 0x80,
    0x00, 0x10, 0x00, 0x00, 0x12, 0x18, 0x00, 0x00,
};

std::atomic<esp_hidd_dev_t*> device{nullptr};
std::atomic<uint32_t> advertising_ready{0};
std::atomic<uint32_t> connection_generation{0};
std::atomic<bool> advertising{false};
std::atomic<bool> connected{false};
std::atomic<bool> encrypted{false};
std::atomic<bool> suspended{false};
std::mutex input_mutex;

#ifdef KNIGHT_ORDERS_CONFIGURED
constexpr uint16_t kReceiptAppId = 0x4b50;
constexpr uint8_t kReceiptServiceUuid[] = {
    0x31, 0xe3, 0xa0, 0x93, 0x3b, 0x77, 0x32, 0xbc, 0xfe, 0x42, 0x65, 0xdb, 0x10, 0x6f, 0x07, 0xa7,
};
std::atomic<bool> receipt_connected{false};
esp_gatt_if_t receipt_interface = ESP_GATT_IF_NONE;
uint16_t receipt_characteristic = 0;
uint16_t relay_characteristic = 0;
uint16_t relay_subscription = 0;
std::atomic<uint16_t> receipt_connection{0};
std::atomic<uint16_t> receipt_mtu{23};
std::atomic<bool> relay_subscribed{false};
std::atomic<int> relay_confirmation{0};
bool relay_cache_refreshed = false;
std::mutex relay_mutex;
uint16_t next_frame = 0;
std::vector<uint8_t> receipt_buffer;

esp_gatt_status_t AcceptReceiptFrame(const esp_ble_gatts_cb_param_t::gatts_write_evt_param& write) {
    if (write.is_prep || !write.need_rsp || write.offset != 0 || write.conn_id != receipt_connection) {
        return ESP_GATT_INVALID_PDU;
    }
    if (write.len == 2 && write.value[0] == 0x80 && write.value[1] == 0) {
        receipt_connected.store(true);
        ESP_LOGI(kTag, "Knight voice feedback channel connected");
        if (!relay_subscribed && !relay_cache_refreshed) {
            auto peer = write.bda;
            esp_bd_addr_t address;
            std::copy_n(peer, sizeof(address), address);
            relay_cache_refreshed = esp_ble_gatts_send_service_change_indication(receipt_interface, address) == ESP_OK;
        }
        return ESP_GATT_OK;
    }
    if (!receipt_connected.load() || write.len < 3) return ESP_GATT_INVALID_PDU;
    const uint8_t flags = write.value[0];
    const uint8_t frame = write.value[1];
    if (flags & ~3) return ESP_GATT_INVALID_PDU;
    if ((flags & 1) && frame == 0) {
        receipt_buffer.clear();
        next_frame = 0;
    }
    if (frame != next_frame || (next_frame == 0 && !(flags & 1)) ||
        (next_frame != 0 && (flags & 1)) || receipt_buffer.size() + write.len - 2 > 2048) {
        receipt_buffer.clear();
        next_frame = 0;
        return ESP_GATT_INVALID_PDU;
    }
    receipt_buffer.insert(receipt_buffer.end(), write.value + 2, write.value + write.len);
    ++next_frame;
    if (!(flags & 2)) return ESP_GATT_OK;
    const bool accepted = ReceiveKnightPickupFeedback(receipt_buffer.data(), receipt_buffer.size());
    receipt_buffer.clear();
    next_frame = 0;
    return accepted ? ESP_GATT_OK : ESP_GATT_WRITE_NOT_PERMIT;
}

bool HandleReceiptGatt(esp_gatts_cb_event_t event, esp_gatt_if_t interface,
                       esp_ble_gatts_cb_param_t* data) {
    if (event == ESP_GATTS_REG_EVT && data->reg.app_id == kReceiptAppId) {
        if (data->reg.status != ESP_GATT_OK) return true;
        receipt_interface = interface;
        esp_gatt_srvc_id_t service{};
        service.is_primary = true;
        service.id.uuid.len = ESP_UUID_LEN_128;
        std::copy_n(kReceiptServiceUuid, ESP_UUID_LEN_128, service.id.uuid.uuid.uuid128);
        esp_ble_gatts_create_service(interface, &service, 6);
        return true;
    }
    if (receipt_interface == ESP_GATT_IF_NONE || interface != receipt_interface) return false;
    switch (event) {
    case ESP_GATTS_CREATE_EVT: {
        if (data->create.status != ESP_GATT_OK) break;
        esp_bt_uuid_t characteristic{};
        characteristic.len = ESP_UUID_LEN_128;
        std::copy_n(kReceiptServiceUuid, ESP_UUID_LEN_128, characteristic.uuid.uuid128);
        characteristic.uuid.uuid128[12] = 0x11;
        esp_attr_control_t control{ESP_GATT_RSP_BY_APP};
        esp_attr_value_t value{};
        value.attr_max_len = 182;
        esp_ble_gatts_add_char(data->create.service_handle, &characteristic,
                               ESP_GATT_PERM_WRITE_ENCRYPTED, ESP_GATT_CHAR_PROP_BIT_WRITE, &value, &control);
        break;
    }
    case ESP_GATTS_ADD_CHAR_EVT: {
        if (data->add_char.status != ESP_GATT_OK) break;
        auto uuid = data->add_char.char_uuid;
        const auto service = data->add_char.service_handle;
        if (uuid.uuid.uuid128[12] == 0x11) {
            receipt_characteristic = data->add_char.attr_handle;
            uuid.uuid.uuid128[12] = 0x12;
            esp_ble_gatts_add_char(service, &uuid, ESP_GATT_PERM_READ_ENCRYPTED, ESP_GATT_CHAR_PROP_BIT_INDICATE,
                                   nullptr, nullptr);
        } else {
            relay_characteristic = data->add_char.attr_handle;
            esp_bt_uuid_t descriptor{};
            descriptor.len = ESP_UUID_LEN_16;
            descriptor.uuid.uuid16 = ESP_GATT_UUID_CHAR_CLIENT_CONFIG;
            esp_attr_control_t control{ESP_GATT_RSP_BY_APP};
            esp_ble_gatts_add_char_descr(service, &descriptor, ESP_GATT_PERM_WRITE_ENCRYPTED, nullptr, &control);
        }
        break;
    }
    case ESP_GATTS_ADD_CHAR_DESCR_EVT:
        if (data->add_char_descr.status == ESP_GATT_OK) {
            relay_subscription = data->add_char_descr.attr_handle;
            esp_ble_gatts_start_service(data->add_char_descr.service_handle);
        }
        break;
    case ESP_GATTS_START_EVT:
        ESP_LOGI(kTag, "Knight voice feedback service start status=%u relay=0x%04x", data->start.status, relay_characteristic);
        break;
    case ESP_GATTS_SEND_SERVICE_CHANGE_EVT:
        ESP_LOGI(kTag, "Knight voice relay service refresh status=%u", data->service_change.status);
        break;
    case ESP_GATTS_CONNECT_EVT:
        receipt_connection = data->connect.conn_id;
        receipt_mtu = 23;
        receipt_connected.store(false);
        relay_subscribed = false;
        relay_cache_refreshed = false;
        receipt_buffer.clear();
        next_frame = 0;
        break;
    case ESP_GATTS_DISCONNECT_EVT:
        receipt_connected.store(false);
        relay_subscribed = false;
        receipt_buffer.clear();
        next_frame = 0;
        break;
    case ESP_GATTS_MTU_EVT:
        if (data->mtu.conn_id == receipt_connection) receipt_mtu = data->mtu.mtu;
        break;
    case ESP_GATTS_CONF_EVT:
        if (data->conf.handle == relay_characteristic && data->conf.conn_id == receipt_connection) {
            relay_confirmation = data->conf.status == ESP_GATT_OK ? 1 : -1;
        }
        break;
    case ESP_GATTS_WRITE_EVT: {
        if (!data->write.need_rsp) break;
        const auto& write = data->write;
        auto status = ESP_GATT_INVALID_HANDLE;
        if (write.handle == receipt_characteristic) status = AcceptReceiptFrame(write);
        if (write.handle == relay_subscription && write.conn_id == receipt_connection && !write.is_prep &&
            write.offset == 0 && write.len == 2 && write.value[1] == 0 && (write.value[0] == 2 || write.value[0] == 0)) {
            relay_subscribed = write.value[0] == 2;
            if (relay_subscribed) ESP_LOGI(kTag, "Knight voice relay subscribed");
            status = ESP_GATT_OK;
        }
        esp_ble_gatts_send_response(interface, write.conn_id, write.trans_id, status, nullptr);
        break;
    }
    default:
        break;
    }
    return true;
}
#endif

bool CanSend() {
    return device.load() != nullptr && connected.load() && encrypted.load() && !suspended.load();
}

void StartAdvertising() {
    if (device.load() == nullptr || advertising_ready.load() != kReadyToAdvertise ||
        connected.load() || advertising.exchange(true)) {
        return;
    }
    esp_ble_adv_params_t params{};
    params.adv_int_min = 0x30;
    params.adv_int_max = 0x60;
    params.adv_type = ADV_TYPE_IND;
    params.own_addr_type = BLE_ADDR_TYPE_PUBLIC;
    params.channel_map = ADV_CHNL_ALL;
    params.adv_filter_policy = ADV_FILTER_ALLOW_SCAN_ANY_CON_ANY;
    const esp_err_t err = esp_ble_gap_start_advertising(&params);
    if (err != ESP_OK) {
        advertising.store(false);
        ESP_LOGW(kTag, "BLE advertising request failed: %s", esp_err_to_name(err));
    }
}

void GapEvent(esp_gap_ble_cb_event_t event, esp_ble_gap_cb_param_t* param) {
    switch (event) {
#ifdef KNIGHT_ORDERS_CONFIGURED
    case ESP_GAP_BLE_ADV_DATA_RAW_SET_COMPLETE_EVT:
        if (param->adv_data_raw_cmpl.status == ESP_BT_STATUS_SUCCESS) {
            advertising_ready.fetch_or(kAdvertisingDataReady);
            StartAdvertising();
        }
        break;
#endif
    case ESP_GAP_BLE_ADV_DATA_SET_COMPLETE_EVT:
        if (param->adv_data_cmpl.status == ESP_BT_STATUS_SUCCESS) {
            advertising_ready.fetch_or(kAdvertisingDataReady);
            StartAdvertising();
        } else {
            ESP_LOGW(kTag, "Advertising data rejected: %u", param->adv_data_cmpl.status);
        }
        break;
    case ESP_GAP_BLE_SCAN_RSP_DATA_SET_COMPLETE_EVT:
        if (param->scan_rsp_data_cmpl.status == ESP_BT_STATUS_SUCCESS) {
            advertising_ready.fetch_or(kScanResponseReady);
            StartAdvertising();
        } else {
            ESP_LOGW(kTag, "Scan response rejected: %u", param->scan_rsp_data_cmpl.status);
        }
        break;
    case ESP_GAP_BLE_ADV_START_COMPLETE_EVT:
        if (param->adv_start_cmpl.status == ESP_BT_STATUS_SUCCESS) {
            ESP_LOGI(kTag, "Advertising as %s", kDeviceName);
        } else {
            advertising.store(false);
            ESP_LOGW(kTag, "Advertising failed: %u", param->adv_start_cmpl.status);
        }
        break;
    case ESP_GAP_BLE_SEC_REQ_EVT:
        esp_ble_gap_security_rsp(param->ble_security.ble_req.bd_addr, true);
        break;
    case ESP_GAP_BLE_AUTH_CMPL_EVT:
        encrypted.store(param->ble_security.auth_cmpl.success);
        if (encrypted.load()) {
            ESP_LOGI(kTag, "BLE link encrypted");
        } else {
            ESP_LOGW(kTag, "BLE pairing failed: 0x%x", param->ble_security.auth_cmpl.fail_reason);
        }
        break;
    default:
        break;
    }
}

void GattEvent(esp_gatts_cb_event_t event, esp_gatt_if_t interface,
               esp_ble_gatts_cb_param_t* data) {
#ifdef KNIGHT_ORDERS_CONFIGURED
    if (interface == ESP_GATT_IF_NONE && (event == ESP_GATTS_CONNECT_EVT || event == ESP_GATTS_DISCONNECT_EVT ||
                                          event == ESP_GATTS_MTU_EVT || event == ESP_GATTS_CONF_EVT)) {
        HandleReceiptGatt(event, receipt_interface, data);
    } else if (HandleReceiptGatt(event, interface, data)) {
        return;
    }
#endif
    switch (event) {
    case ESP_GATTS_CREAT_ATTR_TAB_EVT:
        if (data->add_attr_tab.status == ESP_GATT_OK &&
            data->add_attr_tab.svc_uuid.len == ESP_UUID_LEN_16 &&
            data->add_attr_tab.svc_uuid.uuid.uuid16 == ESP_GATT_UUID_HID_SVC) {
            ESP_LOGI(kTag, "HID service first handle=0x%04x attributes=%u",
                     data->add_attr_tab.handles[0], data->add_attr_tab.num_handle);
        }
        break;
    case ESP_GATTS_WRITE_EVT:
        if (data->write.len == 1 || data->write.len == 2) {
            ESP_LOGI(kTag, "Characteristic write handle=0x%04x length=%u value=0x%02x",
                     data->write.handle, data->write.len, data->write.value[0]);
        }
        break;
    case ESP_GATTS_CONF_EVT:
        ESP_LOGI(kTag, "Characteristic send handle=0x%04x status=0x%02x",
                 data->conf.handle, data->conf.status);
        break;
    default:
        break;
    }
    esp_hidd_gatts_event_handler(event, interface, data);
}

void HidEvent(void*, esp_event_base_t, int32_t event, void* data) {
    switch (event) {
    case ESP_HIDD_START_EVENT:
        advertising_ready.fetch_or(kHidStarted);
        StartAdvertising();
        break;
    case ESP_HIDD_CONNECT_EVENT:
        advertising.store(false);
        suspended.store(false);
        connection_generation.fetch_add(1);
        connected.store(true);
        ESP_LOGI(kTag, "BLE host connected");
        break;
    case ESP_HIDD_DISCONNECT_EVENT:
        connected.store(false);
        encrypted.store(false);
        connection_generation.fetch_add(1);
        ESP_LOGI(kTag, "BLE host disconnected");
        StartAdvertising();
        break;
    case ESP_HIDD_PROTOCOL_MODE_EVENT:
        ESP_LOGI(kTag, "Host HID protocol mode=%u",
                 static_cast<esp_hidd_event_data_t*>(data)->protocol_mode.protocol_mode);
        break;
    case ESP_HIDD_CONTROL_EVENT:
        suspended.store(!static_cast<esp_hidd_event_data_t*>(data)->control.control);
        break;
    default:
        break;
    }
}

esp_err_t StartBlePointer() {
    esp_bt_controller_config_t controller = BT_CONTROLLER_INIT_CONFIG_DEFAULT();
    esp_err_t err = esp_bt_controller_init(&controller);
    if (err != ESP_OK) return err;
    err = esp_bt_controller_enable(ESP_BT_MODE_BLE);
    if (err != ESP_OK) return err;
    err = esp_bluedroid_init();
    if (err != ESP_OK) return err;
    err = esp_bluedroid_enable();
    if (err != ESP_OK) return err;
    err = esp_ble_gap_register_callback(GapEvent);
    if (err != ESP_OK) return err;
    err = esp_ble_gatts_register_callback(GattEvent);
    if (err != ESP_OK) return err;

    esp_ble_auth_req_t auth = ESP_LE_AUTH_REQ_SC_BOND;
    esp_ble_io_cap_t io = ESP_IO_CAP_NONE;
    uint8_t initiator_keys = ESP_BLE_ENC_KEY_MASK | ESP_BLE_ID_KEY_MASK;
    uint8_t responder_keys = initiator_keys;
    uint8_t key_size = 16;
    const struct {
        esp_ble_sm_param_t type;
        void* value;
    } security[] = {
        {ESP_BLE_SM_AUTHEN_REQ_MODE, &auth}, {ESP_BLE_SM_IOCAP_MODE, &io},
        {ESP_BLE_SM_SET_INIT_KEY, &initiator_keys}, {ESP_BLE_SM_SET_RSP_KEY, &responder_keys},
        {ESP_BLE_SM_MAX_KEY_SIZE, &key_size},
    };
    for (const auto& setting : security) {
        err = esp_ble_gap_set_security_param(setting.type, setting.value, 1);
        if (err != ESP_OK) return err;
    }
    err = esp_ble_gap_set_device_name(kDeviceName);
    if (err != ESP_OK) return err;

#ifdef KNIGHT_ORDERS_CONFIGURED
    uint8_t advertisement[29] = {
        2, 0x01, ESP_BLE_ADV_FLAG_GEN_DISC | ESP_BLE_ADV_FLAG_BREDR_NOT_SPT,
        3, 0x19, 0xc2, 0x03,
        3, 0x03, 0x12, 0x18,
        17, 0x07,
    };
    std::copy_n(kReceiptServiceUuid, ESP_UUID_LEN_128, advertisement + 13);
    err = esp_ble_gap_config_adv_data_raw(advertisement, sizeof(advertisement));
#else
    esp_ble_adv_data_t adv{};
    adv.appearance = ESP_HID_APPEARANCE_MOUSE;
    adv.service_uuid_len = sizeof(hid_service_uuid);
    adv.p_service_uuid = hid_service_uuid;
    adv.flag = ESP_BLE_ADV_FLAG_GEN_DISC | ESP_BLE_ADV_FLAG_BREDR_NOT_SPT;
    err = esp_ble_gap_config_adv_data(&adv);
#endif
    if (err != ESP_OK) return err;

    esp_ble_adv_data_t scan_response{};
    scan_response.set_scan_rsp = true;
    scan_response.include_name = true;
    err = esp_ble_gap_config_adv_data(&scan_response);
    if (err != ESP_OK) return err;

    const esp_hid_device_config_t config{
        .vendor_id = 0x02e5,
        .product_id = 0x0001,
        .version = 0x0100,
        .device_name = kDeviceName,
        .manufacturer_name = "Knight",
        .serial_number = "AI-MAIN",
        .report_maps = &mouse_map,
        .report_maps_len = 1,
    };
    esp_hidd_dev_t* hid = nullptr;
    err = esp_hidd_dev_init(&config, ESP_HID_TRANSPORT_BLE, HidEvent, &hid);
    if (err != ESP_OK) return err;
    device.store(hid);
#ifdef KNIGHT_ORDERS_CONFIGURED
    err = esp_ble_gatts_app_register(kReceiptAppId);
    if (err != ESP_OK) ESP_LOGW(kTag, "Pickup receipt GATT registration failed: %s", esp_err_to_name(err));
#endif
    StartAdvertising();
    return ESP_OK;
}

esp_err_t SendReport(uint8_t buttons, int dx, int dy, int wheel) {
    uint8_t report[] = {
        buttons, static_cast<uint8_t>(dx), static_cast<uint8_t>(dy), static_cast<uint8_t>(wheel),
    };
    return esp_hidd_dev_input_set(device.load(), 0, 0, report, sizeof(report));
}

void SendPointerAction(int dx, int dy, int wheel, bool click) {
    std::unique_lock lock(input_mutex, std::try_to_lock);
    if (!lock.owns_lock()) throw std::runtime_error("Pointer is busy; no action queued");
    if (!CanSend()) throw std::runtime_error("Pair the iPhone with Knight Pointer before sending input");
    const auto generation = connection_generation.load();
    const esp_err_t sent = SendReport(click ? kLeftButton : 0, dx, dy, wheel);
    if (sent != ESP_OK) throw std::runtime_error("iPhone did not accept the HID report; check AssistiveTouch");
    if (click) {
        vTaskDelay(pdMS_TO_TICKS(30));
        if (!CanSend() || connection_generation.load() != generation || SendReport(0, 0, 0, 0) != ESP_OK) {
            throw std::runtime_error("Click release was not delivered; check the iPhone before retrying");
        }
    }
    ESP_LOGI(kTag, "Report sent: move=(%d,%d) scroll=%d click=%d", dx, dy, wheel, click);
}
} // namespace

bool KnightPickupBleConnected() {
#ifdef KNIGHT_ORDERS_CONFIGURED
    return receipt_connected.load();
#else
    return false;
#endif
}

bool SendKnightVoiceRelay(const uint8_t* packet, size_t size) {
#ifdef KNIGHT_ORDERS_CONFIGURED
    std::unique_lock lock(relay_mutex, std::try_to_lock);
    if (!lock.owns_lock() || !receipt_connected || !relay_subscribed || size < 71 || size > 1200) return false;
    const auto connection = receipt_connection.load();
    const auto generation = connection_generation.load();
    const auto expiry = xTaskGetTickCount() + pdMS_TO_TICKS(2500);
    const auto capacity = std::min<size_t>(178, std::max<int>(18, receipt_mtu.load() - 5));
    std::array<uint8_t, 180> frame;
    for (size_t offset = 0, sequence = 0; offset < size; ++sequence) {
        if (!receipt_connected || !relay_subscribed || generation != connection_generation) return false;
        const auto length = std::min(capacity, size - offset);
        frame[0] = (offset == 0 ? 1 : 0) | (offset + length == size ? 2 : 0);
        frame[1] = static_cast<uint8_t>(sequence);
        std::copy_n(packet + offset, length, frame.data() + 2);
        relay_confirmation = 0;
        if (esp_ble_gatts_send_indicate(receipt_interface, connection, relay_characteristic,
                                       length + 2, frame.data(), true) != ESP_OK) return false;
        while (!relay_confirmation && receipt_connected && generation == connection_generation &&
               static_cast<int32_t>(expiry - xTaskGetTickCount()) > 0) {
            vTaskDelay(pdMS_TO_TICKS(10));
        }
        if (relay_confirmation != 1) return false;
        offset += length;
    }
    return true;
#else
    return false;
#endif
}

void InitializePhonePointer() {
    const auto err = StartBlePointer();
    if (err != ESP_OK) {
        ESP_LOGW(kTag, "BLE pointer unavailable: %s", esp_err_to_name(err));
    }

    auto& mcp = McpServer::GetInstance();
    mcp.AddTool("self.phone_pointer.status", "查询 iPhone 蓝牙指针是否已连接并可发送输入。", {},
        [](const PropertyList&) -> ReturnValue {
            if (CanSend()) return std::string("Pointer connected");
            if (device.load() == nullptr) return std::string("Pointer unavailable");
            if (connected.load()) return std::string("Connected, waiting for pairing or resume");
            return std::string("Not connected: pair Knight Pointer in AssistiveTouch");
        });
    mcp.AddTool("self.phone_pointer.move", "按用户要求相对移动 iPhone 指针。x 正值向右，y 正值向下。",
        PropertyList({Property("x", kPropertyTypeInteger, 0, -127, 127),
                      Property("y", kPropertyTypeInteger, 0, -127, 127)}),
        [](const PropertyList& args) -> ReturnValue {
            const auto x = args["x"].value<int>();
            const auto y = args["y"].value<int>();
            if (x == 0 && y == 0) throw std::runtime_error("Specify a non-zero pointer movement");
            SendPointerAction(x, y, 0, false);
            return true;
        });
    mcp.AddTool("self.phone_pointer.scroll", "按用户要求滚动 iPhone 当前页面。正值向上，负值向下。",
        PropertyList({Property("steps", kPropertyTypeInteger, -10, 10)}),
        [](const PropertyList& args) -> ReturnValue {
            const auto steps = args["steps"].value<int>();
            if (steps == 0) throw std::runtime_error("Specify a non-zero scroll distance");
            SendPointerAction(0, 0, steps, false);
            return true;
        });
    mcp.AddTool("self.phone_pointer.click", "仅在用户明确说点击时，在 iPhone 当前指针位置单击一次。",
        {}, [](const PropertyList&) -> ReturnValue {
            SendPointerAction(0, 0, 0, true);
            return true;
        });
}
#endif
