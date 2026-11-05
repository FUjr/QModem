'use strict';
'require view';
'require poll';
'require ui';
'require dom';
'require qmodem.sms as smsService';
'require qmodem.qmodem as qmodem';

// Load CSS
document.head.appendChild(E('link', {
	'rel': 'stylesheet',
	'type': 'text/css',
	'href': L.resource('qmodem/qmodem-next.css')
}));

return view.extend({
	load: function() {
		return qmodem.getModemSections();
	},

	render: function(modems) {
		var self = this;
		var container = E('div', { 'class': 'cbi-map' });

		// Filter enabled modems
		modems = modems.filter(function(m) { return m.enabled; });

		if (modems.length === 0) {
			container.appendChild(E('div', { 'class': 'alert-message warning' }, 
				_('No modems configured or all modems are disabled.')));
			return container;
		}

		// Modem selector
		var selectorSection = E('fieldset', { 'class': 'cbi-section' });
		var selectorTable = E('table', { 'class': 'table' });
		var selectorBody = E('tbody', {});
		var selectorRow = E('tr', { 'class': 'tr' });
		var labelCell = E('td', { 'class': 'td', 'width': '33%' }, _('Modem Name'));
		var selectCell = E('td', { 'class': 'td' });
		
		var select = E('select', {
			'class': 'cbi-input-select',
			'id': 'sms_sim_modem_selector'
		});
		
		modems.forEach(function(modem) {
			select.appendChild(E('option', { 'value': modem.id }, modem.name));
		});
		
		selectCell.appendChild(select);
		selectorRow.appendChild(labelCell);
		selectorRow.appendChild(selectCell);
		selectorBody.appendChild(selectorRow);
		selectorTable.appendChild(selectorBody);
		selectorSection.appendChild(selectorTable);
		container.appendChild(selectorSection);

		// Title
		this.modemSelect = select;
		this.busy = false;
		var title = E('h2', { 'name': 'content' }, _('Module SMS Storage'));
		container.appendChild(title);

		// Description
		var desc = E('div', { 'class': 'cbi-map-descr' }, 
			_('View and delete raw SMS in the current module storage (SM: SIM card, ME: module). Archived messages remain available in SMS Messages.'));
		container.appendChild(desc);

		// Main content area
		var contentArea = E('div', { 'id': 'sms-sim-content' });
		container.appendChild(contentArea);

		// Loading indicator
		var loadingDiv = E('div', { 'class': 'spinning' }, _('Loading...'));
		contentArea.appendChild(loadingDiv);

		// Load SIM SMS list with selected modem
		var selectedModem = select.value;
		this.loadSimSmsList(contentArea, loadingDiv, selectedModem);

		// Selector change handler
		select.addEventListener('change', function() {
			var loading = E('div', { 'class': 'spinning' }, _('Loading...'));
			dom.content(contentArea, loading);
			self.loadSimSmsList(contentArea, loading, select.value);
		});

		// Start polling for updates
		poll.add(function() {
			return self.pollSimSmsList(contentArea, select.value);
		}, 10);

		return container;
	},

	loadSimSmsList: function(contentArea, loadingDiv, configSection) {
		var self = this;
		if (this.busy) return Promise.resolve();
		var requestId = this.requestId = (this.requestId || 0) + 1;
		this.pendingLoad = true;
		return smsService.getSimSms(configSection).then(function(result) {
			if (self.busy || self.requestId !== requestId || self.modemSelect.value !== configSection) return;
			self.renderSimSmsList(contentArea, result.messages, configSection, result);
		}).catch(function(err) {
			if (self.busy || self.requestId !== requestId || self.modemSelect.value !== configSection) return;
			dom.content(contentArea, E('div', { 'class': 'alert-message error' },
				_('Failed to read module SMS: ') + err.message));
		}).then(function() {
			if (self.requestId === requestId) self.pendingLoad = false;
		});
	},

	pollSimSmsList: function(contentArea, configSection) {
		if (this.busy || this.pendingLoad) return Promise.resolve();
		return this.loadSimSmsList(contentArea, null, configSection);
	},

	renderSimSmsList: function(contentArea, messages, configSection, result) {
		var self = this;

		// Clear content
		dom.content(contentArea, null);

		// Create messages container
		var messagesDiv = E('div', { 'class': 'sms-sim-messages' });
		messagesDiv.appendChild(E('div', { 'class': 'cbi-map-descr' },
			_('Current reading storage: %s').format(result.storage)));
		if (result.mode !== 'direct' && result.auto_delete) {
			messagesDiv.appendChild(E('div', { 'class': 'alert-message info' },
				_('Automatic removal after archiving is enabled. An empty module storage is normal; view archived messages in SMS Messages.')));
		}

		if (!messages || messages.length === 0) {
			messagesDiv.appendChild(E('div', { 'class': 'alert-message info' }, 
				_('No messages found in module storage')));
		} else {
			// Create messages list
			var listDiv = E('div', { 'class': 'cbi-section' });
			var listFieldset = E('fieldset', { 'class': 'cbi-section' });
			var listLegend = E('legend', {}, _('Raw SMS Messages'));
		
			listFieldset.appendChild(listLegend);

			// Create table
			var table = E('table', { 'class': 'table cbi-section-table' });
			var thead = E('thead', {}, [
				E('tr', { 'class': 'tr cbi-section-table-titles' }, [
					E('th', { 'class': 'th', 'style': 'width: 5%' }, _('Index')),
					E('th', { 'class': 'th', 'style': 'width: 15%' }, _('Sender')),
					E('th', { 'class': 'th', 'style': 'width: 15%' }, _('Time')),
					E('th', { 'class': 'th', 'style': 'width: 50%' }, _('Content')),
					E('th', { 'class': 'th', 'style': 'width: 10%' }, _('Type')),
					E('th', { 'class': 'th', 'style': 'width: 5%' }, _('Actions'))
				])
			]);
			table.appendChild(thead);

			var tbody = E('tbody', {});

			// Add message rows
			for (var i = 0; i < messages.length; i++) {
				var msg = messages[i];
				
				var index = msg.index != null ? String(msg.index) : '-';
				var sender = smsService.formatPhoneNumber(msg.sender || '-');
				var time = msg.timestamp ? smsService.formatTimestamp(msg.timestamp) : '-';
				var content = smsService.truncateMessage(msg.content || msg.sms_text || '', 80);
				
				// Determine message type
				var type = '';
				if (msg.total > 1) {
					type = _('Part') + ' ' + (msg.part || '?') + '/' + (msg.total || '?');
				} else {
					type = _('Single');
				}
				
				var deleteBtn = E('button', {
					'class': 'cbi-button cbi-button-remove',
					'click': L.bind(function(message) {
						self.handleDeleteSimSms(configSection, message, result.storage, contentArea);
					}, this, msg)
				}, _('Delete'));

				var row = E('tr', { 
					'class': 'tr cbi-section-table-row'
				}, [
					E('td', { 'class': 'td' }, index),
					E('td', { 'class': 'td' }, sender),
					E('td', { 'class': 'td' }, time),
					E('td', { 'class': 'td', 'style': 'word-break: break-word;' }, content),
					E('td', { 'class': 'td' }, type),
					E('td', { 'class': 'td' }, deleteBtn)
				]);

				tbody.appendChild(row);
			}

			table.appendChild(tbody);
			listFieldset.appendChild(table);
			listDiv.appendChild(listFieldset);
			messagesDiv.appendChild(listDiv);
		}

		// Add summary info
		var summaryDiv = E('div', { 'class': 'cbi-section' });
		var summaryFieldset = E('fieldset', { 'class': 'cbi-section' });
		summaryFieldset.appendChild(E('legend', {}, _('Summary')));
		
		var summaryTable = E('table', { 'class': 'table' });
		var summaryBody = E('tbody', {}, [
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td', 'width': '33%' }, _('Total Messages')),
				E('td', { 'class': 'td' }, String(messages.length))
			])
		]);
		
		summaryTable.appendChild(summaryBody);
		summaryFieldset.appendChild(summaryTable);
		summaryDiv.appendChild(summaryFieldset);
		messagesDiv.appendChild(summaryDiv);

		// Add action buttons
		var buttonDiv = E('div', { 'class': 'cbi-page-actions' });
		
		var refreshBtn = E('button', {
			'class': 'cbi-button cbi-button-action',
			'click': L.bind(function(ev) {
				ev.preventDefault();
				var loading = E('div', { 'class': 'spinning' }, _('Loading...'));
				dom.content(contentArea, loading);
				this.loadSimSmsList(contentArea, loading, configSection);
			}, this)
		}, _('Refresh'));
		
		var deleteAllBtn = E('button', {
			'class': 'cbi-button cbi-button-remove',
			'click': L.bind(function(ev) {
				ev.preventDefault();
				this.handleDeleteAllSimSms(configSection, messages, result.storage, contentArea);
			}, this)
		}, _('Delete All'));
		
		buttonDiv.appendChild(refreshBtn);
		if (messages.length > 0) {
			buttonDiv.appendChild(deleteAllBtn);
		}
		messagesDiv.appendChild(buttonDiv);

		contentArea.appendChild(messagesDiv);
	},

	setDeleteBusy: function(busy, contentArea) {
		this.busy = busy;
		this.requestId = (this.requestId || 0) + 1;
		this.pendingLoad = false;
		this.modemSelect.disabled = busy;
		contentArea.querySelectorAll('button').forEach(function(button) { button.disabled = busy; });
	},

	handleDeleteSimSms: function(configSection, message, storage, contentArea) {
		return this.confirmDeleteSimSms(configSection, [ message ], storage, contentArea, false);
	},

	handleDeleteAllSimSms: function(configSection, messages, storage, contentArea) {
		return this.confirmDeleteSimSms(configSection, messages, storage, contentArea, true);
	},

	// Work from the confirmed snapshot, never from a later poll result.
	deleteSimSmsSnapshot: function(configSection, messages, storage) {
		var summary = { deleted: 0, absent: 0, failed: 0, errors: [] };
		return messages.reduce(function(chain, message) {
			return chain.then(function() {
				return smsService.deleteSimSms(configSection, storage, message).then(function(result) {
					if (result.deleted) summary.deleted++;
					if (result.already_absent) summary.absent++;
					if (!result.success) {
						summary.failed++;
						summary.errors.push(result.error || _('Failed to delete message'));
					}
				}).catch(function(err) {
					summary.failed++;
					summary.errors.push(err.message);
				});
			});
		}, Promise.resolve()).then(function() { return summary; });
	},

	confirmDeleteSimSms: function(configSection, messages, storage, contentArea, all) {
		var self = this;
		if (this.busy || this.modemSelect.value !== configSection) return;
		if (!messages || messages.length === 0) {
			ui.addNotification(null, E('p', _('No messages to delete')), 'info');
			return;
		}
		var snapshot = messages.map(function(message) { return { index: message.index, pdu: message.pdu }; });
		var started = false;
		this.setDeleteBusy(true, contentArea);
		ui.showModal(all ? _('Confirm Delete All') : _('Confirm Delete'), [
			E('p', all
				? _('Delete all %d listed messages from module storage? Archived messages will be kept.').format(snapshot.length)
				: _('Delete this message from module storage? Archived messages will be kept.')),
			E('div', { 'class': 'right' }, [
				E('button', {
					'class': 'cbi-button cbi-button-neutral',
					'click': function() {
						if (started) return;
						ui.hideModal();
						self.setDeleteBusy(false, contentArea);
					}
				}, _('Cancel')),
				' ',
				E('button', {
					'class': 'cbi-button cbi-button-negative',
					'click': function() {
						if (started) return;
						started = true;
						ui.showModal(_('Deleting...'), E('div', { 'class': 'spinning' }, _('Deleting messages...')));
						return self.deleteSimSmsSnapshot(configSection, snapshot, storage).then(function(summary) {
							var details = [ E('p', _('%d deleted, %d already absent, %d failed.').format(
								summary.deleted, summary.absent, summary.failed)) ];
							if (summary.errors.length) details.push(E('p', summary.errors.join('; ')));
							ui.addNotification(null, E('div', details), summary.failed ? 'warning' : 'info');
						}).finally(function() {
							ui.hideModal();
							self.setDeleteBusy(false, contentArea);
							return self.loadSimSmsList(contentArea, null, configSection);
						});
					}
				}, all ? _('Delete All') : _('Delete'))
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
