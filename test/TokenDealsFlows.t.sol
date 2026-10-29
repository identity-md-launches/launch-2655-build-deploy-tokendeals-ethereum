// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TokenDealsFixture} from "./helpers/TokenDealsFixture.sol";
import {TokenDeals} from "../src/TokenDeals.sol";
import {TestToken, NoBoolToken} from "./mocks/Tokens.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract TokenDealsFlowsTest is TokenDealsFixture {
    function test_initialConfiguration() public view {
        assertEq(desk.owner(), OWNER);
        assertEq(desk.FEE_TO(), FEE_TO);
        assertEq(desk.MAX_FEE_BPS(), 200);
        assertEq(desk.feeBps(), 100);
        assertEq(desk.holderFeeBps(), 50);
        assertEq(desk.passSigner(), address(0));
        assertEq(desk.dealCount(), 0);
        assertFalse(desk.paused());
        address[5] memory coins = [address(0), USDC, USDT, IMD, SHIFT];
        uint256[5] memory caps = [uint256(1 ether), 2500e6, 2500e6, 500e18, 40_000_000e18];
        for (uint256 i; i < coins.length; ++i) {
            assertTrue(desk.payCoin(coins[i]));
            assertEq(desk.maxPay(coins[i]), caps[i]);
        }
    }

    function test_openEventAndImmutableInventory() public {
        uint64 expiry = _expiry();
        vm.expectEmit(true, true, true, true, address(desk));
        emit DealOpened(1, seller, address(sold), address(0), 10e18, 0.01 ether, 2e18, expiry, recipient);
        uint256 id = _open(address(0), 10e18, 0.01 ether, 2e18, recipient);
        assertEq(id, 1);
        TokenDeals.Deal memory d = _deal(id);
        assertEq(d.seller, seller);
        assertEq(d.token, address(sold));
        assertEq(d.payCoin, address(0));
        assertEq(d.held, 10e18);
        assertEq(d.left, 10e18);
        assertEq(d.price, 0.01 ether);
        assertEq(d.minBuy, 2e18);
        assertEq(d.expiry, expiry);
        assertEq(d.buyer, recipient);
        assertTrue(d.open);
        assertEq(sold.balanceOf(address(desk)), 10e18);
        _buyETH(id, 10e18);
        assertEq(_deal(id).held, 10e18);
        assertEq(_ethDeal(), 2);
        assertEq(desk.dealCount(), 2);
    }

    function test_fullETHSettlementAndEvent() public {
        uint256 id = _ethDeal();
        uint256 beforePayer = payer.balance;
        uint256 beforeSeller = seller.balance;
        uint256 beforeFee = FEE_TO.balance;
        vm.expectEmit(true, true, true, true, address(desk));
        emit Bought(id, payer, recipient, 10e18, 0.1 ether, 0.001 ether, false);
        _buyETH(id, 10e18);
        assertEq(payer.balance, beforePayer - 0.101 ether);
        assertEq(seller.balance, beforeSeller + 0.1 ether);
        assertEq(FEE_TO.balance, beforeFee + 0.001 ether);
        assertEq(sold.balanceOf(recipient), 10e18);
        assertEq(sold.balanceOf(payer), 0);
        assertEq(address(desk).balance, 0);
        assertEq(_deal(id).left, 0);
        assertFalse(_deal(id).open);
    }

    function test_sixDecimalSettlement() public {
        _coinFlow(USDC, 12_345_678);
    }

    function test_noBoolUSDTSettlement() public {
        _coinFlow(USDT, 12_345_678);
    }

    function test_eighteenDecimalIMDSettlement() public {
        _coinFlow(IMD, 12_345_678_901_234_567_890);
    }

    function test_SHIFTSettlement() public {
        _coinFlow(SHIFT, 1_234_567e18);
    }

    function _coinFlow(address coin, uint256 price) private {
        uint256 id = _open(coin, 3e18, price, 0, address(0));
        uint256 cost = price * 3;
        uint256 fee = cost / 100;
        _fundCoin(coin, cost + fee);
        vm.expectEmit(true, true, true, true, address(desk));
        emit Bought(id, payer, recipient, 3e18, cost, fee, false);
        vm.prank(payer);
        desk.buy(id, 3e18, recipient, cost + fee, 0, "");
        assertEq(IERC20(coin).balanceOf(seller), cost);
        assertEq(IERC20(coin).balanceOf(FEE_TO), fee);
        assertEq(IERC20(coin).balanceOf(payer), 0);
        assertEq(IERC20(coin).balanceOf(address(desk)), 0);
        assertEq(sold.balanceOf(recipient), 3e18);
        assertFalse(_deal(id).open);
    }

    function test_partialBuysAndRestBelowMinimum() public {
        uint256 id = _open(address(0), 10e18, 0.01 ether, 4e18, address(0));
        _buyETH(id, 4e18);
        assertEq(_deal(id).left, 6e18);
        assertTrue(_deal(id).open);
        _buyETH(id, 4e18);
        assertEq(_deal(id).left, 2e18);
        _buyETH(id, 2e18);
        assertEq(sold.balanceOf(recipient), 10e18);
        assertEq(seller.balance, 0.1 ether);
        assertEq(FEE_TO.balance, 0.001 ether);
        assertFalse(_deal(id).open);
    }

    function test_privateDealRestrictsRecipientNotPayer() public {
        uint256 id = _open(address(0), 10e18, 0.01 ether, 0, recipient);
        vm.prank(payer);
        vm.expectRevert(TokenDeals.InvalidRecipient.selector);
        desk.buy{value: 0.101 ether}(id, 10e18, payer, 0.101 ether, 0, "");
        _buyETH(id, 10e18);
        assertEq(sold.balanceOf(recipient), 10e18);
    }

    function test_openValidation() public {
        vm.startPrank(seller);
        vm.expectRevert(TokenDeals.InvalidToken.selector);
        desk.open(recipient, 1e18, address(0), 1, 0, _expiry(), address(0));
        vm.expectRevert(TokenDeals.InvalidToken.selector);
        desk.open(address(0), 1e18, USDC, 1, 0, _expiry(), address(0));
        vm.expectRevert(TokenDeals.InvalidToken.selector);
        desk.open(USDC, 1e18, USDC, 1, 0, _expiry(), address(0));
        vm.expectRevert(TokenDeals.PaymentCoinNotAllowed.selector);
        desk.open(address(sold), 1e18, recipient, 1, 0, _expiry(), address(0));
        vm.expectRevert(TokenDeals.InvalidAmount.selector);
        desk.open(address(sold), 0, address(0), 1, 0, _expiry(), address(0));
        vm.expectRevert(TokenDeals.InvalidPrice.selector);
        desk.open(address(sold), 1e18, address(0), 0, 0, _expiry(), address(0));
        vm.expectRevert(TokenDeals.InvalidExpiry.selector);
        desk.open(address(sold), 1e18, address(0), 1, 0, uint64(block.timestamp), address(0));
        vm.expectRevert(TokenDeals.InvalidExpiry.selector);
        desk.open(address(sold), 1e18, address(0), 1, 0, uint64(block.timestamp - 1), address(0));
        vm.expectRevert(TokenDeals.InvalidExpiry.selector);
        desk.open(address(sold), 1e18, address(0), 1, 0, uint64(block.timestamp + 365 days + 1), address(0));
        vm.expectRevert(TokenDeals.InvalidMinBuy.selector);
        desk.open(address(sold), 1e18, address(0), 1, 1e18 + 1, _expiry(), address(0));
        vm.stopPrank();
        assertEq(desk.dealCount(), 0);
        assertEq(sold.balanceOf(address(desk)), 0);
        assertEq(sold.balanceOf(seller), 1_000_000e18);
    }

    function test_dealExpiryExactly365DaysAllowed() public {
        vm.prank(seller);
        uint256 id = desk.open(address(sold), 1e18, address(0), 1, 1e18, uint64(block.timestamp + 365 days), address(0));
        assertTrue(_deal(id).open);
    }

    function test_missingApprovalAndBalanceAreAtomic() public {
        vm.prank(seller);
        sold.approve(address(desk), 0);
        vm.expectRevert();
        _ethDeal();
        vm.prank(seller);
        sold.approve(address(desk), type(uint256).max);
        vm.expectRevert();
        _open(address(0), 1_000_001e18, 1, 0, address(0));
        assertEq(desk.dealCount(), 0);
        assertEq(sold.balanceOf(address(desk)), 0);
    }

    function test_amountAndRecipientValidation() public {
        uint256 id = _open(address(0), 10e18, 0.01 ether, 4e18, address(0));
        vm.startPrank(payer);
        vm.expectRevert(TokenDeals.InvalidRecipient.selector);
        desk.buy(id, 4e18, address(0), 1 ether, 0, "");
        vm.expectRevert(TokenDeals.InvalidAmount.selector);
        desk.buy(id, 0, recipient, 1 ether, 0, "");
        vm.expectRevert(TokenDeals.InvalidAmount.selector);
        desk.buy(id, 10e18 + 1, recipient, 1 ether, 0, "");
        vm.expectRevert(TokenDeals.InvalidMinBuy.selector);
        desk.buy(id, 4e18 - 1, recipient, 1 ether, 0, "");
        vm.stopPrank();
        assertEq(_deal(id).left, 10e18);
    }

    function test_maxTotalIncludesFeeAndAllowsEquality() public {
        uint256 id = _ethDeal();
        vm.prank(payer);
        vm.expectRevert(TokenDeals.MaxTotalExceeded.selector);
        desk.buy{value: 0.101 ether}(id, 10e18, recipient, 0.101 ether - 1, 0, "");
        _buyETH(id, 10e18);
    }

    function test_ETHValueMustBeExact() public {
        uint256 id = _ethDeal();
        vm.startPrank(payer);
        vm.expectRevert(TokenDeals.IncorrectETHValue.selector);
        desk.buy(id, 10e18, recipient, 1 ether, 0, "");
        vm.expectRevert(TokenDeals.IncorrectETHValue.selector);
        desk.buy{value: 0.101 ether - 1}(id, 10e18, recipient, 1 ether, 0, "");
        vm.expectRevert(TokenDeals.IncorrectETHValue.selector);
        desk.buy{value: 0.101 ether + 1}(id, 10e18, recipient, 1 ether, 0, "");
        vm.stopPrank();
        assertEq(_deal(id).left, 10e18);
        assertEq(address(desk).balance, 0);
    }

    function test_ETHRejectedForCoinDeal() public {
        uint256 id = _open(USDC, 1e18, 1e6, 0, address(0));
        _fundCoin(USDC, 1_010_000);
        vm.prank(payer);
        vm.expectRevert(TokenDeals.IncorrectETHValue.selector);
        desk.buy{value: 1}(id, 1e18, recipient, 1_010_000, 0, "");
        assertEq(IERC20(USDC).balanceOf(payer), 1_010_000);
    }

    function test_allDefaultCapsIncludeFee() public {
        address[5] memory coins = [address(0), USDC, USDT, IMD, SHIFT];
        for (uint256 i; i < coins.length; ++i) {
            uint256 cap = desk.maxPay(coins[i]);
            uint256 id = _open(coins[i], 1e18, cap, 0, address(0));
            vm.prank(payer);
            vm.expectRevert(TokenDeals.PaymentCapExceeded.selector);
            desk.buy(id, 1e18, recipient, type(uint256).max, 0, "");
            assertEq(_deal(id).left, 1e18);
        }
    }

    function test_capExactBoundaryAndZeroDisablesCap() public {
        uint256 id = _ethDeal();
        vm.prank(OWNER);
        desk.setMaxPay(address(0), 0.101 ether - 1);
        _rejectBuyETH(id, 10e18, abi.encodeWithSelector(TokenDeals.PaymentCapExceeded.selector));
        vm.prank(OWNER);
        desk.setMaxPay(address(0), 0.101 ether);
        _buyETH(id, 10e18);
        vm.prank(OWNER);
        desk.setMaxPay(address(0), 0);
        id = _open(address(0), 10e18, 1 ether, 0, address(0));
        _buyETH(id, 10e18);
    }

    function test_coinCapEqualityAndUncappedSettlement() public {
        uint256 id = _open(USDC, 2e18, 1e6, 0, address(0));
        _fundCoin(USDC, 2_020_000);
        vm.prank(OWNER);
        desk.setMaxPay(USDC, 1_010_000);
        vm.prank(payer);
        desk.buy(id, 1e18, recipient, 1_010_000, 0, "");
        vm.prank(OWNER);
        desk.setMaxPay(USDC, 0);
        vm.prank(payer);
        desk.buy(id, 1e18, recipient, 1_010_000, 0, "");
        assertFalse(_deal(id).open);
    }

    function test_unknownExpiredCancelledAndFilledDeals() public {
        vm.expectRevert(abi.encodeWithSelector(TokenDeals.UnknownDeal.selector, 0));
        desk.buy(0, 1, recipient, 1, 0, "");
        vm.expectRevert(abi.encodeWithSelector(TokenDeals.UnknownDeal.selector, 100));
        desk.quote(100, 1, false);
        vm.expectRevert(abi.encodeWithSelector(TokenDeals.UnknownDeal.selector, 1));
        desk.update(1, 1, 0, _expiry());
        vm.expectRevert(abi.encodeWithSelector(TokenDeals.UnknownDeal.selector, 1));
        desk.cancel(1);
        assertEq(_deal(100).seller, address(0));

        uint256 expired = _ethDeal();
        vm.warp(_deal(expired).expiry);
        _rejectBuyETH(expired, 10e18, abi.encodeWithSelector(TokenDeals.DealExpired.selector, expired));
        vm.prank(seller);
        desk.cancel(expired);
        _rejectBuyETH(expired, 10e18, abi.encodeWithSelector(TokenDeals.DealNotOpen.selector, expired));
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(TokenDeals.DealNotOpen.selector, expired));
        desk.cancel(expired);
        uint256 filled = _ethDeal();
        _buyETH(filled, 10e18);
        _rejectBuyETH(filled, 1, abi.encodeWithSelector(TokenDeals.DealNotOpen.selector, filled));
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(TokenDeals.DealNotOpen.selector, filled));
        desk.update(filled, 1, 0, _expiry());
    }

    function test_updateAndCancelRequireSellerEvenForOwner() public {
        uint256 id = _ethDeal();
        address[3] memory strangers = [payer, recipient, OWNER];
        for (uint256 i; i < strangers.length; ++i) {
            vm.startPrank(strangers[i]);
            vm.expectRevert(TokenDeals.OnlySeller.selector);
            desk.update(id, 1, 0, _expiry());
            vm.expectRevert(TokenDeals.OnlySeller.selector);
            desk.cancel(id);
            vm.stopPrank();
        }
        assertEq(_deal(id).left, 10e18);
    }

    function test_updateValidatesRemainingAndProtectsBuyerWithMaxTotal() public {
        uint256 id = _ethDeal();
        _buyETH(id, 4e18);
        uint64 nextExpiry = uint64(block.timestamp + 90 days);
        vm.startPrank(seller);
        vm.expectRevert(TokenDeals.InvalidMinBuy.selector);
        desk.update(id, 1, 6e18 + 1, nextExpiry);
        vm.expectRevert(TokenDeals.InvalidPrice.selector);
        desk.update(id, 0, 0, nextExpiry);
        vm.expectRevert(TokenDeals.InvalidExpiry.selector);
        desk.update(id, 1, 0, uint64(block.timestamp));
        vm.expectRevert(TokenDeals.InvalidExpiry.selector);
        desk.update(id, 1, 0, uint64(block.timestamp + 365 days + 1));
        vm.expectEmit(true, false, false, true, address(desk));
        emit DealUpdated(id, 0.02 ether, 6e18, nextExpiry);
        desk.update(id, 0.02 ether, 6e18, nextExpiry);
        vm.stopPrank();
        assertEq(_deal(id).held, 10e18);
        assertEq(_deal(id).left, 6e18);
        assertEq(_deal(id).price, 0.02 ether);
        assertEq(_deal(id).minBuy, 6e18);
        assertEq(_deal(id).expiry, nextExpiry);
        vm.prank(payer);
        vm.expectRevert(TokenDeals.MaxTotalExceeded.selector);
        desk.buy{value: 0.0606 ether}(id, 6e18, recipient, 0.0606 ether, 0, "");
        _buyETH(id, 6e18);
    }

    function test_sellerCanRenewExpiredOpenDeal() public {
        uint256 id = _ethDeal();
        vm.warp(_deal(id).expiry + 1);
        vm.prank(seller);
        desk.update(id, 0.01 ether, 0, _expiry());
        _buyETH(id, 10e18);
    }

    function test_pauseBlocksOnlyOpenUpdateBuyAndCancelStillWorks() public {
        uint256 id = _ethDeal();
        _buyETH(id, 4e18);
        uint256 before = sold.balanceOf(seller);
        vm.prank(OWNER);
        vm.expectEmit(false, false, false, true, address(desk));
        emit Paused(OWNER);
        desk.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        _ethDeal();
        vm.prank(seller);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        desk.update(id, 1, 0, _expiry());
        _rejectBuyETH(id, 6e18, abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        vm.expectEmit(true, false, false, true, address(desk));
        emit DealCancelled(id, 6e18);
        vm.prank(seller);
        desk.cancel(id);
        assertEq(sold.balanceOf(seller), before + 6e18);
        assertFalse(_deal(id).open);
        assertEq(_deal(id).left, 0);
        assertEq(_deal(id).held, 10e18);
        vm.prank(OWNER);
        vm.expectEmit(false, false, false, true, address(desk));
        emit Unpaused(OWNER);
        desk.unpause();
        _buyETH(_ethDeal(), 10e18);
    }

    function test_removingPaymentCoinOnlyStopsNewDeals() public {
        address[2] memory coins = [address(0), USDC];
        for (uint256 i; i < coins.length; ++i) {
            uint256 id = _open(coins[i], 1e18, 1e6, 0, address(0));
            vm.prank(OWNER);
            desk.setPayCoin(coins[i], false);
            vm.expectRevert(TokenDeals.PaymentCoinNotAllowed.selector);
            _open(coins[i], 1e18, 1, 0, address(0));
            vm.prank(seller);
            desk.update(id, 1e6, 0, _expiry());
            if (coins[i] == address(0)) {
                _buyETH(id, 1e18);
            } else {
                _fundCoin(coins[i], 1_010_000);
                vm.prank(payer);
                desk.buy(id, 1e18, recipient, 1_010_000, 0, "");
            }
        }
    }

    function test_taxedSoldTokenHeldBuyAndCancel() public {
        TestToken taxed = new TestToken(18, 200);
        taxed.mint(seller, 100e18);
        vm.startPrank(seller);
        taxed.approve(address(desk), 100e18);
        uint256 id = desk.open(address(taxed), 100e18, address(0), 0.001 ether, 0, _expiry(), address(0));
        vm.stopPrank();
        assertEq(_deal(id).held, 98e18);
        assertEq(_deal(id).left, 98e18);
        _buyETH(id, 50e18);
        assertEq(taxed.balanceOf(recipient), 49e18);
        assertEq(_deal(id).left, 48e18);
        assertEq(seller.balance, 0.05 ether);
        assertEq(FEE_TO.balance, 0.0005 ether);
        vm.prank(seller);
        desk.cancel(id);
        assertEq(taxed.balanceOf(seller), 47.04e18);
        assertEq(taxed.balanceOf(address(desk)), 0);
        assertEq(_deal(id).held, 98e18);
    }

    function test_taxedDepositMinBuyUsesActualReceipt() public {
        TestToken taxed = new TestToken(18, 200);
        taxed.mint(seller, 100e18);
        vm.startPrank(seller);
        taxed.approve(address(desk), 100e18);
        vm.expectRevert(TokenDeals.InvalidMinBuy.selector);
        desk.open(address(taxed), 100e18, address(0), 1, 99e18, _expiry(), address(0));
        vm.stopPrank();
        assertEq(taxed.balanceOf(seller), 100e18);
        assertEq(taxed.balanceOf(address(desk)), 0);
        assertEq(desk.dealCount(), 0);
    }

    function test_nothingArrivedReverts() public {
        TestToken taxed = new TestToken(18, 10_000);
        taxed.mint(seller, 100e18);
        vm.startPrank(seller);
        taxed.approve(address(desk), 100e18);
        vm.expectRevert(TokenDeals.InvalidAmount.selector);
        desk.open(address(taxed), 100e18, address(0), 1, 0, _expiry(), address(0));
        vm.stopPrank();
        assertEq(taxed.balanceOf(seller), 100e18);
        assertEq(desk.dealCount(), 0);
    }

    function test_noBoolSoldTokenSupported() public {
        NoBoolToken(USDT).mint(seller, 100e6);
        vm.startPrank(seller);
        NoBoolToken(USDT).approve(address(desk), 100e6);
        uint256 id = desk.open(USDT, 100e6, address(0), 1e24, 0, _expiry(), address(0));
        vm.stopPrank();
        _buyETH(id, 50e6);
        assertEq(NoBoolToken(USDT).balanceOf(recipient), 50e6);
        vm.prank(seller);
        desk.cancel(id);
        assertEq(NoBoolToken(USDT).balanceOf(seller), 50e6);
    }

    function test_failedTokenTransfersRollbackAllSettlement() public {
        uint256 id = _ethDeal();
        sold.setFailTransfers(true);
        _rejectBuyETH(id, 10e18, abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(sold)));
        assertEq(_deal(id).left, 10e18);
        assertEq(seller.balance, 0);
        assertEq(FEE_TO.balance, 0);
        assertEq(address(desk).balance, 0);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(sold)));
        desk.cancel(id);
        assertTrue(_deal(id).open);
        sold.setFailTransfers(false);
        vm.prank(seller);
        desk.cancel(id);
    }

    function test_failedPaymentPullLeavesInventoryUntouched() public {
        uint256 id = _open(USDC, 1e18, 1e6, 0, address(0));
        _fundCoin(USDC, 1_010_000);
        TestToken(USDC).setFailTransfers(true);
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, USDC));
        desk.buy(id, 1e18, recipient, 1_010_000, 0, "");
        assertEq(_deal(id).left, 1e18);
        assertEq(sold.balanceOf(recipient), 0);
        assertEq(IERC20(USDC).balanceOf(payer), 1_010_000);
    }

    function test_quoteIsArithmeticPreviewEvenForUnavailableAmount() public {
        uint256 id = _ethDeal();
        (uint256 cost, uint256 fee, uint256 total) = desk.quote(id, 0, true);
        assertEq(cost + fee + total, 0);
        vm.prank(seller);
        desk.cancel(id);
        (cost, fee, total) = desk.quote(id, 100e18, false);
        assertEq(cost, 1 ether);
        assertEq(fee, 0.01 ether);
        assertEq(total, 1.01 ether);
    }
}
