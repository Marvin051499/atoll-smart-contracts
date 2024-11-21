# Atoll Protocol Smart Contracts

## Protocol Docs
- [Atoll Protocol](https://docs.atoll.money/)

## Audit Scope
- src/PsmAMO.sol
- src/RebalanceAMO.sol
- src/StakedToken.sol
- src/wethRouter.sol
- src/dex/*
- src/oracle/*
- src/tokens/*
- src/interfaces/* (only the interfaces, not the implementations)

## Out of Scope
All tests files under test/ directory. But auditors can run tests locally with `forge build` and `forge test -vv`.

## Additional Notes
In this audit, we are particular interested in the following aspects (while all other aspects are also important):
- Acess control: All the contracts have only the following external anyone-can-call write functions: psm.mint, StakedToken.mint, StakedToken.redeem, StakedToken.withdraw, StakedToken.deposit and wethRouter.mint. All other functions are only callable by the owner/manager/security manager.
- When buying/selling/adding/removing liquidity, we will not get sandwiched given the manager is honest.
- If the manager is compromised, the damage is limited to less than 5% of the TVL within 24 hours.
- Any reentrancy issues.
- If there is a way to mint any of the tokens without providing any underlying assets or without the multi sig owner's approval.
- If the StakedToken holders can suffer from a loss.
- Any token/value that will be stuck in the contract.
- In case of emergency (e.g., the integrating protocol is hacked), the owner can rescue as much as possible assets and will not revert.
- We would like to understand any risks related to the decimals of the stable token (e.g., atBTC-BTC with 8 decimals and atUSDC-USDC with 6 decimals).

Besides, we make the following assumptions:
- The governance multi sig is honest and will not make any malicious actions.
- If the manager, security manager, or the profit manager is compromised, They cannot steal more than 5% of the TVL within 24 hours.

## Known Issues
- We will not integrate with any token that has a call-hook with either the AMO or the PSM.
- We understand that if the manager is compromised, the attacker can manipulate by performing a sandwich attack.
