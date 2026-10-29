// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TokenDeals} from "../src/TokenDeals.sol";
import {DeployTokenDeals} from "../script/DeployTokenDeals.s.sol";

contract DeploymentFactoryProbe {
    function deploy(bytes32 salt) external returns (TokenDeals) {
        return new TokenDeals{salt: salt}();
    }
}

contract TokenDealsDeploymentTest is Test {
    address private constant OWNER = 0x6C4c78f2C3bDf4C4318Fe305FB1C8BC1694d19b5;
    address private constant FEE_TO = 0x1119d5Df2f046bC2d3c0F6279EF2E9cE49422d44;

    function test_factoryDeploymentOnEmptyChainHasFixedOwnerAndNoArguments() public {
        vm.chainId(1);
        assertEq(FEE_TO.code.length, 0);
        assertEq(address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48).code.length, 0);
        DeploymentFactoryProbe factory = new DeploymentFactoryProbe();
        bytes32 salt = keccak256("local deployment test only");
        address expected = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), address(factory), salt, keccak256(type(TokenDeals).creationCode))
                    )
                )
            )
        );
        TokenDeals deployed = factory.deploy(salt);
        assertEq(address(deployed), expected);
        assertEq(deployed.owner(), OWNER);
        assertNotEq(deployed.owner(), address(factory));
        assertNotEq(deployed.owner(), tx.origin);
        assertEq(deployed.FEE_TO(), FEE_TO);
        assertGt(address(deployed).code.length, 0);
        assertLe(address(deployed).code.length, 24_576);
        assertLe(type(TokenDeals).creationCode.length, 49_152);
    }

    function test_deploymentRehearsalUsesExactConfiguration() public {
        DeployTokenDeals rehearsal = new DeployTokenDeals();
        TokenDeals deployed = rehearsal.run();
        assertEq(deployed.owner(), OWNER);
        assertEq(deployed.FEE_TO(), FEE_TO);
        assertEq(deployed.feeBps(), 100);
        assertEq(deployed.holderFeeBps(), 50);
        assertEq(deployed.maxPay(address(0)), 1 ether);
        assertEq(deployed.passSigner(), address(0));
    }

    function test_reachableRuntimeHasNoDelegatecallCallcodeOrSelfdestruct() public {
        TokenDeals deployed = new TokenDeals();
        bytes memory code = address(deployed).code;
        bool reachable = true;
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op == 0x5b) reachable = true;
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            if (reachable) assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden runtime opcode");
            if (op == 0x00 || op == 0x56 || op == 0xf3 || op == 0xfd || op == 0xfe || op == 0xff) reachable = false;
        }
    }
}
