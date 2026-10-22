#define _GNU_SOURCE

#include <crypt.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>
#include <sys/wait.h>
#include <unistd.h>

#define AT_ADAPTER "/usr/lib/qmodem_voip/at_daemon_adapter.sh"
#define ADB_KEY_TEXT "SH_adb_quectel"
#define ADB_PROGRAM "/usr/lib/qmodem_voip/adb_selected.sh"
#define MEDIA_GATE_SOURCE "/usr/share/qmodem_voip/module/libqvoice_media_gate.so"
#define MEDIA_GATE_TEMP "/tmp/libqvoice_media_gate.so"
#define MEDIA_GATE_INSTALL_SOURCE "/usr/share/qmodem_voip/module/install_media_gate.sh"
#define MEDIA_GATE_INSTALL_TEMP "/tmp/install_qmodem_voip_media_gate.sh"
#define VOICE_SERVER_SHA256 "dc9d154d58942e83e3582cfc58ae59c88863052b345279c3bb8f4e5b25f28b33"
#define MAX_OUTPUT 512
#define ADB_COMMAND_TIMEOUT_SECONDS 8U
#define MEDIA_GATE_INSTALL_ATTEMPTS 10U
#define MEDIA_GATE_RETRY_SECONDS 2U

static int valid_sha256_output(const char *output)
{
	size_t i;
	if (!output)
		return 0;
	for (i = 0; i < 64U; i++)
		if (!isxdigit((unsigned char)output[i]))
			return 0;
	return isspace((unsigned char)output[64]);
}

static int run_capture_timeout(const char *program, char *const argv[], char *output,
			       size_t output_size, unsigned timeout_seconds)
{
	int pipe_fd[2];
	pid_t child;
	ssize_t used = 0;
	int status = 0;
	int waited;

	if (!program || !argv || !output || output_size < 2 || pipe(pipe_fd) != 0)
		return -1;
	child = fork();
	if (child < 0) {
		close(pipe_fd[0]);
		close(pipe_fd[1]);
		return -1;
	}
	if (child == 0) {
		close(pipe_fd[0]);
		if (dup2(pipe_fd[1], STDOUT_FILENO) < 0)
			_exit(127);
		close(pipe_fd[1]);
		if (timeout_seconds)
			alarm(timeout_seconds);
		execv(program, argv);
		_exit(127);
	}
	close(pipe_fd[1]);
	while (used < (ssize_t)output_size - 1) {
		ssize_t received = read(pipe_fd[0], output + used,
			output_size - 1U - (size_t)used);
		if (received > 0) {
			used += received;
			continue;
		}
		if (received < 0 && errno == EINTR)
			continue;
		break;
	}
	output[used > 0 ? used : 0] = '\0';
	close(pipe_fd[0]);
	while ((waited = waitpid(child, &status, 0)) < 0 && errno == EINTR)
		;
	if (waited < 0)
		return -1;
	return WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : -1;
}

static int run_capture(const char *program, char *const argv[], char *output,
		       size_t output_size)
{
	return run_capture_timeout(program, argv, output, output_size, 0);
}

static int adapter_at(const char *command, char *output, size_t output_size)
{
	char *const argv[] = { (char *)AT_ADAPTER, "at", (char *)command, NULL };
	return run_capture(AT_ADAPTER, argv, output, output_size);
}

static int run_program_timeout(const char *program, char *const argv[],
			       unsigned timeout_seconds)
{
	pid_t child = fork();
	int status;

	if (child < 0)
		return -1;
	if (child == 0) {
		if (timeout_seconds)
			alarm(timeout_seconds);
		execv(program, argv);
		_exit(127);
	}
	while (waitpid(child, &status, 0) < 0) {
		if (errno != EINTR)
			return -1;
	}
	return WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : -1;
}

static int install_media_gate(void)
{
	char output[MAX_OUTPUT];
	unsigned attempt;
	char *const hash_argv[] = { (char *)ADB_PROGRAM, "shell", "sha256sum",
		"/usr/bin/quectel_voice_server", NULL };
	char *const push_argv[] = { (char *)ADB_PROGRAM, "push",
		(char *)MEDIA_GATE_SOURCE, (char *)MEDIA_GATE_TEMP, NULL };
	char *const push_install_argv[] = { (char *)ADB_PROGRAM, "push",
		(char *)MEDIA_GATE_INSTALL_SOURCE, (char *)MEDIA_GATE_INSTALL_TEMP, NULL };
	char *const install_argv[] = { (char *)ADB_PROGRAM, "shell", "sh",
		(char *)MEDIA_GATE_INSTALL_TEMP, NULL };

	if (access(MEDIA_GATE_SOURCE, R_OK) != 0 ||
	    access(MEDIA_GATE_INSTALL_SOURCE, R_OK) != 0) {
		syslog(LOG_ERR, "media gate source files are unavailable");
		return -1;
	}
	for (attempt = 0; attempt < MEDIA_GATE_INSTALL_ATTEMPTS; attempt++) {
		if (run_capture_timeout(ADB_PROGRAM, hash_argv, output, sizeof(output),
			ADB_COMMAND_TIMEOUT_SECONDS) == 0) {
			if (valid_sha256_output(output) &&
			    strncmp(output, VOICE_SERVER_SHA256,
				sizeof(VOICE_SERVER_SHA256) - 1U) != 0) {
				syslog(LOG_ERR, "voice-server hash is unsupported");
				return -1;
			}
			if (!valid_sha256_output(output)) {
				syslog(LOG_WARNING,
					"ADB voice-server hash unavailable (attempt %u/%u)",
					attempt + 1U, MEDIA_GATE_INSTALL_ATTEMPTS);
				goto retry;
			}
			if (run_program_timeout(ADB_PROGRAM, push_argv,
				ADB_COMMAND_TIMEOUT_SECONDS) == 0 &&
			    run_program_timeout(ADB_PROGRAM, push_install_argv,
				ADB_COMMAND_TIMEOUT_SECONDS) == 0 &&
			    run_program_timeout(ADB_PROGRAM, install_argv,
				ADB_COMMAND_TIMEOUT_SECONDS) == 0)
				return 0;
			syslog(LOG_WARNING,
				"ADB media gate deployment failed (attempt %u/%u)",
				attempt + 1U, MEDIA_GATE_INSTALL_ATTEMPTS);
		} else {
			syslog(LOG_WARNING,
				"ADB voice-server query failed (attempt %u/%u)",
				attempt + 1U, MEDIA_GATE_INSTALL_ATTEMPTS);
		}
	retry:
		if (attempt + 1U < MEDIA_GATE_INSTALL_ATTEMPTS)
			sleep(MEDIA_GATE_RETRY_SECONDS);
	}
	return -1;
}

