/*
 * BLE GATT server (NimBLE, ESP-IDF 5.4).
 *
 * Service  5f1d16a0-... (same as the Arduino firmware, apps are unchanged)
 *   a1 char: READ|WRITE - app writes "2.4,3.4,1.2,2.5" or "ASSIGN:FR";
 *            the value becomes the reply (ACK:<ID>:<bar>, ACK:<ID>:0,
 *            UNASSIGNED or ERR)
 *   a2 char: READ|NOTIFY - live measured pressure "%.2f" from pressure_sim
 */
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>

#include "host/ble_hs.h"
#include "host/ble_gatt.h"
#include "host/util/util.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "nvs_flash.h"
#include "nvs.h"

#include "pressure_sim.h"
#include "tire_pressure.h"
#include "ble.h"

char g_tire[8] = { 0 };

static const ble_uuid128_t svc_uuid =
    BLE_UUID128_INIT(TIRE_SERVICE_UUID_BYTES);
static const ble_uuid128_t cmd_chr_uuid =
    BLE_UUID128_INIT(TIRE_CMD_CHAR_UUID_BYTES);
static const ble_uuid128_t pressure_chr_uuid =
    BLE_UUID128_INIT(TIRE_PRESSURE_CHAR_UUID_BYTES);

static uint16_t cmd_attr_handle;
static uint16_t pressure_attr_handle;

/* Connected phone; this board serves one connection at a time. */
static uint16_t conn_handle = BLE_HS_CONN_HANDLE_NONE;
static bool subscribed;

static int gap_event_cb(struct ble_gap_event *event, void *arg);

/* ------------------------------------------------------------------ */
/* a1 command characteristic                                          */
/* ------------------------------------------------------------------ */

static int cmd_access(uint16_t conn_handle, uint16_t attr_handle,
                      struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    static char buf[64]; /* everything runs on one host task: safe */

    if (ctxt->op == BLE_GATT_ACCESS_OP_READ_CHR) {
        /* The value doubles as the reply to the last command. */
        return os_mbuf_append(ctxt->om, buf, strlen(buf));
    }
    if (ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR) {
        return BLE_ATT_ERR_UNLIKELY;
    }

    uint16_t len = OS_MBUF_PKTLEN(ctxt->om);
    if (len == 0 || len >= sizeof(buf)) {
        app_log("cmd write rejected (len=%u)", len);
        return BLE_ATT_ERR_INSUFFICIENT_RES;
    }
    ble_hs_mbuf_to_flat(ctxt->om, buf, sizeof(buf) - 1, &len);
    buf[len] = '\0';

    /* Assignment command: "ASSIGN:FR" - persisted in NVS so the board
     * remembers its tire across reboots and power loss. */
    if (strncmp(buf, "ASSIGN:", 7) == 0) {
        const char *tire = buf + 7;
        if ((strcmp(tire, "FL") == 0 || strcmp(tire, "FR") == 0 ||
             strcmp(tire, "RL") == 0 || strcmp(tire, "RR") == 0)) {
            nvs_handle_t h;
            if (nvs_open("tirecfg", NVS_READWRITE, &h) == ESP_OK) {
                nvs_set_str(h, "tire", tire);
                nvs_commit(h);
                nvs_close(h);
            }
            strlcpy(g_tire, tire, sizeof(g_tire));
            snprintf(buf, sizeof(buf), "ACK:%s:0", g_tire);
            app_log("assigned to tire %s (stored in NVS)", g_tire);
        } else {
            app_log("bad assignment: '%s'", buf);
            strcpy(buf, "ERR");
        }
        return 0;
    }

    /* CSV order FL,FR,RL,RR - apply the slot matching our assigned tire. */
    const char *order[4] = { "FL", "FR", "RL", "RR" };
    int my_index = -1;
    for (int i = 0; i < 4; i++) {
        if (strcmp(order[i], g_tire) == 0) my_index = i;
    }
    if (my_index < 0) {
        app_log("no tire assigned yet - ignoring '%s'", buf);
        strcpy(buf, "UNASSIGNED");
        return 0;
    }

    char *save = NULL;
    char *slot = NULL;
    char *tmp = strdup(buf);
    if (tmp) {
        int part = 0;
        for (char *tok = strtok_r(tmp, ",", &save);
             tok != NULL && part < 4;
             tok = strtok_r(NULL, ",", &save), part++) {
            if (part == my_index) slot = tok;
        }
    }

    float bar = NAN;
    if (slot != NULL) bar = strtof(slot, NULL);
    free(tmp);

    if (isnan(bar) || bar < PRESSURE_MIN || bar > PRESSURE_MAX) {
        app_log("cmd rejected: '%s' (slot %d invalid)", buf, my_index);
        strcpy(buf, "ERR");
        return 0;
    }

    pressure_sim_set_target(bar);
    snprintf(buf, sizeof(buf), "ACK:%s:%.1f", g_tire, (double)bar);
    app_log("target %.1f bar accepted (%s)", (double)bar, buf);
    return 0;
}

