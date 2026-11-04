// Converts the open-source Fig autocomplete specs (withfig/autocomplete) into
// Anser's JSON spec format. Keeps names, descriptions, subcommands, options,
// args, static suggestions, file/folder templates and plain script generators.
// Drops JavaScript-only logic (custom generators, postProcess functions).
//
// NOTE: this imports (runs) the spec modules from the npm package, which is
// third-party code. Run it yourself after reviewing:
//   mkdir -p .build/fig && (cd .build/fig && npm pack @withfig/autocomplete && tar xzf withfig-autocomplete-*.tgz)
//   node scripts/import-fig-specs.mjs .build/fig/package Sources/AnserCore/Specs/fig
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const [pkg, out] = process.argv.slice(2);
if (!pkg || !out) {
  console.error("usage: node scripts/import-fig-specs.mjs <package-dir> <out-dir>");
  process.exit(1);
}
const buildDir = path.join(pkg, "build");
fs.rmSync(out, { recursive: true, force: true });
fs.mkdirSync(out, { recursive: true });

const arr = (v) => (v === undefined || v === null ? [] : Array.isArray(v) ? v : [v]);
const clean = (o) => Object.fromEntries(Object.entries(o).filter(([, v]) => v !== undefined && !(Array.isArray(v) && v.length === 0) && v !== false));
const desc = (d) => (typeof d === "string" && d.length ? d.replace(/\s+/g, " ").slice(0, 160) : undefined);
const shellQuote = (s) => (/^[\w@%+=:,./-]+$/.test(s) ? s : `'${s.replace(/'/g, `'\\''`)}'`);

function generator(g) {
  if (!g || typeof g !== "object") return undefined;
  if (g.template) return { template: arr(g.template) };
  // Only scripts whose output is used line by line, unchanged.
  if (g.postProcess || g.custom || typeof g.script === "function") return undefined;
  if (g.splitOn !== undefined && g.splitOn !== "\n") return undefined;
  let script;
  if (typeof g.script === "string") script = g.script;
  else if (Array.isArray(g.script) && g.script.every((x) => typeof x === "string")) script = g.script.map(shellQuote).join(" ");
  if (!script) return undefined;
  return { script, cacheSeconds: 5 };
}

function arg(a) {
  if (!a || typeof a !== "object") return undefined;
  const suggestions = [];
  for (const s of arr(a.suggestions)) {
    if (typeof s === "string") suggestions.push(s);
    else if (s && typeof s === "object") {
      for (const n of arr(s.name)) {
        if (typeof n === "string") suggestions.push(desc(s.description) ? { name: n, description: desc(s.description) } : n);
      }
    }
  }
  const template = arr(a.template).filter((t) => t === "filepaths" || t === "folders");
  const generators = [];
  for (const g of arr(a.generators)) {
    const c = generator(g);
    if (!c) continue;
    if (c.template) template.push(...c.template.filter((t) => t === "filepaths" || t === "folders"));
    else generators.push(c);
  }
  return clean({
    name: typeof a.name === "string" ? a.name : undefined,
    description: desc(a.description),
    suggestions: suggestions.slice(0, 300),
    template: [...new Set(template)],
    generators,
    isVariadic: a.isVariadic === true || undefined,
    isOptional: a.isOptional === true || undefined,
    isCommand: a.isCommand === true || a.isScript === true || undefined,
  });
}

function option(o) {
  const names = arr(o.name).filter((n) => typeof n === "string");
  if (!names.length) return undefined;
  return clean({
    name: names.length === 1 ? names[0] : names,
    description: desc(o.description),
    args: arr(o.args).map(arg).filter(Boolean),
    isPersistent: o.isPersistent === true || undefined,
    isRepeatable: o.isRepeatable ? true : undefined,
  });
}

function spec(s, depth = 0) {
  if (!s || typeof s !== "object" || depth > 12) return undefined;
  const names = arr(s.name).filter((n) => typeof n === "string");
  if (!names.length) return undefined;
  return clean({
    name: names.length === 1 ? names[0] : names,
    description: desc(s.description),
    subcommands: arr(s.subcommands).map((x) => spec(x, depth + 1)).filter(Boolean),
    options: arr(s.options).map(option).filter(Boolean),
    args: arr(s.args).map(arg).filter(Boolean),
  });
}

const index = {};
let ok = 0, skipped = 0;
for (const file of fs.readdirSync(buildDir).sort()) {
  if (!file.endsWith(".js") || file.startsWith("-")) continue;
  try {
    const mod = await import(pathToFileURL(path.join(buildDir, file)).href);
    const converted = spec(mod.default);
    if (!converted) { skipped++; continue; }
    const name = file.slice(0, -3);
    fs.writeFileSync(path.join(out, `${name}.json`), JSON.stringify(converted));
    for (const n of arr(converted.name)) index[n] = { file: name, description: converted.description ?? "" };
    ok++;
  } catch {
    skipped++;
  }
}
fs.writeFileSync(path.join(out, "index.json"), JSON.stringify(index));
fs.copyFileSync(path.join(pkg, "LICENSE"), path.join(out, "LICENSE"));
console.log(`converted ${ok} specs, skipped ${skipped}`);
