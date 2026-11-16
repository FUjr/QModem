/* Compile like test_scheduler.c. The fixture supplies UCI and PCIe sysfs. */
#include <dirent.h>
#include <sys/stat.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>

static const char *fixture_path(const char *path, char *buf, size_t len)
{
    if (strncmp(path, "/sys/", 5)) return path;
    snprintf(buf, len, "%s%s", getenv("QMODEM_TEST_ROOT"), path);
    return buf;
}
static int fixture_stat(const char *path, struct stat *st)
{
    char buf[1024];
    return stat(fixture_path(path, buf, sizeof(buf)), st);
}
static DIR *fixture_opendir(const char *path)
{
    char buf[1024];
    return opendir(fixture_path(path, buf, sizeof(buf)));
}
static ssize_t fixture_readlink(const char *path, char *out, size_t len)
{
    char buf[1024];
    return readlink(fixture_path(path, buf, sizeof(buf)), out, len);
}
#define stat(path, st) fixture_stat(path, st)
#define opendir(path) fixture_opendir(path)
#define readlink(path, out, len) fixture_readlink(path, out, len)
#define main qmodem_daemon_main
#include "../src/modem_scand.c"
#undef main

int main(void)
{
    char owner[128] = "", path[1024];
    pthread_mutex_init(&g.queue_lock, NULL);
    pthread_cond_init(&g.queue_cond, NULL);
    g.log_level = LOG_L_ERR;
    /* A configured association alone must not steal a USB-only modem. */
    assert(!associated_pcie_slot("2-1", owner, sizeof(owner)));
    assert(enqueue_event(EV_ADD, "2-1", "usb", 0) == 0);
    assert(!strcmp(g.queue_head->slot, "2-1"));
    assert(!strcmp(g.queue_head->slot_type, "usb"));
    /* An enumerated PCIe device without a data interface is insufficient. */
    snprintf(path, sizeof(path), "%s/sys/bus/pci/devices/0000:01:00.0", getenv("QMODEM_TEST_ROOT"));
    assert(mkdir(path, 0700) == 0);
    assert(!associated_pcie_slot("2-1", owner, sizeof(owner)));
    /* Once a PCIe WWAN data endpoint appears, preserve control/data merging. */
    strncat(path, "/wwan", sizeof(path) - strlen(path) - 1);
    assert(mkdir(path, 0700) == 0);
    strncat(path, "/wwan0", sizeof(path) - strlen(path) - 1);
    assert(mkdir(path, 0700) == 0);
    assert(associated_pcie_slot("2-1", owner, sizeof(owner)) == 1);
    assert(!strcmp(owner, "0000:01:00.0"));
    assert(enqueue_event(EV_ADD, "2-1", "usb", 0) == 0);
    assert(!strcmp(g.queue_tail->slot, "0000:01:00.0"));
    assert(!strcmp(g.queue_tail->slot_type, "pcie"));
    assert(!associated_pcie_slot("2-2", owner, sizeof(owner)));
    puts("PASS: USB-only shared slot, PCIe without data, PCIe control/data association, unrelated USB");
    return 0;
}
