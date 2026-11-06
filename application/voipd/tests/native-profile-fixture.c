#define _POSIX_C_SOURCE 200809L
#include "modem_profile.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv)
{
	struct qmodem_voip_modem_profile profile;
	FILE *file;
	assert(argc == 4);
	assert(setenv("QMODEM_VOIP_SUPPORTS", argv[2], 1) == 0);
	assert(setenv("QMODEM_VOIP_JOURNAL", argv[3], 1) == 0);
	qmodem_voip_profile_default(&profile);
	assert(qmodem_voip_profile_load(&profile, argv[1], "RM520N-GL", "2c7c:0801") == 0);
	assert(!strcmp(profile.method, "uac"));
	assert(!strcmp(profile.firmware, "RM520NGLAAR03A03M4G_01.201.01.201"));
	assert(!profile.adb_unlock && !profile.voice_server_media_gate && !profile.voice_server_restart);
	assert(!strcmp(profile.selection_state, "not_ready"));
	file = fopen(argv[3], "w");
	assert(file);
	assert(fputs("audio_policy=auto\nmedia_method=serial_pcm\nphase=enabled\nfallback_reason=uac_unavailable\n", file) >= 0);
	assert(fclose(file) == 0);
	qmodem_voip_profile_default(&profile);
	assert(qmodem_voip_profile_load(&profile, argv[1], "RM520N-GL", "2c7c:0801") == 0);
	assert(!strcmp(profile.method, "serial_pcm") && !strcmp(profile.qpcmv, "1,0"));
	assert(!strcmp(profile.audio_policy, "auto") && !strcmp(profile.selection_state, "enabled"));
	assert(!strcmp(profile.fallback_reason, "uac_unavailable"));
	qmodem_voip_profile_default(&profile);
	assert(qmodem_voip_profile_load(&profile, argv[1], "RG500Q-EA", "2c7c:0800") == 0);
	assert(!strcmp(profile.method, "pcm_socket"));
	assert(!strcmp(profile.socket_path, "/var/run/fxsd/pcm.sock"));
	assert(profile.idle_clcc_poll && !profile.adb_unlock && !profile.audio_policy[0]);
	assert(qmodem_voip_profile_load(&profile, argv[1], "unsupported", "ffff:ffff") != 0);
	return 0;
}
