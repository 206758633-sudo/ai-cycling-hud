#include "knight_order.h"

#if defined(KNIGHT_ORDERS_CONFIGURED)
#include "board.h"
#include "knight_order_build.h"
#include "mcp_server.h"
#include "phone_pointer.h"

#include <cJSON.h>
#include <esp_log.h>
#include <esp_random.h>
#include <mbedtls/md.h>

#include <chrono>
#include <condition_variable>
#include <ctime>
#include <deque>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>

namespace {
constexpr char kTag[] = "KnightOrders";

#ifdef KNIGHT_DELIVERY_ENDPOINT
struct BluetoothReceipt {
    std::string id;
    std::string text;
    uint32_t expires_at;
};

std::mutex receipts_mutex;
std::condition_variable receipts_changed;
std::deque<BluetoothReceipt> receipts;
std::string latest_pickup_id;
std::string reported_checkout_id;

std::string ReadBluetoothReceipt(const std::string& task_id, bool wait, std::string& resolved_id) {
    std::unique_lock<std::mutex> lock(receipts_mutex);
    const auto target = task_id == "latest" ? latest_pickup_id : task_id;
    std::string text;
    const auto find_receipt = [&]() {
        const auto now = std::time(nullptr);
        for (const auto& receipt : receipts) {
            if (receipt.id == target && now < receipt.expires_at) {
                text = receipt.text;
                resolved_id = receipt.id;
                return true;
            }
        }
        return false;
    };
    if (wait) {
        receipts_changed.wait_for(lock, std::chrono::seconds(24), find_receipt);
    } else {
        find_receipt();
    }
    return text;
}

std::string SpokenFeedback(const std::string& text, const std::string& task_id) {
    const bool checkout = text.rfind("美团自提结算页已就绪。", 0) == 0;
    {
        std::lock_guard<std::mutex> lock(receipts_mutex);
        reported_checkout_id = checkout && task_id.size() == 32 ? task_id : std::string();
    }
    if (checkout) {
        return "请用当前音色简洁播报骑士回执，保留门店、商品规格、金额和待付款状态，随后等待用户确认或提出修改。" + text;
    }
    return "请用当前音色播报骑士的实际处理结果。" + text;
}

std::string PickupFeedback(const std::string& task_id, bool wait) {
    bool wait_on_bluetooth = false;
#if CONFIG_BT_BLE_ENABLED && CONFIG_BT_BLUEDROID_ENABLED
    wait_on_bluetooth = wait && KnightPickupBleConnected();
#endif
    std::string resolved_id;
    auto bluetooth_text = ReadBluetoothReceipt(task_id, wait_on_bluetooth, resolved_id);
    if (!bluetooth_text.empty()) {
        ESP_LOGI(kTag, "Returning Bluetooth pickup feedback: %s", task_id.c_str());
        return SpokenFeedback(bluetooth_text, resolved_id);
    }
    wait = wait && !wait_on_bluetooth;
    auto http = Board::GetInstance().GetNetwork()->CreateHttp();
    http->SetTimeout(wait ? 28000 : 2500);
    http->SetHeader("Authorization", "Bearer " KNIGHT_ORDERS_DEVICE_TOKEN);
    const auto url = std::string(KNIGHT_DELIVERY_ENDPOINT) + "/" + task_id +
                     "/feedback-text" + (wait ? "?wait=1" : "");
    if (!http->Open("GET", url)) {
        return "暂时无法读取骑士自提回执，请稍后说播报我的自提结果。";
    }
    const auto status = http->GetStatusCode();
    bluetooth_text = ReadBluetoothReceipt(task_id, false, resolved_id);
    if (!bluetooth_text.empty()) {
        ESP_LOGI(kTag, "Returning Bluetooth pickup feedback: %s", task_id.c_str());
        return SpokenFeedback(bluetooth_text, resolved_id);
    }
    if (status == 204) return "骑士正在处理自提。稍后说播报我的自提结果即可查询。";
    if (status == 404) return "骑士还没有可查询的自提回执。";
    if (status != 200) return "暂时无法读取骑士自提回执，请稍后再查询。";

    const auto response = http->ReadAll();
    http->Close();
    std::unique_ptr<cJSON, decltype(&cJSON_Delete)> json(cJSON_Parse(response.c_str()), cJSON_Delete);
    const auto* text = cJSON_GetObjectItemCaseSensitive(json.get(), "text");
    const auto* id = cJSON_GetObjectItemCaseSensitive(json.get(), "id");
    if (!cJSON_IsString(text)) return "骑士尚未返回可播报的自提结果。";
    ESP_LOGI(kTag, "Returning pickup feedback in chat: %s", task_id.c_str());
    return SpokenFeedback(text->valuestring, cJSON_IsString(id) ? id->valuestring : task_id);
}

std::string ConfirmPickupFeedback() {
    std::string id;
    {
        std::lock_guard<std::mutex> lock(receipts_mutex);
        id = reported_checkout_id;
    }
    if (id.empty()) return "请先说播报我的自提结果，再确认具体一笔。";
    auto http = Board::GetInstance().GetNetwork()->CreateHttp();
    http->SetTimeout(3000);
    http->SetHeader("Authorization", "Bearer " KNIGHT_ORDERS_DEVICE_TOKEN);
    http->SetHeader("Content-Type", "application/json");
    http->SetContent("{}");
    const auto url = std::string(KNIGHT_DELIVERY_ENDPOINT) + "/" + id + "/confirm-pickup";
    if (!http->Open("POST", url)) return "暂时无法记录你的确认，请在美团核对。";
    const auto status = http->GetStatusCode();
    if (status == 409) return "这笔自提结算已失效，请打开美团核对。";
    if (status != 200) return "暂时无法记录你的确认，请在美团核对。";
    return "已记录这笔自提的语音确认，请在手机美团核对并付款。";
}
#endif

std::string GenerateRequestID() {
    constexpr char hex[] = "0123456789abcdef";
    uint8_t random[16];
    esp_fill_random(random, sizeof(random));
    std::string id;
    id.reserve(2 * sizeof(random));
    for (auto byte : random) {
        id.push_back(hex[byte >> 4]);
        id.push_back(hex[byte & 0x0f]);
    }
    return id;
}

std::string SubmitIntent(const char* endpoint, std::string body, bool delivery, bool pickup = false) {
    for (int attempt = 0; attempt < 2; ++attempt) {
        auto http = Board::GetInstance().GetNetwork()->CreateHttp();
        http->SetTimeout(2500);
        http->SetHeader("Content-Type", "application/json");
        http->SetHeader("Authorization", "Bearer " KNIGHT_ORDERS_DEVICE_TOKEN);
        http->SetContent(std::string(body));
        if (!http->Open("POST", endpoint)) continue;
        const int status = http->GetStatusCode();
        if (status <= 0 || status >= 500) continue;
        if (status != 200 && status != 201) {
            ESP_LOGW(kTag, "Intent rejected (HTTP %d)", status);
            if (delivery && status == 409) {
                throw std::runtime_error("已有待处理的美团任务，请先在骑士 App 核对");
            }
            throw std::runtime_error("Mac 未接受点单请求，请检查服务和请求内容");
        }
        const auto response = http->ReadAll();
        http->Close();
        std::unique_ptr<cJSON, decltype(&cJSON_Delete)> json(cJSON_Parse(response.c_str()), cJSON_Delete);
        const auto* state = cJSON_GetObjectItemCaseSensitive(json.get(), "state");
        const auto* id = cJSON_GetObjectItemCaseSensitive(json.get(), "id");
        if (!cJSON_IsString(state) || !cJSON_IsString(id)) continue;
        ESP_LOGI(kTag, "Intent %s reported as %s", id->valuestring, state->valuestring);
        if (delivery) {
#ifdef KNIGHT_DELIVERY_ENDPOINT
            if (pickup) {
                {
                    std::lock_guard<std::mutex> lock(receipts_mutex);
                    latest_pickup_id = id->valuestring;
                    reported_checkout_id.clear();
                }
                return PickupFeedback(id->valuestring, true);
            }
#endif
            return "美团点单请求已发送，核对结果请看骑士 App 的美团点单。";
        }
        if (std::string(state->valuestring) == "pending") {
            return "已发送热美式测试点单请求，请在骑士 App 的驿站测试订单里确认。";
        }
        return "这一笔测试点单请求已处理，请到骑士 App 查看状态。";
    }
    throw std::runtime_error("无法确认 Mac 收到请求，请先在骑士 App 检查待确认列表");
}
std::string SubmitAmericano(int quantity) {
    const auto body = "{\"sku\":\"hot-americano\",\"quantity\":" + std::to_string(quantity) +
                      ",\"request_id\":\"" + GenerateRequestID() + "\"}";
    return SubmitIntent(KNIGHT_ORDERS_ENDPOINT, body, false);
}

#ifdef KNIGHT_DELIVERY_ENDPOINT
struct DeliveryRequest {
    std::string query;
    std::string merchant;
    std::string options;
    std::string pickup_destination;
    int quantity;
    int budget_cents;
};

PropertyList DeliveryProperties(bool pickup_required = false) {
    return PropertyList({Property("query", kPropertyTypeString),
                         Property("merchant", kPropertyTypeString, std::string()),
                         Property("options", kPropertyTypeString, std::string()),
                         pickup_required ? Property("pickup_destination", kPropertyTypeString)
                                         : Property("pickup_destination", kPropertyTypeString, std::string()),
                         Property("quantity", kPropertyTypeInteger, 1, 1, 5),
                         Property("budget_cents", kPropertyTypeInteger, 0, 0, 100000)});
}

DeliveryRequest ReadDeliveryRequest(const PropertyList& args) {
    DeliveryRequest request{args["query"].value<std::string>(), args["merchant"].value<std::string>(),
                            args["options"].value<std::string>(), args["pickup_destination"].value<std::string>(),
                            args["quantity"].value<int>(),
                            args["budget_cents"].value<int>()};
    if (request.query.empty() || request.query.size() > 192 || request.merchant.size() > 160 ||
        request.options.size() > 192 || request.pickup_destination.size() > 320) {
        throw std::runtime_error("请明确商品名称，并简要说明目的地、店铺和规格");
    }
    return request;
}

std::string SummarizeDelivery(const DeliveryRequest& request) {
    std::string summary = "购买需求：" + request.query + "，数量" + std::to_string(request.quantity) + "。";
    if (!request.merchant.empty()) summary += "店铺：" + request.merchant + "。";
    if (!request.options.empty()) summary += "规格要求：" + request.options + "。";
    if (!request.pickup_destination.empty()) summary += "自提目的地：" + request.pickup_destination + "。";
    if (request.budget_cents > 0) {
        const auto cents = request.budget_cents % 100;
        summary += "实付预算：" + std::to_string(request.budget_cents / 100) + "元";
        if (cents) summary += std::to_string(cents) + "分";
        summary += "。";
    }
    return summary;
}

std::string SubmitDelivery(const DeliveryRequest& request) {
    std::unique_ptr<cJSON, decltype(&cJSON_Delete)> json(cJSON_CreateObject(), cJSON_Delete);
    if (!json) throw std::runtime_error("无法构造美团点单请求");
    cJSON_AddStringToObject(json.get(), "request_id", GenerateRequestID().c_str());
    cJSON_AddStringToObject(json.get(), "query", request.query.c_str());
    cJSON_AddStringToObject(json.get(), "merchant", request.merchant.c_str());
    cJSON_AddStringToObject(json.get(), "options", request.options.c_str());
    cJSON_AddStringToObject(json.get(), "pickup_destination", request.pickup_destination.c_str());
    cJSON_AddNumberToObject(json.get(), "quantity", request.quantity);
    cJSON_AddNumberToObject(json.get(), "budget_cents", request.budget_cents);
    std::unique_ptr<char, decltype(&cJSON_free)> text(cJSON_PrintUnformatted(json.get()), cJSON_free);
    if (!text) throw std::runtime_error("无法编码美团点单请求");
    const bool pickup = !request.pickup_destination.empty();
    auto result = SubmitIntent(KNIGHT_DELIVERY_ENDPOINT, text.get(), true, pickup);
    if (pickup) return result;
    return SummarizeDelivery(request) + result;
}
#endif
} // namespace
#endif

