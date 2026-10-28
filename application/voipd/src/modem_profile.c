#define _POSIX_C_SOURCE 200809L

#include "modem_profile.h"

#include <ctype.h>
#include <dirent.h>
#include <json-c/json.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

void qmodem_voip_profile_default(struct qmodem_voip_modem_profile *profile)
{
	memset(profile, 0, sizeof(*profile));
	snprintf(profile->model, sizeof(profile->model), "%s", "RM520N-GL");
	snprintf(profile->usb_id, sizeof(profile->usb_id), "%s", "2c7c:0801");
	snprintf(profile->method, sizeof(profile->method), "%s", "serial_pcm");
	profile->interface_number = 1;
	profile->sample_rate = 8000;
	profile->frame_ms = 20;
	profile->transfer_bytes = 1024;
	profile->transfer_interval_ms = 60;
	snprintf(profile->qaudmod, sizeof(profile->qaudmod), "2");
	snprintf(profile->qpcmv, sizeof(profile->qpcmv), "1,0");
	snprintf(profile->qpcmv_cfg, sizeof(profile->qpcmv_cfg), "8000,20");
	profile->adb_unlock = 0;
	profile->voice_server_media_gate = 0;
	profile->voice_server_restart = 0;
	profile->voice_server_dependency_service[0] = '\0';
	snprintf(profile->voice_server_service, sizeof(profile->voice_server_service),
		"quectel-voice-server.service");
	profile->frame_samples = profile->sample_rate * profile->frame_ms / 1000U;
	profile->frame_bytes = profile->frame_samples * sizeof(int16_t);
}

static void copy_string(char *target, const char *value, size_t size)
{
	if (!value || !value[0])
		return;
	snprintf(target, size, "%s", value);
}

static unsigned json_unsigned(struct json_object *object)
{
	if (!object)
		return 0;
	if (json_object_get_type(object) == json_type_int)
		return (unsigned)json_object_get_int64(object);
	if (json_object_get_type(object) == json_type_boolean)
		return json_object_get_boolean(object) ? 1U : 0U;
	if (json_object_get_type(object) == json_type_string)
		return (unsigned)strtoul(json_object_get_string(object), NULL, 10);
	return 0;
}

static int service_name_valid(const char *service)
{
	const unsigned char *cursor = (const unsigned char *)service;

	if (!service || !isalnum(*cursor))
		return 0;
	for (; *cursor; cursor++)
		if (!isalnum(*cursor) && *cursor != '-' && *cursor != '_' &&
		    *cursor != '.' && *cursor != '@')
			return 0;
	return 1;
}

