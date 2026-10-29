// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TokenDeals} from "../../src/TokenDeals.sol";
import {TestToken, NoBoolToken} from "../mocks/Tokens.sol";

abstract contract TokenDealsFixture is Test {
    address internal constant OWNER = 0x6C4c78f2C3bDf4C4318Fe305FB1C8BC1694d19b5;
    address internal constant FEE_TO = 0x1119d5Df2f046bC2d3c0F6279EF2E9cE49422d44;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant SHIFT = 0xE5e58E53d0Bb204Aa62c995A6c8CC8a48e60C3AC;
    // Local test identities only. No private key or deployment credential is used by production.
    uint256 internal constant SIGNER_KEY = 0x12345678;
    address internal seller;
    address internal payer;
    address internal recipient;
    TokenDeals internal desk;
    TestToken internal sold;

    event DealOpened(
        uint256 indexed dealId,
        address indexed seller,
        address indexed token,
        address payCoin,
        uint256 held,
        uint256 price,
        uint256 minBuy,
        uint64 expiry,
        address buyer
    );
    event Bought(
        uint256 indexed dealId,
        address indexed payer,
        address indexed recipient,
        uint256 amount,
        uint256 cost,
        uint256 fee,
        bool holder
    );
    event DealUpdated(uint256 indexed dealId, uint256 price, uint256 minBuy, uint64 expiry);
    event DealCancelled(uint256 indexed dealId, uint256 returned);
    event OwedClaimed(address indexed account, uint256 amount);
    event OwedCredited(address indexed account, uint256 amount);
    event FeesSet(uint256 feeBps, uint256 holderFeeBps);
    event PassSignerSet(address signer);
    event PayCoinSet(address indexed coin, bool allowed);
    event MaxPaySet(address indexed coin, uint256 max);
    event Paused(address account);
    event Unpaused(address account);

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        vm.chainId(1);
        seller = makeAddr("seller");
        payer = makeAddr("payer");
        recipient = makeAddr("recipient");
        desk = new TokenDeals();
        sold = new TestToken(18, 0);
        sold.mint(seller, 1_000_000e18);
        vm.prank(seller);
        sold.approve(address(desk), type(uint256).max);
        vm.deal(payer, 10_000 ether);

        TestToken six = new TestToken(6, 0);
        TestToken eighteen = new TestToken(18, 0);
        NoBoolToken noBool = new NoBoolToken();
        vm.etch(USDC, address(six).code);
        vm.etch(USDT, address(noBool).code);
        vm.etch(IMD, address(eighteen).code);
        vm.etch(SHIFT, address(eighteen).code);
    }

    function _expiry() internal view returns (uint64) {
        return uint64(block.timestamp + 30 days);
    }

    function _open(address coin, uint256 amount, uint256 price, uint256 minimum, address buyer)
        internal
        returns (uint256)
    {
        vm.prank(seller);
        return desk.open(address(sold), amount, coin, price, minimum, _expiry(), buyer);
    }

    function _ethDeal() internal returns (uint256) {
        return _open(address(0), 10e18, 0.01 ether, 0, address(0));
    }

    function _deal(uint256 id) internal view returns (TokenDeals.Deal memory d) {
        (d.seller, d.token, d.payCoin, d.held, d.left, d.price, d.minBuy, d.expiry, d.buyer, d.open) = desk.deals(id);
    }

    function _buyETH(uint256 id, uint256 amount) internal {
        (,, uint256 total) = desk.quote(id, amount, false);
        vm.prank(payer);
        desk.buy{value: total}(id, amount, recipient, total, 0, "");
    }

    function _rejectBuyETH(uint256 id, uint256 amount, bytes memory reason) internal {
        (,, uint256 total) = desk.quote(id, amount, false);
        vm.prank(payer);
        vm.expectRevert(reason);
        desk.buy{value: total}(id, amount, recipient, total, 0, "");
    }

    function _fundCoin(address coin, uint256 amount) internal {
        if (coin == USDT) {
            NoBoolToken(coin).mint(payer, amount);
            vm.prank(payer);
            NoBoolToken(coin).approve(address(desk), amount);
        } else {
            TestToken(coin).mint(payer, amount);
            vm.prank(payer);
            TestToken(coin).approve(address(desk), amount);
        }
    }

    function _setSigner() internal {
        vm.prank(OWNER);
        desk.setPassSigner(vm.addr(SIGNER_KEY));
    }

    function _digest(address who, uint64 expiry, uint256 chain, address verifying) internal pure returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("TokenDeals"),
                keccak256("1"),
                chain,
                verifying
            )
        );
        bytes32 message = keccak256(abi.encode(keccak256("HolderPass(address recipient,uint64 expiry)"), who, expiry));
        return keccak256(abi.encodePacked("\x19\x01", domain, message));
    }

    function _pass(address who, uint64 expiry, uint256 key, uint256 chain, address verifying)
        internal
        pure
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, _digest(who, expiry, chain, verifying));
        return abi.encodePacked(r, s, v);
    }
}
