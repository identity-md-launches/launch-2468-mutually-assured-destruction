// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployMADToken} from "../script/DeployMADToken.s.sol";
import {MADToken} from "../src/MADToken.sol";

/// @notice The deploy script's `deploy()` function, called directly: no environment, no broadcaster.
contract DeployMADTokenTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 1e18;

    function test_deployMintsSupplyToTheScriptCaller() public {
        DeployMADToken script = new DeployMADToken();
        MADToken token = script.deploy();
        // `deploy()` is called by the script contract, so the script contract is the deployer and
        // holds the supply. In a broadcast, forge replaces the script with the broadcaster.
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(script)), SUPPLY);
        assertEq(token.name(), "Mutually Assured Destruction");
        assertEq(token.symbol(), "MAD");
        assertEq(token.decimals(), 18);
    }

    function test_twoDeploymentsAreIndependent() public {
        DeployMADToken script = new DeployMADToken();
        MADToken first = script.deploy();
        MADToken second = script.deploy();
        assertTrue(address(first) != address(second));
        assertEq(first.totalSupply(), SUPPLY);
        assertEq(second.totalSupply(), SUPPLY);
        assertEq(first.balanceOf(address(script)), SUPPLY);
        assertEq(second.balanceOf(address(script)), SUPPLY);
    }
}
