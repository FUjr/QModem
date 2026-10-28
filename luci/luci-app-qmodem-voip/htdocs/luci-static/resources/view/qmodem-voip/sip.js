'use strict';
'require view';
'require form';
'require uci';
'require ui';
'require qmodem-voip.rpc as rpc';

document.head.appendChild(E('link', {
	rel: 'stylesheet', type: 'text/css', href: L.resource('qmodem-voip/qmodem-voip.css')
}));

function statusLabel(value, positive) {
	return E('span', { class: `label ${positive ? 'success' : ''}`.trim() }, [ value ]);
}

function directionStatus(name, status) {
	status = status || {};
	let value = _('Stopped');
	if (status.running)
		value = status.registered ? _('Registered') : _('Running');
	else if (status.enabled)
		value = _('Waiting');
	return E('div', { class: 'qvoip-status-item' }, [
		E('div', { class: 'qvoip-status-label' }, [ name ]),
		statusLabel(value, Boolean(status.running)),
		E('div', { class: 'qvoip-status-detail' }, [
			status.enabled ? _('This direction is enabled.') : _('This direction is disabled.')
		])
	]);
}

return view.extend({
	load() {
		return Promise.all([
			uci.load('network'),
			uci.load('qmodem'),
			L.resolveDefault(rpc.sipStatus(), {})
		]);
	},

	addCommonOptions(section, defaultInterface, interfaces, modems) {
		let option = section.option(form.Flag, 'enabled', _('Enable'));
		option.default = '0';
		option.rmempty = false;

		option = section.option(form.ListValue, 'interface', _('Network interface'));
		option.default = defaultInterface;
		option.rmempty = false;
		option.depends('enabled', '1');
		if (!interfaces.some((network) => network['.name'] === defaultInterface))
			option.value(defaultInterface, defaultInterface);
		interfaces.forEach((network) => {
			if (network['.name'])
				option.value(network['.name'], network['.name']);
		});

		option = section.option(form.Value, 'listen_port', _('Local SIP port'));
		option.datatype = 'port';
		option.default = defaultInterface === 'lan' ? '5060' : '5061';
		option.rmempty = false;
		option.depends('enabled', '1');

		option = section.option(form.Flag, 'voip_enabled', _('Connect voice service'));
		option.default = '1';
		option.rmempty = false;
		option.depends('enabled', '1');

		option = section.option(form.Flag, 'sms_enabled', _('Connect SMS service'));
		option.default = '0';
		option.rmempty = false;
		option.depends('enabled', '1');

		option = section.option(form.ListValue, 'sms_modem', _('SMS modem'));
		option.rmempty = false;
		option.depends({ enabled: '1', sms_enabled: '1' });
		modems.forEach((device) => {
			if (device['.name'])
				option.value(device['.name'], device.name || device['.name']);
		});
	},

	createMap() {
		const map = new form.Map('qmodem_sip', _('SIP service'),
			_('Configure the independent inbound and outbound SIP transports.'));
		const interfaces = uci.sections('network', 'interface') || [];
		const modems = uci.sections('qmodem', 'modem-device') || [];

		const main = map.section(form.NamedSection, 'main', 'sipd', _('Service settings'));
		main.anonymous = true;
		main.addremove = false;
		let option = main.option(form.Value, 'media_socket_path', _('VoIP media socket'));
		option.default = '/var/run/qmodem_voip/media.sock';
		option.rmempty = false;
		option = main.option(form.Value, 'rtp_start', _('First RTP port'));
		option.datatype = 'port';
		option.default = '40000';
		option.rmempty = false;
		option = main.option(form.Value, 'rtp_end', _('Last RTP port'));
		option.datatype = 'port';
		option.default = '40031';
		option.rmempty = false;

		const inbound = map.section(form.NamedSection, 'inbound', 'direction',
			_('Inbound SIP'), _('Accept authenticated local SIP calls and messages.'));
		inbound.anonymous = true;
		inbound.addremove = false;
		this.addCommonOptions(inbound, 'lan', interfaces, modems);
		option = inbound.option(form.ListValue, 'transport', _('Transport'));
		option.value('udp_tcp', _('UDP and TCP'));
		option.default = 'udp_tcp';
		option.rmempty = false;
		option.depends('enabled', '1');
		const inboundUser = inbound.option(form.Value, 'username', _('SIP account'));
		inboundUser.rmempty = false;
		inboundUser.depends('enabled', '1');
		option = inbound.option(form.Value, 'password', _('SIP password'),
			_('At least 8 characters, no spaces. Use Generate for a strong one.'));
		option.password = true;
		option.rmempty = false;
		option.depends('enabled', '1');
		option.validate = (sectionId, value) => {
			if (!value)
				return true;
			if (value.length < 8)
				return _('The password must have at least 8 characters.');
			if (value.length > 127)
				return _('The password can have at most 127 characters.');
			if (!/^[\x21-\x7e]+$/.test(value))
				return _('The password can only use letters, numbers and symbols, without spaces.');
			return true;
		};
		option = inbound.option(form.Button, '_generate', _('Generate credentials'));
		option.inputstyle = 'apply';
		option.inputtitle = _('Generate');
		option.onclick = async (ev, sectionId) => {
			const username = inboundUser.formvalue(sectionId);
			if (!username) {
				ui.addNotification(null, E('p', {}, [ _('Enter a SIP account first.') ]), 'warning');
				return;
			}
			const response = await rpc.generateSipCredentials(username);
			if (!response || response.status !== 'success' || !response.password) {
				ui.addNotification(null, E('p', {}, [ _('Credential generation failed.') ]), 'error');
				return;
			}
			ui.showModal(_('New SIP credentials'), [
				E('p', {}, [ _('The password is shown once. Store it before closing this dialog.') ]),
				E('div', { class: 'cbi-value' }, [
					E('label', { class: 'cbi-value-title' }, [ _('Username') ]),
					E('div', { class: 'cbi-value-field' }, [ E('code', {}, [ response.username ]) ])
				]),
				E('div', { class: 'cbi-value' }, [
					E('label', { class: 'cbi-value-title' }, [ _('Password') ]),
					E('div', { class: 'cbi-value-field' }, [ E('code', {}, [ response.password ]) ])
				]),
				E('div', { class: 'right' }, [
					E('button', { class: 'btn', click: ui.hideModal }, [ _('Close') ])
				])
			]);
		};

		const outbound = map.section(form.NamedSection, 'outbound', 'direction',
			_('Outbound SIP'), _('Register with an external SIP server over TLS.'));
		outbound.anonymous = true;
		outbound.addremove = false;
		this.addCommonOptions(outbound, 'wan', interfaces, modems);
		option = outbound.option(form.Value, 'server', _('SIP server'));
		option.datatype = 'host';
		option.rmempty = false;
		option.depends('enabled', '1');
		option = outbound.option(form.Value, 'port', _('Server TLS port'));
		option.datatype = 'port';
		option.default = '5061';
		option.rmempty = false;
		option.depends('enabled', '1');
		option = outbound.option(form.ListValue, 'transport', _('Transport'));
		option.value('tls', _('TLS'));
		option.default = 'tls';
		option.rmempty = false;
		option.depends('enabled', '1');
		option = outbound.option(form.Value, 'username', _('SIP account'));
		option.rmempty = false;
		option.depends('enabled', '1');
		option = outbound.option(form.Value, 'password', _('SIP password'));
		option.password = true;
		option.rmempty = false;
		option.depends('enabled', '1');
		option = outbound.option(form.Value, 'realm', _('SIP realm'));
		option.placeholder = 'asterisk';
		option.depends('enabled', '1');
		option = outbound.option(form.Value, 'register_interval', _('Registration interval'));
		option.datatype = 'range(60,3600)';
		option.default = '300';
		option.rmempty = false;
		option.depends('enabled', '1');
		return map;
	},

	async render(data) {
		const status = data[2] || {};
		const summary = E('div', { class: 'cbi-section qvoip-overview' }, [
			E('h3', {}, [ _('Service status') ]),
			E('div', { class: 'qvoip-status-grid' }, [
				directionStatus(_('Inbound SIP'), status.inbound),
				directionStatus(_('Outbound SIP'), status.outbound),
				E('div', { class: 'qvoip-status-item' }, [
					E('div', { class: 'qvoip-status-label' }, [ _('Connected services') ]),
					statusLabel(status.voipd_available ? _('VoIP ready') : _('VoIP unavailable'), Boolean(status.voipd_available)),
					E('div', { class: 'qvoip-status-detail' }, [
						status.smsd_available ? _('SMSD is available.') : _('SMSD is unavailable.')
					])
				])
			])
		]);
		return E('div', { class: 'qvoip-page' }, [ summary, await this.createMap().render() ]);
	}
});
