idf_component_register(
    SRCS "main.c" "ble.c" "pressure_sim.c" "led.c"
    INCLUDE_DIRS "."
    PRIV_REQUIRES bt nvs_flash esp_driver_rmt esp_driver_gpio led_strip
)

# TIRE_ID is OPTIONAL now: boards ship unassigned and get their tire via
# the app ("ASSIGN:FR" over BLE, stored in NVS). Only set TIRE_ID if you
# want a factory-default assignment baked into the image.
set(TIRE_ID "" CACHE STRING "Optional factory tire: FL FR RL RR")
add_compile_definitions(TIRE_ID="${TIRE_ID}")
