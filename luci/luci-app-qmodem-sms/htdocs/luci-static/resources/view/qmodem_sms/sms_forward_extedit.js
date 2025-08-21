'use strict';
'require view';
'require fs';
'require ui';

return view.extend({
	load: function() {
		return L.resolveDefault(fs.read('/etc/config/sms_daemon'), '');
	},

	render: function(config_data) {
		var m, s, o;

		m = new form.Map('sms_daemon', _('SMS Daemon Configuration Editor'));
		m.description = _('Edit the SMS daemon configuration file directly. Be careful with the syntax.');

		s = m.section(form.NamedSection, 'sms_forward', 'sms_forward', _('Global Settings'));
		s.addremove = false;

		o = s.option(form.Flag, 'enable', _('Enable SMS Forward Service'));
		o.default = '0';

		o = s.option(form.ListValue, 'log_level', _('Log Level'));
		o.value('error', _('Error'));
		o.value('warning', _('Warning'));
		o.value('info', _('Information'));
		o.value('debug', _('Debug'));
		o.default = 'info';

		s = m.section(form.TypedSection, 'sms_forward_instance', _('SMS Forward Instances'));
		s.addremove = true;
		s.anonymous = false;

		o = s.option(form.Flag, 'enable', _('Enable'));
		o.default = '0';

		o = s.option(form.Value, 'listen_port', _('Modem Port'));
		o.placeholder = '/dev/ttyUSB2';

		o = s.option(form.Value, 'poll_interval', _('Poll Interval (seconds)'));
		o.datatype = 'range(15,600)';
		o.default = '30';

		o = s.option(form.ListValue, 'api_type', _('API Type'));
		o.value('tgbot', _('Telegram Bot'));
		o.value('webhook', _('Webhook'));
		o.value('serverchan', _('ServerChan'));
		o.value('custom_script', _('Custom Script'));

		o = s.option(form.TextValue, 'api_config', _('API Configuration'));
		o.rows = 5;
		o.placeholder = _('JSON configuration for the selected API type');

		// Add configuration examples based on API type
		o.description = _('JSON configuration examples:') + '<br/>' +
			'<strong>Telegram Bot:</strong> {"bot_token":"123456:ABC-DEF","chat_id":"123456789"}<br/>' +
			'<strong>Webhook:</strong> {"webhook_url":"https://example.com/webhook","headers":"Authorization: Bearer token"}<br/>' +
			'<strong>ServerChan:</strong> {"token":"SCT123456TCxyz","channel":"9|66","noip":"1","openid":"openid1,openid2"}<br/>' +
			'<strong>Custom Script:</strong> {"script_path":"/usr/bin/my_sms_script.sh"}';

		return m.render();
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
