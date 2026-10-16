/* Compile against json-c; no modem or real UCI configuration is required. */
#define main qmodem_daemon_main
#include "../src/modem_scand.c"
#undef main
#include <assert.h>
int main(void)
{
    struct event *old, *other, *disable, *replacement;
    pthread_mutex_init(&g.queue_lock, NULL);
    pthread_cond_init(&g.queue_cond, NULL);
    g.log_level=LOG_L_ERR;
    assert(enqueue_event(EV_ADD,"2-1","usb",0)==0);
    old=dequeue_event(); current_event=old;
    assert(enqueue_event(EV_DISABLE,"2-1",NULL,0)==0);
    assert(!event_current());
    /* A stale worker cannot schedule a retry after removal. */
    assert(enqueue_event_ex(EV_ADD,"2-1","usb",0,1)==1);
    assert(enqueue_event(EV_ADD,"2-2","usb",0)==0);
    other=dequeue_event(); assert(!strcmp(other->slot,"2-2"));
    finish_event_key(other); free(other);
    finish_event_key(old); free(old); current_event=NULL;
    disable=dequeue_event(); assert(disable->type==EV_DISABLE);
    assert(enqueue_event(EV_ADD,"2-1","usb",0)==0);
    current_event=disable; assert(!event_current());
    finish_event_key(disable); free(disable); current_event=NULL;
    replacement=dequeue_event(); assert(replacement->type==EV_ADD);
    current_event=replacement; assert(event_current());
    finish_event_key(replacement); free(replacement); current_event=NULL;
    assert(g.queue_len==0 && g.active_jobs==0 && active_resources.len==0);
    puts("PASS: slot serialization, independent slots, stale retry cancellation, latest add wins");
    return 0;
}
