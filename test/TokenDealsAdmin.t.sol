// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TokenDealsFixture} from "./helpers/TokenDealsFixture.sol";
import {TokenDeals} from "../src/TokenDeals.sol";
import {TestToken} from "./mocks/Tokens.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract TokenDealsAdminTest is TokenDealsFixture {
    function test_allAdminFunctionsRejectNonOwner() public {
        bytes[6] memory calls = [
            abi.encodeCall(TokenDeals.setFees, (200, 100)),
            abi.encodeCall(TokenDeals.setPassSigner, (recipient)),
            abi.encodeCall(TokenDeals.setPayCoin, (recipient, true)),
            abi.encodeCall(TokenDeals.setMaxPay, (USDC, 0)),
            abi.encodeCall(TokenDeals.pause, ()),
            abi.encodeCall(TokenDeals.unpause, ())
        ];
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(payer);
            (bool ok, bytes memory result) = address(desk).call(calls[i]);
            assertFalse(ok);
            assertEq(result, abi.encodeWithSelector(TokenDeals.OnlyOwner.selector));
        }
    }

    function test_setterEventsAndValues() public {
        vm.startPrank(OWNER);
        vm.expectEmit(false, false, false, true, address(desk));
        emit FeesSet(200, 200);
        desk.setFees(200, 200);
        assertEq(desk.feeBps(), 200);
        assertEq(desk.holderFeeBps(), 200);
        vm.expectEmit(false, false, false, true, address(desk));
        emit PassSignerSet(recipient);
        desk.setPassSigner(recipient);
        assertEq(desk.passSigner(), recipient);
        vm.expectEmit(true, false, false, true, address(desk));
        emit PayCoinSet(address(sold), true);
        desk.setPayCoin(address(sold), true);
        assertTrue(desk.payCoin(address(sold)));
        vm.expectEmit(true, false, false, true, address(desk));
        emit MaxPaySet(address(sold), 5e18);
        desk.setMaxPay(address(sold), 5e18);
        assertEq(desk.maxPay(address(sold)), 5e18);
        desk.setFees(0, 0);
        assertEq(desk.feeBps(), 0);
        assertEq(desk.holderFeeBps(), 0);
        vm.stopPrank();
    }

    function test_feeBoundsRefusedWithoutChangingState() public {
        vm.startPrank(OWNER);
        vm.expectRevert(TokenDeals.InvalidFees.selector);
        desk.setFees(201, 50);
        vm.expectRevert(TokenDeals.InvalidFees.selector);
        desk.setFees(100, 101);
        vm.expectRevert(TokenDeals.InvalidFees.selector);
        desk.setFees(type(uint256).max, 0);
        vm.expectRevert(TokenDeals.InvalidFees.selector);
        desk.setFees(0, 1);
        vm.stopPrank();
        assertEq(desk.feeBps(), 100);
        assertEq(desk.holderFeeBps(), 50);
    }

    function testFuzz_feeBounds(uint256 normal, uint256 holder) public {
        vm.prank(OWNER);
        if (normal > 200 || holder > normal) {
            vm.expectRevert(TokenDeals.InvalidFees.selector);
            desk.setFees(normal, holder);
        } else {
            desk.setFees(normal, holder);
            assertEq(desk.feeBps(), normal);
            assertEq(desk.holderFeeBps(), holder);
        }
    }

    function test_feeChangeIsIncludedInBuyersMaxTotal() public {
        uint256 id = _ethDeal();
        vm.prank(OWNER);
        desk.setFees(200, 100);
        vm.prank(payer);
        vm.expectRevert(TokenDeals.MaxTotalExceeded.selector);
        desk.buy{value: 0.101 ether}(id, 10e18, recipient, 0.101 ether, 0, "");
        _buyETH(id, 10e18);
        assertEq(seller.balance, 0.1 ether);
        assertEq(FEE_TO.balance, 0.002 ether);
    }

    function test_repeatedPauseUnpauseRefusedAndAdminWorksWhilePaused() public {
        vm.startPrank(OWNER);
        vm.expectRevert(Pausable.ExpectedPause.selector);
        desk.unpause();
        desk.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        desk.pause();
        desk.setFees(0, 0);
        desk.setPassSigner(recipient);
        desk.setPayCoin(IMD, false);
        desk.setMaxPay(IMD, 0);
        desk.unpause();
        vm.stopPrank();
        assertFalse(desk.paused());
    }

    function test_newPaymentCoinWorksAfterAllowlisting() public {
        TestToken added = new TestToken(8, 0);
        vm.prank(OWNER);
        desk.setPayCoin(address(added), true);
        uint256 id = _open(address(added), 1e18, 200e8, 0, address(0));
        _fundCoin(address(added), 202e8);
        vm.prank(payer);
        desk.buy(id, 1e18, recipient, 202e8, 0, "");
        assertEq(added.balanceOf(seller), 200e8);
        assertEq(added.balanceOf(FEE_TO), 2e8);
    }

    function test_ownerCannotMoveEscrowOrDonationsOrRedirectFees() public {
        uint256 id = _ethDeal();
        sold.mint(address(desk), 7e18);
        bytes[10] memory forbidden = [
            abi.encodeWithSignature("sweep(address,address,uint256)", address(sold), OWNER, 17e18),
            abi.encodeWithSignature("rescueTokens(address,address,uint256)", address(sold), OWNER, 17e18),
            abi.encodeWithSignature("withdraw(address,uint256)", address(sold), 17e18),
            abi.encodeWithSignature(
                "execute(address,uint256,bytes)",
                address(sold),
                0,
                abi.encodeWithSignature("transfer(address,uint256)", OWNER, 17e18)
            ),
            abi.encodeWithSignature("setFeeTo(address)", OWNER),
            abi.encodeWithSignature("transferOwnership(address)", payer),
            abi.encodeWithSignature("renounceOwnership()"),
            abi.encodeWithSignature("upgradeToAndCall(address,bytes)", payer, bytes("")),
            abi.encodeWithSignature("initialize(address)", payer),
            abi.encodeWithSignature("approve(address,uint256)", OWNER, 17e18)
        ];
        for (uint256 i; i < forbidden.length; ++i) {
            vm.prank(OWNER);
            (bool ok,) = address(desk).call(forbidden[i]);
            assertFalse(ok);
        }
        vm.prank(OWNER);
        vm.expectRevert(TokenDeals.OnlySeller.selector);
        desk.cancel(id);
        vm.prank(OWNER);
        vm.expectRevert(TokenDeals.OnlySeller.selector);
        desk.update(id, 1, 0, _expiry());
        assertEq(sold.balanceOf(address(desk)), 17e18);
        assertEq(sold.allowance(address(desk), OWNER), 0);
        assertEq(desk.FEE_TO(), FEE_TO);
        assertEq(desk.owner(), OWNER);
        vm.prank(seller);
        desk.cancel(id);
        assertEq(sold.balanceOf(address(desk)), 7e18);
    }

    function test_unsolicitedTokensNotCountedInNewDeal() public {
        sold.mint(address(desk), 7e18);
        uint256 id = _ethDeal();
        assertEq(_deal(id).held, 10e18);
        _buyETH(id, 10e18);
        assertEq(sold.balanceOf(address(desk)), 7e18);
    }

    function test_directETHRejectedAndForcedETHHasNoRecoveryPath() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(desk).call{value: 1}("");
        assertFalse(ok);
        vm.deal(address(desk), 1 ether); // models forcibly received ETH without a SELFDESTRUCT helper
        vm.prank(OWNER);
        vm.expectRevert(TokenDeals.NothingOwed.selector);
        desk.claimOwed();
        assertEq(address(desk).balance, 1 ether);
    }
}
