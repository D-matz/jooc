export function set_autodownload(value) {
  localStorage.setItem("sqlite-db-autodownload", value);
}

export function get_autodownload() {
  return localStorage.getItem("sqlite-db-autodownload") === "true";
}
