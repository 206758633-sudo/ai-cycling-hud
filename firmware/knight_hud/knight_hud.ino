/*
 * knight_hud.ino — 骑士 App × ESP32-S3 HUD 固件 v2
 * ---------------------------------------------------------------
 * 把「骑士 App」的 AI 语音对话（数字大冰）和 AI 语音控屏
 * （微信回复 / 驿站点单 / 发路线到群）搬到 128x64 硬件屏上。
 *
 * 硬件（当前这套，已实测点亮）：
 *   ESP32-S3-WROOM-1 N16R8（16MB Flash / 8MB PSRAM）
 *   SSD1306 128x64 I2C OLED    VCC->3V3 GND->GND SCL->GPIO9 SDA->GPIO8
 *   有源蜂鸣器（低电平触发）    VCC->3V3 GND->GND I/O->GPIO17
 *   BUTTON：板载 BOOT 键 GPIO0
 *
 * 协议：docs/hud/ai-hud-protocol.md
 *   手机 -> 板子（UTF-8，可 #seq 分片）：
 *     S:<state>  Q:<用户话>  A:<AI答>  T:<操作标题>
 *     K:<i>,<n>,<步骤>   G:<确认事项>|<按钮>   D:<行1>|<行2>   E:<错误>
 *     BEEP / 旧协议 B1..B3 DB= CHK BOOK NEXT H: 1..4: SHOW CLR
 *   板子 -> 手机：
 *     V,<版本>  S,<state>  B,short|long  G,1|G,0
 *
 * Arduino IDE / arduino-cli：
 *   FQBN = esp32:esp32:esp32s3:CDCOnBoot=cdc,FlashSize=16M,PSRAM=opi,PartitionScheme=default_16MB
 * 依赖：U8g2 >= 2.36（中文字库 wqy12 / wqy16）
 * ---------------------------------------------------------------
 */

#include <U8g2lib.h>
#include <Wire.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <USBCDC.h>

// 日志统一走 USB CDC（S3 原生 USB），不依赖 CDCOnBoot 预编译开关
#define DBG Serial

// ---------------- 引脚 ----------------
#define PIN_SDA     8
#define PIN_SCL     9
#define PIN_BUZZER  17
#define PIN_BUTTON  0
#define BUZZ_ACTIVE_LOW 1

// ---------------- BLE ----------------
#define DEV_NAME     "ROADLINK-HUD"
#define FW_VERSION   "knight-hud/2.1"
#define SERVICE_UUID "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
#define RX_UUID      "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
#define TX_UUID      "6e400003-b5a3-f393-e0a9-e50e24dcca9e"

U8G2_SSD1306_128X64_NONAME_F_HW_I2C u8g2(U8G2_R0, U8X8_PIN_NONE);

BLECharacteristic *txChar = nullptr;
volatile bool bleConnected = false;
volatile bool needReadv = false;      // 断开后延迟重广播（BLE 栈立刻 start 有时不生效）
uint32_t advAt = 0;

// ---------------- 屏幕模式 ----------------
enum Mode : uint8_t { M_IDLE, M_LISTEN, M_THINK, M_SAY, M_ACT, M_GATE, M_HUD, M_LEGACY };

Mode mode = M_IDLE;

// ---------------- 文案缓冲 ----------------
char qText[96];                 // 用户说的话
char aText[240];                // AI 回答
char actTitle[48];              // 操作标题（例：微信回复老王）
char actSteps[4][48];           // 操作步骤，最多 4 步
uint8_t actCur = 0;             // 当前步骤（1 起）
uint8_t actTotal = 0;
char gateText[96];              // 确认事项
char gateYes[40];               // 确认按钮文案
int   gateSec = 8;
uint32_t gateDeadline = 0;
char hud1[48], hud2[48];        // 双行镜像
char errText[96];
uint32_t errUntil = 0;

// AI 回答自动换行后的行
#define SAY_MAX_LINES 12
#define LINE_CHARS 40
char sayLines[SAY_MAX_LINES][LINE_CHARS];
uint8_t sayLineCount = 0;
uint8_t sayScroll = 0;
uint32_t sayScrollAt = 0;

// ---------------- 蜂鸣器 ----------------
uint8_t  beepLeft = 0;
uint16_t beepOnMs = 0, beepOffMs = 0;
uint32_t beepNext = 0;
bool     beepState = false;

// ---------------- 按键 ----------------
bool buttonDown = false;
uint32_t buttonAt = 0;

// ---------------- 绘制节奏 ----------------
uint32_t lastDraw = 0;
bool dirty = true;
uint32_t modeAt = 0;

