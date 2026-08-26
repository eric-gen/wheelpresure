#pragma once

/*
 * Pressure source abstraction.
 *
 * Today this is a simulation (dummy values). When a real pressure sensor
 * arrives, implement its driver behind these three functions - nothing in
 * the BLE layer or the phone apps needs to change.
 */

void  pressure_sim_init(void);
float pressure_sim_get(void);            /* current measured bar        */
float pressure_sim_target(void);         /* what the app asked for      */
void  pressure_sim_set_target(float bar);/* what the app asked for      */
void  pressure_sim_tick(void);           /* advance the simulation one step */
