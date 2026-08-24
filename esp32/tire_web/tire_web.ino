// Tire Pressure WebSocket endpoint - ESP32-S3 or WROVER (one board per tire)
//
// NO website is hosted here. The control UI is a single HTML file that lives
// on the phone (see phone_app/tire.html) and connects to this board over a
// WebSocket on port 81 while joined to the board's WiFi hotspot.
//
// Protocol (same payload contract as all variants):
//   phone -> board : "2.4,3.4,1.2,2.5"   (CSV, fixed order FL,FR,RL,RR)
//   board -> phone : "ID:FL" on connect, then "ACK:FL" after applying
//
// IMPORTANT: set TIRE_ID below to which tire THIS board controls.
//
// Setup (Arduino IDE):
//   1. Install library "WebSockets" by Markus Sattler (Library Manager)
//   2. Board: "ESP32S3 Dev Module" (USB CDC On Boot: Enabled)
//             or "ESP32 Wrover Module"
//   3. Flash, open Serial Monitor at 115200 baud

#include <WiFi.h>
#include <WebSocketsServer.h>

#define TIRE_ID "FL"

static const char *apPassword = "tirepressure";

WebSocketsServer ws(81);

static const char *kOrder[4] = {"FL", "FR", "RL", "RR"};

void handlePayload(const String &raw) {
  String parts[4];
  int part = 0, start = 0;
  for (int i = 0; i <= (int)raw.length() && part < 4; i++) {
    if (i == (int)raw.length() || raw[i] == ',') {
      parts[part++] = raw.substring(start, i);
      start = i + 1;
    }
  }
  int myIndex = -1;
  for (int i = 0; i < 4; i++) {
    if (strcmp(kOrder[i], TIRE_ID) == 0) myIndex = i;
  }
  if (myIndex < 0 || myIndex >= part) {
    Serial.printf("[WS] %s unexpected message: '%s'\n", TIRE_ID,
                  raw.c_str());
    return;
  }
  const float bar = parts[myIndex].toFloat();
  Serial.printf("[WS] %s pressure received: %.1f bar\n", TIRE_ID, bar);
  // ACK back so the phone can show its red warning when silent.
  ws.broadcastTXT(String("ACK:") + TIRE_ID);
}

void onWsEvent(uint8_t num, WStype_t type, uint8_t *payload, size_t len) {
  switch (type) {
    case WStype_CONNECTED:
      Serial.printf("[WS] Phone connected (slot %u)\n", num);
      ws.sendTXT(num, String("ID:") + TIRE_ID);
      break;
    case WStype_TEXT:
      handlePayload(String((const char *)payload));
      break;
    case WStype_DISCONNECTED:
      Serial.printf("[WS] Phone disconnected (slot %u)\n", num);
      break;
    default:
      break;
  }
}

void setup() {
  Serial.begin(115200);
  delay(500);
  Serial.println();
  Serial.printf("=== Tire %s - Pressure WebSocket Server ===\n", TIRE_ID);

  const String ssid = String("TireESP32-") + TIRE_ID;
  WiFi.softAP(ssid.c_str(), apPassword);

  ws.begin();
  ws.onEvent(onWsEvent);

  Serial.printf("SSID : %s\nPASS : %s\n", ssid.c_str(), apPassword);
  Serial.printf("WS   : ws://%s:81/\n", WiFi.softAPIP().toString().c_str());
}

void loop() { ws.loop(); delay(2); }
