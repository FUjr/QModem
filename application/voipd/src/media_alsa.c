#define _POSIX_C_SOURCE 200809L

#include "media.h"
#include "media_pcm_socket.h"
#include "media_serial.h"

#include <dirent.h>
#include <errno.h>
#include <alloca.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>

#define QMODEM_VOIP_PI 3.14159265358979323846

#ifndef QMODEM_VOIP_HOST_TEST
#include <alsa/asoundlib.h>
#endif

static int line(const char *path, char *value, size_t size)
{
	FILE *file = fopen(path, "r");
	if (!file || !fgets(value, (int)size, file)) {
		if (file) fclose(file);
		return -1;
	}
	fclose(file);
	value[strcspn(value, "\r\n")] = '\0';
	return 0;
}

static int identity(const char *root, const char *slot)
{
	char path[256], value[128];
	(void)snprintf(path, sizeof(path), "%s/%s/idVendor", root, slot);
	if (line(path, value, sizeof(value)) || strcmp(value, "2c7c")) return -1;
	(void)snprintf(path, sizeof(path), "%s/%s/idProduct", root, slot);
	if (line(path, value, sizeof(value)) || strcmp(value, "0801")) return -1;
	(void)snprintf(path, sizeof(path), "%s/%s/product", root, slot);
	return line(path, value, sizeof(value)) || strcmp(value, QMODEM_VOIP_MEDIA_PRODUCT) ? -1 : 0;
}

static int card_for_slot(const char *root, const char *slot, unsigned *card)
{
	char path[512];
	DIR *interfaces;
	struct dirent *entry;
	(void)snprintf(path, sizeof(path), "%s/%s", root, slot);
	interfaces = opendir(path);
	if (!interfaces) return -1;
	while ((entry = readdir(interfaces))) {
		DIR *sound;
		struct dirent *sound_entry;
		if (entry->d_name[0] == '.') continue;
		(void)snprintf(path, sizeof(path), "%s/%s/%s/sound", root, slot, entry->d_name);
		sound = opendir(path);
		if (!sound) continue;
		while ((sound_entry = readdir(sound))) {
			unsigned parsed;
			if (sscanf(sound_entry->d_name, "card%u", &parsed) == 1) {
				closedir(sound); closedir(interfaces); *card = parsed; return 0;
			}
		}
		closedir(sound);
	}
	closedir(interfaces);
	return -1;
}

static int has_duplex(const char *proc, unsigned card, unsigned *device)
{
	char path[256], text[1024];
	FILE *file;
	(void)snprintf(path, sizeof(path), "%s/pcm", proc);
	file = fopen(path, "r");
	if (!file) return -1;
	while (fgets(text, sizeof(text), file)) {
		unsigned parsed_card, parsed_device;
		if (sscanf(text, "%u-%u:", &parsed_card, &parsed_device) == 2 && parsed_card == card &&
			strstr(text, "playback") && strstr(text, "capture")) {
			*device = parsed_device;
			fclose(file); return 0;
		}
	}
	fclose(file);
	return -1;
}

int qmodem_voip_media_discover(const char *sysfs_root, const char *proc_root,
				const char *recorded_slot, struct qmodem_voip_media_device *device)
{
	DIR *directory;
	struct dirent *entry;
	unsigned card = 0, pcm = 0;
	char found[64] = { 0 };
	if (!sysfs_root || !proc_root || !recorded_slot || !device || strlen(recorded_slot) >= sizeof(found))
		return -1;
	directory = opendir(sysfs_root);
	if (!directory) return -1;
	while ((entry = readdir(directory)))
		if (!strcmp(entry->d_name, recorded_slot) && identity(sysfs_root, entry->d_name) == 0)
			memcpy(found, entry->d_name, strlen(entry->d_name) + 1U);
	closedir(directory);
	if (!found[0]) return -1;
	if (card_for_slot(sysfs_root, found, &card) || has_duplex(proc_root, card, &pcm))
		return -2; /* Exact modem present, but no duplex UAC endpoint. */
	memset(device, 0, sizeof(*device));
	(void)snprintf(device->slot, sizeof(device->slot), "%s", found);
	(void)snprintf(device->pcm_name, sizeof(device->pcm_name), "hw:%u,%u", card, pcm);
	device->card = card; device->device = pcm; device->full_duplex = 1;
	return 0;
}

