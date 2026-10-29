// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TokenDealsFixture} from "./helpers/TokenDealsFixture.sol";
import {TokenDeals} from "../src/TokenDeals.sol";
import {TestToken, NoBoolToken} from "./mocks/Tokens.sol";
import {ETHActor} from "./mocks/Actors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Cumulative-ledger model. Every successful buy adds cost and fee to running totals; the
/// invariants then compare those totals with what sellers and the FeeSplitter actually hold or are
/// owed. Failure paths (bad maxTotal, bad msg.value, non-seller cancel, paused buy, buy after
/// close) are attempted with try/catch and must revert without moving anything.
contract ConservationHandler is Test {
    uint256 private constant PASS_KEY = 0xA11CE;
    TokenDeals public immutable desk;
    address public immutable feeTo;
    address public immutable usdc;
    address public immutable usdt;
    TestToken public plain;
    TestToken public taxed;
    address[] public coins;
    address[] public sellers;
    address[] public payers;
    address[] public recipients;
    uint256[] public ids;

    // Running ledger, per payment coin (address(0) = ETH).
    mapping(address coin => uint256) public ghostCost;
    mapping(address coin => uint256) public ghostFee;
    mapping(address coin => uint256) public ghostPaid;
    // Per sold token.
    mapping(address token => uint256) public ghostDeposited;
    mapping(address token => uint256) public ghostSoldOut;
    mapping(address token => uint256) public ghostCancelledOut;
    mapping(uint256 id => bool) public everClosed;
    uint256 public ghostClaimed;
    uint256 public buys;
    uint256 public unexpectedSuccesses;

    constructor(TokenDeals desk_, address usdc_, address usdt_) {
        desk = desk_;
        feeTo = desk_.FEE_TO();
        usdc = usdc_;
        usdt = usdt_;
        plain = new TestToken(18, 0);
        taxed = new TestToken(18, 200);
        coins.push(address(0));
        coins.push(usdc_);
        coins.push(usdt_);
        sellers.push(makeAddr("cons seller a"));
        sellers.push(makeAddr("cons seller b"));
        ETHActor rejector = new ETHActor(desk_);
        rejector.setMode(ETHActor.Mode.Reject);
        sellers.push(address(rejector));
        payers.push(makeAddr("cons payer a"));
        payers.push(makeAddr("cons relayer b"));
        recipients.push(makeAddr("cons recipient a"));
        recipients.push(makeAddr("cons recipient b"));
        vm.prank(desk_.owner());
        desk_.setPassSigner(vm.addr(PASS_KEY));
    }

    // ------------------------------------------------------------------ actions

    function open(
        uint256 tokenSeed,
        uint256 coinSeed,
        uint256 sellerSeed,
        uint256 rawAmount,
        uint256 rawPrice,
        uint256 rawMin,
        bool isPrivate
    ) public {
        if (desk.paused()) return;
        TestToken token = tokenSeed % 2 == 0 ? plain : taxed;
        address coin = coins[coinSeed % coins.length];
        address seller = sellers[sellerSeed % sellers.length];
        uint256 amount = bound(rawAmount, 1e6, 1_000e18);
        // ETH: up to 0.1 ETH per token; coins: up to 100 coin units per token.
        uint256 price = bound(rawPrice, 1, coin == address(0) ? 0.1 ether : 100e6);
        uint256 arriving = token == taxed ? amount - amount * 200 / 10_000 : amount;
        uint256 minBuy = bound(rawMin, 0, arriving);
        address buyer = isPrivate ? recipients[rawMin % recipients.length] : address(0);
        token.mint(seller, amount);
        uint256 before = token.balanceOf(address(desk));
        vm.startPrank(seller);
        token.approve(address(desk), amount);
        uint256 id = desk.open(address(token), amount, coin, price, minBuy, uint64(block.timestamp + 7 days), buyer);
        vm.stopPrank();
        (,,, uint256 held, uint256 left,,,,,) = desk.deals(id);
        assertEq(held, arriving, "held != arrival");
        assertEq(left, arriving, "left != arrival");
        assertEq(token.balanceOf(address(desk)) - before, held, "desk balance delta != held");
        ghostDeposited[address(token)] += held;
        ids.push(id);
    }

    function buy(uint256 idSeed, uint256 rawAmount, uint256 payerSeed, uint256 recipientSeed, bool holder) public {
        if (ids.length == 0) return;
        uint256 id = ids[idSeed % ids.length];
        TokenDeals.Deal memory d = _deal(id);
        address payer = payers[payerSeed % payers.length];
        address to = d.buyer != address(0) ? d.buyer : recipients[recipientSeed % recipients.length];
        bool live = d.open && block.timestamp < d.expiry && !desk.paused();
        // After partial buys left may be below minBuy; then only the rest is buyable.
        uint256 lo = d.minBuy == 0 ? 1 : d.minBuy;
        uint256 amount = d.left == 0 ? 1 : lo > d.left ? d.left : bound(rawAmount, lo, d.left);
        if (d.left != 0 && rawAmount % 5 == 0) amount = d.left; // often take the rest
        uint64 passExpiry = uint64(block.timestamp + 1 hours);
        bytes memory pass = holder ? _sign(to, passExpiry) : bytes("");

        uint256 cost = d.price == 0 ? 0 : (amount * d.price + 1e18 - 1) / 1e18;
        uint256 fee = cost * (holder ? desk.holderFeeBps() : desk.feeBps()) / 10_000;
        uint256 total = cost + fee;
        uint256 cap = desk.maxPay(d.payCoin);
        bool overCap = cap != 0 && total > cap;

        _fund(d.payCoin, payer, total);
        uint256 value = d.payCoin == address(0) ? total : 0;

        if (!live || overCap) {
            _expectFailure(payer, value, id, amount, to, total, passExpiry, pass);
            return;
        }
        // A maxTotal one unit short must always fail first.
        _expectFailure(payer, value, id, amount, to, total - 1, passExpiry, pass);
        if (d.payCoin == address(0)) _expectFailure(payer, value + 1, id, amount, to, total + 1, passExpiry, pass);

        uint256 sellerBefore = _received(d.payCoin, d.seller);
        uint256 feeBefore = _received(d.payCoin, feeTo);
        uint256 payerBefore = _balance(d.payCoin, payer);
        uint256 toBefore = IERC20(d.token).balanceOf(to);
        vm.prank(payer);
        desk.buy{value: value}(id, amount, to, total, passExpiry, pass);

        if (d.seller != feeTo) {
            assertEq(_received(d.payCoin, d.seller) - sellerBefore, cost, "seller != cost");
            assertEq(_received(d.payCoin, feeTo) - feeBefore, fee, "FeeSplitter != fee");
        }
        assertEq(payerBefore - _balance(d.payCoin, payer), total, "payer != total");
        uint256 delivered = d.token == address(taxed) ? amount - amount * 200 / 10_000 : amount;
        assertEq(IERC20(d.token).balanceOf(to) - toBefore, delivered, "recipient delivery");

        ghostCost[d.payCoin] += cost;
        ghostFee[d.payCoin] += fee;
        ghostPaid[d.payCoin] += total;
        ghostSoldOut[d.token] += amount;
        if (amount == d.left) everClosed[id] = true;
        ++buys;
    }

    function cancel(uint256 idSeed, bool asStranger) public {
        if (ids.length == 0) return;
        uint256 id = ids[idSeed % ids.length];
        TokenDeals.Deal memory d = _deal(id);
        if (asStranger || !d.open) {
            vm.prank(asStranger ? payers[0] : d.seller);
            try desk.cancel(id) {
                ++unexpectedSuccesses;
            } catch {}
            return;
        }
        uint256 before = IERC20(d.token).balanceOf(address(desk));
        vm.prank(d.seller);
        desk.cancel(id);
        assertEq(before - IERC20(d.token).balanceOf(address(desk)), d.left, "cancel moved != left");
        ghostCancelledOut[d.token] += d.left;
        everClosed[id] = true;
    }

    function update(uint256 idSeed, uint256 rawPrice, uint256 rawMin) public {
        if (ids.length == 0 || desk.paused()) return;
        uint256 id = ids[idSeed % ids.length];
        TokenDeals.Deal memory d = _deal(id);
        if (!d.open) return;
        uint256 price = bound(rawPrice, 1, d.payCoin == address(0) ? 0.1 ether : 100e6);
        vm.prank(d.seller);
        desk.update(id, price, bound(rawMin, 0, d.left), uint64(block.timestamp + 7 days));
    }

    function claim(uint256 seed) public {
        address account = seed % 2 == 0 ? sellers[2] : feeTo;
        uint256 amount = desk.owed(account);
        if (amount == 0) return;
        if (account == sellers[2]) ETHActor(payable(account)).setMode(ETHActor.Mode.Accept);
        uint256 before = account.balance;
        vm.prank(account);
        desk.claimOwed();
        assertEq(account.balance - before, amount, "claim amount");
        ghostClaimed += amount;
        if (account == sellers[2]) ETHActor(payable(account)).setMode(ETHActor.Mode.Reject);
    }

    function admin(uint256 seed, uint256 value) public {
        address owner = desk.owner();
        uint256 action = seed % 4;
        vm.startPrank(owner);
        if (action == 0) {
            uint256 fee = bound(value, 0, 200);
            desk.setFees(fee, bound(value >> 8, 0, fee));
        } else if (action == 1) {
            if (desk.paused()) desk.unpause();
            else desk.pause();
        } else if (action == 2) {
            desk.setMaxPay(coins[value % coins.length], value % 3 == 0 ? 0 : bound(value, 1, 1_000 ether));
        } else {
            // Owner attempts to cancel someone's deal: must always fail.
            if (ids.length != 0) {
                try desk.cancel(ids[value % ids.length]) {
                    ++unexpectedSuccesses;
                } catch {}
            }
        }
        vm.stopPrank();
    }

    function warp(uint256 secondsSeed) public {
        vm.warp(block.timestamp + bound(secondsSeed, 1, 3 days));
    }

    // ------------------------------------------------------------------ helpers and views

    function idsLength() external view returns (uint256) {
        return ids.length;
    }

    function sellerCount() external view returns (uint256) {
        return sellers.length;
    }

    function _expectFailure(
        address payer,
        uint256 value,
        uint256 id,
        uint256 amount,
        address to,
        uint256 maxTotal,
        uint64 passExpiry,
        bytes memory pass
    ) private {
        TokenDeals.Deal memory before = _deal(id);
        uint256 deskEth = address(desk).balance;
        vm.prank(payer);
        try desk.buy{value: value}(id, amount, to, maxTotal, passExpiry, pass) {
            ++unexpectedSuccesses;
        } catch {}
        TokenDeals.Deal memory afterwards = _deal(id);
        assertEq(afterwards.left, before.left, "failed buy moved inventory");
        assertEq(afterwards.open, before.open, "failed buy changed state");
        assertEq(address(desk).balance, deskEth, "failed buy kept ETH");
    }

    function _deal(uint256 id) internal view returns (TokenDeals.Deal memory d) {
        (d.seller, d.token, d.payCoin, d.held, d.left, d.price, d.minBuy, d.expiry, d.buyer, d.open) = desk.deals(id);
    }

    function _fund(address coin, address payer, uint256 total) private {
        if (coin == address(0)) {
            vm.deal(payer, payer.balance + total + 1);
        } else if (coin == usdt) {
            NoBoolToken(coin).mint(payer, total);
            vm.prank(payer);
            NoBoolToken(coin).approve(address(desk), type(uint256).max);
        } else {
            TestToken(coin).mint(payer, total);
            vm.prank(payer);
            TestToken(coin).approve(address(desk), type(uint256).max);
        }
    }

    function _balance(address coin, address account) private view returns (uint256) {
        return coin == address(0) ? account.balance : IERC20(coin).balanceOf(account);
    }

    /// @dev What an account has been paid in a coin: wallet balance plus ETH credit.
    function _received(address coin, address account) private view returns (uint256) {
        return _balance(coin, account) + (coin == address(0) ? desk.owed(account) : 0);
    }

    function _sign(address to, uint64 expiry) private view returns (bytes memory) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("TokenDeals"),
                keccak256("1"),
                block.chainid,
                address(desk)
            )
        );
        bytes32 message = keccak256(abi.encode(keccak256("HolderPass(address recipient,uint64 expiry)"), to, expiry));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PASS_KEY, keccak256(abi.encodePacked("\x19\x01", domain, message)));
        return abi.encodePacked(r, s, v);
    }
}

