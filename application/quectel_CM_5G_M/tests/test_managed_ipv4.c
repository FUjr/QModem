/* Actual CM start/stop code, with side effects intercepted. No DUT required. */
#include <assert.h>
#include <setjmp.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/types.h>
static jmp_buf published;
static int commands, dns_updates, events;
static const char *expected_action;
static pid_t fake_fork(void) { return 0; }
static int fake_system(const char *cmd) { (void)cmd; commands++; return 0; }
static int fake_execl(const char *path, const char *arg0, ...) {
    va_list args;
    va_start(args,arg0);
    assert(!strcmp(path,"/usr/libexec/qmodem-ipv4-event"));
    assert(!strcmp(va_arg(args,const char *),expected_action));
    assert(!strcmp(va_arg(args,const char *),"testmodem0"));
    assert(!strcmp(va_arg(args,const char *),"10.1.2.3"));
    assert(!strcmp(va_arg(args,const char *),"255.255.255.0"));
    assert(!strcmp(va_arg(args,const char *),"10.1.2.1"));
    assert(!strcmp(va_arg(args,const char *),"223.5.5.5"));
    assert(!strcmp(va_arg(args,const char *),"119.29.29.29"));
    va_end(args); events++; longjmp(published,1);
}
#define fork fake_fork
#define system fake_system
#define execl fake_execl
#include "../src/udhcpc.c"
#undef fork
#undef system
#undef execl
FILE *logfilefp;
const struct request_ops qmi_request_ops={0}, mbim_request_ops={0}, atc_request_ops={0};
const char *get_time(void) { return "test"; }
void no_trunc_strncpy(char *d,const char *s,size_t n) { snprintf(d,n,"%s",s); }
int ql_get_netcard_carrier_state(const char *d) { (void)d; return 1; }
int ql_bridge_mode_detect(PROFILE_T *p) { (void)p; return 0; }
void update_resolv_conf(int f,const char *d,const char *a,const char *b) { (void)f;(void)d;(void)a;(void)b;dns_updates++; }
int main(void) {
    PROFILE_T p={0};
    strcpy(p.usbnet_adapter,"testmodem0"); p.managed_ipv4=1; p.enable_ipv4=1; p.no_dhcp=1;
    p.ipv4.Address=0x0a010203; p.ipv4.SubnetMask=0xffffff00; p.ipv4.Gateway=0x0a010201;
    p.ipv4.DnsPrimary=0xdf050505; p.ipv4.DnsSecondary=0x771d1d1d;
    expected_action="up";
    if (!setjmp(published)) udhcpc_start(&p);
    expected_action="down";
    if (!setjmp(published)) udhcpc_stop(&p);
    assert(events==2 && commands==0 && dns_updates==0);
    /* Opt-out retains the existing CM-owned address/DNS implementation. */
    p.managed_ipv4=0;
    udhcpc_start(&p);
    assert(commands>0 && dns_updates==1);
    puts("PASS: managed CM publishes normalized up/down without IPv4 commands or DNS writes; legacy remains functional");
    return 0;
}
