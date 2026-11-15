#pragma once
#include <stddef.h>
#include <stdint.h>

typedef struct cf_dc cf_dc;
enum cf_dc_transport { CF_DC_NONE = 0, CF_DC_EXT = 1, CF_DC_WLR = 2 };
/* Pure choice after discovery; arguments mean advertised availability, not arrival order. */
enum cf_dc_transport cf_dc_choose_transport(int ext_available, int wlr_available);
/* A connection has one serial owner. Only cancel may run concurrently. */
cf_dc *cf_dc_create(void);
/* 1: ready, 0: unsupported, -1: connection failed. */
int cf_dc_open(cf_dc *connection);
/* 1: selection (possibly empty), 0: cancelled, -1: disconnected. */
int cf_dc_next(cf_dc *connection);
size_t cf_dc_type_count(cf_dc *connection);
const char *cf_dc_type(cf_dc *connection, size_t index);
/* Reads at most capacity bytes, including one overflow sentinel byte. */
int cf_dc_receive(cf_dc *connection, const char *mime, uint8_t *bytes, size_t capacity, size_t *length);
void cf_dc_cancel(cf_dc *connection);
void cf_dc_destroy(cf_dc *connection);

/* Pure per-window edge accumulation between foreign-toplevel done events. */
typedef struct cf_wf_activation { int active, changed; } cf_wf_activation;
void cf_wf_activation_state(cf_wf_activation *window, int active);
int cf_wf_activation_done(cf_wf_activation *window);

/* Independent, serial-owner registry/foreign-toplevel monitor. */
typedef struct cf_wf cf_wf;
cf_wf *cf_wf_open(void);
int cf_wf_is_kde(cf_wf *connection);
int cf_wf_available(cf_wf *connection);
/* Nonblocking: 1 new activation, 0 none, -1 connection lost. */
int cf_wf_poll(cf_wf *connection);
void cf_wf_destroy(cf_wf *connection);
