/// Local HTML runs in an opaque origin, where WebKit disables native Web Storage.
/// Keep the browser API available for this document without sharing or saving data.
enum AskPreviewStorage {
    static let script = """
    (() => {
      function createStorage() {
        const entries = new Map();
        const storage = {
          get length() { return entries.size; },
          key(index) { return Array.from(entries.keys())[Number(index) >>> 0] ?? null; },
          getItem(key) { return entries.get(String(key)) ?? null; },
          setItem(key, value) { entries.set(String(key), String(value)); },
          removeItem(key) { entries.delete(String(key)); },
          clear() { entries.clear(); }
        };
        for (const key of Object.keys(storage)) {
          Object.defineProperty(storage, key, { enumerable: false });
        }
        return new Proxy(storage, {
          get(target, key, receiver) {
            return Reflect.has(target, key) ? Reflect.get(target, key, receiver) : entries.get(key);
          },
          set(target, key, value, receiver) {
            if (typeof key !== 'string') return Reflect.set(target, key, value, receiver);
            entries.set(key, String(value));
            return true;
          },
          deleteProperty(target, key) {
            if (typeof key !== 'string') return Reflect.deleteProperty(target, key);
            entries.delete(key);
            return true;
          },
          has(target, key) {
            return Reflect.has(target, key) || entries.has(key);
          },
          ownKeys(target) {
            return [...Reflect.ownKeys(target), ...Array.from(entries.keys()).filter(key => !Reflect.has(target, key))];
          },
          getOwnPropertyDescriptor(target, key) {
            if (!Reflect.has(target, key) && entries.has(key)) {
              return { value: entries.get(key), writable: true, enumerable: true, configurable: true };
            }
            return Reflect.getOwnPropertyDescriptor(target, key);
          },
          preventExtensions() { return false; }
        });
      }
      for (const name of ['localStorage', 'sessionStorage']) {
        Object.defineProperty(window, name, { value: createStorage(), configurable: true, enumerable: true });
      }
    })();
    """
}
