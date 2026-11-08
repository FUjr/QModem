#define _POSIX_C_SOURCE 200809L

#include "sip_credentials.h"

#include <errno.h>
#include <stdlib.h>
#include <fcntl.h>
#include <string.h>
#include <sys/random.h>
#include <sys/stat.h>
#include <uci.h>
#include <unistd.h>

static int read_uci_credentials(char username[QMODEM_VOIP_SIP_USERNAME_SIZE],
				char password[QMODEM_VOIP_SIP_PASSWORD_SIZE])
{
	struct uci_context *context = uci_alloc_context();
	struct uci_package *package = NULL;
	struct uci_section *section;
	const char *value;
	int result = -1;

	if (!context || uci_load(context, "qmodem_sip", &package) != UCI_OK)
		goto out;
	section = uci_lookup_section(context, package, (getenv("QMODEM_SIP_SECTION") ? getenv("QMODEM_SIP_SECTION") : "inbound"));
	if (!section)
		goto out;
	value = uci_lookup_option_string(context, section, "username");
	if (!value || strlen(value) >= QMODEM_VOIP_SIP_USERNAME_SIZE)
		goto out;
	memcpy(username, value, strlen(value) + 1U);
	value = uci_lookup_option_string(context, section, "password");
	if (!value || strlen(value) >= QMODEM_VOIP_SIP_PASSWORD_SIZE)
		goto out;
	memcpy(password, value, strlen(value) + 1U);
	if (qmodem_voip_sip_validate_credentials(username, password) == 0)
		result = 0;
out:
	if (package)
		uci_unload(context, package);
	if (context)
		uci_free_context(context);
	return result;
}

static int set_option(struct uci_context *context, const char *option,
			      struct uci_package *package,
			      struct uci_section *section, const char *value)
{
	struct uci_ptr pointer = { 0 };
	pointer.p = package;
	pointer.s = section;
	pointer.package = "qmodem_sip";
	pointer.section = (getenv("QMODEM_SIP_SECTION") ? getenv("QMODEM_SIP_SECTION") : "inbound");
	pointer.option = option;
	pointer.value = value;
	return uci_set(context, &pointer) == UCI_OK ? 0 : -1;
}

static int persist_credentials(const char *username, const char *password)
{
	struct uci_context *context = uci_alloc_context();
	struct uci_package *package = NULL;
	struct uci_section *section;
	int result = -1;

	if (!context || uci_load(context, "qmodem_sip", &package) != UCI_OK)
		goto out;
	section = uci_lookup_section(context, package, (getenv("QMODEM_SIP_SECTION") ? getenv("QMODEM_SIP_SECTION") : "inbound"));
	if (!section || set_option(context, "username", package, section, username) != 0 ||
	    set_option(context, "password", package, section, password) != 0 ||
	    uci_save(context, package) != UCI_OK ||
	    uci_commit(context, &package, false) != UCI_OK)
		goto out;
	(void)chmod("/etc/config/qmodem_sip", S_IRUSR | S_IWUSR);
	result = 0;
out:
	if (package)
		uci_unload(context, package);
	if (context)
		uci_free_context(context);
	return result;
}

static int random_password(char password[QMODEM_VOIP_SIP_PASSWORD_SIZE])
{
	static const char alphabet[] =
		"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
	unsigned char random[24];
	ssize_t offset = 0;

	while ((size_t)offset < sizeof(random)) {
		ssize_t count = getrandom(random + offset, sizeof(random) - (size_t)offset, 0);
		if (count < 0 && errno == EINTR)
			continue;
		if (count <= 0) {
			memset(random, 0, sizeof(random));
			return -1;
		}
		offset += count;
	}
	for (offset = 0; (size_t)offset < sizeof(random); offset++)
		password[offset] = alphabet[random[offset] & 63U];
	password[sizeof(random)] = '\0';
	memset(random, 0, sizeof(random));
	return 0;
}

int qmodem_voip_sip_credentials_sync(char username[QMODEM_VOIP_SIP_USERNAME_SIZE])
{
	char password[QMODEM_VOIP_SIP_PASSWORD_SIZE] = { 0 };
	int result;

	result = read_uci_credentials(username, password);
	if (result == 0)
		result = qmodem_voip_sip_write_credentials((getenv("QMODEM_SIP_CREDENTIALS") ? getenv("QMODEM_SIP_CREDENTIALS") : QMODEM_VOIP_SIP_CONFIG),
			username, password);
	memset(password, 0, sizeof(password));
	return result;
}

int qmodem_voip_sip_credentials_generate(const char *username,
	char password[QMODEM_VOIP_SIP_PASSWORD_SIZE])
{
	if (random_password(password) != 0 ||
	    qmodem_voip_sip_validate_credentials(username, password) != 0)
		return -1;
	if (persist_credentials(username, password) != 0 ||
	    qmodem_voip_sip_write_credentials((getenv("QMODEM_SIP_CREDENTIALS") ? getenv("QMODEM_SIP_CREDENTIALS") : QMODEM_VOIP_SIP_CONFIG),
		username, password) != 0) {
		memset(password, 0, QMODEM_VOIP_SIP_PASSWORD_SIZE);
		return -1;
	}
	return 0;
}
