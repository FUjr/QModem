#ifndef QMODEM_VOIP_MODEM_PROFILE_H
#define QMODEM_VOIP_MODEM_PROFILE_H

#include <stdint.h>

#define QMODEM_VOIP_PROFILE_PATH "/usr/share/qmodem_voip/modem_profiles.json"

struct qmodem_voip_modem_profile {
	char model[64];
	char usb_id[32];
	unsigned interface_number;
	unsigned sample_rate;
	unsigned frame_ms;
	unsigned transfer_bytes;
	unsigned transfer_interval_ms;
	char qaudmod[16];
	char qpcmv[32];
	char qpcmv_cfg[32];
	unsigned adb_unlock;
	unsigned voice_server_media_gate;
	unsigned voice_server_restart;
	char voice_server_dependency_service[96];
	char voice_server_service[96];
	unsigned frame_samples;
	unsigned frame_bytes;
};

void qmodem_voip_profile_default(struct qmodem_voip_modem_profile *profile);
int qmodem_voip_profile_load(struct qmodem_voip_modem_profile *profile,
			     const char *path, const char *model, const char *usb_id);

#endif
