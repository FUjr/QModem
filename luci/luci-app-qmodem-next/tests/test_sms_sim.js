'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const source = fs.readFileSync(path.join(__dirname,
    '../htdocs/luci-static/resources/view/qmodem/sms_sim.js'), 'utf8');
String.prototype.format = function(...args) {
    return this.replace(/%[ds]/g, () => String(args.shift()));
};
const tick = () => new Promise(resolve => setImmediate(resolve));
const deferred = () => {
    let resolve, reject;
    const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
    return { promise, resolve, reject };
};

function element(tag, attrs, children) {
    if (attrs == null || typeof attrs !== 'object' || Array.isArray(attrs) || attrs.tag) {
        children = attrs;
        attrs = {};
    }
    const node = { tag, attrs, children: [], disabled: false, value: '', listeners: {},
        appendChild(child) {
            this.children.push(child);
            if (child && typeof child === 'object') child.parentNode = this;
            if (this.tag === 'select' && !this.value) this.value = child.attrs.value;
        },
        addEventListener(name, fn) { this.listeners[name] = fn; },
        querySelectorAll(name) {
            return this.children.flatMap(child => child && child.tag
                ? (child.tag === name ? [child] : []).concat(child.querySelectorAll(name)) : []);
        }
    };
    for (const child of Array.isArray(children) ? children : children == null ? [] : [children]) node.appendChild(child);
    return node;
}
function text(node) {
    return typeof node === 'string' ? node : (node.children || []).map(text).join(' ');
}
function harness() {
    const reads = [], deletes = [], notifications = [], polls = [];
    let modal;
    const service = {
        getSimSms(modem) {
            const pending = deferred();
            reads.push({ modem, ...pending });
            return pending.promise;
        },
        deleteSimSms(modem, storage, message) {
            const pending = deferred();
            deletes.push({ modem, storage, message, ...pending });
            return pending.promise;
        },
        formatPhoneNumber: value => value,
        formatTimestamp: String,
        truncateMessage: value => value
    };
    const ui = {
        showModal(title, children) { modal = element('div', {}, children); },
        hideModal() { modal = null; },
        addNotification(_, node, level) { notifications.push({ text: text(node), level }); }
    };
    const dom = { content(node, children) {
        node.children = [];
        for (const child of Array.isArray(children) ? children : children == null ? [] : [children]) node.appendChild(child);
    } };
    const L = { resource: String, bind: (fn, self, ...args) => fn.bind(self, ...args) };
    const view = new Function('view', 'poll', 'ui', 'dom', 'smsService', 'qmodem', 'document', 'L', 'E', '_', source)(
        { extend: value => value }, { add: callback => polls.push(callback) }, ui, dom, service,
        {}, { head: element('head') }, L, element, value => value);
    const root = view.render([
        { id: 'modem_1', enabled: true, name: 'One' }, { id: 'modem_2', enabled: true, name: 'Two' }
    ]);
    const content = root.children.find(n => n.attrs.id === 'sms-sim-content');
    const button = (container, label) => container.querySelectorAll('button').find(n => text(n) === label);
    return { view, root, content, reads, deletes, notifications, polls, button, modal: () => modal };
}
const raw = messages => ({ storage: 'ME', mode: 'database_urc', auto_delete: true, messages });

async function testStaleReads() {
    const h = harness();
    h.view.modemSelect.value = 'modem_2';
    h.view.modemSelect.listeners.change();
    assert.strictEqual(h.reads.length, 2);
    h.reads[1].resolve(raw([{ index: 2, pdu: '0022', content: 'second modem' }]));
    await tick();
    h.reads[0].resolve(raw([{ index: 0, pdu: '0000', content: 'stale first modem' }]));
    await tick();
    assert(text(h.content).includes('second modem'));
    assert(!text(h.content).includes('stale first modem'));
    assert(text(h.content).includes('Current reading storage: ME'));
    assert(text(h.content).includes('Automatic removal after archiving'));
    const pending = h.polls[0]();
    await h.polls[0]();
    assert.strictEqual(h.reads.length, 3, 'do not overlap polling requests');
    h.reads[2].reject(new Error('CPMS failed'));
    await pending;
    assert(text(h.content).includes('CPMS failed'), 'poll failures must be visible');
}

