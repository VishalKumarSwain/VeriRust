#!/usr/bin/env python3
"""
harness_generator.py — Core of VeriRust: HarnessSynth algorithm.

For each instruction in a VeriRust Anchor-subset contract:
  1. Parse program structure via anchor_parser
  2. Infer constraints (signer, has_one, supply_invariant) from naming conventions
  3. Classify vulnerability risks via property_injector
  4. Emit:
       (a) kani::Arbitrary impls for all custom structs
       (b) Safety harnesses  (assume constraints satisfied, Kani finds crashes)
       (c) Auth harnesses    (force mismatched identity, assert failure)
       (d) Invariant harnesses (supply/balance invariants)

Usage:
  python3 harness_generator.py <contract.rs>          # print to stdout
  python3 harness_generator.py <contract.rs> --write  # append to file
"""

import sys
import os
from typing import List, Dict, Set

from anchor_parser import parse_file, AnchorProgram, Struct, Instruction, Constraint
from property_injector import classify_instruction, KNOWN_VULN_CLASSES


# ---------------------------------------------------------------------------
# Arbitrary impl generator
# ---------------------------------------------------------------------------

def _arbitrary_impl(struct: Struct) -> str:
    field_inits = "\n".join(
        f"                {f.name}: kani::any()," for f in struct.fields
    )
    return f"""\
    impl kani::Arbitrary for {struct.name} {{
        fn any() -> Self {{
            {struct.name} {{
{field_inits}
            }}
        }}
    }}"""


# ---------------------------------------------------------------------------
# Harness generators
# ---------------------------------------------------------------------------

def _param_decls(params) -> str:
    return "\n".join(f"        let {p.name}: {p.type_} = kani::any();" for p in params)


def _call_args(params) -> str:
    args = ", ".join(p.name for p in params)
    return (", " + args) if args else ""


def safety_harness(
    instruction: Instruction,
    constraints: List[Constraint],
    suffix: str = ""
) -> str:
    """
    Assume all constraints satisfied, then call the instruction.
    Kani catches arithmetic panics automatically.
    """
    fn_name = f"verify_{instruction.name}{suffix}"
    assumes = []
    for c in constraints:
        if c.kind == "signer":
            assumes.append("kani::assume(ctx.is_signer);")
        elif c.kind == "has_one":
            assumes.append(f"kani::assume(ctx.{c.ctx_field} == ctx.{c.account_field});")

    assume_block = ("\n" + "\n".join(f"        {a}" for a in assumes)) if assumes else ""
    param_decl_block = ("\n" + _param_decls(instruction.params)) if instruction.params else ""
    call_args = _call_args(instruction.params)

    return f"""\
    // Safety harness: {instruction.name} — detect arithmetic panics
    #[kani::proof]
    fn {fn_name}() {{{param_decl_block}{assume_block}
        let mut ctx: {instruction.ctx_type} = kani::any();
        let _ = {instruction.name}(&mut ctx{call_args});
        // Kani checks: no arithmetic panic, no assertion failure
    }}"""


def auth_harness(
    instruction: Instruction,
    has_one_constraint: Constraint,
    suffix: str = "_auth"
) -> str:
    """
    Force ctx_field != account_field (attack scenario).
    Assert the instruction must return Err.
    """
    fn_name = f"verify_{instruction.name}{suffix}"
    call_args = _call_args(instruction.params)
    param_decl_block = ("\n" + _param_decls(instruction.params)) if instruction.params else ""
    extra_assumes = []
    # If the contract also has sufficient-balance style checks we need to
    # assume enough state so only the auth check triggers.
    # We do a generic "enough" assume based on amount param if present.
    for p in instruction.params:
        if p.name == "amount":
            # find the staked/balance field in the embedded account struct
            extra_assumes.append(
                f"// Ensure non-auth check is the binding one"
            )
    extra_block = ("\n" + "\n".join(f"        {a}" for a in extra_assumes)) if extra_assumes else ""

    return f"""\
    // Auth harness: {instruction.name} — non-owner must always be rejected
    #[kani::proof]
    fn {fn_name}() {{{param_decl_block}
        let mut ctx: {instruction.ctx_type} = kani::any();
        kani::assume(ctx.is_signer);
        // Force the attack scenario: caller is NOT the rightful owner
        kani::assume(ctx.{has_one_constraint.ctx_field} != ctx.{has_one_constraint.account_field});{extra_block}
        let result = {instruction.name}(&mut ctx{call_args});
        assert!(
            result.is_err(),
            "AUTH_VIOLATION: {instruction.name} succeeded without matching {has_one_constraint.ctx_field}"
        );
    }}"""


