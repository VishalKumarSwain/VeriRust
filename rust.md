# Rust Smart Contract Verification System — Complete Knowledge Base

> **Purpose of this document**: This file describes the entire `rust_try` project so that any chatbot or AI assistant can understand how the codebase works when asked questions about it. Every file, its role, and all inter-file relationships are documented here.

---

## 1. PROJECT OVERVIEW

This project is a **Rust smart contract formal verification and code-coverage analysis system**. It was built to:

1. **Take Rust source files** (especially smart contracts) as input.
2. **Automatically inject reachability assertions** into every conditional branch (`if`, `while`).
3. **Generate Kani verification harnesses** that use symbolic execution to prove whether each branch is reachable.
4. **Run Kani formal verification** on the instrumented code.
5. **Run `cargo llvm-cov`** to generate LLVM branch-coverage HTML reports.
6. **Produce structured results** (summaries, logs, original vs. modified file diffs) for auditing.

The original source files are **always restored** after verification — modified copies are saved to a `results/` directory for audit purposes.

### Technology Stack

| Layer | Technology |
|---|---|
| Language under test | Rust (edition 2024) |
| Formal verification | [Kani](https://model-checking.github.io/kani/) (CBMC-based model checker for Rust) |
| Code coverage | `cargo llvm-cov` with `--branch` flag (LLVM instrumentation) |
| Assertion injection | Python 3 scripts (`rust_injector.py`, `harness_generator.py`) |
| Orchestration | Bash shell scripts (`verify_rust.sh`, `verify_all_clients.sh`, `process_smartcontracts.sh`) |
| Rust toolchain | Pinned to `nightly-2026-03-10` for reproducibility |
| Target smart contracts | Solana-style smart contracts (via `smart-contract-rs` SDK) and standalone Rust programs |

---

## 2. DIRECTORY STRUCTURE

```
rust_try/
├── Cargo.toml                  # Root Cargo project manifest
├── Cargo.lock                  # Dependency lock file
├── rust-toolchain.toml         # Pins Rust nightly-2026-03-10
├── .gitignore                  # Ignores /target
│
├── ── PYTHON TOOLS ──
├── rust_injector.py            # CORE: Assertion injector + harness generator (combined)
├── harness_generator.py        # STANDALONE: Alternative harness generator (class-based)
│
├── ── SHELL SCRIPTS (Orchestration) ──
├── verify_rust.sh              # MAIN: Verify Rust files/folders with Kani + LLVM coverage
├── verify_all_clients.sh       # Multi-client workspace verification
├── process_smartcontracts.sh   # Smart contract pipeline (Solana examples)
├── test-system.sh              # Quick-start test script (checks system readiness)
├── demo.sh                     # Read-only demo that explains the pipeline visually
│
├── ── RUST SOURCE FILES (Test Subjects) ──
├── binary.rs                   # Binary search tree implementation with tests & iterators
├── complex.rs                  # 20 functions with branching logic (Kani harness test target)
├── simple.rs                   # 3 simple functions with basic conditionals
├── shiba.rs                    # Full ERC-20-like token contract with 12 Kani harnesses
├── lucky_draw.rs               # Token reward contract with Kani harnesses
├── sample1.rs                  # NEAR Protocol counter smart contract
├── testrust.rs                 # Multi-threaded Fibonacci calculator
├── crash_demo.rs               # Deliberate division-by-zero crash
├── crash_runtime.rs            # Runtime crash with panic::catch_unwind
├── panic_contract.rs           # Guaranteed panics: empty vector access + unwrap None
├── test_contract.rs            # Simple contract without Kani proof
├── custom_contract.rs          # Simple contract without Kani proof
├── test_failure.rs             # Intentional verification failure examples
├── test_failure_bad.rs         # Impossible assertion (always fails)
│
├── ── EXTERNAL SMART CONTRACT SDKS ──
├── smart-contract-rs/          # Wavelet/Perlin smart contract SDK
│   ├── examples/               # 6 example contracts:
│   │   ├── chat/               #   Messaging contract
│   │   ├── lucky-draw/         #   Token rewards contract
│   │   ├── nft/                #   NFT contract
│   │   ├── token/              #   Token contract
│   │   ├── transfer-back/      #   Transfer-back contract
│   │   └── recursive-invocation/ # Recursive contract
│   ├── smart-contract/         # Core SDK crate
│   └── smart-contract-macros/  # Procedural macro crate (#[smart_contract])
├── smart-contract/             # Another smart contract project
├── decentralized-chat-master/  # Decentralized chat application
├── program-examples-main/      # Solana program examples (basics, tokens, oracles, etc.)
│
├── ── OUTPUT ──
├── results/                    # Generated verification results (per-contract folders)
│   ├── <contract_name>/
│   │   ├── <name>_original.txt # Backup of original source
│   │   ├── <name>_mod.txt      # Modified source with injected assertions
│   │   ├── injection.log       # Assertion injection log
│   │   ├── kani_output.txt     # Full Kani verification output
│   │   ├── SUMMARY.txt         # Verification summary with stats
│   │   └── coverage_report/    # LLVM branch coverage HTML report
│   │       ├── index.html      # Interactive coverage report
│   │       └── LLVM_COVERAGE_SUMMARY.txt
├── error.txt                   # Error log from previous runs
└── target/                     # Cargo build artifacts (gitignored)
```

---

## 3. CORE PIPELINE — HOW VERIFICATION WORKS

The verification pipeline has **6 stages**. The orchestration scripts automate all of them:

```
┌──────────────────┐
│  1. INPUT        │  A .rs file (smart contract or standalone Rust)
└────────┬─────────┘
         ↓
┌──────────────────┐
│  2. BACKUP       │  cp original.rs → original.rs.bak
└────────┬─────────┘
         ↓
┌──────────────────┐
│  3. INJECTION    │  python3 rust_injector.py original.rs
│                  │  • Finds every `if`/`while` condition
│                  │  • Injects 2 assertions per condition:
│                  │    assert!(!(condition), "REACHABLE_TRUE");
│                  │    assert!((condition), "REACHABLE_FALSE");
│                  │  • For smart contracts: also generates
│                  │    #[kani::proof] harness functions
└────────┬─────────┘
         ↓
┌──────────────────┐
│  4. KANI RUN     │  kani instrumented.rs
│                  │  • Symbolic execution explores ALL input paths
│                  │  • Each assert! is checked:
│                  │    - If REACHABLE_TRUE fails → that branch IS reachable
│                  │    - If REACHABLE_FALSE fails → the negation IS reachable
│                  │  • Results written to kani_output.txt
└────────┬─────────┘
         ↓
┌──────────────────┐
│  5. LLVM COV     │  cargo +nightly llvm-cov --branch --html
│                  │  • Generates branch-level coverage report
│                  │  • HTML report in results/<name>/coverage_report/
└────────┬─────────┘
         ↓
┌──────────────────┐
│  6. RESTORE      │  mv original.rs.bak → original.rs
│  & REPORT        │  Generate SUMMARY.txt with stats
└──────────────────┘
```

### Key Insight — The Assertion Logic

For every conditional branch like:
```rust
if x > 100 {
    // Path A
} else {
    // Path B
}
```

Two assertions are injected right after the `if` line:
```rust
if x > 100 {
    assert!(!(x > 100), "REACHABLE_TRUE");   // Fails when x > 100 → proves Path A is reachable
    assert!((x > 100), "REACHABLE_FALSE");    // Fails when x <= 100 → proves Path B is reachable
    // Path A
} else {
    // Path B
}
```

When Kani reports a `FAILURE` for `REACHABLE_TRUE`, it means **that code path IS reachable** (the assertion was violated, meaning the condition was true and execution reached that point). The same logic applies inversely for `REACHABLE_FALSE`.

This is a **reachability analysis technique** — failures are expected outcomes that prove branch coverage.

---

## 4. FILE-BY-FILE DETAILED DOCUMENTATION

---

### 4.1 Configuration Files

#### `Cargo.toml`
```toml
[package]
name = "rust_try"
version = "0.1.0"
edition = "2024"
```
- The root Cargo project. No dependencies (test files are standalone).
- Edition 2024 means it uses the latest Rust edition features.

#### `rust-toolchain.toml`
```toml
[toolchain]
channel = "nightly-2026-03-10"
components = ["rustfmt", "clippy", "llvm-tools-preview"]
```
- **Pins the Rust compiler** to a specific nightly build for reproducibility.
- `llvm-tools-preview` is required for `cargo llvm-cov` to work.
- This prevents breakage from newer nightly versions.

---

### 4.2 Python Tools

#### `rust_injector.py` — The Core Assertion Injector + Harness Generator

**Role**: The primary tool that instruments Rust source files. It does two things:

**Part 1 — Assertion Injection:**
- Reads a `.rs` file line by line.
- For each `if` or `while` condition, extracts the boolean expression.
- Injects two `assert!` lines immediately after:
  - `assert!(!(condition), "REACHABLE_TRUE");`
  - `assert!((condition), "REACHABLE_FALSE");`
- Skips `if let` expressions (since they aren't simple boolean conditions).

**Part 2 — Kani Harness Generation (Smart Contracts Only):**
- Detects if the file contains `#[smart_contract]` attribute.
- If yes, finds the `impl` block for the smart contract struct.
- Extracts all functions (excluding `init`, `main`, `fmt`, `default`).
- Generates a `#[kani::proof]` harness function for each, using `kani::any()` for symbolic inputs.
- For `Parameters` types, uses `unsafe { std::mem::transmute_copy(...) }` to bypass the `Arbitrary` trait requirement.

**Usage**: `python3 rust_injector.py <file.rs>`
**Output**: Modifies the file in-place (via temp file + `os.replace`). Prints the assertion count to stdout (used by shell scripts).

**Functions:**
| Function | Purpose |
|---|---|
| `synthesize_assertions(condition)` | Creates 2 assert lines from a boolean condition |
| `inject_assertions(line)` | Matches `if`/`while` patterns and calls synthesize |
| `is_smart_contract_file(content)` | Checks for `#[smart_contract]` marker |
| `find_smart_contract_impl(content)` | Extracts the `impl` block with brace-matching |
| `extract_functions_from_block(block)` | Finds function signatures in an impl block |
| `generate_harness(struct, func, args)` | Builds a `#[kani::proof]` function string |
| `generate_all_harnesses(content)` | Orchestrates harness generation for all funcs |

---

#### `harness_generator.py` — Alternative Standalone Harness Generator

**Role**: A more feature-rich, class-based alternative to `rust_injector.py`. It processes `pub fn` functions in any Rust file (not just smart contracts).

**Key Differences from `rust_injector.py`:**
- Uses a `KaniHarnessGenerator` class with state.
- Creates a full `results/<filename>/` directory structure.
- Saves: original backup, modified file, injection log, and summary with percentage stats.
- Generates a single `kani_harness()` function that tests all functions (rather than one harness per function).
- Also provides `display_overall_verification_summary()` to aggregate results across all processed modules.

**Usage**: `python3 harness_generator.py <file.rs>`

---

### 4.3 Shell Scripts — Orchestration Layer

#### `verify_rust.sh` — Main Verification Script (504 lines)

**Role**: The primary orchestration script. Verifies Rust contracts in a folder or a single file.

**Usage:**
```bash
./verify_rust.sh <folder_or_file>
./verify_rust.sh complex.rs      # Single file
./verify_rust.sh .               # Current directory
./verify_rust.sh /path/to/folder # Full folder scan
```

**Full Pipeline:**
1. Detects whether input is a file or directory.
2. If directory: recursively finds all `.rs` files (excluding `main.rs`, test files).
3. If Cargo workspace: extracts workspace members and processes each `src/lib.rs`.
4. For **each** `.rs` file:
   - Creates backup (`file.rs.bak`)
   - Runs `python3 rust_injector.py` to inject assertions
   - Saves modified file to `results/<name>/<name>_mod.txt`
   - Runs `kani <file.rs>` for formal verification
   - Counts REACHABLE_TRUE / REACHABLE_FALSE assertions
   - Determines PASSED/FAILED status
   - Runs `cargo +nightly llvm-cov --branch --html` for LLVM coverage
   - Generates `SUMMARY.txt` and `LLVM_COVERAGE_SUMMARY.txt`
   - Restores original file from backup
   - Cleans up Kani metadata (`.out`, `.json`, `.symtab`, `.profraw`, etc.)
5. Prints overall summary: total contracts, passed, failed, execution time.
6. Skips Solana/Anchor contracts that require the full Solana toolchain.

**Important Details:**
- Uses the pinned toolchain: `cargo +nightly-2026-03-10 llvm-cov`
- Tracks per-file and overall execution timing
- Calculates verification coverage percentages
- Pre-cleans leftover artifacts from previous runs

---

#### `verify_all_clients.sh` — Multi-Client Workspace Verification (253 lines)

**Role**: Extends `verify_rust.sh` to verify contracts organized in a `clients/` folder structure.

**Expected directory structure:**
```
workspace/
├── clients/
│   ├── client1/  (contains *.rs files)
│   └── client2/  (contains *.rs files)
```

**Pipeline (per client):**
1. Iterates over all client subdirectories.
2. Finds `.rs` files in each client folder.
3. For each contract: backup → inject → Kani verify → parse results → restore.
4. Creates per-client results under `results/clients/<client_name>/`.
5. Also scans root-level `.rs` files and saves to `results/root_contracts/`.
6. Cleans up all generated verification artifacts.

---

#### `process_smartcontracts.sh` — Solana Smart Contract Pipeline (180 lines)

**Role**: Specifically processes the 6 example smart contracts from `smart-contract-rs/examples/`.

**Target Contracts:** `chat`, `lucky-draw`, `nft`, `token`, `transfer-back`, `recursive-invocation`

**Pipeline:**
1. For each contract, copies `src/lib.rs` to a temp file.
2. Runs `rust_injector.py` to inject assertions.
3. Runs `kani <tempfile> --default-unwind <depth> -Z stubbing -Z function-contracts`.
4. Parses violation counts (REACHABLE_TRUE/FALSE failures in Kani output).
5. Calculates condition coverage percentage.
6. Generates per-contract result files in `Results/<contract>-kani/`.
7. Measures and reports execution time per contract and overall.

**Usage:**
```bash
./process_smartcontracts.sh . 5    # Quick (unwind depth 5)
./process_smartcontracts.sh . 10   # Thorough (unwind depth 10)
```

---

#### `test-system.sh` — System Readiness Checker (117 lines)

**Role**: Quick diagnostic script that verifies all tools are installed and ready.

**Checks:**
- `verify_rust.sh` exists and is executable
- `process_smartcontracts.sh` exists and is executable
- `rust_injector.py` exists
- All 6 smart contract `lib.rs` files exist
- Documentation files exist
- Previous verification results exist

---

#### `demo.sh` — Visual Explanation Demo (257 lines)

**Role**: A read-only, educational script that explains the verification pipeline step-by-step using ASCII art. Does NOT modify any files.

**Shows:**
- The first 20 lines of a demo contract
- Function count and names
- The complete file transformation flow (with ASCII box diagrams)
- What assertions look like before and after injection
- Expected folder structure after verification
- Example Kani output

---

### 4.4 Rust Source Files — Test Subjects

#### `binary.rs` — Binary Search Tree (300 lines)

**Type**: Data structure implementation + unit tests.

**Contents:**
- `BinaryTree<T>` enum with `Empty` and `NonEmpty(Box<TreeNode<T>>)` variants.
- `TreeNode<T>` struct with `element`, `left`, `right`.
- `walk()` — in-order traversal returning `Vec<T>`.
- `add()` — ordered insertion for `T: Ord`.
- `TreeIter` — external iterator implementing `Iterator` trait with a manual stack-based traversal.
- `IntoIterator` implementation for `&BinaryTree<T>`.
- `fuzz()` test — generates random trees and verifies in-order traversal produces sorted output.
- **6 unit tests** covering tree construction, adding elements, iteration, and fuzz testing.

**Notable**: Uses `rand` crate for the fuzz test. Demonstrates Rust ownership, generics, lifetimes, and trait implementations.

---

#### `complex.rs` — 20-Function Branching Test File (166 lines)

**Type**: Test subject for validation of the harness generator.

**Contents**: 20 public functions named `check_value_1` through `check_value_20`, each containing:
- Simple conditionals (`if/else`)
- Various parameter types: `u32`, `i32`, `i64`, `u64`, `u8`, `u16`, `i8`, `bool`
- Patterns: comparison, equality, modulo, bitwise (`0xDEADBEEF`), nested if, while loop, logical OR/AND, multi-branch if-else chains.
- A `main()` function that is explicitly skipped by the harness generator.

**Purpose**: The "benchmark" file — tests whether the injector can handle diverse conditional patterns and generate correct assertions for all 20 functions.

---

#### `simple.rs` — Basic Conditionals (31 lines)

**Type**: Minimal test file.

**Functions:**
- `simple_check(x: u32)` — checks `x > 50`
- `range_check(val: i32)` — checks `0 <= val <= 100`
- `equality_test(a: u32, b: u32)` — checks `a == b`

---

#### `shiba.rs` — Full ERC-20 Token Contract (571 lines)

**Type**: A complete ERC-20-style token implementation converted from Solidity to pure Rust, heavily instrumented with Kani harnesses.

**Token Details:**
- Name: "Shiba Astronaut", Symbol: "SHIBA", Decimals: 18
- Total supply: 10 trillion tokens (10 × 10^12 × 10^18)

**Core Struct:**
```rust
pub struct TokenData {
    pub name: String,
    pub symbol: String,
    pub decimals: u8,
    pub total_supply: u128,
    pub balances: HashMap<u64, u128>,
    pub allowance: HashMap<(u64, u64), u128>,
}
```

**Methods:**
| Method | Purpose |
|---|---|
| `new()` | Constructor — mints all tokens to account 1 |
| `balance_of(account)` | Returns balance of an account |
| `transfer(from, to, amount)` | Transfers tokens between accounts |
| `approve(owner, spender, amount)` | Sets spending allowance |
| `allowance(owner, spender)` | Gets current allowance |
| `transfer_from(from, to, spender, amount)` | Delegated transfer using allowance |
| `burn(owner, amount)` | Burns (destroys) tokens |
| `mint(owner, amount)` | Mints (creates) new tokens |

**Kani Harnesses (12 total):**
Each harness tests a specific property using `kani::any()` for symbolic inputs:
1. `verify_initialize` — token setup is valid
2. `verify_transfer_valid` — transfers work correctly
3. `verify_transfer_insufficient_balance` — rejects when balance too low
4. `verify_approve` — allowance is set correctly
5. `verify_transfer_from_valid` — delegated transfers work
6. `verify_transfer_from_insufficient_allowance` — rejects with insufficient allowance
7. `verify_balance_conservation` — total balance is conserved during transfers
8. `verify_no_negative_balance` — unsigned types prevent negatives
9. `verify_burn` — burn reduces balance and supply correctly
10. `verify_burn_insufficient_balance` — rejects burning more than owned
11. `verify_mint` — mint increases balance and supply correctly
12. `verify_transfer_to_self` — self-transfer doesn't change balance

**Note**: The file is already instrumented with `// KANI INJECTION: Check Reachability` assertion pairs throughout. These are injected by `rust_injector.py`.

---

#### `lucky_draw.rs` — Token Reward Smart Contract (93 lines)

**Type**: Smart contract using the `smart_contract` SDK.

**Logic**: Users call `lucky_draw()` with an amount. If the last byte of the transaction ID is 0, they receive tokens. Amount must be ≤ 10, and an internal counter prevents overflow.

**Struct**: `LuckyDraw(Contract, u64)` — wraps a base `Contract` with a counter.

**Error Handling**: Custom `LuckyDrawError` enum with `AmountTooHigh` and `CustomError` variants.

**Already has**: Kani injection assertions and an auto-generated harness `kani_harness_lucky_draw()`.

---

#### `sample1.rs` — NEAR Protocol Counter (39 lines)

**Type**: A NEAR Protocol smart contract using `near_sdk`.

**Contract**: `Counter` with `count: u32` and `owner_id: AccountId`.

**Methods:**
- `new()` — initializes with default
- `increment()` — payable function that increments counter
- `get_count()` — view function returning counter value

---

#### `testrust.rs` — Multi-threaded Fibonacci (42 lines)

**Type**: Standalone Rust program demonstrating threading.

**Logic**: Spawns 5 threads to calculate `fibonacci(30)` through `fibonacci(34)` in parallel using `std::thread::spawn`. Joins all handles at the end.

---

#### `crash_demo.rs` — Division by Zero (12 lines)

**Type**: Deliberate crash demo. Calls `a / 0` which panics at runtime.

---

#### `crash_runtime.rs` — Input-Dependent Crash (26 lines)

**Type**: Reads a byte from stdin and divides `100 / byte`. Crashes if input is 0. Uses `std::panic::catch_unwind` to catch the panic.

---

#### `panic_contract.rs` — Guaranteed Panics (28 lines)

**Type**: Two functions that always panic:
- `access_empty_vector()` — indexes into `vec![]` at position 0
- `unwrap_on_none()` — calls `.unwrap()` on `None`

---

#### `test_failure.rs` — Intentional Verification Failures (23 lines)

**Type**: Functions designed to fail Kani verification:
- `unsafe_division(x, y)` — `x / y` fails when `y = 0`
- `potential_overflow(x, y)` — `checked_add().unwrap()` fails on overflow
- `array_out_of_bounds()` — accesses `arr[10]` on a 3-element array

---

#### `test_failure_bad.rs` — Impossible Assertion (14 lines)

**Type**: Contains `assert!(x <= 5)` inside an `if x > 10` block — a logical impossibility that always fails.

---

#### `test_contract.rs` / `custom_contract.rs` — Simple Contracts (16 lines each)

**Type**: Minimal contracts with `verify_amount()` and `check_balance()`. No Kani harnesses — these are targets for the automated harness generator.

---

### 4.5 External Subdirectories

#### `smart-contract-rs/`
The **Wavelet/Perlin smart contract SDK** — provides:
- `smart-contract/` — core crate with `Parameters`, payload handling
- `smart-contract-macros/` — procedural macros (`#[smart_contract]`)
- `examples/` — 6 example contracts (chat, lucky-draw, nft, token, transfer-back, recursive-invocation)

These are the primary targets for `process_smartcontracts.sh`.

#### `decentralized-chat-master/`
A decentralized chat application with a Rust backend/contract and web frontend.

#### `program-examples-main/`
Solana program examples repository containing:
- `basics/` — fundamental Solana programs
- `tokens/` — SPL token programs
- `compression/` — state compression examples
- `oracles/` — oracle programs
- `tools/` and `scripts/`

#### `smart-contract/`
Another standalone smart contract project with `src/` and a hello-world example.

---

## 5. INTER-FILE RELATIONSHIPS & DATA FLOW

```
                     ┌───────────────────────┐
                     │   Shell Scripts        │
                     │ (Orchestration Layer)  │
                     └───────────┬───────────┘
                                 │
          ┌──────────────────────┼──────────────────────┐
          │                      │                      │
          ↓                      ↓                      ↓
┌─────────────────┐  ┌──────────────────┐  ┌──────────────────────┐
│ verify_rust.sh  │  │verify_all_clients│  │process_smartcontracts│
│ (Main script)   │  │.sh (Multi-client)│  │.sh (Solana SDK)      │
└────────┬────────┘  └───────┬──────────┘  └──────────┬───────────┘
         │                   │                        │
         └─────────┬─────────┘────────────────────────┘
                   │
                   ↓ calls
         ┌─────────────────────┐
         │  rust_injector.py   │  ← Python assertion injector
         │  (or harness_       │
         │   generator.py)     │
         └────────┬────────────┘
                  │ modifies
                  ↓
         ┌─────────────────────┐
         │   *.rs source files │  ← Test subject Rust files
         │  (smart contracts   │
         │   or standalone)    │
         └────────┬────────────┘
                  │ fed into
                  ↓
         ┌─────────────────────┐     ┌─────────────────────┐
         │   Kani Verifier     │     │   cargo llvm-cov     │
         │   (kani <file>)     │     │   (--branch --html)  │
         └────────┬────────────┘     └──────────┬──────────┘
                  │                              │
                  ↓ outputs to                   ↓ outputs to
         ┌──────────────────────────────────────────────────┐
         │                 results/<name>/                   │
         │  • SUMMARY.txt       • kani_output.txt           │
         │  • <name>_mod.txt    • <name>_original.txt       │
         │  • injection.log     • coverage_report/index.html│
         └──────────────────────────────────────────────────┘
```

---

## 6. KANI VERIFICATION — HOW IT WORKS

[Kani](https://model-checking.github.io/kani/) is a **formal verification tool** for Rust that uses **bounded model checking** (powered by CBMC). Unlike testing, Kani checks ALL possible inputs symbolically.

### Key Concepts

| Concept | Explanation |
|---|---|
| `#[kani::proof]` | Marks a function as a verification harness (like `#[test]` but exhaustive) |
| `kani::any::<T>()` | Creates a **symbolic value** representing ALL possible values of type T |
| `assert!(...)` | If Kani finds ANY input that violates the assertion, it reports a FAILURE |
| `--default-unwind N` | Limits loop unrolling depth to N iterations |
| `-Z stubbing` | Enables function stubbing for complex dependencies |
| `-Z function-contracts` | Enables function contract checking |

### Example from `shiba.rs`
```rust
#[cfg(kani)]
#[kani::proof]
fn verify_transfer_valid() {
    let mut token = TokenData::new();
    let from: u64 = kani::any();    // ANY possible u64
    let to: u64 = kani::any();      // ANY possible u64
    let amount: u128 = kani::any(); // ANY possible u128
    
    let initial_from = token.balance_of(from);
    
    if amount <= initial_from {
        let result = token.transfer(from, to, amount);
        if result {
            let final_from = token.balance_of(from);
            assert!(final_from == initial_from - amount, "from balance incorrect");
        }
    }
}
```

This doesn't test one value — it mathematically proves the property holds for **every** possible combination of `from`, `to`, and `amount`.

---

## 7. LLVM COVERAGE — HOW IT WORKS

After Kani verification, the pipeline also runs:

```bash
cargo +nightly-2026-03-10 llvm-cov --branch --html --output-dir <dir>
```

This uses **LLVM source-based code coverage** to measure:
- **Line coverage** — which lines were executed
- **Branch coverage** — which branches (if/else) were taken
- **Region coverage** — which code regions were covered

The output is an interactive HTML report where you can see red (uncovered) and green (covered) lines.

---

## 8. COMMON QUESTIONS & ANSWERS

### Q: "Are the original files modified permanently?"
**A**: No. The pipeline always backs up the original (`file.rs.bak`), modifies a copy, runs verification, then restores the backup. Modified versions are saved in `results/` for audit only.

### Q: "What does REACHABLE_TRUE vs REACHABLE_FALSE mean?"
**A**:
- `REACHABLE_TRUE` assertion: `assert!(!(condition), "REACHABLE_TRUE")` — this **fails** when the condition IS true, proving the true-branch is reachable.
- `REACHABLE_FALSE` assertion: `assert!((condition), "REACHABLE_FALSE")` — this **fails** when the condition IS false, proving the false-branch is reachable.
- In Kani, **failures are the desired result** — they prove reachability.

### Q: "What's the difference between `rust_injector.py` and `harness_generator.py`?"
**A**: `rust_injector.py` is the primary tool used by the shell scripts. It handles both assertion injection and smart contract harness generation. `harness_generator.py` is an alternative class-based implementation with more reporting features but generates a simpler single-harness-per-file approach. The shell scripts exclusively use `rust_injector.py`.

### Q: "Why is the toolchain pinned to nightly-2026-03-10?"
**A**: To ensure reproducible builds. Nightly Rust changes daily, and Kani + `cargo llvm-cov` can break on newer versions. Pinning prevents surprise failures.

### Q: "Which files are smart contracts vs. standalone Rust?"
**A**:
- **Smart contracts**: `lucky_draw.rs` (Wavelet SDK), `sample1.rs` (NEAR), files in `smart-contract-rs/examples/`, `program-examples-main/`
- **Standalone Rust**: `binary.rs`, `complex.rs`, `simple.rs`, `shiba.rs` (Solidity-port to pure Rust), `testrust.rs`, crash demos

### Q: "How do I run verification?"
**A**:
```bash
# Single file
./verify_rust.sh complex.rs

# Entire folder
./verify_rust.sh .

# Smart contracts from SDK
./process_smartcontracts.sh . 10

# Multi-client workspace
./verify_all_clients.sh /path/to/workspace
```

### Q: "What does `shiba.rs` verify?"
**A**: It proves 12 properties of an ERC-20 token contract:
- Correct initialization
- Transfer correctness (balance deducted from sender, added to receiver)
- Balance conservation (total balance unchanged during transfer)
- Rejection of insufficient funds
- Correct allowance/approval mechanism
- Burn and mint correctness
- Self-transfer invariance

---

## 9. GLOSSARY

| Term | Definition |
|---|---|
| **Kani** | A formal verification tool for Rust using bounded model checking (CBMC backend) |
| **Harness** | A `#[kani::proof]` function that sets up symbolic inputs and calls the code under test |
| **Symbolic execution** | Exploring ALL possible execution paths rather than specific test values |
| **Bounded model checking** | Verification technique that checks all paths up to a bounded depth |
| **CBMC** | C Bounded Model Checker — the underlying engine Kani uses |
| **Assertion injection** | Automatically inserting `assert!` statements to check branch reachability |
| **REACHABLE_TRUE** | An assertion that proves the true-branch of a condition is reachable |
| **REACHABLE_FALSE** | An assertion that proves the false-branch of a condition is reachable |
| **Branch coverage** | Metric measuring which branches (if/else paths) were executed |
| **`cargo llvm-cov`** | Rust tool for LLVM-based code coverage measurement |
| **`kani::any()`** | Creates a symbolic value representing ALL possible values of a type |
| **ERC-20** | Ethereum token standard (the pattern `shiba.rs` implements in Rust) |
| **Wavelet SDK** | The `smart-contract-rs` framework used by `lucky_draw.rs` and examples |
| **NEAR Protocol** | Blockchain platform — `sample1.rs` uses its SDK |
| **Solana** | Blockchain platform — `program-examples-main/` contains Solana programs |
| **Unwind depth** | Maximum loop iteration count for bounded model checking |

---

## 10. QUICK REFERENCE — Which Script to Use

| Goal | Command |
|---|---|
| Verify a single `.rs` file | `./verify_rust.sh myfile.rs` |
| Verify all contracts in a folder | `./verify_rust.sh /path/to/folder` |
| Verify current directory | `./verify_rust.sh .` |
| Verify multi-client workspace | `./verify_all_clients.sh /path/to/workspace` |
| Verify Solana SDK smart contracts | `./process_smartcontracts.sh . 10` |
| Check if system is ready | `./test-system.sh` |
| See a demo explanation | `./demo.sh` |
| Manually inject assertions | `python3 rust_injector.py myfile.rs` |
| Alternative harness generator | `python3 harness_generator.py myfile.rs` |
| View results | `cat results/<name>/SUMMARY.txt` |
| View coverage report | Open `results/<name>/coverage_report/index.html` in browser |
