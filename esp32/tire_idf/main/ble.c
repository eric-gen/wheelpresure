/*
 * BLE GATT server (NimBLE, ESP-IDF 5.4).
 *
 * Service  5f1d16a0-... (same as the Arduino firmware, apps are unchanged)
 *   a1 char: READ|WRITE - app writes "2.4,3.4,1.2,2.5", board stores
 *            its own slot's target and rewrites the value to "ACK:<ID>:<bar>"
 *   a2 char: READ|NOTIFY - live measured pressure "%.2f" (from pressure_sim)
 *
 * Stability features: advertising restarts after every disconnect,
 * MTU negotiation is left to NimBLE defaults, notify only goes out when
 * a client actually subscribed, all writes are bounds-checked.
 */
#include <string.h>
#include <stdio.h>

#include "ble_hs.h"
#include "ble_svc_gap.h"
#include "ble_svc_gatt.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"

#include "pressure_sim.h"
#include "tire_pressure.h"

static const ble_uuid128_t svc_uuid =
    BLE_UUID128_INIT(TIRE_SERVICE_UUID);
static const ble_uuid128_t cmd_chr_uuid =
    BLE_UUID128_INIT(TIRE_CMD_CHAR_UUID);
static const ble_uuid128_t pressure_chr_uuid =
    BLE_UUID128_INIT(TIRE_PRESSURE_CHAR_UUID);

static uint16_t cmd_attr_handle;
static uint16_t pressure_attr_handle;

/* Connected phone(s); this board serves one connection at a time. */
static uint16_t conn_handle = BLE_HS_CONN_HANDLE_NONE;
static bool subscribed;

static void advertise(void);

/* ------------------------------------------------------------------ */
/* a1 command characteristic                                          */
/* ------------------------------------------------------------------ */

static int cmd_access(uint16_t conn_handle, uint16_t attr_handle,
                      struct ble_gatt_access_ctx *ctx)
{
    static char buf[64]; /* single-threaded host task: safe */

    if (ctx->op == BLE_GATT_ACCESS_OP_READ_CHR) {
        /* The value doubles as the ACK for the last command. */
        return os_mbuf_append(ctx->om, buf, strlen(buf));
    }
    if (ctx->op != BLE_GATT_ACCESS_OP_WRITE_CHR) {
        return BLE_ATT_ERR_UNLIKELY;
    }

    uint16_t len = OS_MBUF_PKTLEN(ctx->om);
    if (len == 0 || len >= sizeof(buf)) {
        app_log("cmd write rejected (len=%u)", len);
        return BLE_ATT_ERR_INSUFFICIENT_RES;
    }
    ble_hs_mbuf_to_flat(ctx->om, buf, sizeof(buf) - 1, &len);
    buf[len] = '\0';

    /* CSV order FL,FR,RL,RR - pick the slot matching TIRE_ID. */
    const char *order[4] = { "FL", "FR", "RL", "RR" };
    int my_index = -1;
    for (int i = 0; i < 4; i++) {
        if (strcmp(order[i], TIRE_ID) == 0) my_index = i;
    }

    char *save = NULL;
    char *slot = NULL;
    char *tmp = strdup(buf);
    if (tmp) {
        int part = 0;
        for (char *tok = strtok_r(tmp, ",", &save);
             tok && part < 4;
             tok = strtok_r(NULL, ",", &save), part++) {
            if (part == my_index) slot = tok;
        }
    }

    float bar = NAN;
    if (my_index >= 0 && slot) bar = strtof(slot, NULL);
    free(tmp);

    if (isnan(bar) || bar < PRESSURE_MIN || bar > PRESSURE_MAX) {
        app_log("cmd rejected: '%s' (no valid slot %d)", buf, my_index);
        strcpy(buf, "ERR");
        return 0; /* still readable so the app can see the refusal */
    }

    pressure_sim_set_target(bar);
    snprintf(buf, sizeof(buf), "ACK:%s:%.1f", TIRE_ID, (double)bar);
    app_log("target %.1f bar accepted (%s)", (double)bar, buf);
    return 0;
}

/* ------------------------------------------------------------------ */
/* a2 live pressure characteristic                                    */
/* ------------------------------------------------------------------ */

static int pressure_access(uint16_t conn_handle, uint16_t attr_handle,
                           struct ble_gatt_access_ctx *ctx)
{
    if (ctx->op != BLE_GATT_ACCESS_OP_READ_CHR) {
        return BLE_ATT_ERR_UNLIKELY;
    }
    char val[8];
    const int n = snprintf(val, sizeof(val), "%.2f",
                           (double)pressure_sim_get());
    return os_mbuf_append(ctx->om, val, n);
}

