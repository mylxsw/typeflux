// Queries and identifiers arrive as arguments, never as executable source.
// Filtering runs in the owning application; bodies are returned only for an explicit preview.
function run(argv) {
    var operation = argv[0], kind = argv[1], query = argv[2] || '';
    var limit = 30, bodyLimit = 50000;
    if (kind !== 'notes') throw new Error('Invalid application');
    var app = Application('com.apple.Notes');
    var collection = app.notes;
    function date(value) {
        if (!value) return null;
        var milliseconds = new Date(value).getTime();
        return isFinite(milliseconds) ? milliseconds / 1000 : null;
    }
    function clip(value, count) {
        if (value.length > count && value.charCodeAt(count - 1) >= 0xD800 && value.charCodeAt(count - 1) <= 0xDBFF) count--;
        return value.slice(0, count);
    }
    function row(item, withBody) {
        var locked = item.passwordProtected();
        var body = withBody && !locked ? String(item.plaintext()) : '';
        return {
            id: String(item.id()), title: withBody ? String(item.name()) : clip(String(item.name()), 300),
            container: clip(String(item.container().name()), 200),
            modified: date(item.modificationDate()), due: null, alarm: null, completed: false,
            locked: locked, body: clip(body, bodyLimit), truncated: body.length > bodyLimit
        };
    }
    if (operation === 'read' || operation === 'open') {
        var selected = collection.byId(query);
        if (!selected.exists()) return JSON.stringify({error: 'missing'});
        if (operation === 'open') {
            app.show(selected);
            app.activate();
            return JSON.stringify({opened: true});
        }
        return JSON.stringify({item: row(selected, true)});
    }
    if (operation !== 'search') throw new Error('Invalid operation');
    var scoped = query ? collection.whose({_or: [
        {name: {_contains: query}},
        {_and: [{passwordProtected: false}, {plaintext: {_contains: query}}]}
    ]}, {ignoring: 'case'}) : collection;
    var ids = scoped.id(), dates = scoped.modificationDate();
    if (ids.length !== dates.length || JSON.stringify(ids) !== JSON.stringify(scoped.id())) {
        return JSON.stringify({error: 'changed'});
    }
    var candidates = ids.map(function(id, index) { return {id: id, date: date(dates[index])}; });
    candidates.sort(function(a, b) { return (b.date || 0) - (a.date || 0); });
    var items = [];
    for (var position = 0; position < Math.min(limit, candidates.length); position++) {
        var target = collection.byId(candidates[position].id);
        if (!target.exists()) return JSON.stringify({error: 'changed'});
        items.push(row(target, false));
    }
    return JSON.stringify({items: items, total: candidates.length, hasMore: candidates.length > limit});
}
