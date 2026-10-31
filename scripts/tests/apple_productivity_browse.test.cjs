const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../../Sources/Typeflux/Resources/AppleProductivityBrowse.js'), 'utf8');

function fixture(rows, mutate = false) {
    let plaintextReads = 0, idReads = 0;
    const opened = [];
    const value = (row, key) => {
        if (key === 'plaintext' && row.locked) throw new Error('Locked content must not be read');
        if (key === 'plaintext') plaintextReads++;
        return ({name: row.title, passwordProtected: !!row.locked, plaintext: row.body || ''})[key];
    };
    function matches(row, predicate) {
        return Object.entries(predicate).every(([key, condition]) => {
            if (key === '_and') return condition.every(part => matches(row, part));
            if (key === '_or') return condition.some(part => matches(row, part));
            if (condition && typeof condition === 'object') {
                return String(value(row, key)).toLowerCase().includes(condition._contains.toLowerCase());
            }
            return value(row, key) === condition;
        });
    }
    function item(row) {
        return {exists: () => !!row, id: () => row.id, name: () => row.title,
            container: () => ({name: () => 'Work'}), passwordProtected: () => !!row.locked,
            plaintext: () => value(row, 'plaintext'),
            modificationDate: () => new Date((row.modified || 0) * 1000)};
    }
    function collection(selected) {
        return {id: () => (++idReads > 1 && mutate ? [] : selected.map(row => row.id)),
            modificationDate: () => selected.map(row => new Date((row.modified || 0) * 1000)),
            whose: predicate => collection(selected.filter(row => matches(row, predicate))),
            byId: id => item(selected.find(row => row.id === id))};
    }
    const all = collection(rows);
    const context = vm.createContext({Application: bundle => {
        assert.equal(bundle, 'com.apple.Notes');
        return {notes: all, show: target => opened.push(target.id()), activate: () => {}};
    }});
    vm.runInContext(source, context);
    return {run: args => JSON.parse(context.run(args)), opened, reads: () => plaintextReads};
}

test('full-text matching includes locked titles without reading locked bodies', () => {
    const app = fixture([{id: 'a', title: 'Alpha', body: 'Needle in the body', modified: 10},
        {id: 'b', title: 'NEEDLE locked', body: 'secret', locked: true, modified: 20},
        {id: 'c', title: 'Other', body: 'irrelevant', modified: 30}]);
    const result = app.run(['search', 'notes', 'needle', 'false']);
    assert.deepEqual(result.items.map(row => row.id), ['b', 'a']);
    assert.ok(result.items.every(row => row.body === ''));
    assert.equal(result.total, 2);
});

test('limits apply after searching the entire collection and report completeness', () => {
    const app = fixture(Array.from({length: 35}, (_, index) => ({id: String(index), title: 'Note ' + index, modified: index})));
    const list = app.run(['search', 'notes', '', 'false']);
    assert.equal(list.items.length, 30);
    assert.equal(list.total, 35);
    assert.equal(list.hasMore, true);
    assert.equal(list.items[0].id, '34');
    assert.equal(app.run(['search', 'notes', 'Note 0', 'false']).items[0].id, '0');
});

test('locked previews omit content and oversized Unicode remains valid', () => {
    const locked = fixture([{id: 'locked', title: 'Locked', locked: true, body: 'secret'}]);
    assert.equal(locked.run(['read', 'notes', 'locked']).item.body, '');
    assert.equal(locked.reads(), 0);
    const app = fixture([{id: 'long', title: 'Long', body: 'x'.repeat(49999) + '🙂tail'}]);
    const item = app.run(['read', 'notes', 'long']).item;
    assert.equal(item.body.length, 49999);
    assert.equal(item.truncated, true);
});

test('missing targets and changing snapshots never look like empty successful reads', () => {
    assert.equal(fixture([]).run(['read', 'notes', 'missing']).error, 'missing');
    assert.equal(fixture([{id: 'a', title: 'A'}], true).run(['search', 'notes', '', 'false']).error, 'changed');
});

test('preview and search never open apps; only the explicit open command does', () => {
    const app = fixture([{id: 'a', title: 'A', body: 'Body'}]);
    app.run(['read', 'notes', 'a']);
    app.run(['search', 'notes', '', 'false']);
    assert.deepEqual(app.opened, []);
    assert.equal(app.run(['open', 'notes', 'a']).opened, true);
    assert.deepEqual(app.opened, ['a']);
});