bool ReceiveKnightPickupFeedback(const uint8_t* packet, size_t size) {
#if defined(KNIGHT_ORDERS_CONFIGURED) && defined(KNIGHT_DELIVERY_ENDPOINT)
    constexpr size_t header_size = 38;
    constexpr size_t signature_size = 32;
    if (size <= header_size + signature_size || size > 2048 || packet[0] != 'K' || packet[1] != '1') return false;
    constexpr char key[] = KNIGHT_ORDERS_DEVICE_TOKEN;
    const size_t body_size = size - signature_size;
    uint8_t expected[signature_size];
    if (mbedtls_md_hmac(mbedtls_md_info_from_type(MBEDTLS_MD_SHA256),
                       reinterpret_cast<const uint8_t*>(key), sizeof(key) - 1,
                       packet, body_size, expected) != 0) return false;
    unsigned difference = 0;
    for (size_t i = 0; i < signature_size; ++i) difference |= expected[i] ^ packet[body_size + i];
    if (difference) return false;
    uint32_t expires = 0;
    for (size_t i = 34; i < header_size; ++i) expires = (expires << 8) | packet[i];
    const auto now = std::time(nullptr);
    if (now < 1700000000 || expires <= now || expires > now + 305) return false;
    const std::string id(reinterpret_cast<const char*>(packet + 2), 32);
    {
        std::lock_guard<std::mutex> lock(receipts_mutex);
        for (const auto& receipt : receipts) {
            if (receipt.id == id) return true;
        }
        if (receipts.size() == 4) receipts.pop_front();
        receipts.push_back({id, std::string(reinterpret_cast<const char*>(packet + header_size),
                                           body_size - header_size), expires});
    }
    receipts_changed.notify_all();
    ESP_LOGI(kTag, "Accepted Bluetooth pickup receipt: %s", id.c_str());
    return true;
#else
    return false;
#endif
}

