// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TokenDealsFixture} from "./helpers/TokenDealsFixture.sol";
import {TokenDeals} from "../src/TokenDeals.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TokenDealsPassesTest is TokenDealsFixture {
    function test_holderPassUsesHalfPercentAndRecipientNotPayer() public {
        _setSigner();
        uint256 id = _ethDeal();
        uint64 expiry = uint64(block.timestamp + 1 hours);
        bytes memory pass = _pass(recipient, expiry, SIGNER_KEY, 1, address(desk));
        vm.expectEmit(true, true, true, true, address(desk));
        emit Bought(id, payer, recipient, 10e18, 0.1 ether, 0.0005 ether, true);
        vm.prank(payer);
        desk.buy{value: 0.1005 ether}(id, 10e18, recipient, 0.1005 ether, expiry, pass);
        assertEq(seller.balance, 0.1 ether);
        assertEq(FEE_TO.balance, 0.0005 ether);
    }

    function test_holderCoinSettlementAtOddPriceAndAmount() public {
        _setSigner();
        uint256 amount = 1_000_000_000_000_000_001;
        uint256 id = _open(USDC, amount, 20_001, 0, address(0));
        // 20001 + 20001/1e18 rounds UP to 20002. Holder fee floors 100.01 to 100.
        uint256 total = 20_102;
        _fundCoin(USDC, total);
        uint64 expiry = uint64(block.timestamp + 1 hours);
        bytes memory pass = _pass(recipient, expiry, SIGNER_KEY, 1, address(desk));
        vm.prank(payer);
        desk.buy(id, amount, recipient, total, expiry, pass);
        assertEq(IERC20(USDC).balanceOf(seller), 20_002);
        assertEq(IERC20(USDC).balanceOf(FEE_TO), 100);
    }

    function test_emptyPassIgnoresExpiryAndUsesNormalFee() public {
        uint256 id = _ethDeal();
        vm.expectEmit(true, true, true, true, address(desk));
        emit Bought(id, payer, recipient, 10e18, 0.1 ether, 0.001 ether, false);
        vm.prank(payer);
        desk.buy{value: 0.101 ether}(id, 10e18, recipient, 0.101 ether, type(uint64).max, "");
    }

    function test_nonemptyPassBeforeSignerSetReverts() public {
        uint256 id = _ethDeal();
        uint64 expiry = uint64(block.timestamp + 1 hours);
        bytes memory pass = _pass(recipient, expiry, SIGNER_KEY, 1, address(desk));
        vm.expectRevert(TokenDeals.PassSignerNotConfigured.selector);
        desk.buy(id, 1e18, recipient, 1 ether, expiry, pass);
    }

    function test_wrongSignerRecipientChainAndContractRevert() public {
        _setSigner();
        uint256 id = _ethDeal();
        uint64 expiry = uint64(block.timestamp + 1 hours);
        bytes[4] memory invalid = [
            _pass(recipient, expiry, SIGNER_KEY + 1, 1, address(desk)),
            _pass(payer, expiry, SIGNER_KEY, 1, address(desk)),
            _pass(recipient, expiry, SIGNER_KEY, 10, address(desk)),
            _pass(recipient, expiry, SIGNER_KEY, 1, address(this))
        ];
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(TokenDeals.InvalidPass.selector);
            desk.buy(id, 1e18, recipient, 1 ether, expiry, invalid[i]);
        }
        assertEq(_deal(id).left, 10e18);
    }

    function test_expiredAndTooFarAheadPassRevert() public {
        _setSigner();
        uint256 id = _ethDeal();
        uint64[2] memory expiries = [uint64(block.timestamp - 1), uint64(block.timestamp + 24 hours + 1)];
        for (uint256 i; i < expiries.length; ++i) {
            bytes memory pass = _pass(recipient, expiries[i], SIGNER_KEY, 1, address(desk));
            vm.expectRevert(TokenDeals.InvalidPass.selector);
            desk.buy(id, 1e18, recipient, 1 ether, expiries[i], pass);
        }
    }

    function test_passExpiryExactNowAnd24HourBoundaries() public {
        _setSigner();
        uint256 id = _ethDeal();
        uint64[2] memory expiries = [uint64(block.timestamp), uint64(block.timestamp + 24 hours)];
        for (uint256 i; i < expiries.length; ++i) {
            bytes memory pass = _pass(recipient, expiries[i], SIGNER_KEY, 1, address(desk));
            vm.prank(payer);
            desk.buy{value: 0.01005 ether}(id, 1e18, recipient, 0.01005 ether, expiries[i], pass);
        }
    }

    function test_passReusePermittedAcrossDealsAndPayersUntilExpiry() public {
        _setSigner();
        uint256 first = _ethDeal();
        uint256 second = _ethDeal();
        uint64 expiry = uint64(block.timestamp + 1 hours);
        bytes memory pass = _pass(recipient, expiry, SIGNER_KEY, 1, address(desk));
        vm.prank(payer);
        desk.buy{value: 0.01005 ether}(first, 1e18, recipient, 0.01005 ether, expiry, pass);
        vm.deal(recipient, 1 ether);
        vm.prank(recipient);
        desk.buy{value: 0.01005 ether}(second, 1e18, recipient, 0.01005 ether, expiry, pass);
        vm.warp(expiry + 1);
        vm.expectRevert(TokenDeals.InvalidPass.selector);
        desk.buy(first, 1e18, recipient, 1 ether, expiry, pass);
    }

    function test_chainIdChangeInvalidatesCachedDomain() public {
        _setSigner();
        uint256 id = _ethDeal();
        uint64 expiry = uint64(block.timestamp + 1 hours);
        bytes memory pass = _pass(recipient, expiry, SIGNER_KEY, 1, address(desk));
        vm.chainId(2);
        vm.expectRevert(TokenDeals.InvalidPass.selector);
        desk.buy(id, 1e18, recipient, 1 ether, expiry, pass);
        pass = _pass(recipient, expiry, SIGNER_KEY, 2, address(desk));
        vm.prank(payer);
        desk.buy{value: 0.01005 ether}(id, 1e18, recipient, 0.01005 ether, expiry, pass);
    }

    function test_signerRotationRevokesOldPassesAndZeroDisablesPasses() public {
        _setSigner();
        uint256 id = _ethDeal();
        uint64 expiry = uint64(block.timestamp + 1 hours);
        bytes memory pass = _pass(recipient, expiry, SIGNER_KEY, 1, address(desk));
        vm.prank(OWNER);
        desk.setPassSigner(vm.addr(SIGNER_KEY + 1));
        vm.expectRevert(TokenDeals.InvalidPass.selector);
        desk.buy(id, 1e18, recipient, 1 ether, expiry, pass);
        pass = _pass(recipient, expiry, SIGNER_KEY + 1, 1, address(desk));
        vm.prank(payer);
        desk.buy{value: 0.01005 ether}(id, 1e18, recipient, 0.01005 ether, expiry, pass);
        vm.prank(OWNER);
        desk.setPassSigner(address(0));
        vm.expectRevert(TokenDeals.PassSignerNotConfigured.selector);
        desk.buy(id, 1e18, recipient, 1 ether, expiry, pass);
        _buyETH(id, 1e18);
    }

    function test_malformedHighSAndInvalidVSignaturesRevert() public {
        _setSigner();
        uint256 id = _ethDeal();
        uint64 expiry = uint64(block.timestamp + 1 hours);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, _digest(recipient, expiry, 1, address(desk)));
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes[5] memory invalid = [
            bytes(hex"01"),
            abi.encodePacked(r, s),
            abi.encodePacked(r, bytes32(n - uint256(s)), uint8(v == 27 ? 28 : 27)),
            abi.encodePacked(r, s, uint8(1)),
            new bytes(65)
        ];
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(TokenDeals.InvalidPass.selector);
            desk.buy(id, 1e18, recipient, 1 ether, expiry, invalid[i]);
        }
    }

    function test_signedExpiryCannotBeAltered() public {
        _setSigner();
        uint256 id = _ethDeal();
        uint64 expiry = uint64(block.timestamp + 1 hours);
        bytes memory pass = _pass(recipient, expiry, SIGNER_KEY, 1, address(desk));
        vm.expectRevert(TokenDeals.InvalidPass.selector);
        desk.buy(id, 1e18, recipient, 1 ether, expiry + 1, pass);
    }

    function test_domainMetadata() public view {
        (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chain,
            address verifying,
            bytes32 salt,
            uint256[] memory extensions
        ) = desk.eip712Domain();
        assertEq(fields, hex"0f");
        assertEq(name, "TokenDeals");
        assertEq(version, "1");
        assertEq(chain, 1);
        assertEq(verifying, address(desk));
        assertEq(salt, bytes32(0));
        assertEq(extensions.length, 0);
    }
}
