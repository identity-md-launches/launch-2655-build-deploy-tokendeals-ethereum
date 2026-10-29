// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TokenDealsFixture} from "./helpers/TokenDealsFixture.sol";
import {TokenDeals} from "../src/TokenDeals.sol";
import {TestToken, CallbackToken, HookToken, BlockedPayoutToken} from "./mocks/Tokens.sol";
import {ETHActor, ReentrantRecipient} from "./mocks/Actors.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract TokenDealsAdversarialTest is TokenDealsFixture {
    function test_failedCoinPayoutRollsBackPullTokenDeliveryAndEarlierPayout() public {
        BlockedPayoutToken coin = new BlockedPayoutToken();
        vm.prank(OWNER);
        desk.setPayCoin(address(coin), true);
        uint256 id = _open(address(coin), 1e18, 100e6, 0, address(0));
        _fundCoin(address(coin), 101e6);
        address[2] memory blocked = [seller, FEE_TO];
        for (uint256 i; i < blocked.length; ++i) {
            coin.blockRecipient(blocked[i]);
            vm.prank(payer);
            vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(coin)));
            desk.buy(id, 1e18, recipient, 101e6, 0, "");
            assertTrue(_deal(id).open);
            assertEq(_deal(id).left, 1e18);
            assertEq(coin.balanceOf(payer), 101e6);
            assertEq(coin.allowance(payer, address(desk)), 101e6);
            assertEq(coin.balanceOf(seller), 0);
            assertEq(coin.balanceOf(FEE_TO), 0);
            assertEq(coin.balanceOf(address(desk)), 0);
            assertEq(sold.balanceOf(address(desk)), 1e18);
            assertEq(sold.balanceOf(recipient), 0);
        }
    }

    function test_sameSellerAndFeeRecipientReceiveBothPayoutsOrCredits() public {
        _feeActor(ETHActor.Mode.Reject);
        sold.mint(FEE_TO, 10e18);
        ETHActor actor = ETHActor(payable(FEE_TO));
        uint256 id = actor.openDeal(address(sold), 10e18, address(0), 0.01 ether, _expiry());
        _buyETH(id, 10e18);
        assertEq(desk.owed(FEE_TO), 0.101 ether);
        actor.setMode(ETHActor.Mode.Accept);
        actor.claim();
        assertEq(FEE_TO.balance, 0.101 ether);
        assertEq(address(desk).balance, 0);
    }

    function test_zeroFeeSkipsFailingCoinFeeRecipient() public {
        BlockedPayoutToken coin = new BlockedPayoutToken();
        coin.blockRecipient(FEE_TO);
        vm.startPrank(OWNER);
        desk.setPayCoin(address(coin), true);
        desk.setFees(0, 0);
        vm.stopPrank();
        uint256 id = _open(address(coin), 1e18, 100e6, 0, address(0));
        _fundCoin(address(coin), 100e6);
        vm.prank(payer);
        desk.buy(id, 1e18, recipient, 100e6, 0, "");
        assertEq(coin.balanceOf(seller), 100e6);
    }

    function test_rejectingSellerCreditedThenClaimsWhilePaused() public {
        ETHActor actor = _seller(ETHActor.Mode.Reject);
        uint256 id = actor.dealId();
        vm.expectEmit(true, false, false, true, address(desk));
        emit OwedCredited(address(actor), 0.1 ether);
        _buyETH(id, 10e18);
        assertEq(desk.owed(address(actor)), 0.1 ether);
        assertEq(address(actor).balance, 0);
        assertEq(FEE_TO.balance, 0.001 ether);
        assertEq(address(desk).balance, 0.1 ether);
        assertEq(sold.balanceOf(recipient), 10e18);
        vm.expectRevert(TokenDeals.ETHClaimFailed.selector);
        actor.claim();
        assertEq(desk.owed(address(actor)), 0.1 ether);
        vm.prank(OWNER);
        desk.pause();
        actor.setMode(ETHActor.Mode.Accept);
        vm.expectEmit(true, false, false, true, address(desk));
        emit OwedClaimed(address(actor), 0.1 ether);
        actor.claim();
        assertEq(address(actor).balance, 0.1 ether);
        assertEq(address(desk).balance, 0);
        assertEq(desk.owed(address(actor)), 0);
        vm.expectRevert(TokenDeals.NothingOwed.selector);
        actor.claim();
    }

    function test_rejectingFeeSplitterAlsoGetsClaimableCredit() public {
        _feeActor(ETHActor.Mode.Reject);
        uint256 id = _ethDeal();
        _buyETH(id, 10e18);
        assertEq(seller.balance, 0.1 ether);
        assertEq(desk.owed(FEE_TO), 0.001 ether);
        assertEq(FEE_TO.balance, 0);
        assertEq(address(desk).balance, 0.001 ether);
        ETHActor(payable(FEE_TO)).setMode(ETHActor.Mode.Accept);
        ETHActor(payable(FEE_TO)).claim();
        assertEq(FEE_TO.balance, 0.001 ether);
        assertEq(desk.owed(FEE_TO), 0);
    }

    function test_bothRejectCreditsAccumulateAndCannotBeClaimedByOthers() public {
        ETHActor actor = _seller(ETHActor.Mode.Reject);
        _feeActor(ETHActor.Mode.Reject);
        _buyETH(actor.dealId(), 4e18);
        _buyETH(actor.dealId(), 6e18);
        assertEq(desk.owed(address(actor)), 0.1 ether);
        assertEq(desk.owed(FEE_TO), 0.001 ether);
        assertEq(address(desk).balance, 0.101 ether);
        vm.prank(OWNER);
        vm.expectRevert(TokenDeals.NothingOwed.selector);
        desk.claimOwed();
        vm.prank(payer);
        vm.expectRevert(TokenDeals.NothingOwed.selector);
        desk.claimOwed();
        actor.setMode(ETHActor.Mode.Accept);
        actor.claim();
        assertEq(address(desk).balance, 0.001 ether);
        assertEq(desk.owed(FEE_TO), 0.001 ether);
    }

    function test_gasExhaustingSellerAndFeeSplitterCannotBlockSettlement() public {
        ETHActor actor = _seller(ETHActor.Mode.ExhaustGas);
        _feeActor(ETHActor.Mode.ExhaustGas);
        _buyETH(actor.dealId(), 10e18);
        assertEq(desk.owed(address(actor)), 0.1 ether);
        assertEq(desk.owed(FEE_TO), 0.001 ether);
        assertEq(sold.balanceOf(recipient), 10e18);
        assertFalse(_deal(actor.dealId()).open);
    }

    function test_largeETHReturnDataDoesNotBreakSettlement() public {
        ETHActor actor = _seller(ETHActor.Mode.LargeReturn);
        _feeActor(ETHActor.Mode.LargeReturn);
        _buyETH(actor.dealId(), 10e18);
        assertEq(address(actor).balance, 0.1 ether);
        assertEq(FEE_TO.balance, 0.001 ether);
        assertEq(address(desk).balance, 0);
    }

    function test_sellerCannotReenterCancellationDuringPartialBuy() public {
        ETHActor actor = _seller(ETHActor.Mode.ReenterCancel);
        _buyETH(actor.dealId(), 4e18);
        assertTrue(actor.attempted());
        assertFalse(actor.succeeded());
        assertEq(actor.errorSelector(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(_deal(actor.dealId()).left, 6e18);
        assertEq(sold.balanceOf(address(desk)), 6e18);
        assertEq(address(actor).balance, 0.04 ether);
        actor.cancel();
        assertEq(sold.balanceOf(address(actor)), 6e18);
    }

    function test_claimReentrancyCannotWithdrawTwice() public {
        ETHActor actor = _seller(ETHActor.Mode.Reject);
        _buyETH(actor.dealId(), 10e18);
        actor.setMode(ETHActor.Mode.ReenterClaim);
        actor.claim();
        assertTrue(actor.attempted());
        assertFalse(actor.succeeded());
        assertEq(actor.errorSelector(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(address(actor).balance, 0.1 ether);
        assertEq(desk.owed(address(actor)), 0);
        assertEq(address(desk).balance, 0);
    }

    function test_feeSplitterCannotReenterClaimDuringSettlement() public {
        _feeActor(ETHActor.Mode.ReenterClaim);
        _buyETH(_ethDeal(), 10e18);
        ETHActor actor = ETHActor(payable(FEE_TO));
        assertTrue(actor.attempted());
        assertFalse(actor.succeeded());
        assertEq(actor.errorSelector(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(FEE_TO.balance, 0.001 ether);
    }

    function test_allStateChangingEntrypointsGuardedDuringOpen() public {
        CallbackToken evil = new CallbackToken();
        evil.mint(seller, 100e18);
        vm.prank(seller);
        evil.approve(address(desk), 100e18);
        bytes[11] memory attempts = _attempts();
        for (uint256 i; i < attempts.length; ++i) {
            evil.arm(address(desk), attempts[i], true, false);
            vm.prank(seller);
            uint256 id = desk.open(address(evil), 1e18, address(0), 1, 0, _expiry(), address(0));
            assertTrue(evil.attempted());
            assertFalse(evil.succeeded());
            assertEq(evil.result(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
            assertEq(_deal(id).held, 1e18);
        }
        assertEq(evil.balanceOf(address(desk)), 11e18);
    }

    function test_maliciousSoldTokenCannotReenterBuyOrCancel() public {
        CallbackToken evil = new CallbackToken();
        evil.mint(seller, 10e18);
        vm.startPrank(seller);
        evil.approve(address(desk), 10e18);
        uint256 id = desk.open(address(evil), 10e18, address(0), 0.01 ether, 0, _expiry(), address(0));
        vm.stopPrank();
        evil.arm(address(desk), abi.encodeCall(TokenDeals.cancel, (id)), false, true);
        _buyETH(id, 4e18);
        assertTrue(evil.attempted());
        assertFalse(evil.succeeded());
        assertEq(evil.result(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(_deal(id).left, 6e18);
        evil.arm(
            address(desk), abi.encodeCall(TokenDeals.buy, (id, 1, recipient, 1, uint64(0), bytes(""))), false, true
        );
        vm.prank(seller);
        desk.cancel(id);
        assertTrue(evil.attempted());
        assertFalse(evil.succeeded());
        assertEq(evil.result(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(evil.balanceOf(address(desk)), 0);
    }

    function test_paymentTokenCannotReenterDuringPullOrPayout() public {
        CallbackToken evil = new CallbackToken();
        vm.prank(OWNER);
        desk.setPayCoin(address(evil), true);
        uint256 id = _open(address(evil), 10e18, 1e18, 0, address(0));
        _fundCoin(address(evil), 10.1e18);
        evil.arm(address(desk), abi.encodeCall(TokenDeals.setFees, (200, 200)), true, true);
        vm.prank(payer);
        desk.buy(id, 10e18, recipient, 10.1e18, 0, "");
        assertTrue(evil.attempted());
        assertFalse(evil.succeeded());
        assertEq(evil.result(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(desk.feeBps(), 100);
        assertEq(evil.balanceOf(seller), 10e18);
        assertEq(evil.balanceOf(FEE_TO), 0.1e18);
        assertEq(evil.balanceOf(address(desk)), 0);
    }

    function test_recipientHookCannotReenterAndSeesUpdatedInventory() public {
        HookToken hooked = new HookToken();
        ReentrantRecipient actor = new ReentrantRecipient(desk);
        hooked.mint(seller, 10e18);
        vm.startPrank(seller);
        hooked.approve(address(desk), 10e18);
        uint256 id = desk.open(address(hooked), 10e18, address(0), 0.01 ether, 0, _expiry(), address(actor));
        vm.stopPrank();
        actor.setDeal(id);
        vm.prank(payer);
        desk.buy{value: 0.0404 ether}(id, 4e18, address(actor), 0.0404 ether, 0, "");
        assertTrue(actor.attempted());
        assertFalse(actor.succeeded());
        assertEq(actor.errorSelector(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(actor.seenLeft(), 6e18);
        assertEq(_deal(id).left, 6e18);
        assertEq(hooked.balanceOf(address(actor)), 4e18);
    }

    function test_paymentCoinCanAlsoBeEscrowedInOtherDealsWithoutLoss() public {
        TestToken(USDC).mint(seller, 100e6);
        vm.startPrank(seller);
        TestToken(USDC).approve(address(desk), 100e6);
        uint256 coinEscrow = desk.open(USDC, 100e6, address(0), 1e24, 0, _expiry(), address(0));
        vm.stopPrank();
        uint256 sale = _open(USDC, 2e18, 5e6, 0, address(0));
        _fundCoin(USDC, 10.1e6);
        vm.prank(payer);
        desk.buy(sale, 2e18, recipient, 10.1e6, 0, "");
        assertEq(TestToken(USDC).balanceOf(address(desk)), 100e6);
        assertEq(_deal(coinEscrow).left, 100e6);
        _buyETH(coinEscrow, 100e6);
        assertEq(TestToken(USDC).balanceOf(address(desk)), 0);
    }

    function _seller(ETHActor.Mode mode) private returns (ETHActor actor) {
        actor = new ETHActor(desk);
        sold.mint(address(actor), 10e18);
        actor.setMode(mode);
        actor.openDeal(address(sold), 10e18, address(0), 0.01 ether, _expiry());
    }

    function _feeActor(ETHActor.Mode mode) private {
        ETHActor implementation = new ETHActor(desk);
        vm.etch(FEE_TO, address(implementation).code);
        ETHActor(payable(FEE_TO)).setMode(mode);
    }

    function _attempts() private view returns (bytes[11] memory attempts) {
        attempts[0] = abi.encodeCall(TokenDeals.open, (address(sold), 1, address(0), 1, 0, _expiry(), address(0)));
        attempts[1] = abi.encodeCall(TokenDeals.buy, (1, 1, recipient, 1, uint64(0), bytes("")));
        attempts[2] = abi.encodeCall(TokenDeals.update, (1, 1, 0, _expiry()));
        attempts[3] = abi.encodeCall(TokenDeals.cancel, (1));
        attempts[4] = abi.encodeCall(TokenDeals.claimOwed, ());
        attempts[5] = abi.encodeCall(TokenDeals.setFees, (200, 200));
        attempts[6] = abi.encodeCall(TokenDeals.setPassSigner, (recipient));
        attempts[7] = abi.encodeCall(TokenDeals.setPayCoin, (recipient, true));
        attempts[8] = abi.encodeCall(TokenDeals.setMaxPay, (address(0), 0));
        attempts[9] = abi.encodeCall(TokenDeals.pause, ());
        attempts[10] = abi.encodeCall(TokenDeals.unpause, ());
    }
}