#ifndef QMODEM_VOIP_HOST_TEST
static int configure(snd_pcm_t *pcm, snd_pcm_stream_t stream, unsigned *rate)
{
	snd_pcm_hw_params_t *params;
	snd_pcm_sw_params_t *software;
	snd_pcm_uframes_t period, buffer;
	int rc;
	unsigned channels = 1;
	int direction = 0;
	snd_pcm_hw_params_alloca(&params);
	snd_pcm_sw_params_alloca(&software);
	if ((rc = snd_pcm_hw_params_any(pcm, params)) < 0 ||
		(rc = snd_pcm_hw_params_set_access(pcm, params, SND_PCM_ACCESS_RW_INTERLEAVED)) < 0 ||
		(rc = snd_pcm_hw_params_set_format(pcm, params, SND_PCM_FORMAT_S16_LE)) < 0 ||
		(rc = snd_pcm_hw_params_set_channels_near(pcm, params, &channels)) < 0 || channels != 1 ||
		(rc = snd_pcm_hw_params_set_rate_near(pcm, params, rate, &direction)) < 0)
		return rc < 0 ? rc : -EINVAL;
	/* ALSA's default can buffer seconds and delay playback until it fills. */
	period = *rate / 50U;
	buffer = period * 4U;
	if ((rc = snd_pcm_hw_params_set_period_size_near(pcm, params, &period, &direction)) < 0 ||
		(rc = snd_pcm_hw_params_set_buffer_size_near(pcm, params, &buffer)) < 0 ||
		(rc = snd_pcm_hw_params(pcm, params)) < 0 ||
		(rc = snd_pcm_sw_params_current(pcm, software)) < 0 ||
		(rc = snd_pcm_sw_params_set_start_threshold(pcm, software, period)) < 0 ||
		(rc = snd_pcm_sw_params_set_avail_min(pcm, software, period)) < 0 ||
		(rc = snd_pcm_sw_params(pcm, software)) < 0 || (rc = snd_pcm_prepare(pcm)) < 0)
		return rc < 0 ? rc : -EINVAL;
	(void)stream;
	return 0;
}
#endif

int qmodem_voip_media_probe(struct qmodem_voip_media_device *device)
{
#ifdef QMODEM_VOIP_HOST_TEST
	return device && device->full_duplex && device->capture_rate && device->playback_rate ? 0 : -1;
#else
	snd_pcm_t *capture = NULL, *playback = NULL;
	unsigned capture_rate, playback_rate;
	int rc;
	if (!device || !device->full_duplex) return -EINVAL;
	capture_rate = device->capture_rate ? device->capture_rate : 8000;
	playback_rate = device->playback_rate ? device->playback_rate : 8000;
	rc = snd_pcm_open(&capture, device->pcm_name, SND_PCM_STREAM_CAPTURE, SND_PCM_NONBLOCK);
	if (rc >= 0) rc = snd_pcm_open(&playback, device->pcm_name, SND_PCM_STREAM_PLAYBACK, SND_PCM_NONBLOCK);
	if (rc >= 0) rc = configure(capture, SND_PCM_STREAM_CAPTURE, &capture_rate);
	if (rc >= 0) rc = configure(playback, SND_PCM_STREAM_PLAYBACK, &playback_rate);
	if (capture) snd_pcm_close(capture);
	if (playback) snd_pcm_close(playback);
	if (rc < 0) return rc;
	if (!capture_rate || !playback_rate || capture_rate % 50U || playback_rate % 50U ||
	    capture_rate / 50U > QMODEM_VOIP_PCM_MAX_SAMPLES ||
	    playback_rate / 50U > QMODEM_VOIP_PCM_MAX_SAMPLES) return -EINVAL;
	device->capture_rate = capture_rate; device->playback_rate = playback_rate;
	return 0;
#endif
}