/* ------------------------------------------------------------------ */
/* a2 live pressure characteristic                                    */
/* ------------------------------------------------------------------ */

static int pressure_access(uint16_t conn_handle, uint16_t attr_handle,
                           struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    if (ctxt->op != BLE_GATT_ACCESS_OP_READ_CHR) {
        return BLE_ATT_ERR_UNLIKELY;
    }
    char val[8];
    const int n = snprintf(val, sizeof(val), "%.2f",
                           (double)pressure_sim_get());
    return os_mbuf_append(ctxt->om, val, n);
}

/* Called by the periodic task in main.c every ~2 s. */
void ble_publish_pressure(float bar)
{
    if (conn_handle == BLE_HS_CONN_HANDLE_NONE || !subscribed) {
        return; /* nobody listening: NimBLE would drop it anyway */
    }
    char val[8];
    const int n = snprintf(val, sizeof(val), "%.2f", (double)bar);
    struct os_mbuf *om = ble_hs_mbuf_from_flat(val, n);
    if (om == NULL) return;
    ble_gatts_notify_custom(conn_handle, pressure_attr_handle, om);
}

bool ble_is_connected(void)
{
    return conn_handle != BLE_HS_CONN_HANDLE_NONE;
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
    /* Build the advertisement explicitly:
     *   ADV      = flags + complete device name (always visible to scanners)
     *   SCAN_RSP = our 128-bit service UUID (doesn't fit in the ADV packet)
     */
    struct ble_hs_adv_fields fields;
    memset(&fields, 0, sizeof(fields));

    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;

    const char *name = ble_svc_gap_device_name();
    size_t name_len = strlen(name);
    if (name_len <= BLE_HS_ADV_MAX_FIELD_SZ) {
        fields.name             = (const uint8_t *)name;
        fields.name_len         = name_len;
        fields.name_is_complete = 1;
    } else {
        fields.name             = (const uint8_t *)name;
        fields.name_len         = BLE_HS_ADV_MAX_FIELD_SZ;
        fields.name_is_complete = 0;
    }

    int rc = ble_gap_adv_set_fields(&fields);
    if (rc != 0) {
        app_log("adv set fields failed rc=%d", rc);
        return;
    }

    struct ble_hs_adv_fields rsp;
    memset(&rsp, 0, sizeof(rsp));
    rsp.uuids128             = (const ble_uuid128_t *)&svc_uuid.u;
    rsp.num_uuids128         = 1;
    rsp.uuids128_is_complete = 1;
    rc = ble_gap_adv_rsp_set_fields(&rsp);
    if (rc != 0) {
        app_log("adv rsp set failed rc=%d", rc);
        return;
    }

    struct ble_gap_adv_params advp = { 0 };
    advp.conn_mode = BLE_GAP_CONN_MODE_UND;
    advp.disc_mode = BLE_GAP_DISC_MODE_GEN;
    advp.itvl_min  = 160; /* 100 ms */
    advp.itvl_max  = 240; /* 150 ms */

    rc = ble_gap_adv_start(BLE_OWN_ADDR_PUBLIC, NULL,
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

    /* Name: assigned tire when known, otherwise last 4 MAC hex digits so
     * every board is uniquely identifiable in the devices screen. */
    char name[32];
    if (g_tire[0]) {
        snprintf(name, sizeof(name), "TireESP32-%s", g_tire);
    } else {
        snprintf(name, sizeof(name), "TireESP32-%02X%02X",
                 addr_val[1], addr_val[0]);
    }
    ble_svc_gap_device_name_set(name);
    app_log("advertising as '%s'", name);

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

void ble_start(void)
{
    int rc = nimble_port_init();
    if (rc != ESP_OK) {
        app_log("nimble init failed rc=%d", rc);
        return;
    }

    /* Load the assigned tire (if any) before the stack syncs: it decides
     * both the advertised name and which CSV slot we apply. */
    esp_err_t nrc = nvs_flash_init();
    if (nrc == ESP_ERR_NVS_NO_FREE_PAGES ||
        nrc == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        nvs_flash_erase();
        nvs_flash_init();
    }
    nvs_handle_t h;
    if (nvs_open("tirecfg", NVS_READONLY, &h) == ESP_OK) {
        size_t len = sizeof(g_tire);
        nvs_get_str(h, "tire", g_tire, &len);
        nvs_close(h);
    }
    app_log("tire assignment: '%s'", g_tire[0] ? g_tire : "(none)");

    ble_hs_cfg.sync_cb  = on_sync;
    ble_hs_cfg.reset_cb = on_reset;
    /* No ble_store_config_init(): we don't use bonding, just plain
     * connections - one less moving part. */

    ble_svc_gap_init();
    ble_svc_gatt_init();

    rc = ble_gatts_count_cfg(gatt_svcs);
    assert(rc == 0);
    rc = ble_gatts_add_svcs(gatt_svcs);
    assert(rc == 0);

    pressure_sim_init();

    nimble_port_freertos_init(host_task);
}
