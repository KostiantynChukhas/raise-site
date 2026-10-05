# Raise content catalog

Static word database served from a CDN. The app downloads `manifest.json`, then any pack whose `version` is newer than
what it has, and caches everything offline. **Adding words = editing JSON and pushing.** No app release needed.

## Layout
```
content/
  manifest.json          # built by tools/build_manifest.py — never edit by hand
  packs/<topic>-<level>.json
  tools/generate_pack.py # Claude API generator (all 10 languages at once)
  tools/build_manifest.py
```

## Pack format
```json
{ "id": "travel-a1", "topic": "travel", "level": "a1", "version": 1,
  "concepts": [
    { "id": "travel.boarding-pass",
      "t":  { "en": "boarding pass", "uk": "посадковий талон", "pl": "karta pokładowa", "...": "..." },
      "ex": { "en": "Show your boarding pass at the gate.", "uk": "...", "...": "..." } }
  ] }
```
A *concept* is one meaning with its word in every language, so any pair (learn ↔ speak) is two lookups:
uk→en, fr→en, en→fr, uk→pl… If a language is missing for a concept, that concept is simply hidden for pairs that need it.

Topics: general, travel, food, work, it, business, health, shopping, home, family, emotions, education, finance,
transport, nature, sports, culture, relationships, emergency, phrases. Levels: a1–c1. 24–48 concepts per pack is ideal
(a watch face holds 24).

## Generating the big database
```
export ANTHROPIC_API_KEY=sk-ant-…
python3 tools/generate_pack.py --all --count 40     # 20 topics × 5 levels ≈ 4 000 concepts × 10 languages
python3 tools/build_manifest.py
git add -A && git commit -m "content: +packs" && git push
```
Review a sample of each pack with a native speaker before marking it premium — machine translation of idioms is where quality slips.
Bump a pack's `version` whenever you change it (the generator does this automatically on regeneration).

## Hosting
Any static host works. Easiest: a public GitHub repo with Pages enabled on `/content` → `https://<user>.github.io/<repo>/`.
Put that URL into `AppConfig.contentBaseURLString`. For scale, front it with Cloudflare (free) — files are ~20–60 KB each.
