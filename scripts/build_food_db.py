#!/usr/bin/env python3
"""Build the bundled offline food database (Sources/HealtherCore/Resources/foods.sqlite).

Sources (see docs/DATA_SOURCES.md for licenses):
  - 台湾食品营养成分资料库 (TFDA, Open Government Data License v1.0)
  - USDA FoodData Central: SR Legacy + Foundation Foods (public domain / CC0)

Usage:
  python3 -m venv .venv && .venv/bin/pip install opencc-python-reimplemented
  .venv/bin/python scripts/build_food_db.py            # downloads into scripts/.cache
  .venv/bin/python scripts/build_food_db.py --cache DIR

The search tokenizer here MUST stay in sync with SearchTokenizer.swift.
"""
from __future__ import annotations

import argparse
import csv
import io
import os
import sqlite3
import sys
import unicodedata
import urllib.request
import zipfile
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "Sources/HealtherCore/Resources/foods.sqlite"

TW_URL = "https://data.fda.gov.tw/data/opendata/export/20/csv"
USDA_SR_URL = "https://fdc.nal.usda.gov/fdc-datasets/FoodData_Central_sr_legacy_food_csv_2018-04.zip"
USDA_FND_URL = "https://fdc.nal.usda.gov/fdc-datasets/FoodData_Central_foundation_food_csv_2026-04-30.zip"

SCHEMA_VERSION = 1

# ---------------------------------------------------------------- tokenizer


def is_cjk(ch: str) -> bool:
    cp = ord(ch)
    return (
        0x4E00 <= cp <= 0x9FFF
        or 0x3400 <= cp <= 0x4DBF
        or 0x20000 <= cp <= 0x2A6DF
        or 0xF900 <= cp <= 0xFAFF
        or 0x3040 <= cp <= 0x30FF  # kana
    )


def index_tokens(text: str | None) -> str:
    """CJK runs -> unigrams + bigrams; latin/digit runs -> lowercase words."""
    if not text:
        return ""
    text = unicodedata.normalize("NFKC", text).lower()
    out: list[str] = []
    run: list[str] = []
    word: list[str] = []

    def flush_run():
        if run:
            out.extend(run)
            out.extend(run[i] + run[i + 1] for i in range(len(run) - 1))
            run.clear()

    def flush_word():
        if word:
            out.append("".join(word))
            word.clear()

    for ch in text:
        if is_cjk(ch):
            flush_word()
            run.append(ch)
        elif ch.isalnum():
            flush_run()
            word.append(ch)
        else:
            flush_run()
            flush_word()
    flush_run()
    flush_word()
    return " ".join(out)


# ---------------------------------------------------------------- helpers


def fetch(url: str, dest: Path) -> Path:
    if dest.exists() and dest.stat().st_size > 0:
        return dest
    dest.parent.mkdir(parents=True, exist_ok=True)
    print(f"  downloading {url}")
    req = urllib.request.Request(url, headers={"User-Agent": "Healther-build/0.1"})
    with urllib.request.urlopen(req) as r, open(dest, "wb") as f:
        f.write(r.read())
    return dest


def num(s: str | None) -> float | None:
    if s is None:
        return None
    s = s.strip()
    if not s:
        return None
    try:
        return float(s)
    except ValueError:
        return None


def zip_csv(zf: zipfile.ZipFile, suffix: str):
    name = next(n for n in zf.namelist() if n.endswith("/" + suffix) or n == suffix)
    with zf.open(name) as f:
        yield from csv.DictReader(io.TextIOWrapper(f, encoding="utf-8-sig"))


# ---------------------------------------------------------------- Taiwan

TW_FIELDS = {
    "熱量": "kcal",
    "粗蛋白": "protein",
    "粗脂肪": "fat",
    "總碳水化合物": "carbs",
    "膳食纖維": "fiber",
    "糖質總量": "sugar",
    "鈉": "sodium_mg",
    "飽和脂肪": "sat_fat",
}


def load_taiwan(path: Path):
    import opencc

    cc = opencc.OpenCC("t2s")
    zf = zipfile.ZipFile(path)
    name = next(n for n in zf.namelist() if n.endswith(".csv"))
    foods: dict[str, dict] = {}
    with zf.open(name) as f:
        for row in csv.DictReader(io.TextIOWrapper(f, encoding="utf-8-sig")):
            fid = row["整合編號"].strip()
            food = foods.get(fid)
            if food is None:
                waste = num(row["廢棄率"]) or 0.0
                food = foods[fid] = {
                    "id": f"tw:{fid}",
                    "source": "tw_fda",
                    "name": cc.convert(row["樣品名稱"].strip()),
                    "name_en": row["樣品英文名稱"].strip() or None,
                    "aliases": cc.convert(row["俗名"].strip()) or None,
                    "category": cc.convert(row["食品分類"].strip()),
                    "description": cc.convert(row["內容物描述"].strip()) or None,
                    "edible_portion": max(0.0, min(1.0, 1 - waste / 100.0)),
                }
            item = row["分析項"].strip()
            if item in TW_FIELDS:
                food[TW_FIELDS[item]] = num(row["每100克含量"])
            elif item == "修正熱量" and food.get("kcal") is None:
                food["kcal"] = num(row["每100克含量"])
    return [f for f in foods.values() if f.get("kcal") is not None]


