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