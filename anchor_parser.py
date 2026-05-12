#!/usr/bin/env python3
"""
anchor_parser.py — Parse VeriRust Anchor-subset Rust contracts.

Extracts from a .rs file:
  - AccountStruct : structs tagged // @account  (e.g. VaultState)
  - CtxStruct     : structs tagged // @context  OR named *Ctx
  - Instruction   : pub fn X(ctx: &mut YCtx, ...) -> Result<...> functions

Constraint inference (naming conventions, no annotations needed):
  - Field named 'is_signer: bool' in a Ctx struct  → signer constraint
  - Field 'authority: Pubkey' present in BOTH the Ctx AND its embedded
    account struct with the same name                → has_one constraint
  - Field named 'user: Pubkey' in Ctx + 'user: Pubkey' in account struct
                                                     → has_one constraint
  - Field named 'total_supply' in any account struct → supply invariant target
"""

import re
import sys
from dataclasses import dataclass, field
from typing import List, Optional, Tuple


# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------

@dataclass
class Field:
    name: str
    type_: str


@dataclass
class Struct:
    name: str
    fields: List[Field]
    is_ctx: bool = False        # True when this is a *Ctx struct
    is_account: bool = False    # True when tagged // @account

    def field_names(self) -> List[str]:
        return [f.name for f in self.fields]

    def get_field(self, name: str) -> Optional[Field]:
        for f in self.fields:
            if f.name == name:
                return f
        return None

    def has_signer_field(self) -> bool:
        return any(f.name == "is_signer" and "bool" in f.type_ for f in self.fields)

    def pubkey_fields(self) -> List[str]:
        return [f.name for f in self.fields if "Pubkey" in f.type_ or f.type_ == "u32"]

    def has_supply_field(self) -> bool:
        return any("supply" in f.name or "total_staked" in f.name for f in self.fields)


@dataclass
class Instruction:
    name: str
    ctx_type: str               # e.g. "WithdrawCtx"
    params: List[Field]         # non-ctx parameters
    body: str                   # raw function body

    def uses_addition(self) -> bool:
        return "+=" in self.body or (
            "checked_add" not in self.body and "+" in self.body
            and "==" not in self.body
        )

    def uses_subtraction(self) -> bool:
        return "-=" in self.body or (
            "checked_sub" not in self.body and
            re.search(r'\w+\s*-\s*\w+', self.body) and
            "!=" not in self.body
        )

    def is_unchecked_arithmetic(self) -> bool:
        has_unsafe_add = "+=" in self.body and "checked_add" not in self.body
        has_unsafe_sub = "-=" in self.body and "checked_sub" not in self.body
        return has_unsafe_add or has_unsafe_sub


@dataclass
class Constraint:
    kind: str       # "signer" | "has_one" | "supply_invariant"
    ctx_field: str  # field name in Ctx struct
    account_field: str = ""  # matching field in account struct (for has_one)
    account_type: str = ""   # account struct name


@dataclass
class AnchorProgram:
    file_path: str
    structs: List[Struct]
    instructions: List[Instruction]

    def get_struct(self, name: str) -> Optional[Struct]:
        for s in self.structs:
            if s.name == name:
                return s
        return None

    def account_structs(self) -> List[Struct]:
        return [s for s in self.structs if s.is_account or not s.is_ctx]

    def ctx_structs(self) -> List[Struct]:
        return [s for s in self.structs if s.is_ctx]

    def infer_constraints(self, ctx: Struct) -> List[Constraint]:
        constraints = []
        if ctx.has_signer_field():
            constraints.append(Constraint(kind="signer", ctx_field="is_signer"))

        # has_one: match pubkey fields by name between ctx and embedded structs
        for cf in ctx.fields:
            if cf.type_ in [s.name for s in self.structs]:
                embedded = self.get_struct(cf.type_)
                if embedded is None:
                    continue
                # Check for matching authority/user pubkey fields
                for pf in ctx.pubkey_fields():
                    if embedded.get_field(pf):
                        constraints.append(Constraint(
                            kind="has_one",
                            ctx_field=pf,
                            account_field=f"{cf.name}.{pf}",
                            account_type=cf.type_
                        ))
                # Supply invariant detection
                if embedded.has_supply_field():
                    supply_field = next(
                        f.name for f in embedded.fields
                        if "supply" in f.name or "total_staked" in f.name
                    )
                    constraints.append(Constraint(
                        kind="supply_invariant",
                        ctx_field=cf.name,
                        account_field=supply_field,
                        account_type=cf.type_
                    ))
        return constraints


# ---------------------------------------------------------------------------
# Parsing helpers
# ---------------------------------------------------------------------------

