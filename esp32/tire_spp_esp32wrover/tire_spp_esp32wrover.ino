// Tire Pressure Bluetooth CLASSIC (SPP) server - ESP32 / ESP32-WROVER-E
//
// NOTE: Bluetooth Classic only exists on the ORIGINAL ESP32 chip
// (WROOM / WROVER). The ESP32-S3 CANNOT run this sketch!
//
// Receives comma separated pressures from the Flutter app over SPP in
// fixed order FL,FR,RL,RR (e.g. "2.4,3.4,1.2,2.5") and applies the slot
// matching TIRE_ID. Every received set is printed to USB serial.
//
// IMPORTANT: set TIRE_ID below to which tire THIS board controls:
//   "FL", "FR", "RL" or "RR". Flash one board per tire.
//
// Setup (Arduino IDE):
//   1. Install the "esp32 by Espressif Systems" board package
//   2. Board: "ESP32 Wrover Module" (or "ESP32 Dev Module")
//   3. Flash, open Serial Monitor at 115200 baud
//   4. Pair the phone with the board once: Android Settings > Bluetooth >
//      it shows up as TireESP32-FL (etc.) - tap to pair

#include "BluetoothSerial.h"

#define TIRE_ID "FL"

#if !defined(CONFIG_BT_ENABLED) || !defined(CONFIG_BLUEDROID_ENABLED)
#error "Bluetooth Classic is not enabled for this board!"
#endif

BluetoothSerial SerialBT;

static const char *kOrder[4] = {"FL", "FR", "RL", "RR"};

String rxBuffer = "";

void handleLine(const String &line) {
  String parts[4];
  int part = 0;
  int start = 0;
  for (int i = 0; i <= (int)line.length() && part < 4; i++) {
    if (i == (int)line.length() || line[i] == ',') {
      parts[part++] = line.substring(start, i);
      start = i + 1;
    }
  }
  int myIndex = -1;
  for (int i = 0; i < 4; i++) {
    if (strcmp(kOrder[i], TIRE_ID) == 0) myIndex = i;
  }
  if (myIndex < 0 || myIndex >= part) {
    Serial.printf("[SPP] %s unexpected message: '%s'\n", TIRE_ID,
                  line.c_str());
    return;
  }
  const float bar = parts[myIndex].toFloat();
  Serial.printf("[SPP] %s pressure received: %.1f bar\n", TIRE_ID, bar);
  // Tell the app this board applied its slot.
  SerialBT.println(String("ACK:") + TIRE_ID);
}

void setup() {
  Serial.begin(115200);
  delay(500);
  Serial.println();
  Serial.printf("=== Tire %s - Pressure SPP Server ===\n", TIRE_ID);

  const String deviceName = String("TireESP32-") + TIRE_ID;
  SerialBT.begin(deviceName.c_str());

  Serial.printf("Bluetooth name : %s\n", deviceName.c_str());
  Serial.println("Pair the phone with this board, then start the app.");
}

void loop() {
  while (SerialBT.available()) {
    const char c = (char)SerialBT.read();
    if (c == '\n') {
      rxBuffer.trim();
      if (!rxBuffer.isEmpty()) handleLine(rxBuffer);
      rxBuffer = "";
    } else if (c != '\r') {
      rxBuffer += c;
    }
  }
  delay(5);
}
