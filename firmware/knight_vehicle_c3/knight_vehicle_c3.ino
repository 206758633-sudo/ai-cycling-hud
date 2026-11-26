#include <Arduino.h>
#include <SPI.h>
#include <Adafruit_SPITFT.h>
#include <BLE2902.h>
#include <BLEDevice.h>
#include <U8g2_for_Adafruit_GFX.h>

#include "hud_packet.h"
#include "panbopo_panel_init.h"
#include "vehicle_route.h"
#include "order_card.h"

namespace {

constexpr int kLcdClock = 1, kLcdData = 2, kLcdDc = 0, kLcdCs = 21, kLcdBacklight = 20;
constexpr int kPanelSize = 360;
constexpr uint32_t kGuideAgeMs = 15000;
constexpr uint32_t kRouteAgeMs = 35000;
constexpr uint16_t kBackground = 0x0842, kForeground = 0xffff, kAccent = 0x5e9f, kMuted = 0x8c91;
constexpr uint16_t kFinish = 0xff25;
constexpr const char *kDeviceName = "ROADLINK-VEHICLE";
constexpr const char *kVersion = "V,vehicle-c3/2.2";
constexpr const char *kService = "6e400001-b5a3-f393-e0a9-e50e24dcca9e";
constexpr const char *kRx = "6e400002-b5a3-f393-e0a9-e50e24dcca9e";
constexpr const char *kTx = "6e400003-b5a3-f393-e0a9-e50e24dcca9e";

class PanbopoDisplay : public Adafruit_SPITFT {
public:
    PanbopoDisplay() : Adafruit_SPITFT(kPanelSize, kPanelSize, &SPI, kLcdCs, kLcdDc, -1) {}

    void begin(uint32_t frequency) override {
        SPI.begin(kLcdClock, -1, kLcdData, kLcdCs);
        initSPI(frequency);
        sendCommand(0x01);
        delay(120);
        for (const auto &cmd : kPanbopoPanelInit) {
            sendCommand(cmd.command, cmd.data, cmd.dataLength);
            if (cmd.delayMs) delay(cmd.delayMs);
        }
        const uint8_t madctl = 0;
        sendCommand(0x36, &madctl, 1);
    }