def supply_invariant_harness(
    instruction: Instruction,
    supply_constraint: Constraint,
    amount_param_name: str = "amount",
    suffix: str = "_supply"
) -> str:
    """
    Assert that total_supply decreases by exactly 'amount' on success.
    """
    fn_name = f"verify_{instruction.name}{suffix}"
    acc = supply_constraint.ctx_field
    sf = supply_constraint.account_field
    call_args = _call_args(instruction.params)
    param_decl_block = ("\n" + _param_decls(instruction.params)) if instruction.params else ""

    return f"""\
    // Supply invariant harness: {instruction.name} — {acc}.{sf} must decrease by {amount_param_name}
    #[kani::proof]
    fn {fn_name}() {{{param_decl_block}
        let mut ctx: {instruction.ctx_type} = kani::any();
        kani::assume(ctx.is_signer);
        // Valid pre-state: amount cannot exceed the supply field
        kani::assume({amount_param_name} <= ctx.{acc}.{sf});
        let pre_{sf} = ctx.{acc}.{sf};
        let result = {instruction.name}(&mut ctx{call_args});
        if result.is_ok() {{
            assert!(
                ctx.{acc}.{sf} == pre_{sf} - {amount_param_name},
                "SUPPLY_INVARIANT: {sf} not reduced after successful {instruction.name}"
            );
        }}
    }}"""


# ---------------------------------------------------------------------------
# Top-level synthesis
# ---------------------------------------------------------------------------

def synthesize(program: AnchorProgram) -> str:
    """
    Run HarnessSynth on a parsed AnchorProgram.
    Returns the full #[cfg(kani)] block as a string.
    """
    lines: List[str] = []
    lines.append("// ============================================================")
    lines.append("// GENERATED BY VeriRust harness_generator.py — DO NOT EDIT")
    lines.append("// ============================================================")
    lines.append("#[cfg(kani)]")
    lines.append("mod verirust_harnesses {")
    lines.append("    use super::*;")
    lines.append("")

    # Emit Arbitrary impls for every struct
    emitted_arbitrary: Set[str] = set()
    for struct in program.structs:
        if struct.name not in emitted_arbitrary:
            lines.append(_arbitrary_impl(struct))
            lines.append("")
            emitted_arbitrary.add(struct.name)

    # Emit harnesses per instruction
    for instruction in program.instructions:
        ctx_struct = program.get_struct(instruction.ctx_type)
        if ctx_struct is None:
            continue

        constraints = program.infer_constraints(ctx_struct)
        vuln_classes = classify_instruction(instruction)

        # (a) Safety harness — always generated
        lines.append(safety_harness(instruction, constraints))
        lines.append("")

        # (b) Auth harness — when there is a has_one constraint
        has_one_constraints = [c for c in constraints if c.kind == "has_one"]
        if has_one_constraints:
            # Use first has_one constraint for the auth harness
            lines.append(auth_harness(instruction, has_one_constraints[0]))
            lines.append("")

        # (c) Supply invariant harness — when there is a supply_invariant constraint
        supply_constraints = [c for c in constraints if c.kind == "supply_invariant"]
        amount_params = [p for p in instruction.params if p.name == "amount"]
        if supply_constraints and amount_params:
            lines.append(supply_invariant_harness(
                instruction,
                supply_constraints[0],
                amount_param_name="amount"
            ))
            lines.append("")

        # Summary comment
        if vuln_classes:
            lines.append(
                f"    // Detected vulnerability classes: {', '.join(vuln_classes)}"
            )
            lines.append("")

    lines.append("}")
    return "\n".join(lines)


def generate_for_file(file_path: str, write_back: bool = False) -> str:
    program = parse_file(file_path)
    code = synthesize(program)

    if write_back:
        # Check if harness block already present; if so, replace it
        with open(file_path, 'r', encoding='utf-8') as f:
            source = f.read()

        marker = "// GENERATED BY VeriRust harness_generator.py"
        if marker in source:
            # Replace existing block
            start = source.find("// ============================================================\n" + marker)
            if start != -1:
                # Find the enclosing #[cfg(kani)] mod end
                cfg_start = source.rfind("#[cfg(kani)]", 0, start)
                if cfg_start != -1:
                    # Find closing brace of the mod
                    depth = 0
                    end = cfg_start
                    for i in range(source.find('{', cfg_start), len(source)):
                        if source[i] == '{':
                            depth += 1
                        elif source[i] == '}':
                            depth -= 1
                            if depth == 0:
                                end = i + 1
                                break
                    new_source = source[:cfg_start] + code + source[end:]
                    with open(file_path, 'w', encoding='utf-8') as f:
                        f.write(new_source)
                    print(f"[harness_generator] Updated harnesses in {file_path}")
                    return code
        # Append new block
        with open(file_path, 'a', encoding='utf-8') as f:
            f.write("\n\n" + code + "\n")
        print(f"[harness_generator] Appended harnesses to {file_path}")

    return code


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    if len(sys.argv) < 2:
        print("Usage: harness_generator.py <contract.rs> [--write]", file=sys.stderr)
        sys.exit(1)

    file_path = sys.argv[1]
    write_back = "--write" in sys.argv

    code = generate_for_file(file_path, write_back=write_back)
    if not write_back:
        print(code)


if __name__ == '__main__':
    main()
