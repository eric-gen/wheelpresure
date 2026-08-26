#include <stdio.h>
#include <stdarg.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"

#include "ble.h"
#include "pressure_sim.h"
#include "tire_pressure.h"

static const char *TAG = "tire";

void app_log(const char *fmt, ...)
{
    char line[128];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof(line), fmt, ap);
    va_end(ap);
    ESP_LOGI(TAG, "%s", line);
}

/* Publishes the measured pressure to BLE every 2 seconds. */
static void pressure_task(void *arg)
{
    for (;;) {
        pressure_sim_tick();
        const float bar = pressure_sim_get();
        ble_publish_pressure(bar);
        app_log("measured %.2f bar (target %.1f)",
                (double)bar, (double)pressure_sim_target());
        vTaskDelay(pdMS_TO_TICKS(2000));
    }
}

void app_main(void)
{
    app_log("=== Tire pressure board (ESP-IDF) ===");

    ble_start();

    if (xTaskCreate(pressure_task, "pressure", 3072, NULL, 5, NULL)
            != pdPASS) {
        app_log("failed to create pressure task");
    }
}
