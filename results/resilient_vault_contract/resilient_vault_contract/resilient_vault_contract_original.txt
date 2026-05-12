// Resilient vault-style standalone Rust contract.
// This file is intentionally branch-heavy while keeping arithmetic saturating and bounded.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VaultDecision {
    Accept,
    Delay,
    Reject,
    Escalate,
}

#[derive(Clone, Copy, Debug)]
pub struct VaultSnapshot {
    pub liquidity: i64,
    pub debt: i64,
    pub trust: i32,
    pub locked: bool,
}

pub fn normalize_amount(amount: i64) -> i64 {
    if amount < 0 {
        return 0;
    }
    if amount > 1_000_000 {
        return 1_000_000;
    }
    amount
}

pub fn evaluate_vault(snapshot: VaultSnapshot, request: i64, age_days: u32) -> VaultDecision {
    let amount = normalize_amount(request);
    let mut flags = 0i32;

    if snapshot.locked {
        flags += 8;
    }
    if snapshot.liquidity < amount {
        flags += 5;
    }
    if snapshot.debt > snapshot.liquidity {
        flags += 4;
    }
    if snapshot.trust < 20 {
        flags += 3;
    }
    if snapshot.trust > 80 {
        flags -= 2;
    }
    if age_days < 3 {
        flags += 2;
    }
    if age_days > 365 {
        flags -= 1;
    }
    if amount == 0 {
        flags += 1;
    }
    if amount > 100_000 && snapshot.trust < 60 {
        flags += 4;
    }
    if snapshot.liquidity.saturating_sub(snapshot.debt) > amount {
        flags -= 2;
    }

    if flags >= 10 {
        VaultDecision::Reject
    } else if flags >= 6 {
        VaultDecision::Escalate
    } else if flags >= 2 {
        VaultDecision::Delay
    } else {
        VaultDecision::Accept
    }
}

pub fn apply_decision(snapshot: VaultSnapshot, decision: VaultDecision, request: i64) -> VaultSnapshot {
    let mut next = snapshot;
    let amount = normalize_amount(request);

    if decision == VaultDecision::Accept {
        next.liquidity = next.liquidity.saturating_sub(amount);
        next.debt = next.debt.saturating_add(amount / 4);
        next.trust = next.trust.saturating_add(1);
    }
    if decision == VaultDecision::Delay {
        next.trust = next.trust.saturating_sub(1);
    }
    if decision == VaultDecision::Reject {
        next.locked = true;
        next.trust = next.trust.saturating_sub(5);
    }
    if decision == VaultDecision::Escalate {
        next.debt = next.debt.saturating_add(amount / 10);
        next.trust = next.trust.saturating_sub(2);
    }
    if next.debt < 0 {
        next.debt = 0;
    }
    if next.liquidity < 0 {
        next.liquidity = 0;
    }
    if next.trust > 100 {
        next.trust = 100;
    }
    if next.trust < 0 {
        next.trust = 0;
    }

    next
}

pub fn run_vault_rounds(mut snapshot: VaultSnapshot, requests: &[i64], ages: &[u32]) -> i64 {
    let mut idx = 0usize;
    let mut accepted = 0i64;

    while idx < requests.len() {
        let age = if idx < ages.len() { ages[idx] } else { 30 };
        let decision = evaluate_vault(snapshot, requests[idx], age);

        if decision == VaultDecision::Accept {
            accepted = accepted.saturating_add(normalize_amount(requests[idx]));
        }
        if decision == VaultDecision::Reject {
            accepted = accepted.saturating_sub(10);
        }
        if decision == VaultDecision::Escalate && snapshot.trust > 50 {
            accepted = accepted.saturating_add(5);
        }

        snapshot = apply_decision(snapshot, decision, requests[idx]);
        idx += 1;
    }

    if snapshot.locked {
        accepted = accepted.saturating_sub(25);
    }
    if snapshot.trust > 75 {
        accepted = accepted.saturating_add(snapshot.trust as i64);
    }
    if accepted < 0 {
        return 0;
    }

    accepted
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_locked_vault() {
        let snapshot = VaultSnapshot {
            liquidity: 100,
            debt: 10,
            trust: 90,
            locked: true,
        };
        assert_eq!(evaluate_vault(snapshot, 50, 20), VaultDecision::Escalate);
    }

    #[test]
    fn rounds_do_not_underflow() {
        let snapshot = VaultSnapshot {
            liquidity: 1_000,
            debt: 200,
            trust: 65,
            locked: false,
        };
        let requests = [10, 50, 500, 90, 3];
        let ages = [100, 2, 400];
        assert!(run_vault_rounds(snapshot, &requests, &ages) >= 0);
    }
}
