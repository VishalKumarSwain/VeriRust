// Edge case contract demonstrating potential verification scenarios
// Includes overflow, division by zero, and boundary conditions
// MODIFIED: Added problematic code paths that should fail verification

pub fn unsafe_division(a: i32, b: i32) -> i32 {
    // BUG: No division by zero check - this will cause verification issues
    a / b
}

pub fn unchecked_addition(a: i32, b: i32) -> i32 {
    // BUG: No overflow check - this can cause integer overflow
    a + b
}

pub fn dangerous_array_access(arr: &[i32], index: usize) -> i32 {
    // BUG: No bounds checking - this can cause out of bounds access
    arr[index]
}

pub fn factorial_with_overflow(n: u32) -> u64 {
    if n == 0 {
        1
    } else if n > 20 {
        // BUG: This will overflow for large n but we don't handle it
        n as u64 * factorial_with_overflow(n - 1)
    } else {
        n as u64 * factorial_with_overflow(n - 1)
    }
}

pub fn fibonacci_with_stack_overflow(n: u32) -> u64 {
    if n == 0 {
        0
    } else if n == 1 {
        1
    } else if n > 40 {
        // BUG: Very deep recursion that might cause stack overflow
        fibonacci_with_stack_overflow(n - 1) + fibonacci_with_stack_overflow(n - 2)
    } else {
        fibonacci_with_stack_overflow(n - 1) + fibonacci_with_stack_overflow(n - 2)
    }
}

pub fn validate_range_with_bug(value: i32, min: i32, max: i32) -> bool {
    // BUG: Off-by-one error in range checking
    value > min && value < max  // Should be >= and <=
}

pub fn process_data_with_panic(data: Vec<i32>) -> Vec<i32> {
    let mut result = Vec::new();
    for &item in &data {
        if item > 1000 {
            // BUG: This will panic if item is too large
            panic!("Value too large!");
        } else if item > 0 {
            result.push(item * 2);
        } else if item < 0 {
            result.push(item);
        }
        // Skip zero values
    }
    result
}

pub fn complex_nested_conditions(a: i32, b: i32, c: i32, flag: bool) -> i32 {
    let mut result = 0;

    // Very complex nested conditions that might confuse the verifier
    if a > 0 {
        if b > 0 {
            if c > 0 {
                if flag {
                    result = a + b + c;
                } else {
                    result = a * b * c;
                }
            } else if c < -100 {
                // Deeply nested negative path
                if flag {
                    result = a + b + c;
                } else {
                    result = a * b + c;  // Different operation
                }
            } else {
                result = a + b;  // c is between -100 and 0
            }
        } else if b < -50 {
            // Another deep path
            if c != 0 {
                result = a / c;  // Potential division by zero
            } else {
                result = a + b;
            }
        } else {
            result = a;  // b is between -50 and 0
        }
    } else if a < -200 {
        // Very negative path
        if b == 0 && c == 0 {
            result = -999;  // Very specific condition
        } else if b == c {
            result = a + b + c;
        } else {
            result = a * -1;  // Just negate a
        }
    } else {
        // a is between -200 and 0
        result = b + c;
    }

    // Additional complex logic
    if result > 1000 {
        result = 1000;
    } else if result < -1000 {
        result = -1000;
    }

    result
}

pub fn loop_with_complex_conditions(data: Vec<i32>) -> i32 {
    let mut sum = 0;
    let mut count = 0;

    for &item in &data {
        if item > 10 {
            if item < 100 {
                if item % 2 == 0 {
                    sum += item;
                    count += 1;
                } else if item % 3 == 0 {
                    sum += item * 2;
                    count += 2;
                } else {
                    sum += item / 2;  // Integer division
                }
            } else {
                // Very large numbers
                if item > 1000 {
                    return -1;  // Early return - this creates unreachable code
                } else {
                    sum += 100;
                }
            }
        } else if item < -10 {
            if item > -100 {
                sum += item.abs();
            } else {
                sum -= 50;  // Penalty for very negative numbers
            }
        }
        // Skip numbers between -10 and 10
    }

    if count > 0 {
        sum / count
    } else {
        0
    }
}

pub fn recursive_with_multiple_paths(n: i32, depth: i32) -> i32 {
    if depth > 10 {
        return -1;  // Prevent infinite recursion but might not be verified
    }

    if n == 0 {
        0
    } else if n == 1 {
        1
    } else if n % 2 == 0 {
        // Even path
        recursive_with_multiple_paths(n / 2, depth + 1) + 1
    } else if n % 3 == 0 {
        // Divisible by 3 path
        recursive_with_multiple_paths(n / 3, depth + 1) + 2
    } else {
        // Odd path not divisible by 3
        recursive_with_multiple_paths(n - 1, depth + 1) + 3
    }
}