def _parse_fields(body: str) -> List[Field]:
    fields = []
    pattern = re.compile(r'(?:pub\s+)?(\w+)\s*:\s*([^,\n}]+)')
    for m in pattern.finditer(body):
        name = m.group(1).strip()
        type_ = m.group(2).strip().rstrip(',').strip()
        # Skip Rust keywords that can appear inside bodies
        if name in ('pub', 'fn', 'let', 'if', 'else', 'return', 'use',
                    'mod', 'impl', 'struct', 'enum', 'match', 'for'):
            continue
        fields.append(Field(name=name, type_=type_))
    return fields


def _extract_brace_block(source: str, start: int) -> str:
    """Return text from opening { to matching closing }, starting search at start."""
    brace_pos = source.find('{', start)
    if brace_pos == -1:
        return ''
    depth = 0
    for i in range(brace_pos, len(source)):
        if source[i] == '{':
            depth += 1
        elif source[i] == '}':
            depth -= 1
            if depth == 0:
                return source[brace_pos:i + 1]
    return ''


def _find_struct_block(source: str, name: str) -> Optional[str]:
    pat = re.compile(r'pub\s+struct\s+' + re.escape(name) + r'\s*\{')
    m = pat.search(source)
    if not m:
        return None
    return _extract_brace_block(source, m.start())


# ---------------------------------------------------------------------------
# Main parser
# ---------------------------------------------------------------------------

def parse_file(file_path: str) -> AnchorProgram:
    with open(file_path, 'r', encoding='utf-8') as f:
        source = f.read()

    # --- Structs ---
    structs: List[Struct] = []
    struct_pat = re.compile(
        r'(// @(?:account|context)\s*\n)?'
        r'(?:#\[derive[^\]]*\]\s*)*'
        r'pub\s+struct\s+(\w+)\s*\{',
        re.DOTALL
    )
    for m in struct_pat.finditer(source):
        tag = m.group(1) or ''
        name = m.group(2)
        block = _extract_brace_block(source, m.start())
        if not block:
            continue
        inner = block[1:-1]  # strip outer braces
        fields = _parse_fields(inner)
        is_ctx = name.endswith('Ctx') or '@context' in tag
        is_account = '@account' in tag or (not is_ctx and name.endswith('State'))
        structs.append(Struct(
            name=name,
            fields=fields,
            is_ctx=is_ctx,
            is_account=is_account
        ))

    # --- Instructions ---
    instructions: List[Instruction] = []
    fn_pat = re.compile(
        r'pub\s+fn\s+(\w+)\s*\(([^)]*)\)\s*->\s*Result',
        re.DOTALL
    )
    for m in fn_pat.finditer(source):
        fn_name = m.group(1)
        param_str = m.group(2)
        body = _extract_brace_block(source, m.start())

        ctx_type = ''
        params: List[Field] = []
        for part in re.split(r',\s*', param_str):
            part = part.strip()
            if not part or part in ('self', '&self', '&mut self'):
                continue
            pm = re.match(r'(\w+)\s*:\s*(?:&\s*mut\s+)?(\w+)', part)
            if not pm:
                continue
            pname, ptype = pm.group(1), pm.group(2)
            if ptype.endswith('Ctx'):
                ctx_type = ptype
            else:
                params.append(Field(name=pname, type_=ptype))

        if ctx_type:
            instructions.append(Instruction(
                name=fn_name,
                ctx_type=ctx_type,
                params=params,
                body=body
            ))

    return AnchorProgram(file_path=file_path, structs=structs, instructions=instructions)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    if len(sys.argv) < 2:
        print("Usage: anchor_parser.py <contract.rs>", file=sys.stderr)
        sys.exit(1)

    prog = parse_file(sys.argv[1])
    print(f"=== {prog.file_path} ===")
    print(f"\nStructs ({len(prog.structs)}):")
    for s in prog.structs:
        tag = '[Ctx]' if s.is_ctx else '[Account]'
        print(f"  {tag} {s.name}")
        for f in s.fields:
            print(f"       {f.name}: {f.type_}")
    print(f"\nInstructions ({len(prog.instructions)}):")
    for i in prog.instructions:
        ps = ', '.join(f'{p.name}: {p.type_}' for p in i.params)
        print(f"  fn {i.name}(ctx: &mut {i.ctx_type}, {ps})")
        ctx = prog.get_struct(i.ctx_type)
        if ctx:
            for c in prog.infer_constraints(ctx):
                print(f"       constraint: {c.kind} on {c.ctx_field}")
        arith = []
        if i.is_unchecked_arithmetic():
            arith.append("UNCHECKED_ARITHMETIC")
        if arith:
            print(f"       detected: {', '.join(arith)}")


if __name__ == '__main__':
    main()
