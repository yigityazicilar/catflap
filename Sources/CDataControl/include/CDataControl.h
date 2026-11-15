#pragma once
#include <stddef.h>
#include <stdint.h>

typedef struct cf_dc cf_dc;
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
