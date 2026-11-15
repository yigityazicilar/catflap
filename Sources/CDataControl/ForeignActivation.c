#include "CDataControl.h"

void cf_wf_activation_state(cf_wf_activation *window, int active) {
    window->changed |= active && !window->active;
    window->active = active;
}

int cf_wf_activation_done(cf_wf_activation *window) {
    /* done is idle-batched: a rising edge may already have fallen again. */
    int activated = window->changed;
    window->changed = 0;
    return activated;
}
