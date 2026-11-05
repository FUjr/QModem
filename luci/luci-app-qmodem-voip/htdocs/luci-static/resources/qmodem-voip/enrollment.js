'use strict';
'require baseclass';

return baseclass.extend({
	parse(text) {
		if (typeof text !== 'string' || text.length > 16384)
			throw new Error(_('Enrollment JSON is too large.'));
		const data = JSON.parse(text);
		if (!data || Array.isArray(data) || data.schema_version !== 1 || data.transport !== 'tls')
			throw new Error(_('Expected a version 1 SIP Gateway Manager enrollment using TLS.'));
		for (const key of ['server', 'username', 'password', 'realm']) {
			if (typeof data[key] !== 'string' || !data[key] || /[\x00-\x20\x7f]/.test(data[key]))
				throw new Error(_('Invalid enrollment field: %s').format(key));
		}
		if (!/^[a-zA-Z0-9._:-]+$/.test(data.server))
			throw new Error(_('Invalid SIP server hostname or address.'));
		if (data.password.length < 8 || data.password.length > 128)
			throw new Error(_('Invalid SIP password length.'));
		if (!Number.isInteger(data.port) || data.port < 1 || data.port > 65535 ||
			!Number.isInteger(data.register_interval) || data.register_interval < 60 || data.register_interval > 3600)
			throw new Error(_('Invalid SIP port or registration interval.'));
		for (const key of ['voip_enabled', 'sms_enabled']) {
			if (typeof data[key] !== 'boolean')
				throw new Error(_('Invalid enrollment service flags.'));
		}
		return {
			enabled: '1', server: data.server, port: String(data.port), transport: 'tls',
			username: data.username, password: data.password, realm: data.realm,
			register_interval: String(data.register_interval),
			voip_enabled: data.voip_enabled ? '1' : '0', sms_enabled: data.sms_enabled ? '1' : '0'
		};
	}
});
