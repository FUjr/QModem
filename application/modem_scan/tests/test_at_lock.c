/* Run through the real scanner and shell helpers; replace only the host shell/path. */
static int host_execl(const char *, const char *, ...);
#define execl host_execl
#define main qmodem_daemon_main
#include "../src/modem_scand.c"
#undef main
#undef execl
#include <assert.h>

static int host_execl(const char *path, const char *arg, ...)
{
    char *args[16];
    char script[2048];
    va_list ap;
    int n = 0;
    (void)path;
    args[n++] = (char *)arg;
    va_start(ap, arg);
    while (n < 15 && (args[n] = va_arg(ap, char *)) != NULL)
        n++;
    va_end(ap);
    args[n] = NULL;
    const char *prefix = ". /usr/share/qmodem/modem_util.sh; ";
    assert(!strncmp(args[2], prefix, strlen(prefix)));
    snprintf(script, sizeof(script), ". \"$QMODEM_HOME/modem_util.sh\"; %s", args[2] + strlen(prefix));
    args[2] = script;
    execv("/bin/bash", args);
    return -1;
}

int main(void)
{
    char port[128], other[160], reply[1024], lockfile[256];
    const char *marker = getenv("QMODEM_TEST_AT_MARKER");
    assert(marker);
    snprintf(port, sizeof(port), "/dev/qmodem_test_%ld", (long)getpid());
    snprintf(other, sizeof(other), "%s_other", port);
    snprintf(lockfile, sizeof(lockfile), "/var/lock/qmodem-at-_dev_qmodem_test_%ld.lock", (long)getpid());
    g.at_timeout_lock = 4;
    g.log_level = LOG_L_WARN;
    setenv("QMODEM_TEST_AT_MODE", "ok", 1);
    assert(at_command(port, "ATI", 1, 1, reply, sizeof(reply)) == 0);
    assert(strstr(reply, "OK"));

    /* Waiting longer than the I/O budget still leaves the full response budget. */
    int held = lock_at_port(port, 1);
    assert(held >= 0);
    pid_t holder = fork();
    assert(holder >= 0);
    if (!holder) { usleep(1500000); close(held); _exit(0); }
    close(held);
    setenv("QMODEM_TEST_AT_MODE", "slow-ok", 1);
    long long start = monotonic_ms();
    assert(at_command(port, "ATI", 1, 1, reply, sizeof(reply)) == 0);
    assert(monotonic_ms() - start >= 1500);
    waitpid(holder, NULL, 0);

    /* Queue expiry never invokes the AT tool, and a different port remains usable. */
    held = lock_at_port(port, 1);
    assert(held >= 0);
    g.at_timeout_lock = 1;
    unlink(marker);
    assert(at_command(port, "ATI", 1, 1, reply, sizeof(reply)) == -3);
    assert(access(marker, F_OK) != 0);
    setenv("QMODEM_TEST_AT_MODE", "ok", 1);
    assert(at_command(other, "ATI", 1, 1, reply, sizeof(reply)) == 0);
    close(held);

    setenv("QMODEM_TEST_AT_MODE", "hang", 1);
    assert(at_command(port, "ATI", 1, 1, reply, sizeof(reply)) == -2);
    setenv("QMODEM_TEST_AT_MODE", "ok", 1);
    assert(at_command(port, "ATI", 0, 1, reply, sizeof(reply)) == 0);
    assert(strstr(reply, "OK"));
    unlink(lockfile);
    /* The suffix is part of the port key, before .lock. */
    snprintf(lockfile, sizeof(lockfile), "/var/lock/qmodem-at-_dev_qmodem_test_%ld_other.lock", (long)getpid());
    unlink(lockfile);
    puts("PASS: independent queue/I/O budgets, inherited flock, timeout cleanup and independent ports");
    return 0;
}