int qmodem_voip_media_capture(struct qmodem_voip_media_engine *engine,
				uint64_t timestamp_ms)
{
	if (engine && engine->backend == QMODEM_VOIP_MEDIA_BACKEND_SERIAL)
		return qmodem_voip_serial_capture(engine, timestamp_ms);
	if (engine && engine->backend == QMODEM_VOIP_MEDIA_BACKEND_PCM_SOCKET)
		return qmodem_voip_pcm_socket_capture(engine, timestamp_ms);
#ifdef QMODEM_VOIP_HOST_TEST
	(void)engine;
	(void)timestamp_ms;
	return -1;
#else
	int16_t canonical[QMODEM_VOIP_MEDIA_SAMPLES];
	size_t expected, produced = 0;
	snd_pcm_sframes_t received;
	if (!engine || !engine->ready || !engine->device.capture_rate) return -1;
	expected = engine->device.capture_rate / 50U;
	if (!expected || expected > QMODEM_VOIP_PCM_MAX_SAMPLES || !engine->capture_pcm) return -1;
	received = snd_pcm_readi(engine->capture_pcm, engine->alsa_capture + engine->alsa_capture_used,
		expected - engine->alsa_capture_used);
	if (received == -EAGAIN || received == 0) { engine->alsa_io_errors = 0; return 0; }
	if (received < 0) {
		if (received == -ENODEV || received == -EIO || ++engine->alsa_io_errors >= 50)
			engine->alsa_io_failed = 1;
		engine->alsa_capture_used = 0;
		if (received == -EPIPE || received == -ESTRPIPE) (void)snd_pcm_prepare(engine->capture_pcm);
		return -1;
	}
	engine->alsa_io_errors = 0;
	engine->alsa_capture_used += (size_t)received;
	if (engine->alsa_capture_used != expected) return 0;
	engine->alsa_capture_used = 0;
	if (qmodem_voip_media_resample(engine->alsa_capture, expected,
		engine->device.capture_rate, canonical, QMODEM_VOIP_MEDIA_SAMPLES,
		QMODEM_VOIP_MEDIA_RATE, &produced) || produced != QMODEM_VOIP_MEDIA_SAMPLES) return -1;
	return qmodem_voip_media_queue_push(&engine->modem_to_canonical, canonical,
		QMODEM_VOIP_MEDIA_SAMPLES, timestamp_ms);
#endif
}

int qmodem_voip_media_playback(struct qmodem_voip_media_engine *engine,
				uint64_t timestamp_ms)
{
	if (engine && engine->backend == QMODEM_VOIP_MEDIA_BACKEND_SERIAL)
		return qmodem_voip_serial_playback(engine, timestamp_ms);
	if (engine && engine->backend == QMODEM_VOIP_MEDIA_BACKEND_PCM_SOCKET)
		return qmodem_voip_pcm_socket_playback(engine, timestamp_ms);
#ifdef QMODEM_VOIP_HOST_TEST
	(void)engine;
	(void)timestamp_ms;
	return -1;
#else
	struct qmodem_voip_media_frame frame;
	size_t expected, produced = 0;
	snd_pcm_sframes_t written;
	if (!engine || !engine->ready || !engine->device.playback_rate || !engine->playback_pcm) return -1;
	expected = engine->device.playback_rate / 50U;
	if (!expected || expected > QMODEM_VOIP_PCM_MAX_SAMPLES) return -1;
	if (!engine->alsa_playback_count) {
		if (qmodem_voip_media_queue_pop(&engine->canonical_to_modem, &frame) < 0) return 0;
		if (qmodem_voip_media_resample(frame.samples, QMODEM_VOIP_MEDIA_SAMPLES,
			QMODEM_VOIP_MEDIA_RATE, engine->alsa_playback, QMODEM_VOIP_PCM_MAX_SAMPLES,
			engine->device.playback_rate, &produced) || produced != expected) return -1;
		engine->alsa_playback_count = produced;
		engine->alsa_playback_used = 0;
	}
	written = snd_pcm_writei(engine->playback_pcm, engine->alsa_playback + engine->alsa_playback_used,
		engine->alsa_playback_count - engine->alsa_playback_used);
	if (written == -EAGAIN || written == 0) return 0;
	if (written < 0) {
		if (written == -ENODEV || written == -EIO) engine->alsa_io_failed = 1;
		engine->alsa_playback_count = engine->alsa_playback_used = 0;
		if (written == -EPIPE || written == -ESTRPIPE) (void)snd_pcm_prepare(engine->playback_pcm);
		return -1;
	}
	engine->alsa_playback_used += (size_t)written;
	if (engine->alsa_playback_used == engine->alsa_playback_count)
		engine->alsa_playback_count = engine->alsa_playback_used = 0;
	(void)timestamp_ms;
	return 0;
#endif
}

