// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TokenDealsFixture} from "./helpers/TokenDealsFixture.sol";
import {TokenDealsHandler} from "./invariant/TokenDealsHandler.sol";
import {TokenDeals} from "../src/TokenDeals.sol";
import {TestToken} from "./mocks/Tokens.sol";
import {ETHActor} from "./mocks/Actors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TokenDealsInvariantTest is TokenDealsFixture {
    TokenDealsHandler internal handler;
    address[] internal assets;

    function setUp() public override {
        super.setUp();
        TestToken taxed = new TestToken(18, 200);
        assets = [address(sold), address(taxed), USDC, USDT, IMD, SHIFT];
        address[] memory coins = new address[](5);
        coins[0] = address(0);
        coins[1] = USDC;
        coins[2] = USDT;
        coins[3] = IMD;
        coins[4] = SHIFT;
        ETHActor feeReceiver = new ETHActor(desk);
        vm.etch(FEE_TO, address(feeReceiver).code);
        handler = new TokenDealsHandler(desk, assets, coins, address(taxed));

        // Nonvacuous starting state: all payment types, both fee tiers, taxed deposits,
        // private recipients, a rejected ETH payout and a claim have already been exercised.
        for (uint256 i; i < 5; ++i) {
            handler.openDeal(i % 2, i, i == 0 ? 3 : i % 3, 10e18, 10_001, 0, i % 2 == 0);
            handler.buyDeal(i, 1e18 + 1, i, i % 2 == 0);
        }
        handler.claimCredits(0);

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = TokenDealsHandler.openDeal.selector;
        selectors[1] = TokenDealsHandler.buyDeal.selector;
        selectors[2] = TokenDealsHandler.cancelDeal.selector;
        selectors[3] = TokenDealsHandler.updateDeal.selector;
        selectors[4] = TokenDealsHandler.donate.selector;
        selectors[5] = TokenDealsHandler.admin.selector;
        selectors[6] = TokenDealsHandler.advanceTime.selector;
        selectors[7] = TokenDealsHandler.claimCredits.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_everyTokenBacksAllOpenDeals() public view {
        for (uint256 i; i < assets.length; ++i) {
            uint256 outstanding;
            for (uint256 id = 1; id <= desk.dealCount(); ++id) {
                TokenDeals.Deal memory d = handler.getDeal(id);
                if (d.token == assets[i] && d.open) outstanding += d.left;
            }
            uint256 balance = IERC20(assets[i]).balanceOf(address(desk));
            assertGe(balance, outstanding, "insolvent escrow");
            assertEq(outstanding, handler.ghostLeft(assets[i]), "model remaining inventory");
            assertEq(balance, outstanding + handler.donations(assets[i]), "only inventory and donations retained");
        }
    }

    function invariant_heldAndLeftFollowLifecycle() public view {
        for (uint256 id = 1; id <= desk.dealCount(); ++id) {
            TokenDeals.Deal memory d = handler.getDeal(id);
            assertEq(d.held, handler.initialHeld(id), "held is immutable");
            assertEq(d.held, d.left + handler.bought(id) + handler.returned(id), "inventory conservation");
            assertEq(d.open, d.left > 0, "closed status matches inventory");
        }
    }

    function invariant_ETHBacksCreditsAndAllBuysSettleExactly() public view {
        assertGe(handler.successfulBuys(), 5, "settlement checks are nonvacuous");
        assertGe(handler.successfulClaims(), 1, "claim checks are nonvacuous");
        assertEq(address(desk).balance, handler.totalOwed(), "ETH exactly covers credited payments");
        assertEq(desk.FEE_TO(), FEE_TO);
        assertEq(desk.owner(), OWNER);
        assertLe(desk.holderFeeBps(), desk.feeBps());
        assertLe(desk.feeBps(), 200);
    }
}
