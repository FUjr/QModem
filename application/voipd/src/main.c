#define _POSIX_C_SOURCE 200809L

#include "daemon_core.h"
#include "media_manager.h"
#include "modem_profile.h"

#include <libubox/uloop.h>
#include <libubus.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>

static void signal_handler(int signal_number)
{
	(void)signal_number;
	qmodem_voip_ctxt.stop = 1;
	uloop_end();
}

int main(int argc, char **argv)
{
	struct qmodem_voip_context *app = &qmodem_voip_ctxt;
	struct sigaction action = { 0 };
	const char *socket_path;
	int result;
	if ((argc != 11 && argc != 15) || strcmp(argv[1], "--media-address") != 0 ||
	    strcmp(argv[3], "--media-cert") != 0 || strcmp(argv[5], "--media-key") != 0 ||
	    strcmp(argv[7], "--media-socket-path") != 0 ||
	    strcmp(argv[9], "--start-enabled") != 0 ||
	    (strcmp(argv[10], "0") != 0 && strcmp(argv[10], "1") != 0))
		return 1;
	socket_path = argv[8];
	if (!socket_path || !socket_path[0] ||
	    strlen(socket_path) >= QMODEM_VOIP_MEDIA_SOCKET_PATH_MAX)
		return 1;
    strcpy(app->object_name,"qmodem_voip");
    strcpy(app->journal_path,"/var/lib/qmodem_voip/modem-safety.journal");
    strcpy(app->history_path,"/var/lib/qmodem_voip/call-history.json");
    if(argc==15) {
        if(strcmp(argv[11],"--group") || strcmp(argv[13],"--modem-id") ||
           !argv[12][0] || strlen(argv[12])>=48 || !argv[14][0] || strlen(argv[14])>=48) return 1;
        if(strspn(argv[12],"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")!=strlen(argv[12]) ||
           strspn(argv[14],"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")!=strlen(argv[14])) return 1;
        strcpy(app->group,argv[12]);strcpy(app->modem_id,argv[14]);
        snprintf(app->object_name,sizeof(app->object_name),"qmodem.voip.%s",app->group);
        snprintf(app->journal_path,sizeof(app->journal_path),"/var/lib/qmodem_voip/%s/modem-safety.journal",app->group);
        snprintf(app->history_path,sizeof(app->history_path),"/var/lib/qmodem_voip/%s/call-history.json",app->group);
        setenv("QMODEM_VOIP_MODEM_ID",app->modem_id,1);
        setenv("QMODEM_VOIP_JOURNAL",app->journal_path,1);
    }
	openlog("qmodem_voip", LOG_PID, LOG_DAEMON);
	qmodem_voip_call_init(&app->call);
	app->start_enabled = strcmp(argv[10], "1") == 0;
	(void)snprintf(app->media_socket_path, sizeof(app->media_socket_path),
		"%s", socket_path);
	if (qmodem_voip_profile_load(&app->media.profile, QMODEM_VOIP_PROFILE_PATH,
		"RM520N-GL", "2c7c:0801") != 0)
		qmodem_voip_profile_default(&app->media.profile);
	syslog(LOG_INFO,
		"profile adb_unlock=%u voice_server_media_gate=%u voice_server_restart=%u",
		app->media.profile.adb_unlock,
		app->media.profile.voice_server_media_gate,
		app->media.profile.voice_server_restart);
	if (app->media.profile.voice_server_restart)
		syslog(LOG_NOTICE, "post-call voice-server recovery enabled");
	app->rtp.fd = -1;
	if (qmodem_voip_browser_configure(&app->browser, &app->media, argv[2], argv[4], argv[6]) != 0)
		return 1;
	if(app->group[0])snprintf(app->browser.socket_path,sizeof(app->browser.socket_path),"/var/run/qmodem_voip/%s/websocket.sock",app->group);
	if (uloop_init() != 0)
		return 1;
	app->ubus = ubus_connect(NULL);
	if (!app->ubus) {
		uloop_done();
		return 1;
	}
	ubus_add_uloop(app->ubus);
	app->object.name = app->object_name;
	app->object.type = &qmodem_voip_object_type;
	app->object.methods = qmodem_voip_object_type.methods;
	app->object.n_methods = qmodem_voip_object_type.n_methods;
	result = ubus_add_object(app->ubus, &app->object);
	if (result != 0) {
		ubus_free(app->ubus);
		uloop_done();
		return 1;
	}
	app->at_events.cb = at_line_event;
	if (ubus_register_event_handler(app->ubus, &app->at_events,
					"qmodem.at.line") != 0) {
		ubus_free(app->ubus);
		uloop_done();
		return 1;
	}
	app->urc_events.cb = at_urc_event;
	if (ubus_register_event_handler(app->ubus, &app->urc_events,
					"qmodem.at.urc") != 0) {
		ubus_free(app->ubus);
		uloop_done();
		return 1;
	}
	app->browser_timer.cb = qmodem_voip_browser_timer;
	app->call_timer.cb = qmodem_voip_call_timer;
	uloop_timeout_set(&app->call_timer, 1000);
	app->activation_timer.cb = qmodem_voip_activation_timer;
	app->restart_timer.cb = qmodem_voip_restart_timer;
	if (qmodem_voip_media_manager_init(app) != 0) {
		ubus_free(app->ubus);
		uloop_done();
		return 1;
	}
	if (app->start_enabled)
		uloop_timeout_set(&app->activation_timer, 0);
	action.sa_handler = signal_handler;
	sigemptyset(&action.sa_mask);
	sigaction(SIGTERM, &action, NULL);
	sigaction(SIGINT, &action, NULL);
	uloop_run();
	uloop_done();
	qmodem_voip_media_manager_shutdown(app);
	ubus_free(app->ubus);
	closelog();
	return app->stop ? 0 : 1;
}
