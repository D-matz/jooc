importScripts("sqlite3.js");

self.onmessage = async ({ data: bytes }) => {
  try {
    const sqlite3 = await sqlite3InitModule();
    sqlite3.capi.sqlite3_js_posix_create_file("/data.sqlite", bytes);
    sqlite3.initWorker1API();
  } catch (e) {
    setTimeout(() => { throw e; });
  }
};
