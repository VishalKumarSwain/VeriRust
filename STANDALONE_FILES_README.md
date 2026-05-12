# Standalone Rust Files for Verification

This directory contains standalone Rust files that can be verified using the `verify_rust.sh` script.

## Files Created

### 1. `simple_contract.rs`
- Basic arithmetic operations
- Conditional logic with if-else chains
- Simple function calls
- Good starting point for verification testing

### 2. `complex_contract.rs`
- Struct with methods (Account simulation)
- State management with mutable references
- Multiple execution paths
- Transfer operations between accounts
- Good for testing state transitions

### 3. `edge_cases.rs` (MODIFIED FOR LOWER COVERAGE)
- **Intentionally buggy code** with verification issues
- Division by zero vulnerabilities (`unsafe_division`)
- Integer overflow problems (`unchecked_addition`)
- Array bounds violations (`dangerous_array_access`)
- Deep recursion that may cause stack overflow
- Off-by-one errors in range checking
- Potential panic conditions
- Unreachable code paths
- **Expected**: Lower verification coverage due to bugs and complex logic

## How to Verify

Run the verification script on any of these files:

```bash
# Verify a single file
./verify_rust.sh simple_contract.rs
./verify_rust.sh complex_contract.rs
./verify_rust.sh edge_cases.rs

# Results will be saved in results/[filename]/ directory
```

## What the Script Does

For each file, the verification process:
1. Injects assert statements to test code paths
2. Runs Kani model checker for formal verification
3. Generates LLVM coverage reports
4. Creates detailed summaries in the results folder

## Expected Results

- **simple_contract.rs**: Should pass with good coverage of arithmetic operations
- **complex_contract.rs**: Should demonstrate state management verification
- **edge_cases.rs**: **NOW SHOWS 0% COVERAGE** - Contains intentional bugs and the verification tools (kani/cargo) are not installed, causing verification to fail:
  - Division by zero vulnerabilities
  - Integer overflow problems
  - Array bounds violations
  - Deep recursion issues
  - Complex nested conditions
  - State machine with potentially unreachable states
  - **Expected coverage: 0% (FAILED)**

## Important Notes

- **Verification Tools**: The `kani` model checker and `cargo` are not installed in this environment
- **Expected Behavior**: Files will show **FAILED** status with **0% coverage** because the verification tools cannot run
- **Real Environment**: In a properly configured environment with kani and cargo installed, the verification would actually analyze the code and potentially find the intentional bugs

## File Structure After Verification

```
results/
├── simple_contract/
│   ├── SUMMARY.txt
│   ├── kani_output.txt
│   ├── coverage_report/
│   │   ├── index.html
│   │   └── LLVM_COVERAGE_SUMMARY.txt
│   └── [other generated files]
├── complex_contract/
│   └── [similar structure]
└── edge_cases/
    └── [similar structure]
```