# ---------------------------------------------------------------- USDA

USDA_FIELDS = {
    "1003": "protein",
    "1004": "fat",
    "1005": "carbs",
    "1079": "fiber",
    "2000": "sugar",
    "1093": "sodium_mg",
    "1258": "sat_fat",
}
USDA_ENERGY = ("1008", "2048", "2047")  # preference order


def load_usda(path: Path, source: str, data_type: str):
    zf = zipfile.ZipFile(path)
    cats = {r["id"]: r["description"] for r in zip_csv(zf, "food_category.csv")}
    foods: dict[str, dict] = {}
    for r in zip_csv(zf, "food.csv"):
        if r["data_type"] != data_type:
            continue
        foods[r["fdc_id"]] = {
            "id": f"usda:{r['fdc_id']}",
            "source": source,
            "name": r["description"].strip(),
            "name_en": r["description"].strip(),
            "aliases": None,
            "category": cats.get(r["food_category_id"]),
            "description": None,
            "edible_portion": 1.0,
        }
    energy: dict[str, dict[str, float]] = {}
    for r in zip_csv(zf, "food_nutrient.csv"):
        food = foods.get(r["fdc_id"])
        if food is None:
            continue
        nid = r["nutrient_id"]
        if nid in USDA_FIELDS:
            food[USDA_FIELDS[nid]] = num(r["amount"])
        elif nid in USDA_ENERGY:
            v = num(r["amount"])
            if v is not None:
                energy.setdefault(r["fdc_id"], {})[nid] = v
    out = []
    for fid, food in foods.items():
        e = energy.get(fid, {})
        kcal = next((e[k] for k in USDA_ENERGY if k in e), None)
        if kcal is None:
            continue
        food["kcal"] = kcal
        out.append(food)
    return out


# ---------------------------------------------------------------- write

COLUMNS = ["id", "source", "name", "name_en", "aliases", "category", "description",
           "kcal", "protein", "fat", "carbs", "fiber", "sugar", "sodium_mg", "sat_fat",
           "edible_portion"]


def write_db(foods: list[dict], out: Path):
    out.parent.mkdir(parents=True, exist_ok=True)
    if out.exists():
        out.unlink()
    db = sqlite3.connect(out)
    db.executescript(
        """
        PRAGMA page_size = 4096;
        CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE foods(
            rowid INTEGER PRIMARY KEY,
            id TEXT NOT NULL UNIQUE,
            source TEXT NOT NULL,
            name TEXT NOT NULL,
            name_en TEXT,
            aliases TEXT,
            category TEXT,
            description TEXT,
            kcal REAL NOT NULL,
            protein REAL, fat REAL, carbs REAL, fiber REAL, sugar REAL,
            sodium_mg REAL, sat_fat REAL,
            edible_portion REAL NOT NULL DEFAULT 1.0
        );
        CREATE VIRTUAL TABLE foods_fts USING fts5(
            name_tokens, alias_tokens, extra_tokens,
            content='', tokenize='unicode61 remove_diacritics 2'
        );
        """
    )
    for i, f in enumerate(foods, start=1):
        db.execute(
            f"INSERT INTO foods(rowid, {', '.join(COLUMNS)}) VALUES (?, {', '.join('?' * len(COLUMNS))})",
            [i] + [f.get(c) for c in COLUMNS],
        )
        db.execute(
            "INSERT INTO foods_fts(rowid, name_tokens, alias_tokens, extra_tokens) VALUES (?, ?, ?, ?)",
            [
                i,
                index_tokens(f["name"]),
                index_tokens(" ".join(x for x in (f.get("aliases"), f.get("name_en")) if x)),
                index_tokens(" ".join(x for x in (f.get("category"), f.get("description")) if x)),
            ],
        )
    db.executemany(
        "INSERT INTO meta VALUES (?, ?)",
        [
            ("schema_version", str(SCHEMA_VERSION)),
            ("built", date.today().isoformat()),
            ("sources", "tw_fda,usda_sr,usda_foundation"),
            ("count", str(len(foods))),
        ],
    )
    db.commit()
    db.execute("INSERT INTO foods_fts(foods_fts) VALUES ('optimize')")
    db.commit()
    db.execute("VACUUM")
    db.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cache", default=str(ROOT / "scripts/.cache"))
    args = ap.parse_args()
    cache = Path(args.cache)

    print("Taiwan TFND…")
    tw = load_taiwan(fetch(TW_URL, cache / "tw.zip"))
    print(f"  {len(tw)} foods")
    print("USDA SR Legacy…")
    sr = load_usda(fetch(USDA_SR_URL, cache / "sr.zip"), "usda_sr", "sr_legacy_food")
    print(f"  {len(sr)} foods")
    print("USDA Foundation…")
    fnd = load_usda(fetch(USDA_FND_URL, cache / "fnd.zip"), "usda_foundation", "foundation_food")
    print(f"  {len(fnd)} foods")

    write_db(tw + fnd + sr, OUT)
    print(f"→ {OUT.relative_to(ROOT)}  ({OUT.stat().st_size / 1e6:.1f} MB)")


if __name__ == "__main__":
    sys.exit(main())
