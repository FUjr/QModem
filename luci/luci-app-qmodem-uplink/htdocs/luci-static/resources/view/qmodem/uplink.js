'use strict';
'require view';
'require form';
'require rpc';
'require uci';
'require poll';

const status = rpc.declare({ object: 'qmodem.uplink', method: 'status', expect: {} });
return view.extend({
    load() { return Promise.all([uci.load('qmodem_uplink'), uci.load('network'), uci.load('qmodem'), status()]); },
    render(data) {
        const m = new form.Map('qmodem_uplink', _('Uplink Balancing'),
            _('Distribute new IPv4 connections across WAN and cellular uplinks. Each connection keeps its exit. Software forwarding is used while enabled. Disable mwan3 before enabling this manager.'));
        const note = E('div', {class: 'alert-message'});
        const update = s => {
            note.replaceChildren(E('p', {}, [!s.enabled ? _('Disabled') :
                s.reason ? `${_('Not applied')}: ${s.reason}` : s.config_generation !== s.applied_generation ? _('Policy pending') : _('Policy applied')]),
                ...((s.members || []).map(row => E('p', {}, [`${row.id}: ${row.health?.healthy ? _('Healthy') : _('Unavailable')}, ${row.selected ? _('Participating') : _('Standby')}, ${_('Effective weight')}: ${row.effective_weight || 0} (${row.reason})`]))));
        };
        update(data[3]); poll.add(() => status().then(update), 5);
        let s = m.section(form.NamedSection, 'main', 'manager');
        s.option(form.Flag, 'enabled', _('Enable manager')).rmempty = false;
        let o = s.option(form.ListValue, 'mode', _('Mode'));
        o.value('balance', _('Load balancing')); o.value('failover', _('Failover')); o.default = 'balance';
        for (const [key, label, value, type] of [
            ['interval', 'Probe interval (s)', '10', 'range(1,300)'], ['timeout', 'Probe timeout (s)', '2', 'range(1,10)'],
            ['fail_threshold', 'Failures before removal', '3', 'range(1,30)'], ['recover_threshold', 'Successes before recovery', '3', 'range(1,30)'],
            ['stable_seconds', 'Recovery stability (s)', '60', 'range(0,3600)']]) {
            o = s.option(form.Value, key, _(label)); o.default = value; o.datatype = type; o.rmempty = false;
        }
        o = s.option(form.DynamicList, 'targets', _('Probe targets')); o.datatype = 'ip4addr'; o.rmempty = false;
        const candidates = [];
        uci.sections('network', 'interface').filter(n => !['lan', 'loopback'].includes(n['.name']) && !n.modem_config && n.proto !== 'none').forEach(n => candidates.push(['wired', n['.name']]));
        uci.sections('qmodem', 'modem-device').forEach(n => candidates.push(['modem', n['.name']]));
        const targets = [...new Set([...candidates.map(([k,t]) => `${k}:${t}`), ...uci.sections('qmodem_uplink', 'member').map(n => `${n.kind}:${n.target}`)])];
        s = m.section(form.GridSection, 'member', _('Uplinks'), _('Lower priority values win; healthy members at the same priority share new connections by weight. Keep offline members to preserve their configuration.'));
        s.addremove = true; s.anonymous = true;
        o = s.option(form.Flag, 'enabled', _('Enabled')); o.default = '1'; o.rmempty = false;
        o = s.option(form.ListValue, 'kind', _('Type')); o.value('wired', _('WAN')); o.value('modem', _('Cellular'));
        o = s.option(form.Value, 'target', _('Interface or modem instance')); candidates.forEach(([,t]) => o.value(t)); o.rmempty = false; o.datatype = 'uciname';
        o = s.option(form.Value, 'priority', _('Priority')); o.default = '10'; o.datatype = 'range(1,65535)'; o.rmempty = false;
        o = s.option(form.Value, 'weight', _('Weight')); o.default = '1'; o.datatype = 'range(1,255)'; o.rmempty = false;
        s = m.section(form.GridSection, 'rule', _('Fixed exit rules'), _('First matching rule wins. An unavailable fixed exit blocks matching connections. Rules affect new connections.'));
        s.addremove = true; s.anonymous = true; s.sortable = true;
        o = s.option(form.Flag, 'enabled', _('Enabled')); o.default = '1'; o.rmempty = false;
        for (const [key, label] of [['src','Source IPv4/CIDR'], ['dest','Destination IPv4/CIDR']]) {
            o = s.option(form.Value,key,_(label)); o.datatype='or(ip4addr,cidr4)';
        }
        o = s.option(form.ListValue, 'proto', _('Protocol')); ['all','tcp','udp','icmp'].forEach(p => o.value(p)); o.default='all';
        for (const [key, label] of [['src_port','Source port'],['dest_port','Destination port']]) {
            o = s.option(form.Value,key,_(label)); o.datatype='range(1,65535)'; o.depends('proto','tcp'); o.depends('proto','udp');
        }
        o=s.option(form.ListValue,'target',_('Fixed exit')); targets.forEach(t=>o.value(t)); o.rmempty=false;
        return m.render().then(node => E('div', {}, [note,node]));
    }
});
