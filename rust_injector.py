import sys
import re
import os

# ---------------------------------------------------------
# PART 1: ASSERTION LOGIC
# ---------------------------------------------------------
def synthesize_assertions(condition):
    cond = condition.strip()
    if cond.startswith("(") and cond.endswith(")"):
        cond = cond[1:-1]
    
    # Kani Assertions
    s1 = f'\t// KANI INJECTION: Check Reachability'
    s2 = f'\tassert!(!({cond}), "REACHABLE_TRUE");'
    s3 = f'\tassert!(({cond}), "REACHABLE_FALSE");'
    return [s1, s2, s3]

def inject_assertions(line):
    # Match if/while statements more flexibly
    pattern = r'^\s*(if|while)\s+(.+?)\s*\{' 
    match = re.search(pattern, line)
    
    injections = []
    if match:
        condition = match.group(2).strip()
        if "let " not in condition:
            injections = synthesize_assertions(condition)
    return injections

def is_smart_contract_file(content):
    return "#[smart_contract]" in content or "smart_contract_macros" in content

# ---------------------------------------------------------
# PART 2: HARNESS GENERATOR
# ---------------------------------------------------------
def find_smart_contract_impl(content):
    regex = r'#\[smart_contract\]\s*.*?\s*impl\s+([a-zA-Z0-9_]+)\s*\{'
    match = re.search(regex, content, re.DOTALL)
    
    if not match:
        print("DEBUG: No #[smart_contract] impl block found.")
        return None, None
        
    struct_name = match.group(1)
    print(f"DEBUG: Found Smart Contract Struct: {struct_name}")
    
    start_index = match.end() - 1 
    open_braces = 0
    block_content = ""
    found_start = False
    
    for i in range(start_index, len(content)):
        char = content[i]
        block_content += char
        if char == '{':
            open_braces += 1
            found_start = True
        elif char == '}':
            open_braces -= 1
        
        if found_start and open_braces == 0:
            break
            
    return struct_name, block_content

def extract_functions_from_block(block_content):
    funcs = []
    pattern = r'fn\s+([a-zA-Z0-9_]+)\s*\((.*?)\)\s*(?:->.*?)?\{'
    matches = re.finditer(pattern, block_content)
    for match in matches:
        name = match.group(1)
        args = match.group(2)
        if name not in ["init", "main", "fmt", "default"]:
            funcs.append((name, args))
    return funcs

def generate_harness(struct_name, func_name, args_str):
    lines = []
    lines.append(f"\n#[cfg(kani)]")
    lines.append(f"#[kani::proof]")
    lines.append(f"fn kani_harness_{func_name}() {{")

    # FIX: Use unsafe transmute_copy to bypass Arbitrary trait check
    # We create 256 bytes of symbolic data and cast it to Parameters.
    if "Parameters" in args_str:
        lines.append(f"    let mut params: smart_contract::payload::Parameters = unsafe {{")
        lines.append(f"        let raw_bytes: [u8; 256] = kani::any();")
        lines.append(f"        std::mem::transmute_copy(&raw_bytes)")
        lines.append(f"    }};")

    if "self" in args_str:
        lines.append(f"    let mut contract = {struct_name}::init(&mut params);")
        lines.append(f"    let _ = contract.{func_name}(&mut params);")

    lines.append("}")
    return "\n".join(lines)

def generate_all_harnesses(code_content):
    harnesses = []
    if is_smart_contract_file(code_content):
        struct_name, block_content = find_smart_contract_impl(code_content)
        if struct_name and block_content:
            funcs = extract_functions_from_block(block_content)
            for func_name, args_str in funcs:
                print(f"DEBUG: Generating harness for function '{func_name}'")
                harness = generate_harness(struct_name, func_name, args_str)
                harnesses.append(harness)
    return harnesses

# ---------------------------------------------------------
# MAIN
# ---------------------------------------------------------
def main():
    if len(sys.argv) < 2: return
    input_file = sys.argv[1]
    temp_file = input_file + ".temp"
    
    condition_count = 0
    full_content = ""
    
    with open(input_file, 'r') as f_in:
        lines = f_in.readlines()
        full_content = "".join(lines)
        
    with open(temp_file, 'w') as f_out:
        for line in lines:
            f_out.write(line)
            injections = inject_assertions(line)
            if injections:
                for inj in injections:
                    f_out.write(inj + "\n")
                condition_count += 1
        
        harnesses = generate_all_harnesses(full_content)
        if harnesses:
            f_out.write("\n\n// --- AUTO-GENERATED KANI HARNESSES ---\n")
            for h in harnesses:
                f_out.write(h + "\n")
                
        f_out.flush() 

    print(condition_count * 2)
    os.replace(temp_file, input_file)

if __name__ == "__main__":
    main()