static int adb_key(const char *response, char *key, size_t key_size)
{
	const char *prefix = "+QADBKEY:";
	const char *value;
	char serial[64];
	char salt[80];
	const char *hashed;
	size_t prefix_length;
	char *end;

	if (!response || !key || key_size < 16 ||
		!(value = strstr(response, prefix)))
		return -1;
	value += strlen(prefix);
	while (isspace((unsigned char)*value))
		value++;
	if (snprintf(serial, sizeof(serial), "%s", value) < 0)
		return -1;
	end = serial + strcspn(serial, "\r\n ,");
	*end = '\0';
	if (!serial[0] || strlen(serial) >= sizeof(salt) - 5U)
		return -1;
	for (value = serial; *value; value++)
		if (!isalnum((unsigned char)*value) && *value != '_' && *value != '-')
			return -1;
	if (snprintf(salt, sizeof(salt), "$1$%s$", serial) < 0)
		return -1;
	hashed = crypt(ADB_KEY_TEXT, salt);
	if (!hashed)
		return -1;
	prefix_length = strlen(salt);
	if (strncmp(hashed, salt, prefix_length) != 0 || strlen(hashed) < prefix_length + 15U)
		return -1;
	memcpy(key, hashed + prefix_length, 15U);
	key[15] = '\0';
	return 0;
}

static int valid_field(const char *field)
{
	const unsigned char *cursor = (const unsigned char *)field;
	if (!field || !field[0])
		return 0;
	while (*cursor) {
		if (!isalnum(*cursor) && *cursor != 'x' && *cursor != 'X')
			return 0;
		cursor++;
	}
	return 1;
}

static int adb_usbcfg(const char *response, char *configuration,
		      size_t configuration_size)
{
	char fields[9][32];
	char copy[MAX_OUTPUT];
	char *cursor;
	char *field;
	unsigned count = 0;
	unsigned i;
	int written = 0;

	if (!response || !configuration || configuration_size < 2)
		return -1;
	if (snprintf(copy, sizeof(copy), "%s", response) < 0)
		return -1;
	cursor = copy;
	while ((field = strsep(&cursor, ",\r\n ")) != NULL) {
		if (!field[0])
			continue;
		if (count >= 9 || !valid_field(field) || strlen(field) >= sizeof(fields[0]))
			return -1;
		(void)snprintf(fields[count++], sizeof(fields[0]), "%s", field);
	}
	if (count != 9)
		return -1;
	(void)snprintf(fields[7], sizeof(fields[7]), "1");
	for (i = 0; i < count; i++) {
		int next = snprintf(configuration + written,
			configuration_size - (size_t)written, "%s%s", i ? "," : "", fields[i]);
		if (next < 0 || (size_t)next >= configuration_size - (size_t)written)
			return -1;
		written += next;
	}
	return 0;
}

static int current_adb_enabled(const char *response)
{
	char configuration[MAX_OUTPUT];
	char *field;
	char *cursor;
	unsigned index = 0;

	if (!response)
		return 0;
	if (snprintf(configuration, sizeof(configuration), "%s", response) < 0)
		return 0;
	cursor = configuration;
	while ((field = strsep(&cursor, ",\r\n ")) != NULL) {
		if (!field[0])
			continue;
		if (index++ == 7)
			return strcmp(field, "1") == 0;
	}
	return 0;
}

int main(int argc, char **argv)
{
	char response[MAX_OUTPUT];
	char key[16];
	char configuration[MAX_OUTPUT];
	char command[MAX_OUTPUT + 32];

	openlog("qmodem_voip_adb", LOG_PID, LOG_DAEMON);
	if (argc != 2)
		return 64;
	if (strcmp(argv[1], "install-media-gate") == 0)
		return install_media_gate() == 0 ? 0 : 1;
	if (strcmp(argv[1], "unlock") != 0)
		return 64;
	if (adapter_at("AT+QCFG=\"usbcfg\"", response, sizeof(response)) != 0)
		return 1;
	if (current_adb_enabled(response))
		return 0;
	if (adb_usbcfg(response, configuration, sizeof(configuration)) != 0)
		return 1;
	if (adapter_at("AT+QADBKEY?", response, sizeof(response)) != 0 ||
		adb_key(response, key, sizeof(key)) != 0)
		return 1;
	(void)snprintf(command, sizeof(command), "AT+QADBKEY=\"%s\"", key);
	if (adapter_at(command, response, sizeof(response)) != 0)
		return 1;
	(void)snprintf(command, sizeof(command), "AT+QCFG=\"usbcfg\",%s", configuration);
	if (adapter_at(command, response, sizeof(response)) != 0 ||
		adapter_at("AT+QPOWD=1", response, sizeof(response)) != 0)
		return 1;
	return 2;
}
