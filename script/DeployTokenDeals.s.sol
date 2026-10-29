// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TokenDeals} from "../src/TokenDeals.sol";

/// @notice Local, credential-free deployment rehearsal. The launch service deploys TokenDeals directly.
contract DeployTokenDeals {
    event DeploymentRehearsed(address indexed application);

    /// @notice Creates a desk locally with exactly the launch's zero-argument configuration.
    /// @dev Does not read environment variables, start a broadcast or contact a chain.
    function run() external returns (TokenDeals application) {
        application = new TokenDeals();
        emit DeploymentRehearsed(address(application));
    }
}
