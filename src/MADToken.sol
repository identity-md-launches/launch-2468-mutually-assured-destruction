// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Mutually Assured Destruction (MAD)
/// @notice A plain, fixed-supply ERC-20. The whole supply of 1,000,000,000 MAD (18 decimals) is
/// minted once, in the constructor, to the deployer. Nothing can mint afterwards, and there is no
/// owner, pause, blocklist, fee or any other privileged power: every holder's balance moves only
/// on that holder's own `transfer` or an allowance they granted.
/// @dev The deployer of a launch is the ProjectFactory, which pays the supply out (swarm share, pool
/// seed, remainder). The constructor calls no other contract, so it deploys on an empty chain.
contract MADToken is ERC20 {
    /// @notice Token name, as `name()` returns it.
    string public constant TOKEN_NAME = "Mutually Assured Destruction";

    /// @notice Token symbol, as `symbol()` returns it.
    string public constant TOKEN_SYMBOL = "MAD";

    /// @notice Number of decimals: the ERC-20 default of 18.
    uint8 public constant DECIMALS = 18;

    /// @notice Whole-token supply, before decimals: one billion.
    uint256 public constant SUPPLY_WHOLE_TOKENS = 1_000_000_000;

    /// @notice The total supply in minor units: 1,000,000,000 * 10^18. Minted once; never changes upward.
    uint256 public constant TOTAL_SUPPLY = SUPPLY_WHOLE_TOKENS * 10 ** DECIMALS;

    /// @notice Emitted once, when the constructor mints the whole supply to the deployer.
    /// @param deployer The address that received the whole supply (`msg.sender` of the deployment).
    /// @param supply The amount minted, in minor units.
    event SupplyMinted(address indexed deployer, uint256 supply);

    /// @notice Mints the whole fixed supply to `msg.sender`, the deployer.
    constructor() ERC20(TOKEN_NAME, TOKEN_SYMBOL) {
        _mint(msg.sender, TOTAL_SUPPLY);
        emit SupplyMinted(msg.sender, TOTAL_SUPPLY);
    }

    /// @inheritdoc ERC20
    function decimals() public pure override returns (uint8) {
        return DECIMALS;
    }
}
