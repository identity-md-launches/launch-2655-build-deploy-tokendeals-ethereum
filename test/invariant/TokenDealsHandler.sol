// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TokenDeals} from "../../src/TokenDeals.sol";
import {TestToken} from "../mocks/Tokens.sol";
import {ETHActor} from "../mocks/Actors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Stateful model: ordinary, taxed and no-return tokens; payment coins can also be escrowed.
contract TokenDealsHandler is Test {
    using SafeERC20 for IERC20;

    uint256 private constant PASS_KEY = 0x87654321;
    TokenDeals public immutable desk;
    address public immutable owner;
    address public immutable feeTo;
    address public immutable taxed;
    address[] public assets;
    address[] public coins;
    address[] public sellers;
    address[] public recipients;
    mapping(uint256 => uint256) public initialHeld;
    mapping(uint256 => uint256) public bought;
    mapping(uint256 => uint256) public returned;
    mapping(address => uint256) public donations;
    mapping(address => uint256) public ghostLeft;
    uint256 public successfulBuys;
    uint256 public successfulClaims;

    constructor(TokenDeals desk_, address[] memory assets_, address[] memory coins_, address taxed_) {
        desk = desk_;
        owner = desk_.owner();
        feeTo = desk_.FEE_TO();
        taxed = taxed_;
        assets = assets_;
        coins = coins_;
        sellers.push(makeAddr("invariant seller 1"));
        sellers.push(makeAddr("invariant seller 2"));
        sellers.push(makeAddr("invariant seller 3"));
        ETHActor rejector = new ETHActor(desk_);
        rejector.setMode(ETHActor.Mode.Reject);
        sellers.push(address(rejector));
        recipients.push(makeAddr("invariant recipient 1"));
        recipients.push(makeAddr("invariant recipient 2"));
        recipients.push(makeAddr("invariant recipient 3"));
        vm.prank(owner);
        desk.setPassSigner(vm.addr(PASS_KEY));
    }

    function openDeal(
        uint256 assetSeed,
        uint256 coinSeed,
        uint256 sellerSeed,
        uint256 rawAmount,
        uint256 rawPrice,
        uint256 rawMinimum,
        bool isPrivate
    ) public {
        if (desk.paused()) return;
        address token = assets[assetSeed % assets.length];
        address coin = coins[coinSeed % coins.length];
        if (coin == token) coin = address(0);
        if (!desk.payCoin(coin)) return;
        address seller = sellers[sellerSeed % sellers.length];
        uint256 amount = bound(rawAmount, 1, 1_000e18);
        uint256 receipt = token == taxed ? amount - amount * 200 / 10_000 : amount;
        uint256 price = bound(rawPrice, 1, 1e18);
        uint256 minimum = bound(rawMinimum, 0, receipt);
        address buyer = isPrivate ? recipients[assetSeed % recipients.length] : address(0);
        TestToken(token).mint(seller, amount);
        vm.startPrank(seller);
        IERC20(token).forceApprove(address(desk), amount);
        uint256 id = desk.open(token, amount, coin, price, minimum, uint64(block.timestamp + 30 days), buyer);
        vm.stopPrank();
        initialHeld[id] = receipt;
        ghostLeft[token] += receipt;
        assertEq(getDeal(id).held, receipt);
    }

    function buyDeal(uint256 idSeed, uint256 rawAmount, uint256 recipientSeed, bool holder) public {
        if (desk.paused() || desk.dealCount() == 0) return;
        uint256 id = idSeed % desk.dealCount() + 1;
        TokenDeals.Deal memory d = getDeal(id);
        if (!d.open || block.timestamp >= d.expiry) return;
        uint256 amount = bound(rawAmount, 1, d.left);
        if (amount < d.minBuy) amount = d.left;
        address to = d.buyer == address(0) ? recipients[recipientSeed % recipients.length] : d.buyer;
        address payer = recipients[(recipientSeed % recipients.length + 1) % recipients.length];

        // Independent arithmetic oracle: bounded operands cannot overflow this multiplication.
        uint256 product = amount * d.price;
        uint256 cost = product / 1e18 + (product % 1e18 == 0 ? 0 : 1);
        uint256 bps = holder ? desk.holderFeeBps() : desk.feeBps();
        uint256 fee = cost * bps / 10_000;
        uint256 total = cost + fee;
        uint256 cap = desk.maxPay(d.payCoin);
        if (cap != 0 && total > cap) return;

        if (d.payCoin == address(0)) {
            vm.deal(payer, payer.balance + total);
        } else {
            TestToken(d.payCoin).mint(payer, total);
            vm.prank(payer);
            IERC20(d.payCoin).forceApprove(address(desk), total);
        }
        uint256 beforeSeller = _paidBalance(d.payCoin, d.seller);
        uint256 beforeFee = _paidBalance(d.payCoin, feeTo);
        uint256 beforePayer = _paidBalance(d.payCoin, payer);
        uint256 beforeRecipient = IERC20(d.token).balanceOf(to);
        uint64 expiry = uint64(block.timestamp + 1 hours);
        bytes memory pass = holder ? _sign(to, expiry) : bytes("");
        vm.prank(payer);
        desk.buy{value: d.payCoin == address(0) ? total : 0}(id, amount, to, total, expiry, pass);

        // Exact per-buy checks cover both successful pushes and credited ETH payouts.
        assertEq(_paidBalance(d.payCoin, d.seller) - beforeSeller, cost, "seller exact cost");
        assertEq(_paidBalance(d.payCoin, feeTo) - beforeFee, fee, "splitter exact fee");
        assertEq(beforePayer - _paidBalance(d.payCoin, payer), total, "payer exact total");
        uint256 received = d.token == taxed ? amount - amount * 200 / 10_000 : amount;
        assertEq(IERC20(d.token).balanceOf(to) - beforeRecipient, received, "recipient actual tokens");
        bought[id] += amount;
        ghostLeft[d.token] -= amount;
        successfulBuys++;
    }

    function cancelDeal(uint256 seed) public {
        if (desk.dealCount() == 0) return;
        uint256 id = seed % desk.dealCount() + 1;
        TokenDeals.Deal memory d = getDeal(id);
        if (!d.open) return;
        uint256 beforeSeller = IERC20(d.token).balanceOf(d.seller);
        vm.prank(d.seller);
        desk.cancel(id);
        uint256 receipt = d.token == taxed ? d.left - d.left * 200 / 10_000 : d.left;
        assertEq(IERC20(d.token).balanceOf(d.seller) - beforeSeller, receipt);
        returned[id] += d.left;
        ghostLeft[d.token] -= d.left;
    }

    function updateDeal(uint256 seed, uint256 rawPrice, uint256 rawMinimum) external {
        if (desk.paused() || desk.dealCount() == 0) return;
        uint256 id = seed % desk.dealCount() + 1;
        TokenDeals.Deal memory d = getDeal(id);
        if (!d.open) return;
        uint256 price = bound(rawPrice, 1, 1e18);
        uint256 minimum = bound(rawMinimum, 0, d.left);
        vm.prank(d.seller);
        desk.update(id, price, minimum, uint64(block.timestamp + 365 days));
    }

    function donate(uint256 seed, uint256 rawAmount) external {
        address token = assets[seed % assets.length];
        uint256 amount = bound(rawAmount, 0, 1_000e18);
        TestToken(token).mint(address(desk), amount);
        donations[token] += amount;
    }

    function admin(uint256 seed, uint256 value) external {
        uint256 operation = seed % 5;
        address coin = coins[value % coins.length];
        vm.startPrank(owner);
        if (operation == 0) {
            uint256 normal = value % 201;
            desk.setFees(normal, value % (normal + 1));
        } else if (operation == 1) {
            if (desk.paused()) desk.unpause();
            else desk.pause();
        } else if (operation == 2) {
            desk.setPayCoin(coin, !desk.payCoin(coin));
        } else if (operation == 3) {
            desk.setMaxPay(coin, value % 2 == 0 ? 0 : bound(value, 1, 10_000e18));
        } else {
            // Both settings are real test receivers of ETH, without changing fixed FEE_TO.
            ETHActor(payable(feeTo)).setMode(value % 2 == 0 ? ETHActor.Mode.Accept : ETHActor.Mode.Reject);
        }
        vm.stopPrank();
    }

    function advanceTime(uint256 secondsSeed) external {
        vm.warp(block.timestamp + secondsSeed % 10 days);
    }

    function claimCredits(uint256 seed) public {
        address account = seed % 2 == 0 ? sellers[3] : feeTo;
        uint256 amount = desk.owed(account);
        if (amount == 0) return;
        uint256 beforeAccount = account.balance;
        ETHActor actor = ETHActor(payable(account));
        ETHActor.Mode previous = actor.mode();
        actor.setMode(ETHActor.Mode.Accept);
        actor.claim();
        actor.setMode(previous);
        assertEq(account.balance - beforeAccount, amount);
        assertEq(desk.owed(account), 0);
        successfulClaims++;
    }

    function getDeal(uint256 id) public view returns (TokenDeals.Deal memory d) {
        (d.seller, d.token, d.payCoin, d.held, d.left, d.price, d.minBuy, d.expiry, d.buyer, d.open) = desk.deals(id);
    }

    function totalOwed() external view returns (uint256 total) {
        total = desk.owed(feeTo);
        for (uint256 i; i < sellers.length; ++i) {
            total += desk.owed(sellers[i]);
        }
    }

    function _paidBalance(address coin, address account) private view returns (uint256) {
        return coin == address(0) ? account.balance + desk.owed(account) : IERC20(coin).balanceOf(account);
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
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domain, message));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PASS_KEY, digest);
        return abi.encodePacked(r, s, v);
    }
}