    void setAddrWindow(uint16_t x, uint16_t y, uint16_t w, uint16_t h) override {
        writeCommand(0x2a);
        SPI_WRITE16(x);
        SPI_WRITE16(x + w - 1);
        writeCommand(0x2b);
        SPI_WRITE16(y);
        SPI_WRITE16(y + h - 1);
        writeCommand(0x2c);
    }
};

struct Event {
    enum Kind : uint8_t { Connected, Disconnected, Write } kind;
    uint8_t length;
    char bytes[20];
};

PanbopoDisplay display;
U8G2_FOR_ADAFRUIT_GFX text;
BLECharacteristic *tx = nullptr;
QueueHandle_t events = nullptr;
HudPacket packet;
VehicleRoute vehicleRoute;
OrderCard orderCard;
bool connected = false;
bool restartAds = false;
uint32_t disconnectedAt = 0;
uint32_t lastDirection = 0;
bool showsDirection = false;
uint32_t lastRouteUpdate = 0;
char guideTitle[49] = "等待指引";
char guideDetail[49] = "";
float guideAngle = 0;

void centerText(const char *value, int baseline, uint16_t color) {
    text.setForegroundColor(color);
    const auto width = text.getUTF8Width(value);
    text.setCursor(max(0, (kPanelSize - static_cast<int>(width)) / 2), baseline);
    text.print(value);
}

void showStatus(const char *status, const char *detail) {
    showsDirection = false;
    display.fillScreen(kBackground);
    centerText("骑士", 105, kAccent);
    centerText(status, 178, kForeground);
    centerText(detail, 214, kMuted);
    Serial.printf("HUD status %s | %s\n", status, detail);
}

void drawOrderCard() {
    display.fillScreen(kBackground);
    centerText(orderCard.title, 110, kAccent);
    centerText(orderCard.item, 185, kForeground);
    centerText(orderCard.detail, 228, kMuted);
    Serial.printf("HUD order card %s | %s | %s\n", orderCard.event, orderCard.title, orderCard.item);
}

bool validUtf8(const char *value) {
    const auto *p = reinterpret_cast<const uint8_t *>(value);
    while (*p) {
        const uint8_t lead = *p++;
        if (lead < 0x20 || lead == 0x7f) return false;
        if (lead < 0x80) continue;
        int bytes = lead < 0xe0 ? 1 : lead < 0xf0 ? 2 : 3;
        if (lead < 0xc2 || lead > 0xf4) return false;
        for (int i = 0; i < bytes; ++i) {
            const uint8_t byte = *p++;
            if ((byte & 0xc0) != 0x80) return false;
            if (i == 0 && ((lead == 0xe0 && byte < 0xa0) || (lead == 0xed && byte >= 0xa0) ||
                           (lead == 0xf0 && byte < 0x90) || (lead == 0xf4 && byte >= 0x90))) return false;
        }
    }
    return true;
}

void drawArrow(float angle, int midX = 180, int midY = 137, float scale = 1) {
    const float dx = sinf(angle), dy = -cosf(angle);
    const auto x = [&](float along, float side) { return midX + scale * (dx * along - dy * side); };
    const auto y = [&](float along, float side) { return midY + scale * (dy * along + dx * side); };
    display.fillTriangle(x(55, 0), y(55, 0), x(12, -34), y(12, -34), x(12, 34), y(12, 34), kAccent);
    display.fillTriangle(x(12, -12), y(12, -12), x(12, 12), y(12, 12), x(-46, -12), y(-46, -12), kAccent);
    display.fillTriangle(x(12, 12), y(12, 12), x(-46, -12), y(-46, -12), x(-46, 12), y(-46, 12), kAccent);
}

void drawRoute() {
    if (orderCard.visible) return;
    display.fillScreen(kBackground);
    centerText("骑行路线", 47, kForeground);
    const auto px = [](VehicleRoute::Point p) { return 70 + (220 * p.x + 127) / 255; };
    const auto py = [](VehicleRoute::Point p) { return 56 + (220 * p.y + 127) / 255; };
    for (size_t i = 1; i < vehicleRoute.count; ++i) {
        const auto a = vehicleRoute.points[i - 1];
        const auto b = vehicleRoute.points[i];
        for (int offset = -1; offset <= 1; ++offset) {
            display.drawLine(px(a) + offset, py(a), px(b) + offset, py(b), kAccent);
            display.drawLine(px(a), py(a) + offset, px(b), py(b) + offset, kAccent);
        }
    }
    const auto end = vehicleRoute.points[vehicleRoute.count - 1];
    display.fillCircle(px(end), py(end), 6, kFinish);
    if (vehicleRoute.hasPosition) {
        display.fillCircle(px(vehicleRoute.position), py(vehicleRoute.position), 7, kForeground);
        display.fillCircle(px(vehicleRoute.position), py(vehicleRoute.position), 4, kAccent);
    }
    if (showsDirection) drawArrow(guideAngle, 86, 296, 0.30f);
    char line[112];
    if (guideDetail[0]) snprintf(line, sizeof(line), "%s  %s", guideTitle, guideDetail);
    else snprintf(line, sizeof(line), "%s", guideTitle);
    centerText(line, 303, kForeground);
    if (vehicleRoute.remainingMeters >= 0) {
        if (vehicleRoute.remainingMeters >= 1000) {
            snprintf(line, sizeof(line), "剩余 %.1f公里", vehicleRoute.remainingMeters / 1000.0);
        } else {
            snprintf(line, sizeof(line), "剩余 %ld米", static_cast<long>(vehicleRoute.remainingMeters));
        }
        centerText(line, 329, kMuted);
    }
}

void showDirection(const char *turn, const char *detail) {
    constexpr float kQuarter = 1.5707963f;
    float angle = 0;
    if (strstr(turn, "掉头") || strstr(turn, "调头")) angle = 2 * kQuarter;
    else if (strstr(turn, "左后")) angle = -1.5f * kQuarter;
    else if (strstr(turn, "右后")) angle = 1.5f * kQuarter;
    else if (strstr(turn, "左前")) angle = -0.5f * kQuarter;
    else if (strstr(turn, "右前")) angle = 0.5f * kQuarter;
    else if (strstr(turn, "左转")) angle = -kQuarter;
    else if (strstr(turn, "右转")) angle = kQuarter;
    else if (!strstr(turn, "直行")) {
        showsDirection = false;
        if (vehicleRoute.count) drawRoute();
        else showStatus(turn, detail);
        return;
    }

    showsDirection = true;
    lastDirection = millis();
    guideAngle = angle;
    if (vehicleRoute.count) {
        drawRoute();
        Serial.printf("HUD direction %s | %s\n", turn, detail);
        return;
    }
    display.fillScreen(kBackground);
    drawArrow(angle);
    centerText(turn, 218, kForeground);
    centerText(detail, 255, kForeground);
    Serial.printf("HUD direction %s | %s\n", turn, detail);
}

void handle(const char *message) {
    if (strcmp(message, "PING") == 0) {
        tx->setValue("PONG");
        tx->notify();
        tx->setValue(kVersion);
        return;
    }
    if (!strncmp(message, "O:", 2)) {
        if (validUtf8(message) && orderCard.accept(message, millis(), vehicleRoute.count != 0)) drawOrderCard();
        return;
    }
    const auto routeUpdate = vehicleRoute.accept(message);
    if (routeUpdate != VehicleRoute::Update::None) {
        lastRouteUpdate = millis();
        if (routeUpdate == VehicleRoute::Update::Heartbeat) {
            Serial.printf("HUD route alive %08lx\n", static_cast<unsigned long>(vehicleRoute.id));
        } else if (routeUpdate == VehicleRoute::Update::Clear) {
            orderCard.hide();
            showStatus("导航结束", "等待新路线");
        } else {
            if (orderCard.visible && !orderCard.timed) orderCard.hide();
            drawRoute();
            if (routeUpdate == VehicleRoute::Update::Shape) {
                char ack[12];
                snprintf(ack, sizeof(ack), "A:R%08lx", static_cast<unsigned long>(vehicleRoute.id));
                tx->setValue(ack);
                tx->notify();
                tx->setValue(kVersion);
                Serial.printf("HUD route %08lx | %u points\n", static_cast<unsigned long>(vehicleRoute.id), static_cast<unsigned>(vehicleRoute.count));
            } else {
                Serial.printf("HUD route position %u,%u | %ldm\n", vehicleRoute.position.x, vehicleRoute.position.y,
                              static_cast<long>(vehicleRoute.remainingMeters));
            }
        }
        return;
    }
    if (strncmp(message, "D:", 2) != 0 || !validUtf8(message)) return;
    const char *separator = strchr(message + 2, '|');
    if (!separator || separator == message + 2 || strlen(separator + 1) == 0 ||
        separator - message - 2 >= 49 || strlen(separator + 1) >= 49 || strchr(separator + 1, '|')) return;
    char turn[49]{};
    memcpy(turn, message + 2, separator - message - 2);
    const char *detail = separator + 1;
    if (!strcmp(turn, "导航结束") || !strcmp(turn, "已到达") || !strcmp(turn, "算路未完成")) {
        orderCard.hide();
        vehicleRoute.clear();
        showStatus(turn, detail);
        return;
    }
    snprintf(guideTitle, sizeof(guideTitle), "%s", turn);
    snprintf(guideDetail, sizeof(guideDetail), "%s", detail);
    if (!strcmp(turn, "路线规划") || !strcmp(turn, "重新算路")) orderCard.hide();
    if (vehicleRoute.count) lastRouteUpdate = millis();
    if (!vehicleRoute.count && orderCard.visible) return;
    const char *unit = detail;
    while (*unit >= '0' && *unit <= '9') ++unit;
    if (*unit == '.' && unit != detail) {
        do { ++unit; } while (*unit >= '0' && *unit <= '9');
    }
    while (*unit == ' ' && unit != detail) ++unit;
    if (unit != detail && (!strcmp(unit, "米") || !strcmp(unit, "公里"))) {
        showDirection(turn, detail);
    } else {
        showsDirection = false;
        if (vehicleRoute.count) drawRoute();
        else showStatus(turn, detail);
    }
}

class Receiver : public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *characteristic) override {
        const auto value = characteristic->getValue();
        Event event{Event::Write, 0, {}};
        if (value.length() <= sizeof(event.bytes)) {
            event.length = static_cast<uint8_t>(value.length());
            memcpy(event.bytes, value.c_str(), event.length);
        }
        xQueueSend(events, &event, 0);
    }
};

