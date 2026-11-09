import { Ok, Error, BitArray } from "./gleam.mjs";

const CACHE_NAME = "sqlite-db";
const KEY = "/data.sqlite";

export async function check_cached_etag() {
  try {
    const cache = await caches.open(CACHE_NAME);
    const response = await cache.match(KEY);
    const etag = response?.headers.get("x-etag");
    return etag ? new Ok(etag) : new Error(undefined);
  } catch {
    return new Error(undefined);
  }
}

export async function load_cached() {
  try {
    const cache = await caches.open(CACHE_NAME);
    const response = await cache.match(KEY);
    if (!response) return new Error(undefined);
    const bytes = new Uint8Array(await response.arrayBuffer());
    return new Ok(new BitArray(bytes));
  } catch {
    return new Error(undefined);
  }
}

export async function save_cached(etag, bits) {
  try {
    const cache = await caches.open(CACHE_NAME);
    await cache.put(
      KEY,
      new Response(bits.rawBuffer, { headers: { "x-etag": etag } })
    );
    return new Ok(undefined);
  } catch (e) {
    return new Error(String(e));
  }
}

export async function open(bits) {
  let worker;
  try {
    worker = new Worker("/static/jooc/sqlite-loader.js");
    const failed = new Promise((_, reject) => {
      worker.onerror = e => reject(e.message);
    });
    const loading = globalThis.sqlite3Worker1Promiser.v2({ worker });

    worker.postMessage(bits.rawBuffer);
    const promiser = await Promise.race([loading, failed]);
    const { dbId } = await promiser("open", { filename: "/data.sqlite" });
    return new Ok({ promiser, dbId });
  } catch (e) {
    worker?.terminate();
    return new Error(e?.result?.message ?? String(e));
  }
}

export async function query(db, sql, bind) {
  try {
    const response = await db.promiser({
      type: "exec",
      dbId: db.dbId,
      args: {
        sql,
        bind: bind.toArray(), // Gleam List -> JS array
        rowMode: "array",
        resultRows: []
      }
    });
    return new Ok(response.result.resultRows);
  } catch (e) {
    return new Error(e?.result?.message ?? String(e));
  }
}