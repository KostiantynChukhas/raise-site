// Adds 2 context sentences per concept, in all catalog languages, to content/packs/*.json (field "exs").
// Usage (from raise-site/):  OPENAI_API_KEY=sk-... node tools/gen-examples.mjs [packId ...]
// Resumable: concepts that already have 2 sentences are skipped. Bumps pack + manifest versions so the app re-syncs.
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../content");
const KEY = process.env.OPENAI_API_KEY;
const MODEL = process.env.OPENAI_MODEL || "gpt-4o-mini";
const BATCH = 10, CONCURRENCY = 4;
if (!KEY) { console.error("Set OPENAI_API_KEY"); process.exit(1); }

const manifest = JSON.parse(await fs.readFile(path.join(ROOT, "manifest.json"), "utf8"));
const LANGS = manifest.languages;
const ALT = process.argv.includes("--alt");
const only = process.argv.slice(2).filter(a => !a.startsWith("--"));

async function ask(level, items) {
  const prompt = `You write short, natural example sentences for a vocabulary app. CEFR level: ${level.toUpperCase()}.
For EACH item:
1) Only for items with "single": true: in "t", if a word in some language has a second common translation for the SAME meaning, return it as "main, second" (max 2 variants, keep the original first, never change "en" unless it also has a common synonym). For items with "single": false (phrases) return "t" exactly unchanged. Otherwise return it unchanged.
2) Write exactly 2 different everyday sentences (max 12 words) that use the given word/phrase in the given meaning.
Give each sentence in all these languages: ${LANGS.join(", ")}. In each language use that language's word from "t". Translations must be faithful.
Return JSON: {"items":[{"id":"...","t":{${LANGS.map(l => `"${l}":"..."`).join(",")}},"exs":[{${LANGS.map(l => `"${l}":"..."`).join(",")}},{...}]}]}
Items: ${JSON.stringify(items.map(c => ({ id: c.id, single: isSingle(c), t: c.t })))}`;
  for (let attempt = 1; attempt <= 4; attempt++) {
    try {
      const r = await fetch("https://api.openai.com/v1/chat/completions", {
        method: "POST",
        headers: { "content-type": "application/json", authorization: `Bearer ${KEY}` },
        body: JSON.stringify({ model: MODEL, temperature: 0.5, response_format: { type: "json_object" },
          messages: [{ role: "user", content: prompt }] }),
      });
      if (!r.ok) throw new Error(`${r.status} ${(await r.text()).slice(0, 200)}`);
      const j = await r.json();
      return JSON.parse(j.choices[0].message.content).items || [];
    } catch (e) { console.warn(`  retry ${attempt}: ${e.message}`); await new Promise(s => setTimeout(s, 2000 * attempt)); }
  }
  return [];
}

// Single word ("hope", "to hope") — phrases like "to get to work" never get a second translation.
const isSingle = c => !/\s/.test((c.t.en || "").trim().replace(/^to\s+/i, ""));
const valid = ex => Array.isArray(ex) && ex.length >= 2 && ex.slice(0, 2).every(d => LANGS.every(l => typeof d?.[l] === "string" && d[l].trim()));

for (const p of manifest.packs) {
  if (only.length && !only.includes(p.id)) continue;
  const file = path.join(ROOT, p.url);
  const pack = JSON.parse(await fs.readFile(file, "utf8"));
  const todo = pack.concepts.filter(c => ALT ? !c._alt : !valid(c.exs));
  if (!todo.length) { console.log(`${p.id}: done`); continue; }
  console.log(`${p.id}: ${todo.length} concepts`);
  const batches = [];
  for (let i = 0; i < todo.length; i += BATCH) batches.push(todo.slice(i, i + BATCH));
  let changed = 0;
  for (let i = 0; i < batches.length; i += CONCURRENCY) {
    const res = await Promise.all(batches.slice(i, i + CONCURRENCY).map(b => ask(pack.level, b)));
    for (const it of res.flat()) {
      const c = pack.concepts.find(x => x.id === it.id);
      if (c && valid(it.exs)) {
        c.exs = it.exs.slice(0, 2).map(d => Object.fromEntries(LANGS.map(l => [l, d[l].trim()])));
        if (ALT && it.t && isSingle(c)) for (const l of LANGS) {
          const v = (it.t[l] || "").trim(), orig = c.t[l] || "";
          // accept only "original, synonym" — never a different main word
          if (orig && v.startsWith(orig + ",") && v.split(",").length === 2) c.t[l] = v.replace(/\s*,\s*/, ", ");
        }
        if (ALT) c._alt = 1;
        changed++;
      }
    }
    process.stdout.write(`  ${Math.min(i + CONCURRENCY, batches.length)}/${batches.length}\r`);
  }
  if (changed) {
    pack.version += 1; p.version = pack.version;
    await fs.writeFile(file, JSON.stringify(pack, null, 1) + "\n");
    manifest.version += 1; manifest.updatedAt = new Date().toISOString();
    await fs.writeFile(path.join(ROOT, "manifest.json"), JSON.stringify(manifest, null, 1) + "\n");
  }
  console.log(`\n  +${changed} (${todo.length - changed} left, rerun to retry)`);
}
