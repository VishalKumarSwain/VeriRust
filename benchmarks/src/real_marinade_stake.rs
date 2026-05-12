// =============================================================================
// VAS-Stripped Real Contract: Marinade-style Liquid Staking
// Source pattern: Marinade Finance (marinade.finance) — real deployed Solana program
// Original: uses anchor-lang, Account<'info,T>, Signer<'info>, Pubkey=[u8;32]
//
// Transformation applied (VAS stripping):
//   Account<'info, State>  → plain struct field
//   Signer<'info>          → is_signer: bool
//   Pubkey ([u8;32])        → u32  (tractable state space for Kani)
//   #[derive(Accounts)]    → // @context comment
//   #[account]             → // @account comment
//   Context<'info, XCtx>   → &mut XCtx
//
// Real vulnerability class tested:
//   MISSING_AUTH — order_unstake allows any caller to unstake tokens
//   on behalf of another user when beneficiary check is absent.
//   (Pattern found in audit reports of Marinade v1 and similar protocols)
// =============================================================================

pub type Pubkey = u32;

// @account
pub struct StakeState {
    pub authority: Pubkey,         // protocol authority
    pub total_staked_lamports: u64,
    pub total_cooling_down: u64,
}

// @account
pub struct TicketAccount {
    pub beneficiary: Pubkey,       // owner of this unstake ticket
    pub lamports_amount: u64,      // amount queued for unstake
    pub created_epoch: u64,
}

// @account
pub struct UserStakeAccount {
    pub owner: Pubkey,
    pub staked_lamports: u64,
    pub rewards_earned: u64,
}

// @context
pub struct StakeCtx {
    pub stake_state: StakeState,
    pub user_stake: UserStakeAccount,
    pub owner: Pubkey,
    pub is_signer: bool,
}

// @context
pub struct OrderUnstakeCtx {
    pub stake_state: StakeState,
    pub ticket: TicketAccount,
    pub user_stake: UserStakeAccount,
    pub beneficiary: Pubkey,
    pub is_signer: bool,
}

// @context
pub struct ClaimCtx {
    pub stake_state: StakeState,
    pub ticket: TicketAccount,
    pub beneficiary: Pubkey,
    pub is_signer: bool,
}

// ─── Instructions ────────────────────────────────────────────────────────────

pub fn stake(ctx: &mut StakeCtx, lamports: u64) -> Result<(), &'static str> {
    if !ctx.is_signer {
        return Err("not signer");
    }
    if ctx.stake_state.authority != ctx.owner {
        return Err("unauthorized");
    }
    ctx.user_stake.staked_lamports = ctx.user_stake.staked_lamports
        .checked_add(lamports).ok_or("overflow")?;
    ctx.stake_state.total_staked_lamports = ctx.stake_state.total_staked_lamports
        .checked_add(lamports).ok_or("overflow")?;
    Ok(())
}

/// order_unstake: queue lamports for withdrawal into a ticket.
/// BUG (real pattern): missing check that ticket.beneficiary == ctx.beneficiary
/// An attacker can call this with another user's ticket and drain their stake.
pub fn order_unstake(ctx: &mut OrderUnstakeCtx, lamports: u64) -> Result<(), &'static str> {
    if !ctx.is_signer {
        return Err("not signer");
    }
    // BUG: missing ownership check:
    //   if ctx.ticket.beneficiary != ctx.beneficiary { return Err("unauthorized"); }
    if ctx.user_stake.staked_lamports < lamports {
        return Err("insufficient stake");
    }
    ctx.user_stake.staked_lamports -= lamports;
    ctx.ticket.lamports_amount = ctx.ticket.lamports_amount
        .checked_add(lamports).ok_or("overflow")?;
    ctx.stake_state.total_cooling_down = ctx.stake_state.total_cooling_down
        .checked_add(lamports).ok_or("overflow")?;
    Ok(())
}

/// claim: withdraw matured ticket to beneficiary.
pub fn claim(ctx: &mut ClaimCtx) -> Result<(), &'static str> {
    if !ctx.is_signer {
        return Err("not signer");
    }
    if ctx.ticket.beneficiary != ctx.beneficiary {
        return Err("unauthorized");
    }
    if ctx.ticket.lamports_amount == 0 {
        return Err("nothing to claim");
    }
    ctx.stake_state.total_cooling_down = ctx.stake_state.total_cooling_down
        .saturating_sub(ctx.ticket.lamports_amount);
    ctx.ticket.lamports_amount = 0;
    Ok(())
}

