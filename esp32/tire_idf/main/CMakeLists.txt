idf_component_register(
    SRCS "main.c" "ble.c" "pressure_sim.c"
    INCLUDE_DIRS "."
)

# TIRE_ID can be overridden per board from the build command line, e.g.:
#   idf.py -DTIRE_ID=FR build
set(TIRE_ID "FL" CACHE STRING "Which tire this board controls: FL FR RL RR")
add_compile_definitions(TIRE_ID="${TIRE_ID}")
