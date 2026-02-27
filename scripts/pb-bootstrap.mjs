import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { fileURLToPath, pathToFileURL } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, "..");
const webNodeModulesPocketBase = path.join(
  repoRoot,
  "web",
  "node_modules",
  "pocketbase",
  "dist",
  "pocketbase.es.mjs"
);

let PocketBase;
try {
  ({ default: PocketBase } = await import("pocketbase"));
} catch {
  ({ default: PocketBase } = await import(pathToFileURL(webNodeModulesPocketBase).href));
}

const cwd = process.cwd();
const pbUrl = process.env.PB_URL || "http://127.0.0.1:8090";
const adminEmail = process.env.PB_EMAIL;
const adminPassword = process.env.PB_PASSWORD;
const schemaPath =
  process.env.PB_SCHEMA_PATH ||
  path.join(repoRoot, "pocketbase", "collections.example.json");

if (!adminEmail || !adminPassword) {
  console.error("Missing PB_EMAIL or PB_PASSWORD environment variables.");
  console.error("Example:");
  console.error("  PB_EMAIL=admin@example.com PB_PASSWORD=secret npm run pb:bootstrap");
  process.exit(1);
}

const pb = new PocketBase(pbUrl);

async function readSchema() {
  const raw = await fs.readFile(schemaPath, "utf8");
  const parsed = JSON.parse(raw);
  if (!Array.isArray(parsed)) {
    throw new Error("Schema file must contain a JSON array of collections");
  }
  return parsed;
}

async function authAdmin() {
  await pb.collection("_superusers").authWithPassword(adminEmail, adminPassword);
}

async function request(method, urlPath, body) {
  const res = await fetch(`${pbUrl}${urlPath}`, {
    method,
    headers: {
      Authorization: `Bearer ${pb.authStore.token}`,
      "Content-Type": "application/json"
    },
    body: body ? JSON.stringify(body) : undefined
  });

  const text = await res.text();
  let data = text;
  try {
    data = JSON.parse(text);
  } catch {
    // keep text
  }

  if (!res.ok) {
    throw new Error(`${method} ${urlPath} failed: ${res.status} ${res.statusText} ${typeof data === "string" ? data : JSON.stringify(data)}`);
  }

  return data;
}

async function listCollections() {
  const data = await request("GET", "/api/collections?perPage=200&page=1", undefined);
  return Array.isArray(data?.items) ? data.items : [];
}

async function upsertCollection(existingByName, schema) {
  const existing = existingByName.get(schema.name);
  const payload = {
    name: schema.name,
    type: schema.type || "base",
    fields: Array.isArray(schema.fields) ? schema.fields : [],
    listRule: schema.listRule ?? "",
    viewRule: schema.viewRule ?? "",
    createRule: schema.createRule ?? "",
    updateRule: schema.updateRule ?? "",
    deleteRule: schema.deleteRule ?? ""
  };

  if (!existing) {
    await request("POST", "/api/collections", payload);
    console.log(`created collection: ${schema.name}`);
    return;
  }

  await request("PATCH", `/api/collections/${existing.id}`, payload);
  console.log(`updated collection: ${schema.name}`);
}

async function main() {
  await authAdmin();
  const schema = await readSchema();
  const existing = await listCollections();
  const existingByName = new Map(existing.map((c) => [c.name, c]));

  for (const collection of schema) {
    await upsertCollection(existingByName, collection);
  }

  console.log(`PocketBase bootstrap complete against ${pbUrl}`);
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
});
