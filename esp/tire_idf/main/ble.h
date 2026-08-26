#pragma once

#include <stdbool.h>

void ble_start(void);
void ble_publish_pressure(float bar);

/* true while a phone holds the connection */
bool ble_is_connected(void);