void InitializeKnightOrders() {
#if defined(KNIGHT_ORDERS_CONFIGURED)
    McpServer::GetInstance().AddTool("self.knight_orders.request_americano",
        "当用户明确要求在骑士驿站点热美式时，提交本地测试点单请求，并提示用户到骑士 App 确认。",
        PropertyList({Property("quantity", kPropertyTypeInteger, 1, 1, 5)}),
        [](const PropertyList& args) -> ReturnValue {
            return SubmitAmericano(args["quantity"].value<int>());
        });
#ifdef KNIGHT_DELIVERY_ENDPOINT
    auto& mcp = McpServer::GetInstance();
    mcp.AddTool("self.knight_orders.summarize_meituan",
        "当用户请你复述或总结购买需求时使用。按对话提取商品、数量、指定店铺、规格、实付预算、自提目的地。这个工具只复述。",
        DeliveryProperties(), [](const PropertyList& args) -> ReturnValue {
            return SummarizeDelivery(ReadDeliveryRequest(args));
        });
    mcp.AddTool("self.knight_orders.prepare_meituan",
        "当用户明确要求操控美团搜索或准备配送订单时使用。保留商品、数量、规格和实付预算。"
        "到店自提请使用 prepare_meituan_pickup。工具受理后提示到骑士 App 查看。",
        DeliveryProperties(), [](const PropertyList& args) -> ReturnValue {
            return SubmitDelivery(ReadDeliveryRequest(args));
        });
    mcp.AddTool("self.knight_orders.prepare_meituan_pickup",
        "当用户要求在骑行目的地附近点咖啡到店自提时使用。把对话中用户已明确的目的地原文放进 pickup_destination。"
        "没说清地点或商品就先追问，保留明确的糖度、温度和预算。用当前对话音色读回工具的实际结果，用户在美团结算页提交付款。",
        DeliveryProperties(true), [](const PropertyList& args) -> ReturnValue {
            const auto request = ReadDeliveryRequest(args);
            if (request.pickup_destination.find_first_not_of(" \t\r\n") == std::string::npos) {
                throw std::runtime_error("请先明确到店自提的目的地");
            }
            return SubmitDelivery(request);
        });
    mcp.AddTool("self.knight_orders.get_pickup_feedback",
        "当用户想听上一笔美团自提结果时使用。只查询并播报，保留回执中的商品、金额和付款状态。",
        PropertyList(), [](const PropertyList&) -> ReturnValue {
            return PickupFeedback("latest", false);
        });
    mcp.AddTool("self.knight_orders.confirm_pickup_feedback",
        "仅当用户明确确认刚播报的美团自提结果时调用。核对结算是否就绪，提醒在美团付款。"
        "用户想重听时用 get_pickup_feedback。用户要求修改时先复述需要修改的字段并等待用户明确要求重新查找。",
        PropertyList(), [](const PropertyList&) -> ReturnValue {
            return ConfirmPickupFeedback();
        });
#endif
#endif
}
