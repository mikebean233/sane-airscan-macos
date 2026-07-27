#include "airscan.h"
#include <arpa/inet.h>
#include <pthread.h>
#include <string.h>
#include <unistd.h>
#include <assert.h>
#include <sys/time.h>

static int watch_fired = 0, timeout_fired = 0;
static int pipefd[2];
static AvahiSimplePoll *sp;
static AvahiWatch   *w;
static AvahiTimeout *t;

static void on_watch(AvahiWatch *ww, int fd, AvahiWatchEvent ev, void *ud) {
    char buf[16];
    (void)ww; (void)ud;
    assert(ev & AVAHI_WATCH_IN);
    assert(fd == pipefd[0]);
    (void) read(fd, buf, sizeof(buf));
    watch_fired++;
}
static void on_timeout(AvahiTimeout *tt, void *ud) {
    (void)tt; (void)ud; timeout_fired++;
}
static void *quitter(void *a) {
    (void)a; usleep(150000); avahi_simple_poll_quit(sp); return NULL;
}

/* Pump the loop like eloop_thread_func does, until *flag changes or we
 * run out of budget. Spurious wakeups (from watch_new/timeout_new) make
 * a single iterate() insufficient -- this mirrors real usage. */
static int pump(volatile int *flag, int want, int budget_ms) {
    struct timeval t0, now;
    gettimeofday(&t0, NULL);
    for (;;) {
        int rc = avahi_simple_poll_iterate(sp, 20);
        if (rc > 0) return rc;
        if (rc < 0) return rc;
        if (*flag >= want) return 0;
        gettimeofday(&now, NULL);
        if ((now.tv_sec - t0.tv_sec) * 1000 +
            (now.tv_usec - t0.tv_usec) / 1000 > budget_ms) return -99;
    }
}

int main(void) {
    const AvahiPoll *api;
    struct timeval tv;
    pthread_t th;
    int rc;

    assert(avahi_domain_equal("Foo.local", "foo.local."));
    assert(!avahi_domain_equal("a.local", "b.local"));
    assert(avahi_is_valid_domain_name("printer.local"));
    assert(!avahi_is_valid_domain_name("bad..name"));
    assert(avahi_is_valid_fqdn("printer.local"));
    assert(!avahi_is_valid_fqdn("192.168.1.5"));
    printf("domain helpers      OK\n");

    { AvahiAddress a; char buf[AVAHI_ADDRESS_STR_MAX];
      a.proto = AVAHI_PROTO_INET;
      inet_pton(AF_INET, "192.168.1.42", &a.data.ipv4.address);
      assert(avahi_address_snprint(buf, sizeof(buf), &a));
      assert(!strcmp(buf, "192.168.1.42")); }
    printf("address_snprint     OK\n");

    { struct timeval a, b;
      avahi_elapse_time(&a, 0, 0); avahi_elapse_time(&b, 500, 0);
      assert(b.tv_sec > a.tv_sec || (b.tv_sec == a.tv_sec && b.tv_usec > a.tv_usec)); }
    printf("elapse_time         OK\n");

    sp = avahi_simple_poll_new(); assert(sp);
    api = avahi_simple_poll_get(sp);
    assert(pipe(pipefd) == 0);

    w = api->watch_new(api, pipefd[0], AVAHI_WATCH_IN, on_watch, NULL);
    assert(w);
    assert(write(pipefd[1], "x", 1) == 1);
    rc = pump(&watch_fired, 1, 1000);
    assert(rc == 0 && watch_fired == 1);
    printf("watch dispatch      OK\n");

    avahi_elapse_time(&tv, 50, 0);
    t = api->timeout_new(api, &tv, on_timeout, NULL); assert(t);
    rc = pump(&timeout_fired, 1, 2000);
    assert(rc == 0 && timeout_fired == 1);
    printf("timeout dispatch    OK\n");

    rc = pump(&timeout_fired, 2, 200);
    assert(rc == -99 && timeout_fired == 1);
    printf("timeout one-shot    OK (did not re-fire)\n");

    api->timeout_update(t, &tv);
    rc = pump(&timeout_fired, 2, 1000);
    assert(rc == 0 && timeout_fired == 2);
    printf("timeout re-arm      OK\n");

    api->watch_free(w);
    rc = pump(&watch_fired, 99, 100);
    assert(rc == -99 && watch_fired == 1);
    printf("watch_free          OK (no use-after-free)\n");

    pthread_create(&th, NULL, quitter, NULL);
    rc = avahi_simple_poll_iterate(sp, -1);
    while (rc == 0) rc = avahi_simple_poll_iterate(sp, -1);
    pthread_join(th, NULL);
    assert(rc == 1);
    printf("cross-thread quit   OK\n");

    api->timeout_free(t);
    avahi_simple_poll_free(sp);
    close(pipefd[0]); close(pipefd[1]);
    printf("\nALL COMPAT TESTS PASSED\n");
    return 0;
}