// ---------------- 旧协议数据（保持 v1 兼容） ----------------
struct Build {
  const char *name;
  uint8_t score;
  uint8_t db;
  uint8_t stock;
  uint16_t cost;
  uint8_t colorPct;
  const char *code;
  uint8_t dist100m;
  uint16_t labor;
};
const Build BUILDS[3] = {
  { "BLACKGOLD", 92, 87, 78, 7460, 24, "#T208", 46, 380 },
  { "CEMENT",    88, 85, 78, 6980, 12, "#T315", 32, 360 },
  { "RETRO",     90, 86, 78, 9090,  0, "#T109", 28, 420 },
};
const uint8_t DB_LIMIT = 90;
uint8_t  buildIdx   = 0;
uint8_t  dbValue    = 87;
bool     legalPass  = true;
bool     booked     = false;
uint8_t  legacyPage = 1;
uint8_t  queueNo    = 3;
char hdrText[28] = "ROADLINK";
char lineText[4][28] = { "", "", "", "" };

// ================================================================
//  工具：UTF-8 / 文本换行
// ================================================================
// 取一个 UTF-8 字符的字节数
static uint8_t utf8Len(uint8_t c) {
  if (c < 0x80) return 1;
  if ((c & 0xE0) == 0xC0) return 2;
  if ((c & 0xF0) == 0xE0) return 3;
  if ((c & 0xF8) == 0xF0) return 4;
  return 1;
}

// 把 src 按像素宽度折成多行（U8g2 当前字体必须已 setFont）
static uint8_t wrapLines(const char *src, char dst[][LINE_CHARS], uint8_t maxLines, int maxPx) {
  uint8_t n = 0;
  int x = 0;
  uint8_t col = 0;
  dst[0][0] = 0;
  const char *p = src;
  while (*p && n < maxLines) {
    uint8_t len = utf8Len((uint8_t)*p);
    char tok[5] = { 0 };
    for (uint8_t i = 0; i < len; i++) tok[i] = p[i];
    int w = u8g2.getUTF8Width(tok);
    if (w <= 0) w = (len == 1) ? 6 : 12;
    bool wrap = (x + w > maxPx);
    if (wrap && col > 0) {
      dst[n][col] = 0;
      n++;
      if (n >= maxLines) break;
      dst[n][0] = 0;
      col = 0;
      x = 0;
    }
    if (col + len < LINE_CHARS) {
      memcpy(dst[n] + col, tok, len);
      col += len;
      dst[n][col] = 0;
    }
    x += w;
    p += len;
  }
  if (col > 0 && n < maxLines) { dst[n][col] = 0; n++; }
  return n;
}

// 截断到 n 个 UTF-8 字符
static void clipUtf8(const char *src, char *dst, size_t dstSize, uint8_t maxChars) {
  uint8_t c = 0;
  size_t i = 0;
  while (src[i] && c < maxChars && i + 1 < dstSize) {
    uint8_t len = utf8Len((uint8_t)src[i]);
    if (i + len >= dstSize) break;
    for (uint8_t k = 0; k < len; k++) dst[i + k] = src[i + k];
    i += len;
    c++;
  }
  dst[i] = 0;
}

static bool startsWith(const char *s, const char *prefix) {
  return strncmp(s, prefix, strlen(prefix)) == 0;
}

// ================================================================
//  蜂鸣器
// ================================================================
void buzzerWrite(bool on) {
#if BUZZ_ACTIVE_LOW
  digitalWrite(PIN_BUZZER, on ? LOW : HIGH);
#else
  digitalWrite(PIN_BUZZER, on ? HIGH : LOW);
#endif
}

void beep(uint8_t times, uint16_t onMs, uint16_t offMs) {
  beepLeft = times; beepOnMs = onMs; beepOffMs = offMs;
  beepState = true; buzzerWrite(true);
  beepNext = millis() + onMs;
}

void beepTask() {
  if (!beepLeft && !beepState) return;
  if (millis() < beepNext) return;
  if (beepState) {
    buzzerWrite(false);
    beepState = false;
    beepLeft--;
    beepNext = millis() + beepOffMs;
  } else if (beepLeft) {
    buzzerWrite(true);
    beepState = true;
    beepNext = millis() + beepOnMs;
  }
}

// ================================================================
//  BLE 通知
// ================================================================
void notifyText(const char *s) {
  if (!txChar || !bleConnected) return;
  txChar->setValue((uint8_t *)s, strlen(s));
  txChar->notify();
  DBG.printf("[ble] -> %s\n", s);
}

void notifyState() {
  const char *n = "idle";
  switch (mode) {
    case M_LISTEN: n = "listen"; break;
    case M_THINK:  n = "think";  break;
    case M_SAY:    n = "say";    break;
    case M_ACT:    n = "act";    break;
    case M_GATE:   n = "gate";   break;
    case M_HUD:    n = "hud";    break;
    case M_LEGACY: n = "legacy"; break;
    default:       n = "idle";   break;
  }
  char buf[32];
  snprintf(buf, sizeof(buf), "S,%s", n);
  notifyText(buf);
}

void setMode(Mode m) {
  if (mode == m) return;
  mode = m;
  modeAt = millis();
  dirty = true;
  DBG.printf("[mode] %d\n", (int)m);
  notifyState();
}

// ================================================================
//  旧协议：合规 / 方案
// ================================================================
bool checkLegal(uint8_t db, uint8_t colorPct) {
  return (db <= DB_LIMIT) && (colorPct < 30);
}

