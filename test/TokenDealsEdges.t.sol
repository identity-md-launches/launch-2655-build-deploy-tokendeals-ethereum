// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TokenDealsFixture} from "./helpers/TokenDealsFixture.sol";
import {TokenDeals} from "../src/TokenDeals.sol";
import {TestToken, NoBoolToken} from "./mocks/Tokens.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @dev ETH receiver that, while being paid as a seller, tries every mutating entrypoint.
contract GreedySeller {
    TokenDeals public immutable desk;
    uint256 public dealId;
    bool public accept;

    /// @dev Events, not storage: the desk forwards only 50k gas, too little for fresh SSTOREs.
    event Attempt(uint256 index, bool ok);

    constructor(TokenDeals desk_) {
        desk = desk_;
    }

    function openDeal(address token, uint256 amount, uint64 expiry) external returns (uint256) {
        IERC20(token).approve(address(desk), amount);
        dealId = desk.open(token, amount, address(0), 0.01 ether, 0, expiry, address(0));
        return dealId;
    }

    function setAccept(bool accept_) external {
        accept = accept_;
    }

    receive() external payable {
        bytes[4] memory payloads = [
            abi.encodeCall(TokenDeals.cancel, (dealId)),
            abi.encodeCall(TokenDeals.update, (dealId, 1, 0, uint64(block.timestamp + 1 days))),
            abi.encodeCall(TokenDeals.buy, (dealId, 1, address(this), type(uint256).max, uint64(0), bytes(""))),
            abi.encodeCall(TokenDeals.claimOwed, ())
        ];
        for (uint256 i; i < payloads.length; ++i) {
            (bool ok,) = address(desk).call(payloads[i]);
            emit Attempt(i, ok);
        }
        if (!accept) revert("no");
    }

    function claim() external {
        desk.claimOwed();
    }
}