int qmodem_voip_media_self_test(struct qmodem_voip_media_device *device,
				 struct qmodem_voip_media_tone *tone)
{
	int16_t canonical[QMODEM_VOIP_MEDIA_SAMPLES];
	int16_t playback[QMODEM_VOIP_BROWSER_SAMPLES];
	int16_t capture[QMODEM_VOIP_BROWSER_SAMPLES];
	int16_t measured[QMODEM_VOIP_MEDIA_SAMPLES];
	size_t playback_samples = 0, capture_samples = 0, measured_samples = 0;
	unsigned i;
	if (!device || !tone || !device->full_duplex || !device->capture_rate || !device->playback_rate)
		return -1;
	for (i = 0; i < QMODEM_VOIP_MEDIA_SAMPLES; i++)
		canonical[i] = (int16_t)(12000.0 * sin((2.0 * QMODEM_VOIP_PI * 1000.0 * i) / QMODEM_VOIP_MEDIA_RATE));
	if (qmodem_voip_media_resample(canonical, QMODEM_VOIP_MEDIA_SAMPLES,
		QMODEM_VOIP_MEDIA_RATE, playback, QMODEM_VOIP_BROWSER_SAMPLES,
		device->playback_rate, &playback_samples)) return -1;
#ifdef QMODEM_VOIP_HOST_TEST
	if (playback_samples > QMODEM_VOIP_BROWSER_SAMPLES) return -1;
	memcpy(capture, playback, playback_samples * sizeof(*capture));
	capture_samples = playback_samples;
#else
	{
		snd_pcm_t *out = NULL, *in = NULL;
		int written, read;
		if (snd_pcm_open(&out, device->pcm_name, SND_PCM_STREAM_PLAYBACK, 0) < 0 ||
			snd_pcm_open(&in, device->pcm_name, SND_PCM_STREAM_CAPTURE, 0) < 0 ||
			configure(out, SND_PCM_STREAM_PLAYBACK, &device->playback_rate) ||
			configure(in, SND_PCM_STREAM_CAPTURE, &device->capture_rate)) {
			if (out)
				snd_pcm_close(out);
			if (in)
				snd_pcm_close(in);
			return -1;
		}
		written = snd_pcm_writei(out, playback, playback_samples);
		read = snd_pcm_readi(in, capture, QMODEM_VOIP_BROWSER_SAMPLES);
		snd_pcm_close(out); snd_pcm_close(in);
		if (written != (int)playback_samples || read <= 0) return -1;
		capture_samples = (size_t)read;
	}
#endif
	if (qmodem_voip_media_resample(capture, capture_samples, device->capture_rate,
		measured, QMODEM_VOIP_MEDIA_SAMPLES, QMODEM_VOIP_MEDIA_RATE, &measured_samples) ||
		measured_samples != QMODEM_VOIP_MEDIA_SAMPLES) return -1;
	qmodem_voip_media_tone_analyse(measured, measured_samples, QMODEM_VOIP_MEDIA_RATE, tone);
	memset(canonical, 0, sizeof(canonical)); memset(playback, 0, sizeof(playback));
	memset(capture, 0, sizeof(capture)); memset(measured, 0, sizeof(measured));
	return tone->valid ? 0 : -1;
}

static int recorded_media(char *slot, size_t slot_size, char *method,
			  size_t method_size)
{
	const char *journal = getenv("QMODEM_VOIP_JOURNAL");
	char text[128];
	FILE *file;
	if (!journal) journal = "/var/lib/qmodem_voip/modem-safety.journal";
	file = fopen(journal, "r");
	if (!file) return -1;
	while (fgets(text, sizeof(text), file)) {
		if (strncmp(text, "slot=", 5) == 0) {
			text[5 + strcspn(text + 5, "\r\n")] = '\0';
			if (text[5] && strlen(text + 5) < slot_size)
				(void)snprintf(slot, slot_size, "%s", text + 5);
		}
		if (strncmp(text, "media_method=", 13) == 0) {
			text[13 + strcspn(text + 13, "\r\n")] = '\0';
			if (text[13] && strlen(text + 13) < method_size)
				(void)snprintf(method, method_size, "%s", text + 13);
		}
	}
	fclose(file);
	return slot[0] && method[0] ? 0 : -1;
}

