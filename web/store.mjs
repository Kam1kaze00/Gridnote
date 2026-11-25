import { validate, kind } from "./engine.mjs";

const database = new Promise((resolve, reject) => {
  const open = indexedDB.open("gridnote-notebooks", 1);
  open.onupgradeneeded = () => {
    for (const key of ["books", "recovery", "assets", "state"])
      open.result.createObjectStore(key);
  };
  open.onsuccess = () => resolve(open.result);
  open.onerror = () => reject(open.error);
});
const request = (r) =>
  new Promise((resolve, reject) => {
    r.onsuccess = () => resolve(r.result);
    r.onerror = () => reject(r.error);
  });
const finish = (tx) =>
  new Promise((resolve, reject) => {
    tx.oncomplete = resolve;
    tx.onerror = () => reject(tx.error);
    tx.onabort = () => reject(tx.error || Error("Save interrupted."));
  });
async function get(store, key) {
  const db = await database;
  return request(db.transaction(store).objectStore(store).get(key));
}
export const loadState = (key) => get("state", key);
export async function saveState(key, value) {
  const db = await database,
    tx = db.transaction("state", "readwrite");
  tx.objectStore("state").put(value, key);
  await finish(tx);
}
const known = new Set();
function assetKey(id, field) {
  return id + "/" + field;
}
export async function saveRecord(book, title, previousRevision) {
  const db = await database,
    tx = db.transaction(["books", "recovery", "assets", "state"], "readwrite");
  const done = finish(tx);
  const record = { ...book },
    pending = new Set();
  const saveAsset = (key, data) => {
    if (!known.has(key)) {
      tx.objectStore("assets").put(data, key);
      pending.add(key);
    }
    return key;
  };
  if (record.sourcePDF) {
    record.pdfRef = saveAsset(assetKey(book.id, "pdf"), record.sourcePDF);
    delete record.sourcePDF;
  }
  record.objects = book.objects.map((o) =>
    kind(o) !== "image"
      ? o
      : {
          ...o,
          content: {
            image: {
              ref: saveAsset(assetKey(book.id, o.id), o.content.image._0),
            },
          },
        },
  );
  const files = tx.objectStore("books");
  const prior = await request(files.get(book.id));
  if (prior && prior.book.revision !== previousRevision) {
    tx.abort();
    try {
      await done;
    } catch {}
    throw Error(
      "This notebook was changed in another window. Download an editable copy before reopening it.",
    );
  }
  if (prior) tx.objectStore("recovery").put(prior, book.id);
  files.put({ book: record, title, updated: Date.now() }, book.id);
  tx.objectStore("state").put(book.id, "last");
  await done;
  for (const key of pending) known.add(key);
  return book.revision;
}
async function expand(record) {
  if (!record) return null;
  const book = { ...record.book };
  if (book.pdfRef) {
    book.sourcePDF = await get("assets", book.pdfRef);
    if (!book.sourcePDF) throw Error("Missing PDF");
    known.add(book.pdfRef);
    delete book.pdfRef;
  }
  book.objects = await Promise.all(
    book.objects.map(async (o) => {
      const ref = o.content.image?.ref;
      if (!ref) return o;
      const data = await get("assets", ref);
      if (!data) throw Error("Missing image");
      known.add(ref);
      return { ...o, content: { image: { _0: data } } };
    }),
  );
  return { ...record, book: validate(book) };
}
export async function loadRecord(id) {
  const current = await get("books", id);
  try {
    return await expand(current);
  } catch (error) {
    const backup = await expand(await get("recovery", id));
    if (!backup) throw error;
    return {
      ...backup,
      recovered: true,
      storedRevision: current.book.revision,
    };
  }
}
export async function library() {
  const db = await database,
    dbtx = db.transaction("books");
  const list = await request(dbtx.objectStore("books").getAll());
  return list
    .map((x) => ({ title: x.title, id: x.book.id, updated: x.updated }))
    .sort((a, b) => b.updated - a.updated);
}
