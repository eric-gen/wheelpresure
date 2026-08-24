// Tire Pressure WiFi server - ESP32-S3 (one board per tire)
//
// The board creates its own WiFi hotspot (no router / internet needed).
// The phone joins the hotspot, the app talks TCP to the board, and every
// received pressure command is printed to USB serial.
//
// IMPORTANT: set TIRE_ID below to which tire THIS board controls:
//   "FL", "FR", "RL" or "RR". Flash one board per tire.
//
// Setup (Arduino IDE):
//   1. Install the "esp32 by Espressif Systems" board package
//   2. Board: "ESP32S3 Dev Module", USB CDC On Boot: Enabled
//   3. Flash, open Serial Monitor at 115200 baud
//   4. On the phone: Settings > WiFi > join the network shown on serial
//      (default password: tirepressure)

#include <WiFi.h>

#define TIRE_ID "FL"

static const char *apPassword = "tirepressure";

WiFiServer server(3333);
WiFiClient client;

void setup() {
  Serial.begin(115200);
  delay(500);

  const String ssid = String("TireESP32-") + TIRE_ID;
  WiFi.softAP(ssid.c_str(), apPassword);

  server.begin();

  Serial.printf("=== Tire %s - Pressure WiFi Server ===\n", TIRE_ID);
  Serial.printf("SSID : %s\n", ssid.c_str());
  Serial.printf("PASS : %s\n", apPassword);
  Serial.printf("TCP  : %s:3333\n", WiFi.softAPIP().toString().c_str());
}

void loop() {
  if (!client || !client.connected()) {
    WiFiClient incoming = server.available();
    if (incoming) {
      client.stop();
      client = incoming;
      Serial.println("[WIFI] App connected");
      client.print(String("ID:") + TIRE_ID + "\n");
    }
    return;
  }

  while (client.available()) {
    String line = client.readStringUntil('\n');
    line.trim();
    if (line.length() == 0) continue;
    if (line == "?") {
      client.print(String("ID:") + TIRE_ID + "\n");
      continue;
    }
    Serial.printf("[WIFI] %s pressure received: %s bar\n", TIRE_ID,
                  line.c_str());
  }
}