void applyBuild(uint8_t idx) {
  buildIdx  = idx % 3;
  dbValue   = BUILDS[buildIdx].db;
  legalPass = checkLegal(dbValue, BUILDS[buildIdx].colorPct);
  booked    = false;
  legacyPage = 1;
  dirty = true;
}

void notifyLegacy() {
  char buf[48];
  snprintf(buf, sizeof(buf), "S,%u,%u,%u,%u,%u",
           buildIdx + 1, dbValue, legalPass ? 1 : 0, booked ? 1 : 0, legacyPage);
  notifyText(buf);
}

// ================================================================
//  画面
// ================================================================
void titleBar(const char *title) {
  u8g2.setFont(u8g2_font_wqy12_t_gb2312);
  u8g2.setDrawColor(1);
  u8g2.drawBox(0, 0, 128, 13);
  u8g2.setDrawColor(0);
  u8g2.drawUTF8(3, 10, title);
  u8g2.setDrawColor(1);
}

void drawIdle() {
  u8g2.setFont(u8g2_font_wqy16_t_gb2312);
  u8g2.drawUTF8(8, 24, "骑士 HUD");
  u8g2.setFont(u8g2_font_wqy12_t_gb2312);
  u8g2.drawUTF8(8, 40, bleConnected ? "蓝牙 已连接" : "蓝牙 等待连接");
  u8g2.drawUTF8(8, 54, "按住 BOOT 说话");
  u8g2.drawUTF8(8, 63, FW_VERSION);
}

void drawListen() {
  titleBar("语音助手");
  u8g2.setFont(u8g2_font_wqy16_t_gb2312);
  u8g2.drawUTF8(10, 34, "在听…");
  u8g2.setFont(u8g2_font_wqy12_t_gb2312);
  u8g2.drawUTF8(10, 50, "说完松开 BOOT");
  // 音量动画：5 根柱
  uint32_t t = millis() / 120;
  for (uint8_t i = 0; i < 5; i++) {
    uint8_t h = 4 + ((t + i * 2) % 5) * 3;
    u8g2.drawBox(84 + i * 8, 56 - h, 5, h);
  }
}

void drawThink() {
  titleBar("数字大冰");
  u8g2.setFont(u8g2_font_wqy16_t_gb2312);
  u8g2.drawUTF8(10, 36, "正在思考");
  uint8_t dots = (millis() / 350) % 4;
  for (uint8_t i = 0; i < 3; i++)
    if (i < dots) u8g2.drawDisc(96 + i * 10, 50, 2);
}

void drawSay() {
  char title[LINE_CHARS];
  clipUtf8(qText[0] ? qText : "AI 回答", title, sizeof(title), 9);
  titleBar(title);

  u8g2.setFont(u8g2_font_wqy12_t_gb2312);
  // 每屏 4 行，超长每 3s 翻页
  uint8_t pages = (sayLineCount + 3) / 4;
  if (pages == 0) pages = 1;
  if (pages > 1 && millis() - sayScrollAt > 3000) {
    sayScrollAt = millis();
    sayScroll = (sayScroll + 1) % pages;
    dirty = true;
  }
  for (uint8_t i = 0; i < 4; i++) {
    uint8_t idx = sayScroll * 4 + i;
    if (idx >= sayLineCount) break;
    u8g2.drawUTF8(3, 25 + i * 13, sayLines[idx]);
  }
  if (pages > 1) {
    char pg[8];
    snprintf(pg, sizeof(pg), "%u/%u", sayScroll + 1, pages);
    u8g2.drawUTF8(108, 62, pg);
  }
}

void drawAct() {
  titleBar(actTitle[0] ? actTitle : "正在操作");
  u8g2.setFont(u8g2_font_wqy12_t_gb2312);
  for (uint8_t i = 0; i < actTotal && i < 4; i++) {
    uint8_t y = 28 + i * 13;
    if (i + 1 < actCur) {          // 已完成
      u8g2.drawUTF8(3, y, "✓");
      u8g2.drawUTF8(19, y, actSteps[i]);
    } else if (i + 1 == actCur) {  // 当前
      u8g2.drawBox(0, y - 11, 128, 13);
      u8g2.setDrawColor(0);
      u8g2.drawUTF8(3, y, "▶");
      u8g2.drawUTF8(19, y, actSteps[i]);
      u8g2.setDrawColor(1);
    } else {                       // 待执行
      u8g2.drawUTF8(3, y, "○");
      u8g2.drawUTF8(19, y, actSteps[i]);
    }
  }
}

void drawGate() {
  titleBar("需要你确认");
  u8g2.setFont(u8g2_font_wqy12_t_gb2312);

  // 事项：最多两行
  char q[2][LINE_CHARS];
  uint8_t n = wrapLines(gateText, q, 2, 122);
  for (uint8_t i = 0; i < n; i++) u8g2.drawUTF8(3, 26 + i * 13, q[i]);

  // 倒计时条
  uint32_t left = 0;
  if (gateDeadline > millis()) left = (gateDeadline - millis()) / 1000 + 1;
  uint8_t w = 0;
  if (gateSec > 0) w = (left * 124) / gateSec;
  u8g2.drawFrame(2, 44, 124, 8);
  if (w > 1) u8g2.drawBox(3, 45, w > 122 ? 122 : w, 6);

  u8g2.drawUTF8(3, 62, "BOOT 确认 · 长按取消");
}