class Connection : public BLEServerCallbacks {
    void onConnect(BLEServer *) override {
        const Event event{Event::Connected, 0, {}};
        xQueueSend(events, &event, 0);
    }

    void onDisconnect(BLEServer *) override {
        const Event event{Event::Disconnected, 0, {}};
        xQueueSend(events, &event, 0);
    }
};

}  // namespace

void setup() {
    Serial.begin(115200);
    pinMode(kLcdBacklight, OUTPUT);
    digitalWrite(kLcdBacklight, LOW);
    display.begin(32000000);
    text.begin(display);
    text.setFont(u8g2_font_wqy16_t_gb2312);
    text.setFontMode(1);
    showStatus("车载导航", "等待骑士连接");
    digitalWrite(kLcdBacklight, HIGH);

    events = xQueueCreate(20, sizeof(Event));
    if (!events) {
        showStatus("蓝牙启动失败", "请重新上电");
        return;
    }
    BLEDevice::init(kDeviceName);
    BLEServer *server = BLEDevice::createServer();
    server->setCallbacks(new Connection);
    BLEService *service = server->createService(kService);
    tx = service->createCharacteristic(kTx, BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
    tx->addDescriptor(new BLE2902);
    tx->setValue(kVersion);
    auto *rx = service->createCharacteristic(kRx, BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
    rx->setCallbacks(new Receiver);
    service->start();
    BLEDevice::getAdvertising()->addServiceUUID(kService);
    BLEDevice::getAdvertising()->setScanResponse(true);
    BLEDevice::startAdvertising();
    Serial.println("PANBOPO vehicle-c3 ready 360x360");
}

void loop() {
    if (!events) {
        delay(100);
        return;
    }
    Event event{};
    if (xQueueReceive(events, &event, pdMS_TO_TICKS(20)) == pdTRUE) {
        switch (event.kind) {
            case Event::Connected:
                packet.reset();
                vehicleRoute.clear();
                orderCard.reset();
                snprintf(guideTitle, sizeof(guideTitle), "等待指引");
                guideDetail[0] = '\0';
                tx->setValue(kVersion);
                connected = true;
                restartAds = false;
                showStatus("已连接骑士", "等待导航");
                break;
            case Event::Disconnected:
                packet.reset();
                vehicleRoute.clear();
                orderCard.reset();
                connected = false;
                restartAds = true;
                disconnectedAt = millis();
                showStatus("蓝牙已断开", "等待骑士重连");
                break;
            case Event::Write:
                if (connected) {
                    if (const char *message = packet.accept(event.bytes, event.length, millis())) handle(message);
                }
                break;
        }
    }
    if (restartAds && millis() - disconnectedAt >= 250) {
        restartAds = false;
        BLEDevice::startAdvertising();
    }
    if (vehicleRoute.count && millis() - lastRouteUpdate >= kRouteAgeMs) {
        orderCard.hide();
        vehicleRoute.clear();
        showStatus("路线同步暂停", "留意道路");
    }
    if (showsDirection && millis() - lastDirection >= kGuideAgeMs) {
        showsDirection = false;
        if (vehicleRoute.count) {
            snprintf(guideTitle, sizeof(guideTitle), "指引暂停");
            guideDetail[0] = '\0';
            drawRoute();
        } else {
            showStatus("指引暂停", "留意道路");
        }
    }
    if (orderCard.expire(millis()) && vehicleRoute.count) {
        drawRoute();
        Serial.println("HUD order card expired | route restored");
    }
}
