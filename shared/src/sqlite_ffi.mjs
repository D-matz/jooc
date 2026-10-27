import { Ok, Error } from "./gleam.mjs";

export async function open(bits) {
  let worker;
  try {
    worker = new Worker("/sqlite-loader.js");
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

async function execute(db, sql, read) {
  try {
    const response = await db.promiser({
      type: "exec",
      dbId: db.dbId,
      args: {
        sql,
        rowMode: "array",
        resultRows: read ? [] : undefined
      }
    });
    return new Ok(read ? response.result.resultRows : undefined);
  } catch (e) {
    return new Error(e?.result?.message ?? String(e));
  }
}

export const exec = (db, sql) => execute(db, sql, false);
export const query = (db, sql) => execute(db, sql, true);
