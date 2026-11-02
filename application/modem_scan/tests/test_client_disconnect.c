#define main scanner_main
#include "../src/modem_scand.c"
#undef main
#include <assert.h>

int main(void)
{
    int pair[2], status;
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0);
    assert(write(pair[1], "status\n", 7) == 7);
    close(pair[1]);
    pid_t child = fork();
    assert(child >= 0);
    if (!child) {
        int next[2];
        char reply[128];
        pthread_mutex_init(&g.queue_lock, NULL);
        setup_signals();
        handle_client(pair[0]); /* Peer closed before the reply: EPIPE. */
        close(pair[0]);
        assert(socketpair(AF_UNIX, SOCK_STREAM, 0, next) == 0);
        assert(write(next[1], "status\n", 7) == 7);
        handle_client(next[0]);
        ssize_t n = read(next[1], reply, sizeof(reply) - 1);
        assert(n > 0);
        reply[n] = '\0';
        assert(strstr(reply, "\"queue\":0"));
        _exit(0);
    }
    close(pair[0]);
    assert(waitpid(child, &status, 0) == child);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    puts("PASS: early client disconnect does not kill scanner or prevent later requests");
    return 0;
}
