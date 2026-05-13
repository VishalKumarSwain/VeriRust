#!/usr/bin/env python3
"""
anchor_to_vas.py - best-effort Anchor-to-VAS type stripping.

This converter turns raw Anchor source into the VeriRust Anchor Subset (VAS)
surface that anchor_parser.py and harness_generator.py understand:

  - Context<Foo> instruction arguments become &mut FooCtx
  - #[derive(Accounts)] structs become // @context FooCtx structs
  - Account<'info, T> / AccountLoader<'info, T> fields become plain T fields
  - Signer<'info> contributes both a Pubkey field and is_signer: bool
  - Pubkey/account-like runtime handles are reduced to u32 Pubkey aliases

The output is intentionally conservative. It preserves the instruction surface
and inferred account shape, but it does not inline full Anchor runtime behavior
or CPI semantics.
"""

import argparse
import re
from pathlib import Path
from typing import Dict, Iterable, List, Set, Tuple


RUST_PRIMITIVES = {"bool", "u8", "u16", "u32", "u64", "i64", "usize"}
ACCOUNT_HANDLE_TYPES = {
    "AccountInfo",
    "InterfaceAccount",
    "Program",
    "Sysvar",
    "SystemAccount",
    "UncheckedAccount",
}


def _read_sources(paths: Iterable[Path]) -> str:
    chunks: List[str] = []
    for path in paths:
        if path.is_dir():
            for rs in sorted(path.rglob("*.rs")):
                chunks.append(rs.read_text(encoding="utf-8", errors="ignore"))
        elif path.suffix == ".rs":
            chunks.append(path.read_text(encoding="utf-8", errors="ignore"))
    return "\n\n".join(chunks)


def _extract_brace_block(source: str, start: int) -> str:
    brace_pos = source.find("{", start)
    if brace_pos == -1:
        return ""
    depth = 0
    for i in range(brace_pos, len(source)):
        if source[i] == "{":
            depth += 1
        elif source[i] == "}":
            depth -= 1
            if depth == 0:
                return source[brace_pos:i + 1]
    return ""


def _split_top_level_commas(text: str) -> List[str]:
    parts: List[str] = []
    start = 0
    angle = paren = bracket = 0
    for i, ch in enumerate(text):
        if ch == "<":
            angle += 1
        elif ch == ">" and angle:
            angle -= 1
        elif ch == "(":
            paren += 1
        elif ch == ")" and paren:
            paren -= 1
        elif ch == "[":
            bracket += 1
        elif ch == "]" and bracket:
            bracket -= 1
        elif ch == "," and angle == paren == bracket == 0:
            parts.append(text[start:i].strip())
            start = i + 1
    tail = text[start:].strip()
    if tail:
        parts.append(tail)
    return parts


def _last_generic_type(type_text: str) -> str:
    inner = re.search(r"<(.+)>", type_text)
    if not inner:
        return ""
    parts = _split_top_level_commas(inner.group(1))
    for part in reversed(parts):
        cleaned = re.sub(r"['&\s]", "", part)
        if cleaned and cleaned != "info":
            return cleaned.split("::")[-1]
    return ""


def _vas_type(type_text: str) -> Tuple[str, bool]:
    compact = re.sub(r"\s+", "", type_text)
    compact = compact.replace("Box<", "").rstrip(">")
    base = compact.split("::")[-1]

    if "&" in compact or "[" in compact or compact.startswith("Vec<") or compact.startswith("Option<"):
        return "u64", False
    if "Signer<" in compact:
        return "Pubkey", True
    if base in ("Pubkey", "Key"):
        return "Pubkey", False
    if base in RUST_PRIMITIVES:
        return base, False
    if compact.startswith("[u8;32]"):
        return "Pubkey", False

    generic_target = _last_generic_type(compact)
    outer = compact.split("<", 1)[0].split("::")[-1]
    if generic_target and (outer in ACCOUNT_HANDLE_TYPES or "Account" in outer or "Loader" in outer):
        return generic_target, False

    if outer in ACCOUNT_HANDLE_TYPES:
        return "Pubkey", False

    return base.split("<", 1)[0], False


def _parse_fields(block: str) -> List[Tuple[str, str, bool]]:
    fields: List[Tuple[str, str, bool]] = []
    body = block[1:-1]
    for raw in _split_top_level_commas(body.replace("\n", ",")):
        raw = re.sub(r"#\[[^\]]*\]", "", raw).strip()
        raw = re.sub(r"///.*", "", raw).strip()
        m = re.match(r"(?:pub\s+)?(\w+)\s*:\s*(.+)$", raw)
        if not m:
            continue
        name, type_text = m.group(1), m.group(2).strip()
        if name in {"constraint", "seeds", "bump"}:
            continue
        vas_type, signer = _vas_type(type_text)
        fields.append((name, vas_type, signer))
    return fields


def _parse_account_structs(source: str) -> Dict[str, List[Tuple[str, str, bool]]]:
    accounts: Dict[str, List[Tuple[str, str, bool]]] = {}
    pat = re.compile(r"(?:#\[[^\]]*\]\s*)*pub\s+struct\s+(\w+)(?:<[^>]+>)?\s*\{", re.MULTILINE)
    for m in pat.finditer(source):
        prefix = source[max(0, m.start() - 300):m.start()]
        name = m.group(1)
        if "derive(Accounts" in prefix or "derive( Accounts" in prefix:
            continue
        block = _extract_brace_block(source, m.start())
        if not block:
            continue
        fields = _parse_fields(block)
        if fields:
            accounts[name] = fields
    return accounts


