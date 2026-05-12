#!/usr/bin/env python3
"""
property_injector.py — Safety property library for VeriRust harness synthesis.

Provides property templates keyed by vulnerability class:
  OVERFLOW          : arithmetic overflow on addition
  UNDERFLOW         : arithmetic underflow on subtraction
  MISSING_AUTH      : missing authority / identity check
  SUPPLY_INVARIANT  : token supply not updated correctly

Each template returns (assume_lines, assert_lines) as lists of Rust code strings.
"""

import re

from dataclasses import dataclass
from typing import List, Tuple


@dataclass
class Property:
    kind: str
    description: str
    assumes: List[str]
    asserts: List[str]
    pre_captures: List[str]  # statements to run before calling the instruction


# ---------------------------------------------------------------------------
# Property builders
# ---------------------------------------------------------------------------

def overflow_property(ctx_account_field: str, balance_field: str) -> Property:
    """
    Arithmetic overflow: no upper-bound assume on balance or amount.
    Kani auto-detects panic from unchecked += in debug mode.
    """
    return Property(
        kind="OVERFLOW",
        description=f"Unchecked addition on {ctx_account_field}.{balance_field} may overflow",
        assumes=[],
        asserts=[],  # Kani detects the panic automatically
        pre_captures=[]
    )


def underflow_property(ctx_account_field: str, balance_field: str) -> Property:
    """
    Arithmetic underflow: no lower-bound assume.
    Kani auto-detects panic from unchecked -= in debug mode.
    """
    return Property(
        kind="UNDERFLOW",
        description=f"Unchecked subtraction on {ctx_account_field}.{balance_field} may underflow",
        assumes=[],
        asserts=[],  # Kani detects the panic automatically
        pre_captures=[]
    )


def auth_property(ctx_id_field: str, account_id_field: str) -> Property:
    """
    Missing authority check: force mismatched identity and assert operation fails.
    ctx_id_field     : e.g. "user"  (field in Ctx struct)
    account_id_field : e.g. "user_stake.user"  (dotted path inside Ctx)
    """
    return Property(
        kind="MISSING_AUTH",
        description=f"Operation must fail when {account_id_field} != {ctx_id_field}",
        assumes=[
            f"kani::assume(ctx.{account_id_field} != ctx.{ctx_id_field});"
        ],
        asserts=[
            f'assert!(result.is_err(), "AUTH_VIOLATION: operation succeeded without matching {ctx_id_field}");'
        ],
        pre_captures=[]
    )


def supply_invariant_property(ctx_account_field: str, supply_field: str,
                               amount_param: str) -> Property:
    """
    Supply invariant: after a successful burn/transfer, total_supply must decrease
    by exactly the burned/transferred amount.
    """
    pre_var = f"pre_{supply_field}"
    return Property(
        kind="SUPPLY_INVARIANT",
        description=f"{ctx_account_field}.{supply_field} must decrease by {amount_param} on success",
        assumes=[
            # user cannot hold more than total supply
        ],
        asserts=[
            f'if result.is_ok() {{',
            f'    assert!(',
            f'        ctx.{ctx_account_field}.{supply_field} == {pre_var} - {amount_param},',
            f'        "SUPPLY_INVARIANT: {supply_field} not reduced after successful operation"',
            f'    );',
            f'}}',
        ],
        pre_captures=[
            f"let {pre_var} = ctx.{ctx_account_field}.{supply_field};"
        ]
    )


# ---------------------------------------------------------------------------
# Constraint → property mapping
# ---------------------------------------------------------------------------

def build_safety_harness_body(
    instruction_name: str,
    ctx_type: str,
    params: List[str],
    assumes: List[str],
    pre_captures: List[str],
    asserts: List[str],
    harness_suffix: str = ""
) -> str:
    """
    Render a complete #[kani::proof] harness function body.
    """
    fn_name = f"verify_{instruction_name}{harness_suffix}"
    param_decls = "\n".join(
        f"    let {p['name']}: {p['type_']} = kani::any();" for p in params
    )
    assume_block = "\n".join(f"    {a}" for a in assumes) if assumes else ""
    capture_block = "\n".join(f"    {c}" for c in pre_captures) if pre_captures else ""
    param_call = ", ".join(p['name'] for p in params)
    assert_block = "\n".join(f"    {a}" for a in asserts) if asserts else ""

    return f"""    #[kani::proof]
    fn {fn_name}() {{
        let mut ctx: {ctx_type} = kani::any();
{param_decls}
{assume_block}
{capture_block}
        let result = {instruction_name}(&mut ctx{(', ' + param_call) if param_call else ''});
{assert_block}
    }}"""


# ---------------------------------------------------------------------------
# Vulnerability classification helpers
# ---------------------------------------------------------------------------

KNOWN_VULN_CLASSES = {
    "OVERFLOW": "Arithmetic overflow (unchecked addition)",
    "UNDERFLOW": "Arithmetic underflow (unchecked subtraction)",
    "MISSING_AUTH": "Missing authority / identity verification",
    "SUPPLY_INVARIANT": "Token supply invariant violation",
}


def classify_instruction(instruction) -> List[str]:
    """Return list of vulnerability class strings inferred from instruction body."""
    classes = []
    body = instruction.body
    if "+=" in body and "checked_add" not in body:
        classes.append("OVERFLOW")
    if "-=" in body and "checked_sub" not in body and "checked_sub" not in body:
        # heuristic: if there's no prior bounds check either
        if not re.search(r'if\s.*<\s*\w', body):
            classes.append("UNDERFLOW")
    return classes