int qmodem_voip_media_engine_start(struct qmodem_voip_media_engine *engine)
{
	char slot[64];
	char method[32];
	int rc;
	struct qmodem_voip_media_tone tone = { 0 };
	const char *sysfs = getenv("QMODEM_VOIP_SYSFS_ROOT");
	const char *proc = getenv("QMODEM_VOIP_PROC_ASOUND_ROOT");
	const char *devices = getenv("QMODEM_VOIP_DEVICE_ROOT");
	memset(slot, 0, sizeof(slot));
	memset(method, 0, sizeof(method));
	if (!engine || recorded_media(slot, sizeof(slot), method, sizeof(method))) {
		syslog(LOG_ERR, "qmodem_voip media: journal slot unavailable");
		return -1;
	}
	if (!sysfs) sysfs = "/sys/bus/usb/devices";
	if (!proc) proc = "/proc/asound";
	if (!devices) devices = "/dev";
	qmodem_voip_media_release(engine);
	qmodem_voip_media_queue_init(&engine->modem_to_canonical);
	qmodem_voip_media_queue_init(&engine->canonical_to_modem);
	if (strcmp(method, "serial_pcm") == 0) {
		if (qmodem_voip_serial_start(engine, sysfs, devices, slot)) {
			qmodem_voip_media_release(engine);
			syslog(LOG_ERR, "qmodem_voip media: serial PCM interface-01 discovery failed");
			return -1;
		}
		return 0;
	}
	if (strcmp(method, "pcm_socket") == 0) {
		if (qmodem_voip_pcm_socket_start(engine)) {
			qmodem_voip_media_release(engine);
			syslog(LOG_ERR, "qmodem_voip media: PCM socket path missing from profile");
			return -1;
		}
		return 0;
	}
	if (strcmp(method, "uac") != 0) {
		qmodem_voip_media_release(engine);
		return -1;
	}
	if ((rc = qmodem_voip_media_discover(sysfs, proc, slot, &engine->device)) != 0) {
		syslog(LOG_ERR, "qmodem_voip media: UAC discovery failed for recorded slot");
		qmodem_voip_media_release(engine);
		return rc;
	}
	engine->device.capture_rate = engine->device.playback_rate = engine->profile.sample_rate;
#ifdef QMODEM_VOIP_HOST_TEST
	engine->device.capture_rate = QMODEM_VOIP_BROWSER_RATE;
	engine->device.playback_rate = QMODEM_VOIP_BROWSER_RATE;
#endif
	if ((rc = qmodem_voip_media_probe(&engine->device)) != 0) {
		syslog(LOG_ERR, "qmodem_voip media: UAC duplex probe failed for %s (%d)", engine->device.pcm_name, rc);
		qmodem_voip_media_release(engine);
		return rc == -EINVAL || rc == -ENOENT || rc == -ENODEV ? -2 : -1;
	}
	if (getenv("QMODEM_VOIP_STARTUP_TONE_TEST") &&
		qmodem_voip_media_self_test(&engine->device, &tone)) {
		qmodem_voip_media_release(engine);
		return -1;
	}
#ifndef QMODEM_VOIP_HOST_TEST
	engine->backend = QMODEM_VOIP_MEDIA_BACKEND_UAC;
	if (snd_pcm_open(&engine->capture_pcm, engine->device.pcm_name,
		SND_PCM_STREAM_CAPTURE, SND_PCM_NONBLOCK) < 0 ||
		snd_pcm_open(&engine->playback_pcm, engine->device.pcm_name,
		SND_PCM_STREAM_PLAYBACK, SND_PCM_NONBLOCK) < 0 ||
		configure(engine->capture_pcm, SND_PCM_STREAM_CAPTURE,
			&engine->device.capture_rate) ||
		configure(engine->playback_pcm, SND_PCM_STREAM_PLAYBACK,
			&engine->device.playback_rate)) {
		qmodem_voip_media_release(engine);
		return -1;
	}
#endif
	engine->backend = QMODEM_VOIP_MEDIA_BACKEND_UAC;
	engine->ready = 1;
	engine->browser_media_ready = 0;
	return engine->ready ? 0 : -1;
}