void drawHudArrowHead(int x, int y, int dx, int dy) {
  u8g2.drawTriangle(x, y, x - 9 * dx + 5 * dy, y - 9 * dy - 5 * dx,
                    x - 9 * dx - 5 * dy, y - 9 * dy + 5 * dx);
}

bool drawHudTurn(const char *turn) {
  int horizontal = 0;
  if (!strcmp(turn, "左转") || !strcmp(turn, "环岛左转")) horizontal = -1;
  if (!strcmp(turn, "右转") || !strcmp(turn, "环岛右转")) horizontal = 1;
  if (horizontal) {
    int tip = horizontal < 0 ? 9 : 47;
    u8g2.drawBox(26, 25, 5, 24);
    u8g2.drawBox(horizontal < 0 ? tip + 5 : 28, 25, 15, 5);
    drawHudArrowHead(tip, 27, horizontal, 0);
    return true;
  }
  if (!strcmp(turn, "直行") || !strcmp(turn, "环岛直行")) {
    u8g2.drawBox(26, 20, 5, 29);
    drawHudArrowHead(28, 14, 0, -1);
    return true;
  }
  if (!strcmp(turn, "掉头") || !strcmp(turn, "环岛掉头")) {
    u8g2.drawBox(13, 19, 5, 30);
    u8g2.drawBox(13, 18, 26, 5);
    u8g2.drawBox(34, 19, 5, 20);
    drawHudArrowHead(36, 45, 0, 1);
    return true;
  }
  int dx = 0;
  int dy = -1;
  if (!strcmp(turn, "向左前")) dx = -1;
  if (!strcmp(turn, "向右前")) dx = 1;
  if (!strcmp(turn, "向左后")) { dx = -1; dy = 1; }
  if (!strcmp(turn, "向右后")) { dx = 1; dy = 1; }
  if (!dx) return false;
  int tipX = 28 + 14 * dx;
  int tipY = 31 + 14 * dy;
  for (int offset = -1; offset <= 1; offset++) {
    u8g2.drawLine(28 - 12 * dx + offset, 31 - 12 * dy, tipX + offset, tipY);
  }
  drawHudArrowHead(tipX, tipY, dx, dy);
  return true;
}

void drawHud() {
  u8g2.setFont(u8g2_font_wqy16_t_gb2312);
  const char *l1 = hud1[0] ? hud1 : "骑士";
  const char *l2 = hud2[0] ? hud2 : "已连接";
  int detailWidth = u8g2.getUTF8Width(l2);
  if (l2[0] >= '0' && l2[0] <= '9' && detailWidth <= 70 && drawHudTurn(l1)) {
    int gutter = 54;
    u8g2.drawVLine(gutter, 10, 44);
    u8g2.drawUTF8(gutter + (128 - gutter - u8g2.getUTF8Width(l1)) / 2, 27, l1);
    u8g2.drawUTF8(gutter + (128 - gutter - detailWidth) / 2, 49, l2);
    return;
  }
  int w1 = u8g2.getUTF8Width(l1);
  int w2 = u8g2.getUTF8Width(l2);
  u8g2.drawUTF8((128 - w1) / 2, 30, l1);
  u8g2.drawFrame(10, 36, 108, 1);
  u8g2.drawUTF8((128 - w2) / 2, 56, l2);
}

