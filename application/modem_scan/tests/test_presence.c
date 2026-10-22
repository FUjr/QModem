#define main qmodem_daemon_main
#include "../src/modem_scand.c"
#undef main
#include <assert.h>

static void expect_state(const char *expected)
{
    char state[32];
    assert(!uci_get("qmodem.1_1.state", state, sizeof(state)));
    assert(!strcmp(state, expected));
}

int main(void)
{
    char control[512], original[512], other[512], fail_commit[512];
    const char *sys = getenv("QMODEM_SYSFS"), *fail = getenv("QMODEM_TEST_FAIL");
    struct event *old, *event;
    pthread_mutex_init(&g.queue_lock, NULL);
    pthread_cond_init(&g.queue_cond, NULL);
    g.log_level = LOG_L_ERR;
    g.add_retry_max = 2;
    g.add_retry_delay = 0;
    snprintf(control, sizeof(control), "%s/dev/char/1:3", sys);
    snprintf(original, sizeof(original), "%s/devices/usb/1-1/control", sys);
    snprintf(other, sizeof(other), "%s/devices/usb/1-10/control", sys);
    snprintf(fail_commit, sizeof(fail_commit), "%s.commit", fail);

    assert(enqueue_event(EV_CHECK, "../escape", NULL, 0) == -1);
    revoke_ready("1_1");
    assert(!check_modem("1_1"));
    assert(!ready_command("check", "1_1"));
    expect_state("enabled");
    /* A running scan loses authority immediately on remove arrival. */
    assert(!enqueue_event(EV_ADD, "1-1", "usb", 0));
    old = dequeue_event(); current_event = old;
    assert(!enqueue_event(EV_DISABLE, "1-1", NULL, 0));
    assert(ready_command("check", "1_1"));
    assert(!event_current());
    assert(!confirm_section("1_1"));
    assert(ready_command("check", "1_1"));
    finish_event_key(old); free(old); current_event = NULL;
    event = dequeue_event(); current_event = event;
    process_event(event);
    expect_state("disabled");
    finish_event_key(event); free(event); current_event = NULL;

    /* Manual mode validates existing settings and never discovers a new section. */
    assert(!add_modem("1-1", "usb"));
    expect_state("enabled");
    assert(!ready_command("check", "1_1"));
    assert(!add_modem("2-2", "usb"));
    char value[32];
    assert(uci_get("qmodem.2_2", value, sizeof(value)));
    assert(!unlink(control)); assert(!symlink(other, control));
    assert(check_modem("1_1"));
    expect_state("disabled");
    assert(ready_command("check", "1_1"));

    /* Even if the modem returns, failed host cleanup must not enable it. */
    assert(!unlink(control)); assert(!symlink(original, control));
    int fd = open(fail, O_CREAT | O_WRONLY, 0600); assert(fd >= 0); close(fd);
    assert(check_modem("1_1"));
    expect_state("disabled");
    assert(ready_command("check", "1_1"));
    assert(!enqueue_event(EV_DISABLE, "1-1", NULL, 0));
    event = dequeue_event(); current_event = event; process_event(event);
    assert(g.queue_len == 1); /* failed disable queued a bounded retry */
    finish_event_key(event); free(event); current_event = NULL;
    unlink(fail);
    event = dequeue_event(); current_event = event; process_event(event);
    finish_event_key(event); free(event); current_event = NULL;
    assert(g.queue_len == 0);

    /* Failed UCI commit revokes proof, even if the set was visible in memory. */
    fd = open(fail_commit, O_CREAT | O_WRONLY, 0600); assert(fd >= 0); close(fd);
    assert(confirm_section("1_1"));
    assert(ready_command("check", "1_1"));
    unlink(fail_commit);
    assert(!check_modem("1_1"));
    expect_state("enabled");

    /* Full scans reconcile old sections even with automatic discovery blocked. */
    assert(!unlink(control)); assert(!symlink(other, control));
    assert(!enqueue_event(EV_SCAN, "usb", NULL, 0));
    event = dequeue_event(); current_event = event; process_event(event);
    finish_event_key(event); free(event); current_event = NULL;
    while (g.queue_len) {
        event = dequeue_event(); current_event = event; process_event(event);
        finish_event_key(event); free(event); current_event = NULL;
    }
    expect_state("disabled");
    assert(ready_command("check", "1_1"));
    /* Fixed configurations are checked but their user settings are not probed. */
    assert(!unlink(control)); assert(!symlink(original, control));
    assert(!uci_set("qmodem.main.block_auto_probe", "0"));
    assert(!uci_set("qmodem.1_1.fixed_device", "1"));
    assert(!add_modem("1-1", "usb"));
    expect_state("enabled");
    assert(!ready_command("check", "1_1"));
    assert(!uci_set("qmodem.1_1.fixed_device", "0"));
    assert(!unlink(control)); assert(!symlink(other, control));
    /* Automatic mode can rediscover ports within the same configured slot. */
    assert(!uci_set("qmodem.main.block_auto_probe", "0"));
    assert(!enqueue_event(EV_CHECK, "1_1", NULL, 0));
    event = dequeue_event(); current_event = event; process_event(event);
    finish_event_key(event); free(event); current_event = NULL;
    assert(g.queue_len == 1);
    event = dequeue_event();
    assert(event->type == EV_ADD && !strcmp(event->slot, "1-1"));
    finish_event_key(event); free(event);
    puts("PASS: scanner confirmation, stale events, manual mode, disable retries, commit failure, stale-section reconciliation");
    return 0;
}