async function testSnapshotDelete() {
    const h = harness();
    const messages = [0, 7, 9, 10].map(index => ({ index, pdu: '00AB', content: 'raw ' + index }));
    h.reads[0].resolve(raw(messages)); await tick();
    h.button(h.content, 'Delete All').attrs.click({ preventDefault() {} });
    assert(h.view.busy && h.view.modemSelect.disabled);
    assert(h.content.querySelectorAll('button').every(b => b.disabled));
    await h.polls[0]();
    assert.strictEqual(h.reads.length, 1, 'polling is paused during confirmation/deletion');
    messages.push({ index: 99, pdu: '0099', content: 'arrived later' });
    const confirm = h.button(h.modal(), 'Delete All');
    const deleting = confirm.attrs.click();
    confirm.attrs.click();
    await tick();
    assert.strictEqual(h.deletes.length, 1, 'duplicate confirm must not duplicate deletion');
    h.deletes[0].resolve({ success: true, deleted: 1 }); await tick();
    assert.strictEqual(h.deletes.length, 2, 'deletions must be sequential');
    h.deletes[1].resolve({ success: true, already_absent: true }); await tick();
    h.deletes[2].resolve({ success: false, error: 'message changed' }); await tick();
    h.deletes[3].reject(new Error('AT failed')); await tick();
    assert.strictEqual(h.reads.length, 2, 'reload after mixed success/failure');
    h.reads[1].resolve(raw([{ index: 99, pdu: '0099', content: 'arrived later' }]));
    await deleting;
    assert.deepStrictEqual(h.deletes.map(d => d.message.index), [0, 7, 9, 10]);
    assert(h.deletes.every(d => d.modem === 'modem_1' && d.storage === 'ME' && d.message.pdu === '00AB'));
    assert.strictEqual(h.notifications[0].level, 'warning');
    assert(h.notifications[0].text.includes('1 deleted, 1 already absent, 2 failed.'));
    assert(h.notifications[0].text.includes('message changed'));
    assert(h.notifications[0].text.includes('AT failed'));
    assert(!h.view.busy && !h.view.modemSelect.disabled);
    assert(text(h.content).includes('arrived later'));
}

async function testCancelAndPendingPoll() {
    const h = harness();
    h.reads[0].resolve(raw([{ index: 0, pdu: '00AB', content: 'current' }])); await tick();
    const poll = h.polls[0]();
    h.button(h.content, 'Delete').attrs.click();
    h.reads[1].resolve(raw([])); await poll;
    assert(text(h.content).includes('current'), 'in-flight polling must not replace a confirmed snapshot');
    h.button(h.modal(), 'Cancel').attrs.click();
    assert(!h.view.busy && !h.view.modemSelect.disabled);
    assert.strictEqual(h.deletes.length, 0);
    h.button(h.content, 'Delete').attrs.click();
    const deleting = h.button(h.modal(), 'Delete').attrs.click(); await tick();
    h.deletes[0].resolve({ success: false, deleted: 1, error: 'metadata update failed' }); await tick();
    h.reads[2].resolve(raw([])); await deleting;
    assert(h.notifications[0].text.includes('1 deleted, 0 already absent, 1 failed.'));
    assert(h.notifications[0].text.includes('metadata update failed'));
    assert(text(h.content).includes('No messages found in module storage'));
}

(async () => {
    await testStaleReads();
    await testSnapshotDelete();
    await testCancelAndPendingPoll();
    console.log('PASS: module SMS view polling, modem switching, snapshot deletion and partial failures');
})().catch(error => { console.error(error); process.exit(1); });
