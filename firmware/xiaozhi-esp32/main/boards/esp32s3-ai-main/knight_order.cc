#include "knight_order.h"

#if defined(KNIGHT_ORDERS_CONFIGURED)
#include "board.h"
#include "application.h"
#include "knight_order_build.h"
#include "mcp_server.h"
#include "phone_pointer.h"

#include <cJSON.h>
#include <esp_log.h>
#include <esp_random.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <mbedtls/md.h>

#include <ctime>
#include <cstring>
#include <deque>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <utility>

namespace {
constexpr char kTag[] = "KnightOrders";

#ifdef KNIGHT_DELIVERY_ENDPOINT
struct BluetoothReceipt {
    std::string id;
    std::string text;
    uint32_t expires_at;
};

std::mutex receipts_mutex;
std::deque<BluetoothReceipt> receipts;
std::string latest_pickup_id;
std::string reported_checkout_id;
std::string latest_ordinary_route_id;
std::string latest_recommendation_id;

void TrackVoiceResult(std::string id, bool pickup);
void MarkVoiceResultRead(const std::string& id);
bool NavigationHasPriority();
int RelayPickupRide(const std::string& task_id);

std::string ReadBluetoothReceipt(const std::string& task_id, std::string& resolved_id) {
    std::lock_guard<std::mutex> lock(receipts_mutex);
    const auto target = task_id == "latest" ? latest_pickup_id : task_id;
    const auto now = std::time(nullptr);
    for (const auto& receipt : receipts) {
        if (receipt.id == target && now < receipt.expires_at) {
            resolved_id = receipt.id;
            return receipt.text;
        }
    }
    return {};
}

std::string SpokenFeedback(const std::string& text, const std::string& task_id) {
    if (text.rfind("美团门店推荐", 0) == 0) {
        return "请用当前音色播报以下实际查店结果。只有用户之后明确说开始导航，才调用 start_recommended_ride。" + text;
    }
    const bool checkout = text.rfind("美团自提结算页已就绪。", 0) == 0;
    const bool sugar_question = text.rfind("这家门店只有不额外加糖、半糖和全糖。", 0) == 0;
    {
        std::lock_guard<std::mutex> lock(receipts_mutex);
        reported_checkout_id = checkout && task_id.size() == 32 ? task_id : std::string();
        if (sugar_question && task_id.size() == 32) latest_pickup_id = task_id;
    }
    if (checkout) {
        return "请用当前音色简洁播报骑士的实际结算回执，保留门店、品项、金额和待付款状态。"
               "只有播报后听到用户明确说开始导航，才调用 start_pickup_ride。" + text;
    }
    if (sugar_question) {
        return "请直接读出这个问题，等待用户用语音答复。只有用户明确接受不额外加糖时才调用 continue_meituan_pickup。" + text;
    }
    return "请用当前音色播报骑士的实际处理结果。" + text;
}

std::string PickupFeedback(const std::string& task_id) {
    if (NavigationHasPriority()) return "正在导航，订单结果会在导航结束后播报。";
    std::string resolved_id;
    auto bluetooth_text = ReadBluetoothReceipt(task_id, resolved_id);
    if (!bluetooth_text.empty()) {
        MarkVoiceResultRead(resolved_id);
        ESP_LOGI(kTag, "Returning Bluetooth pickup feedback: %s", task_id.c_str());
        return SpokenFeedback(bluetooth_text, resolved_id);
    }
    auto http = Board::GetInstance().GetNetwork()->CreateHttp();
    http->SetTimeout(2500);
    http->SetHeader("Authorization", "Bearer " KNIGHT_ORDERS_DEVICE_TOKEN);
    const auto url = std::string(KNIGHT_DELIVERY_ENDPOINT) + "/" + task_id +
                     "/feedback-text";
    if (!http->Open("GET", url)) {
        return "暂时无法读取骑士自提回执，请稍后说播报我的自提结果。";
    }
    const auto status = http->GetStatusCode();
    bluetooth_text = ReadBluetoothReceipt(task_id, resolved_id);
    if (!bluetooth_text.empty()) {
        MarkVoiceResultRead(resolved_id);
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
    const auto* state = cJSON_GetObjectItemCaseSensitive(json.get(), "state");
    if (!cJSON_IsString(text)) return "骑士尚未返回可播报的自提结果。";
    if (cJSON_IsString(id) && cJSON_IsString(state) &&
        (!std::strcmp(state->valuestring, "pickup_checkout") || !std::strcmp(state->valuestring, "needs_input"))) {
        MarkVoiceResultRead(id->valuestring);
    }
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

std::string PickupRide(bool request_start) {
    std::string id;
    {
        std::lock_guard<std::mutex> lock(receipts_mutex);
        id = reported_checkout_id;
    }
    if (id.empty()) return "请先说播报我的自提结果，核对取餐门店和结算后再开始导航。";
    const auto endpoint = std::string(KNIGHT_DELIVERY_ENDPOINT) + "/" + id + "/ride";
    auto request = [&](bool post) {
        auto http = Board::GetInstance().GetNetwork()->CreateHttp();
        http->SetTimeout(2500);
        http->SetHeader("Authorization", "Bearer " KNIGHT_ORDERS_DEVICE_TOKEN);
        if (post) {
            http->SetHeader("Content-Type", "application/json");
            http->SetContent("{}");
        }
        if (!http->Open(post ? "POST" : "GET", endpoint)) {
            return std::pair<int, std::string>{0, {}};
        }
        const auto status = http->GetStatusCode();
        auto response = http->ReadAll();
        http->Close();
        return std::make_pair(status, std::move(response));
    };
    if (request_start) {
        const auto relay = RelayPickupRide(id);
        if (relay == 200 || relay == 201) return "已受理自提导航，骑士正在核对并启动路线。你可以继续说话。";
        if (relay == 409 || relay == 404) return "当前没有在有效期内的已核实自提结算，导航没有启动。";
        const auto [status, response] = request(true);
        if (status == 409) return "当前没有在有效期内的已核实自提结算，导航没有启动。";
        if (status != 200 && status != 201) return "骑士没有确认接收导航请求。你可以说查询导航状态。";
        return "已受理自提导航，骑士正在核对并启动路线。你可以继续说话。";
    }
    const auto [status, response] = request(false);
    if (status == 204) return "骑士还没有确认导航启动。你可以说查询导航状态。";
    if (status == 404) return "还没有这笔自提的导航启动请求。";
    if (status != 200) return "暂时无法查询高德导航状态。";
    std::unique_ptr<cJSON, decltype(&cJSON_Delete)> json(cJSON_Parse(response.c_str()), cJSON_Delete);
    const auto* text = cJSON_GetObjectItemCaseSensitive(json.get(), "text");
    if (!cJSON_IsString(text)) return "没有收到可核对的高德导航状态。";
    return std::string("请按骑士回执用当前音色回答，不提前声称导航已启动。") + text->valuestring;
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

#ifdef KNIGHT_DELIVERY_ENDPOINT
struct VoiceTask {
    std::string id;
    bool pickup;
};
struct VoiceNotice {
    VoiceTask task;
    std::string text;
};
std::deque<VoiceTask> pending_voice;
std::deque<VoiceNotice> ready_voice;
std::string prompted_voice_id;
struct NavigationVoice {
    std::string route;
    std::string retired_route;
    uint32_t control_sequence = 0;
    uint32_t guidance_sequence = 0;
    std::time_t active_until = 0;
    std::time_t line_until = 0;
    std::string line;
    std::string line_id;
    bool ended = false;
} navigation_voice;

bool NavigationHasPriority() {
    std::lock_guard<std::mutex> lock(receipts_mutex);
    return std::time(nullptr) < navigation_voice.active_until;
}

std::string PromptCandidateLocked(std::time_t now) {
    if (!navigation_voice.line.empty() && now < navigation_voice.line_until) return navigation_voice.line_id;
    if (now < navigation_voice.active_until || ready_voice.empty()) return {};
    return ready_voice.front().task.id;
}

void ScheduleVoicePrompt() {
    bool available;
    {
        std::lock_guard<std::mutex> lock(receipts_mutex);
        const auto candidate = PromptCandidateLocked(std::time(nullptr));
        available = !candidate.empty() && candidate != prompted_voice_id;
    }
    if (!available) return;
    Application::GetInstance().Schedule([] {
        auto& app = Application::GetInstance();
        if (app.GetDeviceState() != kDeviceStateIdle) return;
        bool navigation;
        {
            std::lock_guard<std::mutex> lock(receipts_mutex);
            const auto candidate = PromptCandidateLocked(std::time(nullptr));
            if (candidate.empty() || candidate == prompted_voice_id) return;
            navigation = candidate == navigation_voice.line_id;
            prompted_voice_id = candidate;
        }
        app.WakeWordInvoke(navigation ? "请准确播报骑士当前的导航指引" :
                                       "请播报骑士待播放的任务回执");
    });
}

bool AcceptNavigationVoice(const std::string& route, const std::string& payload, std::time_t expires) {
    if (payload.size() < 9 || payload.size() > 180) return false;
    const char mode = payload[0];
    if (mode != 'S' && mode != 'H' && mode != 'G' && mode != 'E') return false;
    uint32_t sequence = 0;
    for (size_t i = 1; i < 9; ++i) {
        const char c = payload[i];
        if (c >= '0' && c <= '9') sequence = (sequence << 4) | (c - '0');
        else if (c >= 'a' && c <= 'f') sequence = (sequence << 4) | (c - 'a' + 10);
        else return false;
    }
    if (!sequence || (mode == 'G' && payload.size() == 9) ||
        ((mode == 'S' || mode == 'H') && payload.size() != 9)) return false;
    {
        std::lock_guard<std::mutex> lock(receipts_mutex);
        auto& nav = navigation_voice;
        const auto now = std::time(nullptr);
        if (route == nav.retired_route) return true;
        if (route != nav.route) {
            if (mode == 'E' || (now < nav.active_until && mode != 'S')) return true;
            const std::string previous = nav.route;
            nav = {};
            nav.retired_route = previous;
            nav.route = route;
        }
        if (nav.ended) return true;
        if (mode == 'G') {
            if (sequence <= nav.guidance_sequence) return true;
            nav.guidance_sequence = sequence;
        } else {
            if (sequence <= nav.control_sequence) return true;
            nav.control_sequence = sequence;
        }
        nav.active_until = mode == 'E' ? 0 : now + 20;
        if (mode == 'G' || mode == 'E') {
            nav.ended = mode == 'E';
            nav.line = payload.substr(9);
            nav.line_id = route + ":" + std::to_string(sequence);
            nav.line_until = expires;
            if (!nav.line.empty()) ESP_LOGI(kTag, "Navigation voice cue received %s", nav.line_id.c_str());
        }
    }
    ScheduleVoicePrompt();
    return true;
}

std::string CyclingEndpoint() {
    const std::string base = KNIGHT_DELIVERY_ENDPOINT;
    return base.substr(0, base.find("/api/")) + "/api/cycling/routes";
}

std::string RecommendationEndpoint() {
    const std::string base = KNIGHT_DELIVERY_ENDPOINT;
    return base.substr(0, base.find("/api/")) + "/api/voice/recommendations";
}

using JSON = std::unique_ptr<cJSON, decltype(&cJSON_Delete)>;
struct RelayAck {
    int status = 0;
    std::string task_id;
};

std::mutex relay_exchange_mutex;
std::mutex relay_ack_mutex;
std::string relay_request_id;
RelayAck relay_ack;

bool AcceptRelayAck(const std::string& request_id, const std::string& payload) {
    if (payload.size() != 3 && payload.size() != 35) return false;
    if (payload[0] < '2' || payload[0] > '5' || payload[1] < '0' || payload[1] > '9' ||
        payload[2] < '0' || payload[2] > '9') return false;
    const auto status = (payload[0] - '0') * 100 + (payload[1] - '0') * 10 + (payload[2] - '0');
    if ((status == 200 || status == 201) != (payload.size() == 35)) return false;
    std::lock_guard<std::mutex> lock(relay_ack_mutex);
    if (relay_request_id == request_id) relay_ack = {status, payload.substr(3)};
    return true;
}

RelayAck RelayVoiceRequest(const char* prefix, const std::string& body) {
    if (!KnightPickupBleConnected() || body.size() > 1130 || std::time(nullptr) < 1700000000) return {};
    std::unique_lock exchange(relay_exchange_mutex, std::try_to_lock);
    if (!exchange.owns_lock()) return {};
    JSON json(cJSON_Parse(body.c_str()), cJSON_Delete);
    const auto* field = cJSON_GetObjectItemCaseSensitive(json.get(), "request_id");
    if (!cJSON_IsString(field) || std::strlen(field->valuestring) != 32) return {};
    const std::string id = field->valuestring;
    const auto expires = static_cast<uint32_t>(std::time(nullptr) + 25);
    std::string packet = std::string(prefix) + id;
    for (int shift = 24; shift >= 0; shift -= 8) packet.push_back(static_cast<char>((expires >> shift) & 0xff));
    packet += body;
    constexpr char key[] = KNIGHT_ORDERS_DEVICE_TOKEN;
    uint8_t signature[32];
    if (mbedtls_md_hmac(mbedtls_md_info_from_type(MBEDTLS_MD_SHA256), reinterpret_cast<const uint8_t*>(key),
                        sizeof(key) - 1, reinterpret_cast<const uint8_t*>(packet.data()), packet.size(), signature) != 0) {
        return {};
    }
    packet.append(reinterpret_cast<const char*>(signature), sizeof(signature));
    {
        std::lock_guard<std::mutex> lock(relay_ack_mutex);
        relay_request_id = id;
        relay_ack = {};
    }
    if (SendKnightVoiceRelay(reinterpret_cast<const uint8_t*>(packet.data()), packet.size())) {
        const auto deadline = xTaskGetTickCount() + pdMS_TO_TICKS(2400);
        do {
            {
                std::lock_guard<std::mutex> lock(relay_ack_mutex);
                if (relay_ack.status) break;
            }
            vTaskDelay(pdMS_TO_TICKS(20));
        } while (KnightPickupBleConnected() && static_cast<int32_t>(deadline - xTaskGetTickCount()) > 0);
    }
    std::lock_guard<std::mutex> lock(relay_ack_mutex);
    relay_request_id.clear();
    if (relay_ack.status) ESP_LOGI(kTag, "Bluetooth relay %s returned %d", prefix, relay_ack.status);
    return std::move(relay_ack);
}

int RelayPickupRide(const std::string& task_id) {
    const auto body = "{\"request_id\":\"" + GenerateRequestID() + "\",\"task_id\":\"" + task_id + "\"}";
    return RelayVoiceRequest("V1", body).status;
}

JSON TaskHTTP(const std::string& url, const std::string& body = {}) {
    auto http = Board::GetInstance().GetNetwork()->CreateHttp();
    http->SetTimeout(2200);
    http->SetHeader("Authorization", "Bearer " KNIGHT_ORDERS_DEVICE_TOKEN);
    if (!body.empty()) {
        http->SetHeader("Content-Type", "application/json");
        http->SetContent(std::string(body));
    }
    if (!http->Open(body.empty() ? "GET" : "POST", url) ||
        (http->GetStatusCode() != 200 && http->GetStatusCode() != 201)) return {nullptr, cJSON_Delete};
    const auto result = http->ReadAll();
    http->Close();
    return JSON(cJSON_Parse(result.c_str()), cJSON_Delete);
}

std::string JSONString(const JSON& json, const char* key) {
    const auto* field = cJSON_GetObjectItemCaseSensitive(json.get(), key);
    return cJSON_IsString(field) ? field->valuestring : "";
}

std::string RequestRecommendation(const std::string& category, const std::string& city,
                                  const std::string& district, const std::string& destination) {
    if (category.empty() || city.empty() || destination.empty()) return "请告诉我想吃什么，以及搜索的城市和地点。";
    JSON request(cJSON_CreateObject(), cJSON_Delete);
    if (!request) return "暂时无法创建查店请求。";
    cJSON_AddStringToObject(request.get(), "request_id", GenerateRequestID().c_str());
    cJSON_AddStringToObject(request.get(), "category", category.c_str());
    cJSON_AddStringToObject(request.get(), "city", city.c_str());
    cJSON_AddStringToObject(request.get(), "district", district.c_str());
    cJSON_AddStringToObject(request.get(), "destination", destination.c_str());
    std::unique_ptr<char, decltype(&cJSON_free)> data(cJSON_PrintUnformatted(request.get()), cJSON_free);
    if (!data) return "暂时无法创建查店请求。";
    const auto relay = RelayVoiceRequest("Q1", data.get());
    if (relay.status >= 400 && relay.status < 500) return "骑士未接受这次查店请求，请核对地点和菜系。";
    auto id = relay.task_id;
    if (id.empty()) id = JSONString(TaskHTTP(RecommendationEndpoint(), data.get()), "id");
    if (id.size() != 32) return "未确认收到查店任务，请检查骑士连接。";
    {
        std::lock_guard<std::mutex> lock(receipts_mutex);
        latest_recommendation_id = id;
    }
    TrackVoiceResult(id, true);
    return "骑士已受理，只在美团查店。等小屏显示结果，你可以再说开始导航。";
}

std::string StartRecommendedRide() {
    std::string id;
    {
        std::lock_guard<std::mutex> lock(receipts_mutex);
        id = latest_recommendation_id;
    }
    if (id.empty()) return "请先让骑士在小屏显示推荐门店。";
    const auto body = "{\"request_id\":\"" + GenerateRequestID() + "\",\"task_id\":\"" + id + "\"}";
    const auto relay = RelayVoiceRequest("L1", body);
    if (relay.status == 409) return "还未确认小屏显示这笔推荐，或推荐已经过期。";
    auto route = relay.task_id;
    if (route.empty()) route = JSONString(TaskHTTP(RecommendationEndpoint() + "/navigation", body), "id");
    if (route.size() != 32) return "骑士还没有确认接收推荐门店导航。";
    {
        std::lock_guard<std::mutex> lock(receipts_mutex);
        latest_ordinary_route_id = route;
    }
    TrackVoiceResult(route, false);
    return "骑士已受理导航，正在核对高德上的同一家分店。";
}

void TrackVoiceResult(std::string id, bool pickup) {
    if (id.size() != 32) return;
    std::lock_guard<std::mutex> lock(receipts_mutex);
    for (const auto& task : pending_voice) if (task.id == id) return;
    for (const auto& notice : ready_voice) if (notice.task.id == id) return;
    if (pending_voice.size() >= 8) pending_voice.pop_back();
    pending_voice.push_front({std::move(id), pickup});
}

void MarkVoiceResultRead(const std::string& id) {
    std::lock_guard<std::mutex> lock(receipts_mutex);
    std::erase_if(pending_voice, [&](const auto& task) { return task.id == id; });
    std::erase_if(ready_voice, [&](const auto& entry) { return entry.task.id == id; });
    if (prompted_voice_id == id) prompted_voice_id.clear();
}

std::string ReadVoiceNotice() {
    VoiceNotice item;
    {
        std::lock_guard<std::mutex> lock(receipts_mutex);
        auto& nav = navigation_voice;
        const auto now = std::time(nullptr);
        if (!nav.line.empty() && now < nav.line_until) {
            auto line = std::move(nav.line);
            nav.line.clear();
            prompted_voice_id.clear();
            ESP_LOGI(kTag, "Navigation voice cue returned %s", nav.line_id.c_str());
            return "用当前音色逐字播报这条导航指引。只读这句话，不解释：" + line;
        }
        if (now < nav.active_until) return "当前没有新的导航转向提示。";
        if (ready_voice.empty()) return "当前没有新的骑士任务回执。";
        item = std::move(ready_voice.front());
        ready_voice.pop_front();
        prompted_voice_id.clear();
    }
    return item.task.pickup ? SpokenFeedback(item.text, item.task.id) :
                              "请用当前音色播报骑士的实际导航结果：" + item.text;
}

std::string CollectVoiceNotice(const VoiceTask& task) {
    if (task.pickup) {
        std::string id;
        auto bluetooth = ReadBluetoothReceipt(task.id, id);
        if (!bluetooth.empty()) return bluetooth;
        const auto body = TaskHTTP(std::string(KNIGHT_DELIVERY_ENDPOINT) + "/" + task.id + "/feedback-text");
        const auto state = JSONString(body, "state");
        if (state == "pickup_checkout" || state == "needs_input") return JSONString(body, "text");
        return {};
    }
    const auto body = TaskHTTP(CyclingEndpoint() + "/" + task.id);
    const auto state = JSONString(body, "state");
    if (state == "active" || state == "failed" || state == "expired" || state == "ended") return JSONString(body, "note");
    return {};
}

void VoiceResultWorker(void*) {
    for (;;) {
        VoiceTask task;
        {
            std::lock_guard<std::mutex> lock(receipts_mutex);
            if (!pending_voice.empty()) {
                task = pending_voice.front();
                pending_voice.pop_front();
                pending_voice.push_back(task);
            }
        }
        if (!task.id.empty()) {
            auto text = CollectVoiceNotice(task);
            if (!text.empty()) {
                std::lock_guard<std::mutex> lock(receipts_mutex);
                if (std::erase_if(pending_voice, [&](const auto& current) { return current.id == task.id; })) {
                    if (ready_voice.size() >= 8) ready_voice.pop_front();
                    ready_voice.push_back({task, std::move(text)});
                    ESP_LOGI(kTag, "Asynchronous receipt %s ready", task.id.c_str());
                }
            }
        }
        ScheduleVoicePrompt();
        vTaskDelay(pdMS_TO_TICKS(2800));
    }
}

std::string RequestOrdinaryRide(const std::string& city, const std::string& district, const std::string& destination) {
    if (city.empty() || destination.empty()) return "请告诉我导航的城市和具体地点。";
    JSON args(cJSON_CreateObject(), cJSON_Delete);
    if (!args) return "暂时无法创建骑行请求。";
    cJSON_AddStringToObject(args.get(), "request_id", GenerateRequestID().c_str());
    cJSON_AddStringToObject(args.get(), "city", city.c_str());
    cJSON_AddStringToObject(args.get(), "district", district.c_str());
    cJSON_AddStringToObject(args.get(), "destination", destination.c_str());
    std::unique_ptr<char, decltype(&cJSON_free)> raw(cJSON_PrintUnformatted(args.get()), cJSON_free);
    if (!raw) return "暂时无法创建骑行请求。";
    const auto relay = RelayVoiceRequest("R1", raw.get());
    if (relay.status >= 400 && relay.status < 500) return "骑士未接受这条导航请求，请核对目的地或当前路线。";
    auto id = relay.task_id;
    if (id.empty()) id = JSONString(TaskHTTP(CyclingEndpoint(), raw.get()), "id");
    if (id.size() != 32) return "没有确认骑士接收导航请求。";
    {
        std::lock_guard<std::mutex> lock(receipts_mutex);
        latest_ordinary_route_id = id;
    }
    TrackVoiceResult(id, false);
    ESP_LOGI(kTag, "Ordinary ride %s accepted", id.c_str());
    return "骑士已受理普通导航。手机会优先启动路线，暂停的订单在导航结束后自动续办。";
}

std::string OrdinaryRideStatus() {
    std::string id;
    {
        std::lock_guard<std::mutex> lock(receipts_mutex);
        id = latest_ordinary_route_id;
    }
    if (id.size() != 32) return "还没有发起过普通骑行导航。";
    const auto result = TaskHTTP(CyclingEndpoint() + "/" + id);
    if (!result) return "暂时无法查询导航状态。";
    const auto note = JSONString(result, "note");
    if (note.empty()) return "骑士正在等待领取或启动路线。";
    MarkVoiceResultRead(id);
    return "骑士的导航状态：" + note;
}
#endif

std::string SubmitIntent(const char* endpoint, std::string body, bool delivery, bool pickup = false) {
    const auto accepted = [&](const std::string& id, const std::string& state) -> std::string {
        ESP_LOGI(kTag, "Intent %s reported as %s", id.c_str(), state.c_str());
        if (delivery) {
#ifdef KNIGHT_DELIVERY_ENDPOINT
            if (pickup) {
                {
                    std::lock_guard<std::mutex> lock(receipts_mutex);
                    latest_pickup_id = id;
                    reported_checkout_id.clear();
                }
                TrackVoiceResult(id, true);
                return "骑士已受理这笔自提，会继续处理。你可以继续说话，也可以直接说导航到指定地点。";
            }
#endif
            return "美团点单请求已发送，核对结果请看骑士 App 的美团点单。";
        }
        if (state == "pending") return "已发送热美式测试点单请求，请在骑士 App 的驿站测试订单里确认。";
        return "这一笔测试点单请求已处理，请到骑士 App 查看状态。";
    };
#ifdef KNIGHT_DELIVERY_ENDPOINT
    if (delivery && std::strcmp(endpoint, KNIGHT_DELIVERY_ENDPOINT) == 0) {
        const auto relay = RelayVoiceRequest("P1", body);
        if (!relay.task_id.empty()) return accepted(relay.task_id, "accepted");
        if (relay.status == 409) throw std::runtime_error("已有待处理任务，请稍后再试或查询当前结果");
        if (relay.status >= 400 && relay.status < 500) throw std::runtime_error("骑士未接受点单，请核对请求内容");
    }
#endif
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
                throw std::runtime_error("已有待处理任务，或当前任务已不能续办。可以说播报我的自提结果");
            }
            throw std::runtime_error("Mac 未接受点单请求，请检查服务和请求内容");
        }
        const auto response = http->ReadAll();
        http->Close();
        std::unique_ptr<cJSON, decltype(&cJSON_Delete)> json(cJSON_Parse(response.c_str()), cJSON_Delete);
        const auto* state = cJSON_GetObjectItemCaseSensitive(json.get(), "state");
        const auto* id = cJSON_GetObjectItemCaseSensitive(json.get(), "id");
        if (!cJSON_IsString(state) || !cJSON_IsString(id)) continue;
        return accepted(id->valuestring, state->valuestring);
    }
    throw std::runtime_error("无法确认骑士服务收到请求。请先说播报我的自提结果，避免重复提交");
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

std::string ContinuePickup(const std::string& selection) {
    if (selection != "不额外加糖") return "没有改变订单。若你接受该规格，请明确说可以，就不额外加糖。";
    std::string id;
    {
        std::lock_guard<std::mutex> lock(receipts_mutex);
        id = latest_pickup_id;
    }
    if (id.size() != 32) return "还未核对到等待答复的任务。你可以先说播报我的自提结果。";
    const auto endpoint = std::string(KNIGHT_DELIVERY_ENDPOINT) + "/" + id + "/continue-pickup";
    const auto body = "{\"selection\":\"不额外加糖\",\"request_id\":\"" + GenerateRequestID() + "\"}";
    return SubmitIntent(endpoint.c_str(), body, true, true);
}
#endif
} // namespace
#endif

bool ReceiveKnightPickupFeedback(const uint8_t* packet, size_t size) {
#if defined(KNIGHT_ORDERS_CONFIGURED) && defined(KNIGHT_DELIVERY_ENDPOINT)
    constexpr size_t header_size = 38;
    constexpr size_t signature_size = 32;
    if (size <= header_size + signature_size || size > 2048 ||
        (packet[0] != 'K' && packet[0] != 'N' && packet[0] != 'A') ||
        packet[1] != '1') return false;
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
    if (now < 1700000000 || expires <= now || expires > now + 305) {
        ESP_LOGW(kTag, "Bluetooth voice packet rejected by clock (expires in %llds)",
                 static_cast<long long>(expires) - static_cast<long long>(now));
        return false;
    }
    const std::string id(reinterpret_cast<const char*>(packet + 2), 32);
    if (packet[0] == 'A') {
        if (expires > now + 30) return false;
        return AcceptRelayAck(id, std::string(reinterpret_cast<const char*>(packet + header_size), body_size - header_size));
    }
    if (packet[0] == 'N') {
        if (expires > now + 15) return false;
        return AcceptNavigationVoice(id, std::string(reinterpret_cast<const char*>(packet + header_size),
                                                     body_size - header_size), expires);
    }
    {
        std::lock_guard<std::mutex> lock(receipts_mutex);
        for (const auto& receipt : receipts) {
            if (receipt.id == id) return true;
        }
        if (receipts.size() == 4) receipts.pop_front();
        receipts.push_back({id, std::string(reinterpret_cast<const char*>(packet + header_size),
                                           body_size - header_size), expires});
    }
    ESP_LOGI(kTag, "Accepted Bluetooth pickup receipt: %s", id.c_str());
    return true;
#else
    return false;
#endif
}

void InitializeKnightOrders() {
#if defined(KNIGHT_ORDERS_CONFIGURED)
    McpServer::GetInstance().AddTool("self.knight_orders.request_americano",
        "仅供开发联调，当用户明确说运行驿站测试订单时使用。真实点单请用美团工具。",
        PropertyList({Property("quantity", kPropertyTypeInteger, 1, 1, 5)}),
        [](const PropertyList& args) -> ReturnValue {
            return SubmitAmericano(args["quantity"].value<int>());
        });
#ifdef KNIGHT_DELIVERY_ENDPOINT
    auto& mcp = McpServer::GetInstance();
    xTaskCreate(VoiceResultWorker, "knight_voice_tasks", 6144, nullptr, 3, nullptr);
    mcp.AddTool("self.knight_orders.recommend_meituan_store",
        "用户说找附近餐厅、推荐、评价最高、看特色菜或先显示店名和菜单时使用。只读美团，不点单。"
        "从对话保留城市、区、地铁站具体出口和菜系。说找店再导航也先用本工具，显示后等待用户说开始导航。",
        PropertyList({Property("category", kPropertyTypeString), Property("city", kPropertyTypeString),
                      Property("district", kPropertyTypeString, std::string()), Property("destination", kPropertyTypeString)}),
        [](const PropertyList& args) -> ReturnValue {
            return RequestRecommendation(args["category"].value<std::string>(), args["city"].value<std::string>(),
                                         args["district"].value<std::string>(), args["destination"].value<std::string>());
        });
    mcp.AddTool("self.knight_orders.start_recommended_ride",
        "用户在美团门店推荐已显示后明确说开始导航、导航过去或去这家店时使用。高德会核对同一分店。",
        PropertyList(), [](const PropertyList&) -> ReturnValue { return StartRecommendedRide(); });
    mcp.AddTool("self.knight_orders.request_ordinary_ride",
        "用户要求导航到明确地点时使用，独立于点单。按对话填城市、区和地名，地名可含具体出口。"
        "工具仅确认已受理，启动结果稍后反馈。",
        PropertyList({Property("city", kPropertyTypeString), Property("district", kPropertyTypeString, std::string()),
                      Property("destination", kPropertyTypeString)}),
        [](const PropertyList& args) -> ReturnValue {
            return RequestOrdinaryRide(args["city"].value<std::string>(), args["district"].value<std::string>(),
                                       args["destination"].value<std::string>());
        });
    mcp.AddTool("self.knight_orders.get_ordinary_ride_status",
        "用户查询指定目的地的普通导航是否启动时使用。",
        PropertyList(), [](const PropertyList&) -> ReturnValue { return OrdinaryRideStatus(); });
    mcp.AddTool("self.knight_orders.read_task_notice",
        "收到「请准确播报骑士当前的导航指引」或「请播报骑士待播放的任务回执」时使用，"
        "也可用于用户主动查询新的任务回执。"
        "只用当前音色播报工具返回内容。",
        PropertyList(), [](const PropertyList&) -> ReturnValue { return ReadVoiceNotice(); });
    mcp.AddTool("self.knight_orders.summarize_meituan",
        "当用户请你复述或总结购买需求时使用。按对话提取商品、数量、指定店铺、规格、实付预算、自提目的地。这个工具只复述。",
        DeliveryProperties(), [](const PropertyList& args) -> ReturnValue {
            return SummarizeDelivery(ReadDeliveryRequest(args));
        });
    mcp.AddTool("self.knight_orders.prepare_meituan",
        "只在用户明确要求购买、点餐或准备配送订单时使用，不用于找餐厅、比较评分或查看菜品。保留商品、数量、规格和实付预算。"
        "到店自提请使用 prepare_meituan_pickup。工具受理后提示到骑士 App 查看。",
        DeliveryProperties(), [](const PropertyList& args) -> ReturnValue {
            return SubmitDelivery(ReadDeliveryRequest(args));
        });
    mcp.AddTool("self.knight_orders.prepare_meituan_pickup",
        "只在用户明确要求购买、点餐或加购物车到店自提时使用。找店、比较评分、推荐菜或导航时禁止调用。"
        "把对话中用户已明确的目的地原文放进 pickup_destination。"
        "没说清地点或商品就用语音追问。按用户明确说出的商品、数量、门店、糖度、温度和预算直接准备。"
        "默认无需用户再次确认或在手机输入。用当前对话音色读回实际结果，最终由用户在美团付款。",
        DeliveryProperties(true), [](const PropertyList& args) -> ReturnValue {
            const auto request = ReadDeliveryRequest(args);
            if (request.pickup_destination.find_first_not_of(" \t\r\n") == std::string::npos) {
                throw std::runtime_error("请先明确到店自提的目的地");
            }
            return SubmitDelivery(request);
        });
    mcp.AddTool("self.knight_orders.continue_meituan_pickup",
        "仅在上一笔真实自提回执明确询问是否接受不额外加糖，而且用户已明确接受这一选项时调用。"
        "传入原文规格不额外加糖。拒绝、含糊答复或其他规格不调用本工具。成功后继续原任务，保留其他字段并播报实际回执。",
        PropertyList({Property("selection", kPropertyTypeString)}), [](const PropertyList& args) -> ReturnValue {
            return ContinuePickup(args["selection"].value<std::string>());
        });
    mcp.AddTool("self.knight_orders.get_pickup_feedback",
        "当用户想听上一笔美团自提结果时使用。只查询并播报，保留回执中的商品、金额和付款状态。",
        PropertyList(), [](const PropertyList&) -> ReturnValue {
            return PickupFeedback("latest");
        });
    mcp.AddTool("self.knight_orders.confirm_pickup_feedback",
        "用户主动对已经就绪的结算回执表示确认时可调用。确认只记录结果，付款仍在美团完成。"
        "遇到糖度追问时应按回执使用 continue_meituan_pickup。",
        PropertyList(), [](const PropertyList&) -> ReturnValue {
            return ConfirmPickupFeedback();
        });
    mcp.AddTool("self.knight_orders.start_pickup_ride",
        "只有已播报实际自提结算回执，且用户明确说开始导航或导航去该取餐门店时调用。"
        "普通好的、确认订单、播报结果均不调用。根据工具回执答复是否确实启动。",
        PropertyList(), [](const PropertyList&) -> ReturnValue { return PickupRide(true); });
    mcp.AddTool("self.knight_orders.get_pickup_ride_status",
        "用户询问刚才的自提骑行导航是否已启动时，查询实际 GPS 状态。",
        PropertyList(), [](const PropertyList&) -> ReturnValue { return PickupRide(false); });
#endif
#endif
}