int qmodem_voip_profile_load(struct qmodem_voip_modem_profile *profile,
			     const char *path, const char *model, const char *usb_id)
{
	struct json_object *root;
	struct json_object *modems;
	struct json_object *property;
	char *text;
	long length;
	FILE *file;
	struct stat status;
	size_t count;

	if (!profile || !path)
		return -1;
	if (stat(path, &status) != 0 || status.st_size <= 0 || status.st_size > 65536)
		return -1;
	length = status.st_size;
	file = fopen(path, "r");
	if (!file)
		return -1;
	text = malloc((size_t)length + 1U);
	if (!text) {
		fclose(file);
		return -1;
	}
	if (fread(text, 1, (size_t)length, file) != (size_t)length) {
		free(text);
		fclose(file);
		return -1;
	}
	fclose(file);
	text[length] = '\0';
	root = json_tokener_parse(text);
	free(text);
	if (!root)
		return -1;
	if (!json_object_object_get_ex(root, "modems", &modems) ||
	    json_object_get_type(modems) != json_type_array) {
		json_object_put(root);
		return -1;
	}
	count = json_object_array_length(modems);
	for (size_t i = 0; i < count; i++) {
		struct json_object *entry = json_object_array_get_idx(modems, i);
		struct json_object *audio;
		struct json_object *entry_model;
		struct json_object *usb_object;
		const char *entry_model_text;
		const char *entry_usb_id_text = NULL;
		if (!entry || json_object_get_type(entry) != json_type_object)
			continue;
		if (!json_object_object_get_ex(entry, "model", &entry_model))
			continue;
		entry_model_text = json_object_get_string(entry_model);
		if (json_object_object_get_ex(entry, "usb_id", &usb_object) &&
		    json_object_get_type(usb_object) == json_type_string)
			entry_usb_id_text = json_object_get_string(usb_object);
		if (model && entry_model_text && strcmp(entry_model_text, model) != 0)
			continue;
		if (entry_usb_id_text && usb_id && strcmp(entry_usb_id_text, usb_id) != 0)
			continue;
		if (!json_object_object_get_ex(entry, "audio", &audio) ||
		    json_object_get_type(audio) != json_type_object) {
			json_object_put(root);
			return -1;
		}
		if (entry_model_text)
			snprintf(profile->model, sizeof(profile->model), "%s", entry_model_text);
		if (entry_usb_id_text)
			snprintf(profile->usb_id, sizeof(profile->usb_id), "%s", entry_usb_id_text);
		snprintf(profile->method, sizeof(profile->method), "%s", "serial_pcm");
		if (json_object_object_get_ex(audio, "method", &property))
			copy_string(profile->method, json_object_get_string(property), sizeof(profile->method));
		if (json_object_object_get_ex(audio, "socket_path", &property))
			copy_string(profile->socket_path, json_object_get_string(property),
				sizeof(profile->socket_path));
		if (json_object_object_get_ex(entry, "idle_clcc_poll", &property))
			profile->idle_clcc_poll = json_unsigned(property) != 0;
		if (json_object_object_get_ex(audio, "interface_number", &property))
			profile->interface_number = (unsigned)json_object_get_int64(property);
		if (json_object_object_get_ex(audio, "sample_rate", &property))
			profile->sample_rate = json_unsigned(property);
		if (json_object_object_get_ex(audio, "frame_ms", &property))
			profile->frame_ms = json_unsigned(property);
		if (json_object_object_get_ex(audio, "transfer_bytes", &property))
			profile->transfer_bytes = json_unsigned(property);
		if (json_object_object_get_ex(audio, "transfer_interval_ms", &property))
			profile->transfer_interval_ms = json_unsigned(property);
		if (json_object_object_get_ex(audio, "qaudmod", &property))
			copy_string(profile->qaudmod, json_object_get_string(property), sizeof(profile->qaudmod));
		if (json_object_object_get_ex(audio, "qpcmv", &property))
			copy_string(profile->qpcmv, json_object_get_string(property), sizeof(profile->qpcmv));
		if (json_object_object_get_ex(audio, "qpcmv_cfg", &property))
			copy_string(profile->qpcmv_cfg, json_object_get_string(property), sizeof(profile->qpcmv_cfg));
		if (json_object_object_get_ex(entry, "adb_unlock", &property))
			profile->adb_unlock = json_unsigned(property) != 0;
		if (json_object_object_get_ex(entry, "voice_server_media_gate", &property))
			profile->voice_server_media_gate = json_unsigned(property) != 0;
		if (json_object_object_get_ex(entry, "voice_server_restart", &property))
			profile->voice_server_restart = json_unsigned(property) != 0;
		if (json_object_object_get_ex(entry, "voice_server_dependency_service", &property))
			copy_string(profile->voice_server_dependency_service,
				json_object_get_string(property),
				sizeof(profile->voice_server_dependency_service));
		if (json_object_object_get_ex(entry, "voice_server_service", &property))
			copy_string(profile->voice_server_service,
				json_object_get_string(property), sizeof(profile->voice_server_service));
		if ((profile->voice_server_media_gate && !profile->adb_unlock) ||
		    (profile->voice_server_dependency_service[0] &&
		     !service_name_valid(profile->voice_server_dependency_service)) ||
		    (profile->voice_server_restart &&
		     !service_name_valid(profile->voice_server_service))) {
			json_object_put(root);
			return -1;
		}
		profile->frame_samples = profile->sample_rate * profile->frame_ms / 1000U;
		profile->frame_bytes = profile->frame_samples * sizeof(int16_t);
		if (strcmp(profile->method, "pcm_socket") == 0) {
			if (profile->socket_path[0] != '/' || profile->sample_rate != 8000U ||
			    profile->frame_ms != 20U) {
				json_object_put(root);
				return -1;
			}
			json_object_put(root);
			return 0;
		}
		if (!profile->interface_number || !profile->sample_rate || !profile->frame_samples ||
		    !profile->frame_bytes || !profile->transfer_bytes || !profile->transfer_interval_ms) {
			json_object_put(root);
			return -1;
		}
		json_object_put(root);
		return 0;
	}
	json_object_put(root);
	return -1;
}

