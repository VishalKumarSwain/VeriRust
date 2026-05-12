// Labyrinth-style standalone Rust contract for branch-heavy verification.
// The logic is intentionally tangled, but it keeps operations bounded and guarded.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Route {
    Hold,
    Release,
    Review,
    Freeze,
}

#[derive(Clone, Copy, Debug)]
pub struct LabyrinthState {
    pub balance: i64,
    pub risk: i32,
    pub epoch: u32,
    pub route: Route,
}

impl LabyrinthState {
    pub fn new(balance: i64, risk: i32, epoch: u32) -> Self {
        let mut state = LabyrinthState {
            balance,
            risk,
            epoch,
            route: Route::Review,
        };
        state.route = choose_route(balance, risk, epoch);
        state
    }
}

pub fn clamp_i64(value: i64, low: i64, high: i64) -> i64 {
    if value < low {
        return low;
    }
    if value > high {
        return high;
    }
    value
}

pub fn choose_route(balance: i64, risk: i32, epoch: u32) -> Route {
    let mut score = 0i32;

    if balance < 0 {
        score += 7;
    }
    if balance == 0 {
        score += 2;
    }
    if balance > 1_000_000 {
        score += 5;
    }
    if risk > 80 {
        score += 8;
    }
    if risk < -20 {
        score -= 3;
    }
    if epoch % 2 == 0 {
        score += 1;
    }
    if epoch % 7 == 0 {
        score += 2;
    }
    if balance > 0 && risk < 30 {
        score -= 4;
    }

    if score >= 12 {
        Route::Freeze
    } else if score >= 7 {
        Route::Review
    } else if score <= -2 {
        Route::Release
    } else {
        Route::Hold
    }
}

pub fn reconcile_window(values: &[i64], salt: i64) -> i64 {
    let mut acc = 0i64;
    let mut idx = 0usize;

    while idx < values.len() {
        let current = values[idx];

        if current > salt {
            acc = acc.saturating_add(current - salt);
        }
        if current < -salt {
            acc = acc.saturating_sub((-salt).saturating_sub(current));
        }
        if current == salt {
            acc = acc.saturating_add(1);
        }
        if idx % 3 == 0 {
            acc = acc.saturating_add(idx as i64);
        }
        if acc > 10_000 {
            acc = 10_000;
        }
        if acc < -10_000 {
            acc = -10_000;
        }

        idx += 1;
    }

    acc
}

pub fn transition(state: LabyrinthState, signal: i64, nonce: u32) -> LabyrinthState {
    let mut next = state;
    let influence = clamp_i64(signal, -500, 500);

    if next.route == Route::Freeze {
        next.risk = next.risk.saturating_add(3);
    }
    if next.route == Route::Release {
        next.balance = next.balance.saturating_add(influence.abs());
    }
    if next.route == Route::Review {
        next.balance = next.balance.saturating_add(influence / 2);
    }
    if nonce % 5 == 0 {
        next.risk = next.risk.saturating_sub(1);
    }
    if signal < 0 && next.balance > 0 {
        next.risk = next.risk.saturating_add(2);
    }
    if next.balance < -250 {
        next.risk = next.risk.saturating_add(4);
    }

    next.epoch = next.epoch.saturating_add(1);
    next.risk = next.risk.clamp(-100, 100);
    next.balance = clamp_i64(next.balance, -1_000_000, 1_000_000);
    next.route = choose_route(next.balance, next.risk, next.epoch);
    next
}

pub fn labyrinth_score(seed: i64, risk: i32, epoch: u32, signals: &[i64]) -> i64 {
    let mut state = LabyrinthState::new(seed, risk, epoch);
    let mut idx = 0usize;

    while idx < signals.len() {
        state = transition(state, signals[idx], idx as u32 + epoch);
        idx += 1;
    }

    let window = reconcile_window(signals, seed.abs().min(31));
    let mut result = state.balance.saturating_add(window);

    if state.route == Route::Freeze {
        result = result.saturating_sub(100);
    }
    if state.route == Route::Release {
        result = result.saturating_add(75);
    }
    if state.risk > 70 {
        result = result.saturating_sub(state.risk as i64);
    }
    if state.risk < -40 {
        result = result.saturating_add((-state.risk) as i64);
    }

    clamp_i64(result, -1_000_000, 1_000_000)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn route_changes_with_risk() {
        assert_eq!(choose_route(20, 90, 14), Route::Review);
        assert_eq!(choose_route(-10, 95, 14), Route::Freeze);
    }

    #[test]
    fn score_is_bounded() {
        let values = [10, -20, 30, 40, -50, 60];
        let score = labyrinth_score(100, 10, 3, &values);
        assert!(score >= -1_000_000);
        assert!(score <= 1_000_000);
    }
}
