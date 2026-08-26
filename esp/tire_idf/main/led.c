#include "led.h"

#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

#include "driver/gpio.h"
#include "led_strip.h"

#include "ble.h"

static led_strip_handle_t s_strip;
static volatile bool s_pairing;

void led_pairing(bool active)
{
    s_pairing = active;
}

static void set_rgb(uint8_t r, uint8_t g, uint8_t b)
{
    if (s_strip == NULL) return;
    led_strip_set_pixel(s_strip, 0, r, g, b);
    led_strip_refresh(s_strip);
}

/* Flickers while pairing; otherwise shows connection state.
 * The classic red LED (GPIO2) blinks during pairing on every variant. */
static void led_task(void *arg)
{
    bool on = false;

    gpio_reset_pin(LED_GPIO_RED);
    gpio_set_direction(LED_GPIO_RED, GPIO_MODE_OUTPUT);

    for (;;) {
        if (s_pairing) {
            on = !on;
            if (on) set_rgb(60, 60, 60);   /* white blink */
            else    set_rgb(0, 0, 0);      /* off blink   */
            gpio_set_level(LED_GPIO_RED, on ? 1 : 0); /* red blink */
            vTaskDelay(pdMS_TO_TICKS(120));
        } else {
            gpio_set_level(LED_GPIO_RED, 0);
            if (ble_is_connected()) {
                set_rgb(0, 25, 10);        /* steady dim green: paired */
            } else {
                set_rgb(0, 0, 0);          /* idle */
            }
            vTaskDelay(pdMS_TO_TICKS(500));
        }
    }
}

void led_start(void)
{
    /* red LED works even without the RGB strip */
    gpio_reset_pin(LED_GPIO_RED);
    gpio_set_direction(LED_GPIO_RED, GPIO_MODE_OUTPUT);
    gpio_set_level(LED_GPIO_RED, 0);

    led_strip_config_t strip_cfg = {
        .strip_gpio_num = LED_GPIO,
        .max_leds = 1,
    };
    led_strip_rmt_config_t rmt_cfg = { 0 };

    if (led_strip_new_rmt_device(&strip_cfg, &rmt_cfg, &s_strip) != ESP_OK) {
        s_strip = NULL; /* no RGB on this board variant - red LED still works */
    } else {
        led_strip_clear(s_strip);
    }

    if (xTaskCreate(led_task, "led", 2048, NULL, 4, NULL) != pdPASS) {
        s_strip = NULL;
    }
}