// ---- 旧协议画面 ----
void drawLegacy() {
  u8g2.clearBuffer();
  char buf[28];
  switch (legacyPage) {
    case 0:
      u8g2.setFont(u8g2_font_9x15B_tf);
      u8g2.drawStr(6, 22, "ROADLINK");
      u8g2.setFont(u8g2_font_6x12_tf);
      u8g2.drawStr(6, 38, "HUD HARNESS v2");
      u8g2.drawStr(6, 54, bleConnected ? "BLE: connected" : "BLE: waiting...");
      break;
    case 1:
      u8g2.setFont(u8g2_font_6x12_tf);
      u8g2.drawStr(0, 9, "BUILD / s5 TUNING");
      u8g2.drawLine(0, 12, 127, 12);
      u8g2.setFont(u8g2_font_9x15B_tf);
      snprintf(buf, sizeof(buf), "#%u %s", buildIdx + 1, BUILDS[buildIdx].name);
      u8g2.drawStr(0, 28, buf);
      u8g2.setFont(u8g2_font_6x12_tf);
      snprintf(buf, sizeof(buf), "SCORE %u   dB %u", BUILDS[buildIdx].score, dbValue);
      u8g2.drawStr(0, 42, buf);
      snprintf(buf, sizeof(buf), "COST %u", BUILDS[buildIdx].cost);
      u8g2.drawStr(0, 56, buf);
      break;
    case 2:
      u8g2.setFont(u8g2_font_6x12_tf);
      u8g2.drawStr(0, 9, "LEGAL PRE-CHECK");
      u8g2.drawLine(0, 12, 127, 12);
      u8g2.setFont(u8g2_font_9x15B_tf);
      u8g2.drawStr(0, 30, legalPass ? "PASS" : "FAIL");
      u8g2.setFont(u8g2_font_6x12_tf);
      snprintf(buf, sizeof(buf), "dB %u/%u", dbValue, DB_LIMIT);
      u8g2.drawStr(0, 44, buf);
      snprintf(buf, sizeof(buf), "COLOR %u%%", BUILDS[buildIdx].colorPct);
      u8g2.drawStr(0, 56, buf);
      break;
    case 3: {
      u8g2.setFont(u8g2_font_6x12_tf);
      u8g2.drawStr(0, 9, "EXHAUST SOUND");
      u8g2.drawLine(0, 12, 127, 12);
      u8g2.setFont(u8g2_font_helvB24_tf);
      snprintf(buf, sizeof(buf), "%u", dbValue);
      u8g2.drawStr(0, 40, buf);
      u8g2.setFont(u8g2_font_6x12_tf);
      u8g2.drawStr(38, 40, "dB(A)");
      uint8_t w = (dbValue <= 70) ? 0 : (dbValue >= 100 ? 100 : (dbValue - 70) * 100 / 30);
      u8g2.drawFrame(0, 46, 101, 8);
      u8g2.drawBox(1, 47, w, 6);
      u8g2.drawStr(104, 54, "90");
      break;
    }
    case 4:
      u8g2.setFont(u8g2_font_6x12_tf);
      u8g2.drawStr(0, 9, "SHOP BOOKING");
      u8g2.drawLine(0, 12, 127, 12);
      u8g2.setFont(u8g2_font_9x15B_tf);
      if (booked) {
        u8g2.drawStr(0, 30, BUILDS[buildIdx].code);
        u8g2.setFont(u8g2_font_6x12_tf);
        snprintf(buf, sizeof(buf), "%u.%u km  %u CNY",
                 BUILDS[buildIdx].dist100m / 10, BUILDS[buildIdx].dist100m % 10,
                 BUILDS[buildIdx].labor);
        u8g2.drawStr(0, 44, buf);
        snprintf(buf, sizeof(buf), "QUEUE #%02u", queueNo);
        u8g2.drawStr(0, 56, buf);
      } else {
        u8g2.drawStr(0, 34, "NOT BOOKED");
        u8g2.setFont(u8g2_font_6x12_tf);
        u8g2.drawStr(0, 50, "press BOOK in app");
      }
      break;
    case 5:
      u8g2.setFont(u8g2_font_6x12_tf);
      u8g2.drawBox(0, 0, 128, 11);
      u8g2.setDrawColor(0);
      u8g2.drawStr(2, 9, hdrText);
      u8g2.setDrawColor(1);
      for (uint8_t i = 0; i < 4; i++) u8g2.drawStr(2, 23 + i * 12, lineText[i]);
      break;
  }
  u8g2.sendBuffer();
  dirty = false;
}

void drawScreen() {
  // 错误提示：短暂覆盖
  if (errText[0] && millis() < errUntil) {
    u8g2.clearBuffer();
    u8g2.setFont(u8g2_font_wqy12_t_gb2312);
    u8g2.drawUTF8(4, 30, "出错了");
    char tmp[3][LINE_CHARS];
    uint8_t n = wrapLines(errText, tmp, 3, 120);
    for (uint8_t i = 0; i < n && i < 2; i++) u8g2.drawUTF8(4, 44 + i * 13, tmp[i]);
    u8g2.sendBuffer();
    dirty = false;
    return;
  }
  if (mode == M_LEGACY) { drawLegacy(); return; }

  u8g2.clearBuffer();
  switch (mode) {
    case M_LISTEN: drawListen(); break;
    case M_THINK:  drawThink();  break;
    case M_SAY:    drawSay();    break;
    case M_ACT:    drawAct();    break;
    case M_GATE:   drawGate();   break;
    case M_HUD:    drawHud();    break;
    default:       drawIdle();   break;
  }
  u8g2.sendBuffer();
  dirty = false;
}

// ================================================================
//  文本设置（收到指令时处理）
// ================================================================
void setSayText() {
  u8g2.setFont(u8g2_font_wqy12_t_gb2312);
  sayLineCount = wrapLines(aText, sayLines, SAY_MAX_LINES, 122);
  sayScroll = 0;
  sayScrollAt = millis();
  setMode(M_SAY);
  beep(1, 40, 0);
  DBG.printf("[say] %u lines\n", sayLineCount);
  for (uint8_t i = 0; i < sayLineCount; i++) DBG.printf("  | %s\n", sayLines[i]);
}

// ================================================================
//  指令处理
// ================================================================
void handleMessage(const char *cmd);