// ─── Unit tests (mirror what the real protocol ships) ────────────────────────
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_stake_ok() {
        let mut ctx = StakeCtx {
            stake_state: StakeState { authority: 1, total_staked_lamports: 0, total_cooling_down: 0 },
            user_stake: UserStakeAccount { owner: 1, staked_lamports: 0, rewards_earned: 0 },
            owner: 1,
            is_signer: true,
        };
        assert!(stake(&mut ctx, 500).is_ok());
        assert_eq!(ctx.user_stake.staked_lamports, 500);
    }

    #[test]
    fn test_order_unstake_ok() {
        let mut ctx = OrderUnstakeCtx {
            stake_state: StakeState { authority: 1, total_staked_lamports: 500, total_cooling_down: 0 },
            ticket: TicketAccount { beneficiary: 2, lamports_amount: 0, created_epoch: 1 },
            user_stake: UserStakeAccount { owner: 2, staked_lamports: 500, rewards_earned: 0 },
            beneficiary: 2,
            is_signer: true,
        };
        assert!(order_unstake(&mut ctx, 200).is_ok());
        // Unit test does NOT check beneficiary ownership — bug goes undetected
    }

    #[test]
    fn test_claim_ok() {
        let mut ctx = ClaimCtx {
            stake_state: StakeState { authority: 1, total_staked_lamports: 500, total_cooling_down: 200 },
            ticket: TicketAccount { beneficiary: 2, lamports_amount: 200, created_epoch: 1 },
            beneficiary: 2,
            is_signer: true,
        };
        assert!(claim(&mut ctx).is_ok());
        assert_eq!(ctx.ticket.lamports_amount, 0);
    }
}

// ─── VeriRust Kani Harnesses (auto-generated pattern) ────────────────────────
#[cfg(kani)]
mod verirust_harnesses {
    use super::*;

    impl kani::Arbitrary for StakeState {
        fn any() -> Self {
            StakeState {
                authority: kani::any(),
                total_staked_lamports: kani::any(),
                total_cooling_down: kani::any(),
            }
        }
    }

    impl kani::Arbitrary for TicketAccount {
        fn any() -> Self {
            TicketAccount {
                beneficiary: kani::any(),
                lamports_amount: kani::any(),
                created_epoch: kani::any(),
            }
        }
    }

    impl kani::Arbitrary for UserStakeAccount {
        fn any() -> Self {
            UserStakeAccount {
                owner: kani::any(),
                staked_lamports: kani::any(),
                rewards_earned: kani::any(),
            }
        }
    }

    impl kani::Arbitrary for StakeCtx {
        fn any() -> Self {
            StakeCtx {
                stake_state: kani::any(),
                user_stake: kani::any(),
                owner: kani::any(),
                is_signer: kani::any(),
            }
        }
    }

    impl kani::Arbitrary for OrderUnstakeCtx {
        fn any() -> Self {
            OrderUnstakeCtx {
                stake_state: kani::any(),
                ticket: kani::any(),
                user_stake: kani::any(),
                beneficiary: kani::any(),
                is_signer: kani::any(),
            }
        }
    }

    impl kani::Arbitrary for ClaimCtx {
        fn any() -> Self {
            ClaimCtx {
                stake_state: kani::any(),
                ticket: kani::any(),
                beneficiary: kani::any(),
                is_signer: kani::any(),
            }
        }
    }

    // Safety harness: stake with valid authority
    #[kani::proof]
    fn verify_real_stake() {
        let mut ctx: StakeCtx = kani::any();
        let lamports: u64 = kani::any();
        kani::assume(ctx.is_signer);
        kani::assume(ctx.stake_state.authority == ctx.owner);
        kani::assume(ctx.user_stake.staked_lamports <= u64::MAX / 2);
        kani::assume(ctx.stake_state.total_staked_lamports <= u64::MAX / 2);
        kani::assume(lamports <= u64::MAX / 2);
        let _ = stake(&mut ctx, lamports);
    }

    // AUTH harness: order_unstake — attacker with mismatched beneficiary must be rejected
    // This harness FAILS on the real contract because the check is missing
    #[kani::proof]
    fn verify_real_order_unstake_auth() {
        let mut ctx: OrderUnstakeCtx = kani::any();
        let lamports: u64 = kani::any();
        kani::assume(ctx.is_signer);
        // Attack: caller's beneficiary != ticket's beneficiary (wrong owner)
        kani::assume(ctx.ticket.beneficiary != ctx.beneficiary);
        kani::assume(ctx.user_stake.staked_lamports >= lamports);
        let result = order_unstake(&mut ctx, lamports);
        assert!(
            result.is_err(),
            "AUTH_VIOLATION: order_unstake succeeded for wrong beneficiary"
        );
    }

    // Safety harness: claim with valid beneficiary
    #[kani::proof]
    fn verify_real_claim() {
        let mut ctx: ClaimCtx = kani::any();
        kani::assume(ctx.is_signer);
        kani::assume(ctx.ticket.beneficiary == ctx.beneficiary);
        kani::assume(ctx.ticket.lamports_amount > 0);
        kani::assume(ctx.stake_state.total_cooling_down >= ctx.ticket.lamports_amount);
        let _ = claim(&mut ctx);
    }
}
