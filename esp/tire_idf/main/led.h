#pragma once

/* Onboard status LED (WS2812 RGB on GPIO48 of the DevKitC).
 *
 * Behavior:
 *   flickering (white) : a phone is connecting / pairing
 *   steady dim green   : paired and serving a connection
 *   off                : idle, waiting to be discovered
 */

#define LED_GPIO 48

void led_start(void);
void led_pairing(bool active);