void handleKeyValue(const char *k, const char *v) {
  if (strcmp(k, "S") == 0) {
    if (strcmp(v, "listen") == 0) { setMode(M_LISTEN); beep(1, 30, 0); }
    else if (strcmp(v, "think") == 0) { setMode(M_THINK); }
    else if (strcmp(v, "say") == 0) { setMode(M_SAY); }
    else if (strcmp(v, "act") == 0) { setMode(M_ACT); }
    else if (strcmp(v, "gate") == 0) { setMode(M_GATE); }
    else if (strcmp(v, "hud") == 0) { setMode(M_HUD); }
    else if (strcmp(v, "idle") == 0) { setMode(M_IDLE); }
    else if (strcmp(v, "legacy") == 0) { setMode(M_LEGACY); }
  } else if (strcmp(k, "Q") == 0) {
    clipUtf8(v, qText, sizeof(qText), 24);
    dirty = true;
  } else if (strcmp(k, "A") == 0) {
    strncpy(aText, v, sizeof(aText) - 1);
    aText[sizeof(aText) - 1] = 0;
    setSayText();
  } else if (strcmp(k, "T") == 0) {
    clipUtf8(v, actTitle, sizeof(actTitle), 12);
    actTotal = 0; actCur = 1;
    setMode(M_ACT);
    dirty = true;
  } else if (strcmp(k, "K") == 0) {
    // K:<i>,<n>,<text>
    int i = atoi(v);
    const char *c1 = strchr(v, ',');
    if (!c1) return;
    int n = atoi(c1 + 1);
    const char *c2 = strchr(c1 + 1, ',');
    if (!c2) return;
    if (i >= 1 && i <= 4) {
      clipUtf8(c2 + 1, actSteps[i - 1], sizeof(actSteps[i - 1]), 9);
      actCur = (uint8_t)i;
      if (n >= 1 && n <= 4) actTotal = (uint8_t)n;
      setMode(M_ACT);
      dirty = true;
      DBG.printf("[act] %d/%d %s\n", i, n, actSteps[i - 1]);
    }
  } else if (strcmp(k, "G") == 0) {
    const char *bar = strchr(v, '|');
    if (bar) {
      size_t n = bar - v;
      if (n >= sizeof(gateText)) n = sizeof(gateText) - 1;
      memcpy(gateText, v, n); gateText[n] = 0;
      clipUtf8(bar + 1, gateYes, sizeof(gateYes), 10);
    } else {
      strncpy(gateText, v, sizeof(gateText) - 1); gateText[sizeof(gateText) - 1] = 0;
    }
    gateDeadline = millis() + (uint32_t)gateSec * 1000;
    setMode(M_GATE);
    beep(2, 40, 40);
    dirty = true;
  } else if (strcmp(k, "D") == 0) {
    const char *bar = strchr(v, '|');
    if (bar) {
      size_t n = bar - v;
      if (n >= sizeof(hud1)) n = sizeof(hud1) - 1;
      memcpy(hud1, v, n); hud1[n] = 0;
      clipUtf8(bar + 1, hud2, sizeof(hud2), 8);
    } else {
      strncpy(hud1, v, sizeof(hud1) - 1); hud1[sizeof(hud1) - 1] = 0;
      hud2[0] = 0;
    }
    setMode(M_HUD);
    dirty = true;
  } else if (strcmp(k, "E") == 0) {
    clipUtf8(v, errText, sizeof(errText), 16);
    errUntil = millis() + 1800;
    if (mode != M_HUD) beep(2, 250, 120);
    dirty = true;
  } else if (strcmp(k, "GA") == 0) {
    resolveGate(v[0] == '1');
  }
}

// 确认结果：按键 / App 远程 / 超时都走这里
void resolveGate(bool ok) {
  if (mode != M_GATE) return;
  gateDeadline = 0;
  notifyText(ok ? "G,1" : "G,0");
  beep(ok ? 1 : 2, ok ? 80 : 50, 50);
  setMode(ok ? M_SAY : M_IDLE);
}

// 无屏验收：把当前屏幕内容回传给 App / 调试脚本
void dumpScreen() {
  char b[96];
  const char *n = "idle";
  switch (mode) {
    case M_LISTEN: n = "listen"; break;
    case M_THINK:  n = "think";  break;
    case M_SAY:    n = "say";    break;
    case M_ACT:    n = "act";    break;
    case M_GATE:   n = "gate";   break;
    case M_HUD:    n = "hud";    break;
    case M_LEGACY: n = "legacy"; break;
  }
  snprintf(b, sizeof(b), "M,%s", n);
  notifyText(b);
  snprintf(b, sizeof(b), "UP,%lu", (unsigned long)millis());
  notifyText(b);
  if (mode == M_SAY) {
    if (qText[0]) { snprintf(b, sizeof(b), "Q,%s", qText); notifyText(b); }
    for (uint8_t i = 0; i < sayLineCount; i++) {
      snprintf(b, sizeof(b), "L,%u,%s", i, sayLines[i]);
      notifyText(b);
    }
  } else if (mode == M_ACT) {
    snprintf(b, sizeof(b), "T,%s", actTitle);
    notifyText(b);
    for (uint8_t i = 0; i < actTotal && i < 4; i++)
      if (actSteps[i][0]) {
        snprintf(b, sizeof(b), "K,%u,%s", i + 1, actSteps[i]);
        notifyText(b);
      }
  } else if (mode == M_GATE) {
    snprintf(b, sizeof(b), "G,%s", gateText);
    notifyText(b);
  } else if (mode == M_HUD) {
    snprintf(b, sizeof(b), "D1,%s", hud1);
    notifyText(b);
    snprintf(b, sizeof(b), "D2,%s", hud2);
    notifyText(b);
  }
}

