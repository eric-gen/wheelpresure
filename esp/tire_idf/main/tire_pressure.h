#pragma once
#include <stdint.h>
#include <stdbool.h>

/* Shared constants between BLE layer and pressure source. */

#define TIRE_SERVICE_UUID \
    { 0x52, 0x8f, 0x11, 0xae, 0xf1, 0xd6, 0x9a, 0xb4, \
      0xfd, 0x47, 0x6d, 0x04, 0xa0, 0x16, 0x1d, 0x5f }
      /* 5f1d16a0-046d-47fd-b49a-d6f1ae118f52 (little-endian) */

#define TIRE_CMD_CHAR_UUID \
    { 0x52, 0x8f, 0x11, 0xae, 0xf1, 0xd6, 0x9a, 0xb4, \
      0xfd, 0x47, 0x6d, 0x04, 0xa1, 0x16, 0x1d, 0x5f }
      /* ...-a1-... : app writes CSV targets / "ASSIGN:<TIRE>", board
         answers via the same value ("ACK:<ID>:<bar>" or "ACK:<ID>:0") */

#define TIRE_PRESSURE_CHAR_UUID \
    { 0x52, 0x8f, 0x11, 0xae, 0xf1, 0xd6, 0x9a, 0xb4, \
      0xfd, 0x47, 0x6d, 0x04, 0xa2, 0x16, 0x1d, 0x5f }
      /* ...-a2-... : live measured pressure, READ | NOTIFY, "%.2f" */

#define PRESSURE_MIN 1.0f
#define PRESSURE_MAX 4.0f

/* Assigned tire ("FL".."RR"); empty string until the app assigns one.
 * Loaded from NVS at boot; changed by the ASSIGN command over BLE. */
extern char g_tire[8];

void app_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