def _parse_contexts(source: str) -> Dict[str, List[Tuple[str, str, bool]]]:
    contexts: Dict[str, List[Tuple[str, str, bool]]] = {}
    pat = re.compile(r"#\s*\[\s*derive\s*\([^\)]*Accounts[^\)]*\)\s*\]\s*(?:#\[[^\]]*\]\s*)*pub\s+struct\s+(\w+)(?:<[^>]+>)?\s*\{", re.MULTILINE)
    for m in pat.finditer(source):
        name = m.group(1)
        block = _extract_brace_block(source, m.start())
        if not block:
            continue
        contexts[name] = _parse_fields(block)
    return contexts


def _parse_instructions(source: str) -> List[Tuple[str, str, List[Tuple[str, str]]]]:
    instructions: List[Tuple[str, str, List[Tuple[str, str]]]] = []
    pat = re.compile(r"pub\s+fn\s+(\w+)\s*\(([^)]*Context\s*<[^)]*)\)\s*->\s*Result", re.DOTALL)
    for m in pat.finditer(source):
        name = m.group(1)
        params = m.group(2)
        ctx_match = re.search(r"ctx\s*:\s*Context\s*<\s*(\w+)\s*>", params)
        if not ctx_match:
            continue
        ctx_name = ctx_match.group(1)
        if ctx_name == "Self":
            prefix = source[:m.start()]
            impls = list(re.finditer(r"impl(?:<[^>]+>)?\s+(\w+)(?:<[^>]+>)?\s*\{", prefix))
            if impls:
                ctx_name = impls[-1].group(1)
        extra_params: List[Tuple[str, str]] = []
        for part in _split_top_level_commas(params):
            if "Context" in part:
                continue
            pm = re.match(r"(\w+)\s*:\s*(.+)", part.strip())
            if not pm:
                continue
            pname, ptype = pm.group(1), _vas_type(pm.group(2))[0]
            if ptype not in RUST_PRIMITIVES and ptype != "Pubkey":
                ptype = "u64"
            extra_params.append((pname, ptype))
        instructions.append((name, ctx_name, extra_params))
    return instructions


def convert_to_vas(source: str) -> str:
    account_structs = _parse_account_structs(source)
    contexts = _parse_contexts(source)
    instructions = _parse_instructions(source)

    referenced_types: Set[str] = set()
    for fields in list(contexts.values()) + list(account_structs.values()):
        for _, type_name, _ in fields:
            if type_name not in RUST_PRIMITIVES and type_name != "Pubkey":
                referenced_types.add(type_name)

    lines: List[str] = [
        "// Generated by anchor_to_vas.py from raw Anchor source.",
        "// This is a type-stripped VAS model, not a full Anchor runtime model.",
        "pub type Pubkey = u32;",
        "",
    ]

    for name in sorted(referenced_types | set(account_structs)):
        fields = account_structs.get(name)
        lines.append("// @account")
        lines.append(f"pub struct {name} {{")
        if fields:
            for field_name, type_name, _ in fields:
                if type_name == name:
                    continue
                lines.append(f"    pub {field_name}: {type_name},")
        else:
            lines.append("    pub authority: Pubkey,")
            lines.append("    pub total_supply: u64,")
        lines.append("}")
        lines.append("")

    for name, fields in sorted(contexts.items()):
        ctx_name = name if name.endswith("Ctx") else f"{name}Ctx"
        has_signer = False
        lines.append("// @context")
        lines.append(f"pub struct {ctx_name} {{")
        for field_name, type_name, signer in fields:
            lines.append(f"    pub {field_name}: {type_name},")
            has_signer = has_signer or signer
        lines.append("    pub is_signer: bool,")
        lines.append("}")
        lines.append("")

    emitted = set()
    for name, ctx_name, params in instructions:
        if name in emitted:
            continue
        emitted.add(name)
        vas_ctx = ctx_name if ctx_name.endswith("Ctx") else f"{ctx_name}Ctx"
        param_text = "".join(f", {pname}: {ptype}" for pname, ptype in params)
        lines.append(f"pub fn {name}(ctx: &mut {vas_ctx}{param_text}) -> Result<(), &'static str> {{")
        lines.append("    if !ctx.is_signer {")
        lines.append('        return Err("not signer");')
        lines.append("    }")
        for pname, _ in params:
            lines.append(f"    let _ = {pname};")
        lines.append("    Ok(())")
        lines.append("}")
        lines.append("")

    return "\n".join(lines).rstrip() + "\n"


def main() -> None:
    parser = argparse.ArgumentParser(description="Convert raw Anchor Rust source to a VAS model.")
    parser.add_argument("inputs", nargs="+", help="Rust file or source directory")
    parser.add_argument("-o", "--output", required=True, help="Output VAS .rs file")
    args = parser.parse_args()

    source = _read_sources(Path(p) for p in args.inputs)
    Path(args.output).write_text(convert_to_vas(source), encoding="utf-8")


if __name__ == "__main__":
    main()