void handleMessage(const char *cmd) {
  if (!cmd || !*cmd) return;
  DBG.printf("[cmd] %s\n", cmd);

  // 旧协议文本页先处理，否则会被新协议 "X:value" 分支吃掉
  if (cmd[0] == 'H' && cmd[1] == ':') {
    clipUtf8(cmd + 2, hdrText, sizeof(hdrText), 18);
    legacyPage = 5; setMode(M_LEGACY); dirty = true;
    return;
  }
  if (cmd[0] >= '1' && cmd[0] <= '4' && cmd[1] == ':') {
    uint8_t i = cmd[0] - '1';
    clipUtf8(cmd + 2, lineText[i], sizeof(lineText[i]), 18);
    legacyPage = 5; setMode(M_LEGACY); dirty = true;
    return;
  }

  if (strcmp(cmd, "PING") == 0) {
    char b[40];
    snprintf(b, sizeof(b), "PONG,%lu", (unsigned long)millis());
    notifyText(b);
    return;
  }
  if (strcmp(cmd, "DUMP") == 0) {
    dumpScreen();
    return;
  }

  // 新协议：X:value
  const char *colon = strchr(cmd, ':');
  if (colon && colon != cmd && colon[1] != 0 && strlen(cmd) < 250) {
    char key[4] = { 0 };
    size_t klen = colon - cmd;
    if (klen > 3) klen = 3;
    memcpy(key, cmd, klen);
    handleKeyValue(key, colon + 1);
    return;
  }

  // 旧协议
  if (cmd[0] == 'B' && cmd[1] >= '1' && cmd[1] <= '3') {
    applyBuild(cmd[1] - '1');
    beep(1, 60, 0);
    notifyLegacy();
  } else if (startsWith(cmd, "DB=")) {
    int v = atoi(cmd + 3);
    if (v >= 60 && v <= 110) {
      dbValue = v;
      legalPass = checkLegal(dbValue, BUILDS[buildIdx].colorPct);
      if (dbValue > DB_LIMIT) beep(1, 220, 0);
      notifyLegacy();
    }
  } else if (strcmp(cmd, "CHK") == 0) {
    legalPass = checkLegal(dbValue, BUILDS[buildIdx].colorPct);
    legacyPage = 2;
    setMode(M_LEGACY);
    notifyLegacy();
  } else if (strcmp(cmd, "BOOK") == 0) {
    booked = true; legacyPage = 4; queueNo = 1 + random(1, 9);
    setMode(M_LEGACY);
    beep(2, 70, 70);
    notifyLegacy();
  } else if (strcmp(cmd, "NEXT") == 0) {
    if (mode != M_LEGACY) setMode(M_LEGACY);
    legacyPage = (legacyPage + 1) % 6;
    dirty = true;
    notifyLegacy();
  } else if (strcmp(cmd, "BEEP") == 0) {
    beep(1, 120, 0);
  } else if (startsWith(cmd, "H:")) {
    clipUtf8(cmd + 2, hdrText, sizeof(hdrText), 18);
    legacyPage = 5; setMode(M_LEGACY); dirty = true;
  } else if (cmd[1] == ':' && cmd[0] >= '1' && cmd[0] <= '4') {
    uint8_t i = cmd[0] - '1';
    clipUtf8(cmd + 2, lineText[i], sizeof(lineText[i]), 18);
    legacyPage = 5; setMode(M_LEGACY); dirty = true;
  } else if (strcmp(cmd, "SHOW") == 0) {
    legacyPage = 5; setMode(M_LEGACY); dirty = true;
  } else if (strcmp(cmd, "CLR") == 0) {
    for (uint8_t i = 0; i < 4; i++) lineText[i][0] = 0;
    dirty = true;
  }
}

// ================================================================
//  BLE 分片重组
// ================================================================
static char rxBuf[260];
static uint16_t rxLen = 0;

static int hexVal(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

void handleRxValue(const char *v, size_t len) {
  if (!len) return;
  // 分片帧：#<seq2>,<frag>  或  #<seq2>!,<frag>
  if (v[0] == '#' && len >= 5) {
    int s1 = hexVal(v[1]), s2 = hexVal(v[2]);
    if (s1 < 0 || s2 < 0) return;
    int seq = s1 * 16 + s2;
    bool last = (v[3] == '!');
    const char *frag = v + (last ? 5 : 4);
    size_t flen = len - (last ? 5 : 4);
    if (last && v[4] != ',') return;
    if (!last && v[3] != ',') return;

    if (seq == 0) rxLen = 0;                    // 新消息
    if (rxLen + flen >= sizeof(rxBuf) - 1) {
      rxLen = 0;
      DBG.println("[x] overflow");
      return;
    }
    memcpy(rxBuf + rxLen, frag, flen);
    rxLen += flen;
    rxBuf[rxLen] = 0;
    if (last) {
      rxLen = 0;
      handleMessage(rxBuf);
    }
    return;
  }
  // 不分片的短消息
  char tmp[64];
  size_t n = len < sizeof(tmp) - 1 ? len : sizeof(tmp) - 1;
  memcpy(tmp, v, n);
  tmp[n] = 0;
  handleMessage(tmp);
}

class RxCB : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *c) override {
    String v = c->getValue();
    handleRxValue(v.c_str(), v.length());
  }
};

