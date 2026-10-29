// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TokenDealsFixture} from "./helpers/TokenDealsFixture.sol";

contract TokenDealsMathTest is TokenDealsFixture {
    function test_oddAmountRoundsCostUpAndFeeDown() public {
        uint256 id = _open(address(0), 2e18, 10_001, 0, address(0));
        (uint256 cost, uint256 fee, uint256 total) = desk.quote(id, 1e18 + 1, false);
        assertEq(cost, 10_002);
        assertEq(fee, 100);
        assertEq(total, 10_102);
        (cost, fee, total) = desk.quote(id, 1e18 + 1, true);
        assertEq(cost, 10_002);
        assertEq(fee, 50);
        assertEq(total, 10_052);
        _buyETH(id, 1e18 + 1);
        assertEq(seller.balance, 10_002);
        assertEq(FEE_TO.balance, 100);
    }

    function test_oneBaseUnitAlwaysHasPositiveCostAndCanHaveZeroFee() public {
        uint256 id = _open(address(0), 1, 1, 0, address(0));
        (uint256 cost, uint256 fee, uint256 total) = desk.quote(id, 1, false);
        assertEq(cost, 1);
        assertEq(fee, 0);
        assertEq(total, 1);
        _buyETH(id, 1);
        assertEq(seller.balance, 1);
        assertEq(FEE_TO.balance, 0);
    }

    function test_mulDivHandles512BitIntermediate() public {
        uint256 id = _open(address(0), 1, 1e60, 0, address(0));
        (uint256 cost, uint256 fee, uint256 total) = desk.quote(id, 1e30, false);
        assertEq(cost, 1e72);
        assertEq(fee, 1e70);
        assertEq(total, 101e70);
    }

    function test_feeMultiplicationDoesNotOverflowWhenResultFits() public {
        uint256 price = type(uint256).max / 2;
        uint256 id = _open(address(0), 1, price, 0, address(0));
        (uint256 cost, uint256 fee, uint256 total) = desk.quote(id, 1e18, false);
        assertEq(cost, price);
        assertEq(fee, price / 100);
        assertEq(total, price + price / 100);
    }

    function test_unrepresentableCostAndTotalRevert() public {
        uint256 id = _open(address(0), 1, type(uint256).max, 0, address(0));
        vm.expectRevert();
        desk.quote(id, 2e18, false);
        vm.expectRevert();
        desk.quote(id, 1e18, false);
        vm.prank(OWNER);
        desk.setFees(0, 0);
        (uint256 cost, uint256 fee, uint256 total) = desk.quote(id, 1e18, false);
        assertEq(cost, type(uint256).max);
        assertEq(fee, 0);
        assertEq(total, cost);
    }

    function testFuzz_quoteMatchesIndependentArithmetic(uint128 rawAmount, uint128 rawPrice, bool holder) public {
        uint256 price = uint256(rawPrice) + 1;
        uint256 amount = rawAmount;
        uint256 id = _open(address(0), 1, price, 0, address(0));
        uint256 product = amount * price;
        uint256 expectedCost = product / 1e18 + (product % 1e18 == 0 ? 0 : 1);
        uint256 expectedFee = expectedCost / (holder ? 200 : 100);
        (uint256 cost, uint256 fee, uint256 total) = desk.quote(id, amount, holder);
        assertEq(cost, expectedCost);
        assertEq(fee, expectedFee);
        assertEq(total, expectedCost + expectedFee);
    }

    function testFuzz_settlementExactPayouts(uint96 rawAmount, uint96 rawPrice, bool holder, bool coin) public {
        uint256 amount = bound(rawAmount, 1, 1_000_000e18);
        uint256 price = bound(rawPrice, 1, 1e24);
        address pay = coin ? USDC : address(0);
        vm.prank(OWNER);
        desk.setMaxPay(pay, 0);
        uint256 id = _open(pay, amount, price, 0, address(0));
        uint256 product = amount * price;
        uint256 cost = product / 1e18 + (product % 1e18 == 0 ? 0 : 1);
        uint256 fee = cost / (holder ? 200 : 100);
        uint64 expiry;
        bytes memory pass;
        if (holder) {
            _setSigner();
            expiry = uint64(block.timestamp + 1 hours);
            pass = _pass(recipient, expiry, SIGNER_KEY, 1, address(desk));
        }
        if (coin) _fundCoin(pay, cost + fee);
        else vm.deal(payer, cost + fee);
        vm.prank(payer);
        desk.buy{value: coin ? 0 : cost + fee}(id, amount, recipient, cost + fee, expiry, pass);
        assertEq(coin ? _coinBalance(pay, seller) : seller.balance, cost);
        assertEq(coin ? _coinBalance(pay, FEE_TO) : FEE_TO.balance, fee);
        assertEq(coin ? _coinBalance(pay, payer) : payer.balance, 0);
        assertEq(sold.balanceOf(recipient), amount);
        assertFalse(_deal(id).open);
    }

    function _coinBalance(address coin, address account) private view returns (uint256) {
        (bool ok, bytes memory result) = coin.staticcall(abi.encodeWithSignature("balanceOf(address)", account));
        require(ok);
        return abi.decode(result, (uint256));
    }
}
