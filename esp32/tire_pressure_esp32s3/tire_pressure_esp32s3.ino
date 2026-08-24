// Tire Pressure BLE GATT server - ESP32-S3 (one board per tire)
//
// Receives tire pressure commands from the Flutter app and prints them
// to the USB serial output.
//
// IMPORTANT: set TIRE_ID below to which tire THIS board controls:
//   "FL" = front left, "FR" = front right, "RL" = rear left, "RR" = rear right
// Flash one board per tire with a different TIRE_ID. The boards advertise
// as TireESP32-FL, TireESP32-FR, ... so the app can tell them apart.
//
// Setup (Arduino IDE):
//   1. Install the "esp32 by Espressif Systems" board package
//   2. Board: "ESP32S3 Dev Module", USB CDC On Boot: Enabled
//   3. The BLE library used here ships with the esp32 board package
//   4. Flash, then open Serial Monitor at 115200 baud

#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>

#define TIRE_ID "FL"

#define SERVICE_UUID "5f1d16a0-046d-47fd-b49a-d6f1ae118f52"
#define CHAR_UUID "5f1d16a1-046d-47fd-b49a-d6f1ae118f52"

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer *server) override {
    Serial.println("[BLE] App connected");
  }
  void onDisconnect(BLEServer *server) override {
    // Without restarting advertising here, the board stays invisible to
    // scans after any disconnect until it is power-cycled.
    Serial.println("[BLE] App disconnected - advertising again");
    BLEDevice::startAdvertising();
  }
};

class TireWriteCallback : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *pCharacteristic) override {
    // getValue() returns std::string on esp32 core 2.x and String on 3.x;
    // routing through c_str() + String() works for both.
    const String raw = String(pCharacteristic->getValue().c_str());
    if (raw.isEmpty()) {
      Serial.printf("[BLE] %s received EMPTY write\n", TIRE_ID);
      return;
    }
    // Expected payload: comma separated pressures in fixed tire order
    // FL,FR,RL,RR - e.g. "2.4,3.4,1.2,2.5". This board applies the slot
    // matching its own TIRE_ID.
    static const char *kOrder[4] = {"FL", "FR", "RL", "RR"};
    String parts[4];
    int part = 0;
    int start = 0;
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
      Serial.printf("[BLE] %s unexpected message: '%s'\n", TIRE_ID,
                    raw.c_str());
      return;
    }
    const float bar = parts[myIndex].toFloat();
    Serial.printf("[BLE] %s pressure received: %.1f bar\n", TIRE_ID, bar);
  }
};

void setup() {
  Serial.begin(115200);
  delay(500);
  Serial.println();
  Serial.printf("=== Tire %s - Pressure BLE Server ===\n", TIRE_ID);

  const String deviceName = String("TireESP32-") + TIRE_ID;
  BLEDevice::init(deviceName.c_str());

  BLEServer *server = BLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());

  BLEService *service = server->createService(SERVICE_UUID);

  BLECharacteristic *characteristic = service->createCharacteristic(
      CHAR_UUID, BLECharacteristic::PROPERTY_WRITE);
  characteristic->setCallbacks(new TireWriteCallback());

  service->start();

  BLEAdvertising *advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(SERVICE_UUID);
  advertising->setScanResponse(true);
  BLEDevice::startAdvertising();

  Serial.printf("Advertising as '%s' - waiting for the app...\n",
                deviceName.c_str());
}

void loop() {
  delay(1000);
}
