'use strict';
'require qmodem.sms-number as smsNumber';
'require qmodem.sms as smsService';
'require ui';

return L.Class.extend({
	create: function(getNumber, getModem) {
		var pending = false, sequence = 0;
		var code = E('input', { 'type': 'text', 'class': 'cbi-input-text',
			'placeholder': _('As entered'), 'maxlength': '4', 'aria-label': _('Country calling code (optional)') });
		var preview = E('span');
		var save = E('button', { 'type': 'button', 'class': 'cbi-button cbi-button-apply' }, _('Save for this modem'));
		var field = E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, _('Country calling code (optional)')),
			E('div', { 'class': 'cbi-value-field' }, [ code, ' ', save,
				E('div', { 'class': 'cbi-value-description' },
					_('Leave empty to send as entered, including service numbers. Use + for a complete international number. When adding a country code, omit the domestic trunk prefix.')),
				E('div', {}, [ _('Send to:') + ' ', preview ]) ])
		]);
		function recipient() {
			if (pending) throw new Error('Loading country calling code');
			return smsNumber.normalize(getNumber(), code.value);
		}
		function update() {
			try { preview.textContent = recipient(); }
			catch (e) { preview.textContent = getNumber() ? _(e.message) : '—'; }
		}
		code.addEventListener('input', update);
		save.addEventListener('click', function() {
			var selectedModem = getModem(), normalized;
			try { normalized = smsNumber.normalizeCode(code.value); }
			catch (err) { ui.addNotification(null, E('p', _(err.message)), 'error'); return; }
			save.disabled = true;
			smsService.setCountryCode(selectedModem, normalized).then(function() {
				ui.addNotification(null, E('p', _('Configuration saved')), 'info');
			}).catch(function(err) { ui.addNotification(null, E('p', err.message), 'error'); })
				.finally(function() { if (!pending) save.disabled = false; });
		});
		function load() {
			var current = ++sequence;
			pending = true; code.disabled = true; save.disabled = true; code.value = ''; update();
			return smsService.getCountryCode(getModem()).then(function(value) {
				if (current !== sequence) return;
				value = smsNumber.normalizeCode(value);
				code.value = value ? '+' + value : '';
				pending = false; code.disabled = false; save.disabled = false; update();
			}).catch(function(err) {
				if (current !== sequence) return;
				pending = false; code.disabled = false; save.disabled = false;
				ui.addNotification(null, E('p', _('Failed to load country calling code') + ': ' + err.message), 'error');
				update();
			});
		}
		load();
		return { node: field, recipient: recipient, update: update,
			load: load };
	}
});