contract TokenDealsEdgesTest is TokenDealsFixture {
    function _independentCost(uint256 amount, uint256 price) internal pure returns (uint256) {
        // Bounded inputs only: amount * price stays below 2^256.
        return (amount * price + 1e18 - 1) / 1e18;
    }

    // ---------------------------------------------------------------- price convention and boundaries

    function test_sixDecimalSoldTokenIsPricedPer1e18BaseUnitsNotPerWholeToken() public {
        TestToken six = new TestToken(6, 0);
        six.mint(seller, 5e6);
        vm.startPrank(seller);
        six.approve(address(desk), 5e6);
        // 2 ETH per 1e18 base units: 5e6 base units cost 1e7 wei, not 10 ETH.
        uint256 id = desk.open(address(six), 5e6, address(0), 2 ether, 0, _expiry(), address(0));
        vm.stopPrank();
        (uint256 cost, uint256 fee, uint256 total) = desk.quote(id, 5e6, false);
        assertEq(cost, 1e7);
        assertEq(fee, 1e5);
        assertEq(total, 1.01e7);
        vm.prank(payer);
        desk.buy{value: total}(id, 5e6, recipient, total, 0, "");
        assertEq(six.balanceOf(recipient), 5e6);
        assertEq(seller.balance, 1e7);
        assertEq(FEE_TO.balance, 1e5);
    }

    function test_buyOneSecondBeforeExpiryWorksAndAtExpiryFails() public {
        uint256 id = _ethDeal();
        uint64 expiry = _deal(id).expiry;
        vm.warp(expiry - 1);
        _buyETH(id, 1e18);
        vm.warp(expiry);
        _rejectBuyETH(id, 1e18, abi.encodeWithSelector(TokenDeals.DealExpired.selector, id));
        // The seller may still cancel the expired deal and gets exactly what is left.
        vm.prank(seller);
        vm.expectEmit(true, false, false, true, address(desk));
        emit DealCancelled(id, 9e18);
        desk.cancel(id);
        assertEq(sold.balanceOf(address(desk)), 0);
        assertEq(_deal(id).held, 10e18);
        assertEq(_deal(id).left, 0);
    }

    function test_updatedMinBuyEqualToLeftOnlyAllowsTheRest() public {
        uint256 id = _ethDeal();
        _buyETH(id, 7e18);
        vm.prank(seller);
        desk.update(id, 0.01 ether, 3e18, _expiry());
        _rejectBuyETH(id, 2e18, abi.encodeWithSelector(TokenDeals.InvalidMinBuy.selector));
        _buyETH(id, 3e18);
        assertFalse(_deal(id).open);
        assertEq(sold.balanceOf(recipient), 10e18);
    }

    function test_restBelowMinBuyAfterOddPartial() public {
        uint256 id = _open(address(0), 10e18, 0.01 ether, 3e18, address(0));
        _buyETH(id, 3e18);
        _buyETH(id, 3e18);
        _buyETH(id, 3e18);
        // 1e18 left is below minBuy but is the rest, so it is always buyable.
        assertEq(_deal(id).left, 1e18);
        _rejectBuyETH(id, 1e18 - 1, abi.encodeWithSelector(TokenDeals.InvalidMinBuy.selector));
        _buyETH(id, 1e18);
        assertFalse(_deal(id).open);
    }

    function test_dealIdsCountUpAcrossCancelsAndFills() public {
        uint256 a = _ethDeal();
        vm.prank(seller);
        desk.cancel(a);
        uint256 b = _ethDeal();
        _buyETH(b, 10e18);
        uint256 c = _ethDeal();
        assertEq(a, 1);
        assertEq(b, 2);
        assertEq(c, 3);
        assertEq(desk.dealCount(), 3);
        assertFalse(_deal(a).open);
        assertFalse(_deal(b).open);
        assertTrue(_deal(c).open);
    }

    function test_claimOwedWithNothingOwedReverts() public {
        vm.prank(payer);
        vm.expectRevert(TokenDeals.NothingOwed.selector);
        desk.claimOwed();
        vm.prank(OWNER);
        vm.expectRevert(TokenDeals.NothingOwed.selector);
        desk.claimOwed();
    }

    function test_pausedBuyOpenUpdateRevertWithoutStateChange() public {
        uint256 id = _ethDeal();
        vm.prank(OWNER);
        desk.pause();
        _rejectBuyETH(id, 1e18, abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        vm.startPrank(seller);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        desk.update(id, 1, 0, _expiry());
        vm.expectRevert(Pausable.EnforcedPause.selector);
        desk.open(address(sold), 1e18, address(0), 1, 0, _expiry(), address(0));
        vm.stopPrank();
        assertEq(_deal(id).left, 10e18);
        assertEq(_deal(id).price, 0.01 ether);
        assertEq(desk.dealCount(), 1);
    }

    // ---------------------------------------------------------------- fees, caps and passes

    function test_zeroFeesSettleWithoutPayingFeeSplitter() public {
        vm.prank(OWNER);
        desk.setFees(0, 0);
        uint256 id = _open(USDT, 3e18, 333_333, 0, address(0));
        (uint256 cost, uint256 fee, uint256 total) = desk.quote(id, 3e18, false);
        assertEq(cost, 999_999);
        assertEq(fee, 0);
        assertEq(total, 999_999);
        _fundCoin(USDT, total);
        vm.prank(payer);
        desk.buy(id, 3e18, recipient, total, 0, "");
        assertEq(NoBoolToken(USDT).balanceOf(seller), 999_999);
        assertEq(NoBoolToken(USDT).balanceOf(FEE_TO), 0);
        assertEq(NoBoolToken(USDT).balanceOf(address(desk)), 0);
    }

    function test_maxFeeTwoPercentSettlesExactly() public {
        vm.prank(OWNER);
        desk.setFees(200, 200);
        uint256 id = _open(USDC, 7e18, 1_234_567, 0, address(0));
        (uint256 cost, uint256 fee, uint256 total) = desk.quote(id, 7e18, false);
        assertEq(cost, 8_641_969);
        assertEq(fee, 172_839); // floor(8_641_969 * 200 / 10_000) = floor(172_839.38)
        assertEq(total, 8_814_808);
        _fundCoin(USDC, total);
        vm.prank(payer);
        desk.buy(id, 7e18, recipient, total, 0, "");
        assertEq(IERC20(USDC).balanceOf(seller), cost);
        assertEq(IERC20(USDC).balanceOf(FEE_TO), fee);
    }

    function test_capCountsHolderTotalSoPassCanFitUnderCap() public {
        _setSigner();
        uint256 id = _ethDeal(); // 10e18 at 0.01 ether: cost 0.1 ether
        vm.prank(OWNER);
        desk.setMaxPay(address(0), 0.1005 ether);
        // Normal total 0.101 ether exceeds the cap.
        _rejectBuyETH(id, 10e18, abi.encodeWithSelector(TokenDeals.PaymentCapExceeded.selector));
        uint64 passExpiry = uint64(block.timestamp + 1 hours);
        bytes memory pass = _pass(recipient, passExpiry, SIGNER_KEY, block.chainid, address(desk));
        vm.prank(payer);
        desk.buy{value: 0.1005 ether}(id, 10e18, recipient, 0.1005 ether, passExpiry, pass);
        assertEq(seller.balance, 0.1 ether);
        assertEq(FEE_TO.balance, 0.0005 ether);
    }

    function test_relayerBuysPrivateDealWithRecipientsPassInSixDecimalCoin() public {
        _setSigner();
        address relayer = makeAddr("relayer");
        uint256 id = _open(USDC, 10e18, 1_000_003, 0, recipient);
        uint64 passExpiry = uint64(block.timestamp + 24 hours);
        bytes memory relayerPass = _pass(relayer, passExpiry, SIGNER_KEY, block.chainid, address(desk));
        bytes memory recipientPass = _pass(recipient, passExpiry, SIGNER_KEY, block.chainid, address(desk));
        TestToken(USDC).mint(relayer, 100e6);
        vm.startPrank(relayer);
        IERC20(USDC).approve(address(desk), type(uint256).max);
        // A pass for the relayer is not a pass for the recipient.
        vm.expectRevert(TokenDeals.InvalidPass.selector);
        desk.buy(id, 3e18 + 1, recipient, type(uint256).max, passExpiry, relayerPass);
        // The relayer itself cannot receive a private deal.
        vm.expectRevert(TokenDeals.InvalidRecipient.selector);
        desk.buy(id, 3e18 + 1, relayer, type(uint256).max, passExpiry, relayerPass);
        // cost = ceil((3e18 + 1) * 1_000_003 / 1e18) = 3_000_010; fee = floor(3_000_010 * 50 / 10_000) = 15_000.
        vm.expectEmit(true, true, true, true, address(desk));
        emit Bought(id, relayer, recipient, 3e18 + 1, 3_000_010, 15_000, true);
        desk.buy(id, 3e18 + 1, recipient, 3_015_010, passExpiry, recipientPass);
        vm.stopPrank();
        assertEq(IERC20(USDC).balanceOf(relayer), 100e6 - 3_015_010);
        assertEq(IERC20(USDC).balanceOf(seller), 3_000_010);
        assertEq(IERC20(USDC).balanceOf(FEE_TO), 15_000);
        assertEq(sold.balanceOf(recipient), 3e18 + 1);
        assertEq(sold.balanceOf(relayer), 0);
    }

    function test_passSignedOneSecondPast24HoursRejected() public {
        _setSigner();
        uint256 id = _ethDeal();
        uint64 passExpiry = uint64(block.timestamp + 24 hours + 1);
        bytes memory pass = _pass(recipient, passExpiry, SIGNER_KEY, block.chainid, address(desk));
        vm.prank(payer);
        vm.expectRevert(TokenDeals.InvalidPass.selector);
        desk.buy{value: 0.0505 ether}(id, 5e18, recipient, 1 ether, passExpiry, pass);
        // One second later the same pass is within the window and valid.
        vm.warp(block.timestamp + 1);
        vm.prank(payer);
        desk.buy{value: 0.05025 ether}(id, 5e18, recipient, 1 ether, passExpiry, pass);
        assertEq(FEE_TO.balance, 0.00025 ether);
    }

    // ---------------------------------------------------------------- reentrancy by a greedy seller

    function test_sellerReceivingETHCannotReenterAnythingAndIsCreditedWhenRejecting() public {
        GreedySeller greedy = new GreedySeller(desk);
        sold.mint(address(greedy), 10e18);
        uint256 id = greedy.openDeal(address(sold), 10e18, _expiry());

        greedy.setAccept(true);
        for (uint256 i; i < 4; ++i) {
            vm.expectEmit(false, false, false, true, address(greedy));
            emit GreedySeller.Attempt(i, false);
        }
        _buyETH(id, 4e18);
        assertEq(address(greedy).balance, 0.04 ether, "accepting seller paid directly");
        assertEq(desk.owed(address(greedy)), 0);
        assertEq(_deal(id).left, 6e18);

        greedy.setAccept(false);
        _buyETH(id, 6e18);
        assertEq(desk.owed(address(greedy)), 0.06 ether);
        assertEq(address(desk).balance, 0.06 ether);
        assertFalse(_deal(id).open);

        greedy.setAccept(true);
        greedy.claim();
        assertEq(address(greedy).balance, 0.1 ether);
        assertEq(desk.owed(address(greedy)), 0);
        assertEq(address(desk).balance, 0);
    }

    // ---------------------------------------------------------------- fuzz properties

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_splittingABuyNeverLowersTheSellersCost(uint256 a, uint256 b, uint256 price) public {
        a = bound(a, 1, 1e30);
        b = bound(b, 1, 1e30);
        price = bound(price, 1, 1e30);
        uint256 id = _ethDeal();
        vm.prank(seller);
        desk.update(id, price, 0, _expiry());
        (uint256 costA,,) = desk.quote(id, a, false);
        (uint256 costB,,) = desk.quote(id, b, false);
        (uint256 costAB,,) = desk.quote(id, a + b, false);
        assertEq(costA, _independentCost(a, price));
        assertGe(costA + costB, costAB, "split cheaper than single buy");
        assertLe(costA + costB, costAB + 1, "split overcharged by more than one unit");
        // Cost is never below the exact price.
        assertGe(costA * 1e18, a * price);
        assertLt(costA * 1e18 - a * price, 1e18);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_holderFeeNeverAboveNormalFeeOrMaximum(
        uint256 feeBps,
        uint256 holderBps,
        uint256 amount,
        uint256 price
    ) public {
        feeBps = bound(feeBps, 0, 200);
        holderBps = bound(holderBps, 0, feeBps);
        amount = bound(amount, 1, 1e30);
        price = bound(price, 1, 1e30);
        vm.prank(OWNER);
        desk.setFees(feeBps, holderBps);
        uint256 id = _ethDeal();
        vm.prank(seller);
        desk.update(id, price, 0, _expiry());
        (uint256 cost, uint256 fee, uint256 total) = desk.quote(id, amount, false);
        (uint256 hCost, uint256 hFee, uint256 hTotal) = desk.quote(id, amount, true);
        assertEq(hCost, cost);
        assertLe(hFee, fee);
        assertLe(hTotal, total);
        assertEq(fee, cost * feeBps / 10_000);
        assertEq(hFee, cost * holderBps / 10_000);
        assertLe(fee, cost * 200 / 10_000);
        assertEq(total, cost + fee);
    }

    /// forge-config: default.fuzz.runs = 500
    function testFuzz_invalidFeesNeverAccepted(uint256 feeBps, uint256 holderBps) public {
        vm.assume(holderBps > feeBps || feeBps > 200);
        vm.prank(OWNER);
        vm.expectRevert(TokenDeals.InvalidFees.selector);
        desk.setFees(feeBps, holderBps);
        assertEq(desk.feeBps(), 100);
        assertEq(desk.holderFeeBps(), 50);
    }

    /// forge-config: default.fuzz.runs = 500
    function testFuzz_taxedDepositHoldsExactlyWhatArrived(uint256 amount) public {
        amount = bound(amount, 1, 1e30);
        TestToken taxed = new TestToken(18, 200);
        taxed.mint(seller, amount);
        uint256 expectedHeld = amount - amount * 200 / 10_000;
        vm.startPrank(seller);
        taxed.approve(address(desk), amount);
        uint256 id = desk.open(address(taxed), amount, address(0), 1, 0, _expiry(), address(0));
        vm.stopPrank();
        assertEq(_deal(id).held, expectedHeld);
        assertEq(_deal(id).left, expectedHeld);
        assertEq(taxed.balanceOf(address(desk)), expectedHeld);
        // The full held amount is always cancellable; the desk keeps nothing back.
        vm.prank(seller);
        desk.cancel(id);
        assertEq(taxed.balanceOf(address(desk)), 0);
    }

    /// forge-config: default.fuzz.runs = 500
    function testFuzz_USDTBuyForOtherRecipientPaysExactlyCostAndFee(
        uint256 amount,
        uint256 price,
        bool holder,
        uint256 pastMin
    ) public {
        _setSigner();
        amount = bound(amount, 1, 1_000_000e18);
        price = bound(price, 1, 1_000e6);
        uint256 id = _open(USDT, 1_000_000e18, price, 0, address(0));
        uint256 cost = _independentCost(amount, price);
        uint256 fee = cost * (holder ? 50 : 100) / 10_000;
        uint256 total = cost + fee;
        uint64 passExpiry = uint64(block.timestamp + bound(pastMin, 0, 24 hours));
        bytes memory pass = holder ? _pass(recipient, passExpiry, SIGNER_KEY, block.chainid, address(desk)) : bytes("");
        _fundCoin(USDT, total);

        if (total > 2500e6) {
            vm.prank(payer);
            vm.expectRevert(TokenDeals.PaymentCapExceeded.selector);
            desk.buy(id, amount, recipient, total, passExpiry, pass);
            assertEq(_deal(id).left, 1_000_000e18);
            return;
        }
        if (total > 0) {
            vm.prank(payer);
            vm.expectRevert(TokenDeals.MaxTotalExceeded.selector);
            desk.buy(id, amount, recipient, total - 1, passExpiry, pass);
        }
        vm.prank(payer);
        vm.expectEmit(true, true, true, true, address(desk));
        emit Bought(id, payer, recipient, amount, cost, fee, holder);
        desk.buy(id, amount, recipient, total, passExpiry, pass);
        assertEq(NoBoolToken(USDT).balanceOf(payer), 0);
        assertEq(NoBoolToken(USDT).balanceOf(seller), cost);
        assertEq(NoBoolToken(USDT).balanceOf(FEE_TO), fee);
        assertEq(NoBoolToken(USDT).balanceOf(address(desk)), 0);
        assertEq(sold.balanceOf(recipient), amount);
        assertEq(sold.balanceOf(payer), 0);
        assertEq(_deal(id).left, 1_000_000e18 - amount);
        assertEq(sold.balanceOf(address(desk)), _deal(id).left);
    }

    /// forge-config: default.fuzz.runs = 500
    function testFuzz_wrongETHValueAlwaysRejected(uint256 amount, uint256 value) public {
        amount = bound(amount, 1, 10e18);
        uint256 id = _ethDeal();
        (,, uint256 total) = desk.quote(id, amount, false);
        value = bound(value, 0, 10 ether);
        vm.assume(value != total);
        vm.prank(payer);
        vm.expectRevert(TokenDeals.IncorrectETHValue.selector);
        desk.buy{value: value}(id, amount, recipient, type(uint256).max, 0, "");
        assertEq(_deal(id).left, 10e18);
        assertEq(address(desk).balance, 0);
    }
}