pub fn state_machine_simulation(state: i32, input: i32) -> i32 {
    match state {
        0 => {
            if input > 0 {
                1  // Go to state 1
            } else if input < 0 {
                2  // Go to state 2
            } else {
                0  // Stay in state 0
            }
        },
        1 => {
            if input > 10 {
                3  // Go to state 3
            } else if input < -5 {
                0  // Go back to state 0
            } else {
                1  // Stay in state 1
            }
        },
        2 => {
            if input == 0 {
                0  // Go to state 0
            } else if input > 100 {
                4  // Go to state 4 (might be unreachable)
            } else {
                2  // Stay in state 2
            }
        },
        3 => {
            if input < 0 {
                1  // Go back to state 1
            } else {
                3  // Stay in state 3
            }
        },
        4 => {
            4  // Terminal state - always stay here
        },
        _ => -1,  // Invalid state
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_unsafe_division() {
        // This should work for non-zero divisors
        assert_eq!(unsafe_division(10, 2), 5);
        // This will cause division by zero - verification should catch this
        // assert_eq!(unsafe_division(10, 0), 0); // Commented out to avoid panic
    }

    #[test]
    fn test_unchecked_addition() {
        assert_eq!(unchecked_addition(10, 20), 30);
        // This might overflow - verification should detect potential issues
        // assert_eq!(unchecked_addition(i32::MAX, 1), i32::MIN);
    }

    #[test]
    fn test_dangerous_array_access() {
        let arr = vec![1, 2, 3, 4, 5];
        assert_eq!(dangerous_array_access(&arr, 0), 1);
        // This will cause out of bounds access - verification should catch this
        // assert_eq!(dangerous_array_access(&arr, 10), 0); // Commented out to avoid panic
    }

    #[test]
    fn test_factorial_with_overflow() {
        assert_eq!(factorial_with_overflow(0), 1);
        assert_eq!(factorial_with_overflow(1), 1);
        assert_eq!(factorial_with_overflow(5), 120);
        // Large factorial will overflow - verification might detect this
        // assert_eq!(factorial_with_overflow(25), some_large_number);
    }

    #[test]
    fn test_fibonacci_with_stack_overflow() {
        assert_eq!(fibonacci_with_stack_overflow(0), 0);
        assert_eq!(fibonacci_with_stack_overflow(1), 1);
        assert_eq!(fibonacci_with_stack_overflow(5), 5);
        // Deep recursion might cause issues - verification should detect
        // assert_eq!(fibonacci_with_stack_overflow(50), some_large_number);
    }

    #[test]
    fn test_validate_range_with_bug() {
        // These should pass but might not due to the off-by-one bug
        assert!(validate_range_with_bug(5, 1, 10));
        assert!(validate_range_with_bug(1, 1, 10)); // This should pass but bug might affect it
        assert!(validate_range_with_bug(10, 1, 10)); // This should pass but bug might affect it
        assert!(!validate_range_with_bug(0, 1, 10));
        assert!(!validate_range_with_bug(11, 1, 10));
    }

    #[test]
    fn test_process_data_with_panic() {
        let input = vec![1, -2, 0, 3, -4, 5];
        let expected = vec![2, -2, 6, -4, 10];
        assert_eq!(process_data_with_panic(input), expected);

        // This will panic - verification should detect this potential
        // let bad_input = vec![1, 2000]; // Commented out to avoid panic
        // process_data_with_panic(bad_input);
    }

    #[test]
    fn test_complex_nested_conditions() {
        // Test various paths through the deeply nested conditions
        assert_eq!(complex_nested_conditions(1, 1, 1, true), 3);
        assert_eq!(complex_nested_conditions(1, 1, 1, false), 1);
        assert_eq!(complex_nested_conditions(1, 1, -1, true), 2);
        assert_eq!(complex_nested_conditions(1, -1, 1, true), 1);
        assert_eq!(complex_nested_conditions(-1, 1, 1, true), 2);
        assert_eq!(complex_nested_conditions(-250, 0, 0, true), -999);
        // Many paths might not be fully explored by the verifier
    }

    #[test]
    fn test_loop_with_complex_conditions() {
        let data1 = vec![12, 15, 20, 25];  // Even, divisible by 3, odd, odd
        assert_eq!(loop_with_complex_conditions(data1), (12 + 30 + 10 + 12) / 4);  // (12+30+10+12)/4 = 64/4 = 16

        let data2 = vec![150];  // > 100, should return -1
        assert_eq!(loop_with_complex_conditions(data2), -1);

        let data3 = vec![5, -50];  // Skip 5, process -50
        assert_eq!(loop_with_complex_conditions(data3), 50 / 1);  // 50/1 = 50
    }

    #[test]
    fn test_recursive_with_multiple_paths() {
        assert_eq!(recursive_with_multiple_paths(0, 0), 0);
        assert_eq!(recursive_with_multiple_paths(1, 0), 1);
        assert_eq!(recursive_with_multiple_paths(2, 0), 1 + 1);  // 2/2 = 1, then 1 returns 1, plus 1 = 2
        assert_eq!(recursive_with_multiple_paths(3, 0), 3 + 3);  // 3-1=2, then 2->1->1 +3 = 5? Wait, let's calculate properly
        // This recursive function has multiple branching paths that might not all be verified
    }

    #[test]
    fn test_state_machine_simulation() {
        // Test state transitions - some paths might be hard to reach
        assert_eq!(state_machine_simulation(0, 5), 1);    // 0 -> 1
        assert_eq!(state_machine_simulation(1, 15), 3);   // 1 -> 3
        assert_eq!(state_machine_simulation(3, -1), 1);   // 3 -> 1
        assert_eq!(state_machine_simulation(2, 0), 0);    // 2 -> 0
        assert_eq!(state_machine_simulation(4, 100), 4);  // 4 stays 4
        // State 4 might be unreachable in normal usage
        // State 2 -> 4 transition requires input > 100
    }
}