contract TokenDealsConservationTest is TokenDealsFixture {
    ConservationHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new ConservationHandler(desk, USDC, USDT);
        // Nonvacuous start: one deal per coin, including the ETH-rejecting seller, each bought once.
        for (uint256 i; i < 3; ++i) {
            handler.open(i, i, i == 0 ? 2 : i, 50e18, 0.003 ether + i, 0, i == 1);
            handler.buy(i, 7e18 + i, i, i, i == 2);
        }
        assertEq(handler.buys(), 3);
        assertGt(desk.owed(handler.sellers(2)), 0);

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = ConservationHandler.open.selector;
        selectors[1] = ConservationHandler.buy.selector;
        selectors[2] = ConservationHandler.buy.selector; // weight buys up
        selectors[3] = ConservationHandler.cancel.selector;
        selectors[4] = ConservationHandler.update.selector;
        selectors[5] = ConservationHandler.claim.selector;
        selectors[6] = ConservationHandler.admin.selector;
        selectors[7] = ConservationHandler.warp.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function _sellersReceived(address coin) internal view returns (uint256 total) {
        for (uint256 i; i < handler.sellerCount(); ++i) {
            address s = handler.sellers(i);
            total += coin == address(0) ? s.balance + desk.owed(s) : IERC20(coin).balanceOf(s);
        }
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_sellersReceivedExactlyCumulativeCost() public view {
        address[3] memory coins = [address(0), USDC, USDT];
        for (uint256 i; i < coins.length; ++i) {
            assertEq(_sellersReceived(coins[i]), handler.ghostCost(coins[i]), "sellers != sum(cost)");
        }
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_feeSplitterReceivedExactlyCumulativeFee() public view {
        assertEq(FEE_TO.balance + desk.owed(FEE_TO), handler.ghostFee(address(0)), "ETH fees");
        assertEq(IERC20(USDC).balanceOf(FEE_TO), handler.ghostFee(USDC), "USDC fees");
        assertEq(NoBoolToken(USDT).balanceOf(FEE_TO), handler.ghostFee(USDT), "USDT fees");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_deskKeepsNoPaymentsExceptOwedETH() public view {
        assertEq(IERC20(USDC).balanceOf(address(desk)), 0, "USDC stuck in desk");
        assertEq(NoBoolToken(USDT).balanceOf(address(desk)), 0, "USDT stuck in desk");
        uint256 owedTotal = desk.owed(FEE_TO);
        for (uint256 i; i < handler.sellerCount(); ++i) {
            owedTotal += desk.owed(handler.sellers(i));
        }
        assertEq(address(desk).balance, owedTotal, "ETH != sum(owed)");
        // Everything paid in equals what went to sellers plus the FeeSplitter.
        for (uint256 i; i < 3; ++i) {
            address coin = i == 0 ? address(0) : i == 1 ? USDC : USDT;
            assertEq(handler.ghostPaid(coin), handler.ghostCost(coin) + handler.ghostFee(coin));
        }
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_soldTokensConservedAndBackOpenDeals() public view {
        address[2] memory tokens = [address(handler.plain()), address(handler.taxed())];
        for (uint256 t; t < 2; ++t) {
            uint256 sumLeft;
            for (uint256 i; i < handler.idsLength(); ++i) {
                (, address token,,, uint256 left,,,,, bool open) = desk.deals(handler.ids(i));
                if (token == tokens[t] && open) sumLeft += left;
            }
            uint256 balance = IERC20(tokens[t]).balanceOf(address(desk));
            assertGe(balance, sumLeft, "escrow below sum(left)");
            assertEq(
                balance,
                handler.ghostDeposited(tokens[t]) - handler.ghostSoldOut(tokens[t])
                    - handler.ghostCancelledOut(tokens[t]),
                "escrow != deposited - sold - cancelled"
            );
            assertEq(balance, sumLeft, "escrow holds unexplained tokens");
        }
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_closedDealsStayClosedAndNoForbiddenCallSucceeds() public view {
        assertEq(handler.unexpectedSuccesses(), 0, "a call that must fail succeeded");
        for (uint256 i; i < handler.idsLength(); ++i) {
            uint256 id = handler.ids(i);
            (,,, uint256 held, uint256 left,,,,, bool open) = desk.deals(id);
            if (handler.everClosed(id)) {
                assertFalse(open, "closed deal reopened");
                assertEq(left, 0);
            }
            assertLe(left, held);
            assertEq(open, left > 0);
        }
    }
}
