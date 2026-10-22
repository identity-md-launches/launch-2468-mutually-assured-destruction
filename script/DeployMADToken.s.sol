// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {MADToken} from "../src/MADToken.sol";

/// @title Deploy script for MADToken
/// @notice Reviewable reference for how the token is deployed. The IdentityMD launch deploys the
/// token itself, from its built bytecode, through the ProjectFactory; this script is for local
/// forks and reviews only. It takes no configuration: the token has no constructor arguments, and
/// whoever broadcasts the deployment receives the whole supply.
contract DeployMADToken is Script {
    /// @notice Deploys the token. Separate from `run()` so tests can call it directly without
    /// touching the environment or depending on the broadcaster.
    /// @return token The deployed token.
    function deploy() public returns (MADToken token) {
        token = new MADToken();
    }

    /// @notice Broadcast entry point. Uses the broadcaster forge is given on the command line
    /// (`--private-key`, `--account`, `--ledger`); reads nothing from the environment itself.
    /// @return token The deployed token.
    function run() external returns (MADToken token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }
}
