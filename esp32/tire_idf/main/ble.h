#pragma once

#include <stdbool.h>

struct ble_gap_event;
int gap_event_cb(struct ble_gap_event *event, void *arg);

void ble_start(const char *device_name);
void ble_publish_pressure(float bar);

/* true while a phone holds the connection */
bool ble_is_connected(void);