static int journal_slot(char *slot, size_t size)
{
	const char *journal = getenv("QMODEM_VOIP_JOURNAL");
	char text[128];
	FILE *file;
	int found = 0;

	if (!journal)
		journal = "/var/lib/qmodem_voip/modem-safety.journal";
	file = fopen(journal, "r");
	if (!file)
		return -1;
	while (fgets(text, sizeof(text), file)) {
		if (strncmp(text, "slot=", 5) != 0)
			continue;
		text[5 + strcspn(text + 5, "\r\n")] = '\0';
		if (text[5] && strlen(text + 5) < size && strspn(text + 5, "0123456789.-") ==
		    strlen(text + 5)) {
			snprintf(slot, size, "%s", text + 5);
			found = 1;
		}
	}
	fclose(file);
	return found ? 0 : -1;
}

static int sysfs_hex(const char *root, const char *slot, const char *name,
		     char *value, size_t size)
{
	char path[256];
	FILE *file;

	snprintf(path, sizeof(path), "%s/%s/%s", root, slot, name);
	file = fopen(path, "r");
	if (!file)
		return -1;
	if (!fgets(value, (int)size, file)) {
		fclose(file);
		return -1;
	}
	fclose(file);
	value[strcspn(value, "\r\n")] = '\0';
	return value[0] && strspn(value, "0123456789abcdefABCDEF") == strlen(value) ? 0 : -1;
}

static int load_for_slot(struct qmodem_voip_modem_profile *profile, const char *path,
			 const char *sysfs, const char *slot)
{
	char vendor[8];
	char product[8];
	char usb_id[32];

	if (sysfs_hex(sysfs, slot, "idVendor", vendor, sizeof(vendor)) != 0 ||
	    sysfs_hex(sysfs, slot, "idProduct", product, sizeof(product)) != 0)
		return -1;
	snprintf(usb_id, sizeof(usb_id), "%s:%s", vendor, product);
	qmodem_voip_profile_default(profile);
	return qmodem_voip_profile_load(profile, path, NULL, usb_id);
}

void qmodem_voip_profile_select(struct qmodem_voip_modem_profile *profile,
				const char *path)
{
	struct qmodem_voip_modem_profile candidate;
	const char *sysfs = getenv("QMODEM_VOIP_SYSFS_ROOT");
	struct dirent *entry;
	DIR *devices;
	char slot[64];

	if (!profile)
		return;
	if (!sysfs)
		sysfs = "/sys/bus/usb/devices";
	if (journal_slot(slot, sizeof(slot)) == 0 &&
	    load_for_slot(&candidate, path, sysfs, slot) == 0) {
		*profile = candidate;
		return;
	}
	devices = opendir(sysfs);
	while (devices && (entry = readdir(devices))) {
		if (!entry->d_name[0] || strspn(entry->d_name, "0123456789.-") !=
		    strlen(entry->d_name))
			continue;
		if (load_for_slot(&candidate, path, sysfs, entry->d_name) == 0) {
			closedir(devices);
			*profile = candidate;
			return;
		}
	}
	if (devices)
		closedir(devices);
	qmodem_voip_profile_default(&candidate);
	if (qmodem_voip_profile_load(&candidate, path, "RM520N-GL", "2c7c:0801") != 0)
		qmodem_voip_profile_default(&candidate);
	*profile = candidate;
}