class ServerCB : public BLEServerCallbacks {
  void onConnect(BLEServer *s) override {
    bleConnected = true;
    dirty = true;
    DBG.println("[ble] connected");
    delay(80);
    notifyText("V," FW_VERSION);
    notifyState();
  }
  void onDisconnect(BLEServer *s) override {
    bleConnected = false;
    if (mode == M_HUD) {
      hud1[0] = 0;
      hud2[0] = 0;
      setMode(M_IDLE);
    }
    dirty = true;
    DBG.println("[ble] disconnected");
    s->startAdvertising();
  }
};

// ================================================================
//  按键
// ================================================================
void buttonTask() {
  bool raw = (digitalRead(PIN_BUTTON) == LOW);
  uint32_t now = millis();
  if (raw && !buttonDown) {
    buttonDown = true;
    buttonAt = now;
  } else if (!raw && buttonDown) {
    buttonDown = false;
    uint32_t dur = now - buttonAt;
    if (dur < 30) return;

    if (mode == M_GATE) {
      bool ok = (dur < 800);
      resolveGate(ok);
    } else {
      notifyText(dur < 800 ? "B,short" : "B,long");
      beep(1, 25, 0);
      if (!bleConnected) {                 // 离线时按键翻页做自检
        if (mode == M_IDLE) setMode(M_HUD);
        else if (mode == M_HUD) setMode(M_ACT);
        else setMode(M_IDLE);
      }
    }
  }
}

// ================================================================
//  setup / loop
// ================================================================
void setup() {
  DBG.begin(115200);
  delay(300);
  DBG.println("\n[knight-hud] boot " FW_VERSION);

  pinMode(PIN_BUZZER, OUTPUT);
  buzzerWrite(false);
  pinMode(PIN_BUTTON, INPUT_PULLUP);

  Wire.begin(PIN_SDA, PIN_SCL);
  Wire.setClock(400000);
  u8g2.begin();
  u8g2.setBusClock(400000);

  // 开机自检：反白 + 两声
  u8g2.clearBuffer();
  u8g2.drawBox(0, 0, 128, 64);
  u8g2.setDrawColor(0);
  u8g2.setFont(u8g2_font_wqy16_t_gb2312);
  u8g2.drawUTF8(20, 34, "骑士 HUD");
  u8g2.setFont(u8g2_font_wqy12_t_gb2312);
  u8g2.drawUTF8(20, 52, "AI 语音 v2.0");
  u8g2.sendBuffer();
  u8g2.setDrawColor(1);
  beep(2, 60, 60);
  delay(700);

  BLEDevice::init(DEV_NAME);
  BLEServer *server = BLEDevice::createServer();
  server->setCallbacks(new ServerCB());
  BLEService *svc = server->createService(SERVICE_UUID);

  BLECharacteristic *rx = svc->createCharacteristic(
      RX_UUID, BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
  rx->setCallbacks(new RxCB());

  txChar = svc->createCharacteristic(TX_UUID, BLECharacteristic::PROPERTY_NOTIFY);
  txChar->addDescriptor(new BLE2902());

  svc->start();
  BLEAdvertising *adv = BLEDevice::getAdvertising();
  adv->addServiceUUID(SERVICE_UUID);
  adv->setScanResponse(true);
  adv->setMinPreferred(0x06);
  adv->start();
  DBG.println("[ble] advertising as " DEV_NAME);

  applyBuild(0);
  setMode(M_IDLE);
  mode = M_IDLE;      // setMode 在构造后 dirty
  drawScreen();
  DBG.printf("[sys] heap=%u psram=%u\n", ESP.getFreeHeap(), ESP.getFreePsram());
}

void loop() {
  buttonTask();
  beepTask();

  // 断开后重广播（延迟一点，避免 BLE 栈还在收尾导致广播起不来）
  if (needReadv && millis() > advAt) {
    needReadv = false;
    BLEDevice::getAdvertising()->start();
    Serial.println("[ble] re-advertising");
  }

  // 确认屏超时
  if (mode == M_GATE && gateDeadline && millis() > gateDeadline) {
    resolveGate(false);
  }

  uint32_t interval = 200;
  if (mode == M_LISTEN || mode == M_THINK || mode == M_GATE || mode == M_SAY) interval = 100;

  if (millis() - lastDraw > interval && (dirty || mode != M_HUD)) {
    lastDraw = millis();
    drawScreen();
  }
}
