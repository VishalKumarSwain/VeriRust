// Simple Rust contract example with basic arithmetic operations
// This demonstrates function verification with different code paths

pub fn add_numbers(a: i32, b: i32) -> i32 {
    a + b
}

pub fn multiply_numbers(a: i32, b: i32) -> i32 {
    a * b
}

pub fn calculate_result(x: i32, y: i32, operation: i32) -> i32 {
    if operation == 1 {
        add_numbers(x, y)
    } else if operation == 2 {
        multiply_numbers(x, y)
    } else {
        0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_add() {
        assert_eq!(add_numbers(2, 3), 5);
    }

    #[test]
    fn test_multiply() {
        assert_eq!(multiply_numbers(4, 5), 20);
    }

    #[test]
    fn test_calculate_add() {
        assert_eq!(calculate_result(10, 20, 1), 30);
    }

    #[test]
    fn test_calculate_multiply() {
        assert_eq!(calculate_result(3, 4, 2), 12);
    }

    #[test]
    fn test_calculate_default() {
        assert_eq!(calculate_result(5, 10, 0), 0);
    }
}