/* Called by the periodic task in main.c. */
void ble_publish_pressure(float bar)
{
    char val[8];
    const int n = snprintf(val, sizeof(val), "%.2f", (double)bar);

    /* Store the value so plain reads also see it... */
    ble_gatts_set_attr_value(pressure_attr_handle, n, (const uint8_t *)val);
    /* ...then push it to the subscribed phone (NimBLE drops this silently
     * when nobody subscribed or the connection is gone). */
    if (conn_handle != BLE_HS_CONN_HANDLE_NONE && subscribed) {
        struct os_mbuf *om = ble_hs_mbuf_from_flat(val, n);
        if (om) {
            ble_gatts_notify_custom(conn_handle, pressure_attr_handle, om);
        }
    }
}

/* ------------------------------------------------------------------ */
/* GATT service definition                                            */
/* ------------------------------------------------------------------ */

static const struct ble_gatt_svc_def gatt_svcs[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &svc_uuid.u,
        .characteristics = (struct ble_gatt_chr_def[]) {
            { .uuid = &cmd_chr_uuid.u,
              .access_cb = cmd_access,
              .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_WRITE,
              .val_handle = &cmd_attr_handle },
            { .uuid = &pressure_chr_uuid.u,
              .access_cb = pressure_access,
              .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_NOTIFY,
              .val_handle = &pressure_attr_handle },
            { 0 },
        },
    },
    { 0 },
};

/* ------------------------------------------------------------------ */
/* GAP events + advertising                                           */
/* ------------------------------------------------------------------ */

static void advertise(void)
{
    struct ble_gap_adv_params advp = { 0 };
    advp.conn_mode = BLE_GAP_CONN_MODE_UND;
    advp.disc_mode = BLE_GAP_DISC_MODE_GEN;
    advp.itms_min  = 160; /* 100 ms  */
    advp.itmx_max  = 240; /* 150 ms  */

    int rc = ble_gap_adv_start(BLE_OWN_ADDR_PUBLIC, NULL,
                               BLE_HS_FOREVER, &advp, gap_event_cb, NULL);
    if (rc != 0) {
        app_log("adv start failed rc=%d", rc);
    }
}

int gap_event_cb(struct ble_gap_event *event, void *arg)
{
    switch (event->type) {
    case BLE_GAP_EVENT_CONNECT:
        if (event->connect.status == 0) {
            conn_handle = event->connect.conn_handle;
            subscribed = false;
            app_log("phone connected");
        } else {
            app_log("connect failed rc=%d - advertising again",
                    event->connect.status);
            advertise();
        }
        return 0;

    case BLE_GAP_EVENT_DISCONNECT:
        app_log("phone disconnected (reason=%d) - advertising again",
                event->disconnect.reason);
        conn_handle = BLE_HS_CONN_HANDLE_NONE;
        subscribed = false;
        advertise();
        return 0;

    case BLE_GAP_EVENT_SUBSCRIBE:
        subscribed =
            event->subscribe.cur_notify != 0 ||
            event->subscribe.cur_indicate != 0;
        app_log("subscribe: %d", subscribed);
        return 0;

    case BLE_GAP_EVENT_MTU:
        app_log("mtu=%d", event->mtu.value);
        return 0;
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* Host stack bring-up                                                */
/* ------------------------------------------------------------------ */

static void on_sync(void)
{
    int rc = ble_hs_util_ensure_addr(0);
    assert(rc == 0);

    uint8_t addr_val[6] = { 0 };
    rc = ble_hs_id_copy_addr(BLE_ADDR_PUBLIC, addr_val, NULL);
    app_log("addr %02x:%02x:%02x:%02x:%02x:%02x",
            addr_val[5], addr_val[4], addr_val[3],
            addr_val[2], addr_val[1], addr_val[0]);

    advertise();
}

static void on_reset(int reason)
{
    app_log("host reset, reason=%d - restarting", reason);
}

static void host_task(void *param)
{
    nimble_port_run();               /* returns only on termination */
    nimble_port_freertos_deinit();
}

void ble_start(const char *device_name)
{
    int rc = nimble_port_init();
    if (rc != ESP_OK) {
        app_log("nimble init failed rc=%d", rc);
        return;
    }

    ble_hs_cfg.sync_cb  = on_sync;
    ble_hs_cfg.reset_cb = on_reset;
    ble_store_config_init();

    ble_svc_gap_device_name_set(device_name);

    ble_svc_gap_init();
    ble_svc_gatt_init();

    rc = ble_gatts_count_cfg(gatt_svcs);
    assert(rc == 0);
    rc = ble_gatts_add_svcs(gatt_svcs);
    assert(rc == 0);

    /* The a1 value starts as an empty ACK. */
    pressure_sim_init();

    nimble_port_freertos_init(host_task);
}
