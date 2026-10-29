// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title TokenDeals
/// @notice Fixed-price ERC-20 escrow with atomic settlement and buyer-paid fees.
/// @dev No custody privileges, upgrades, arbitrary calls, token recovery or ownership transfer.
/// Payment coins must be plain ERC-20s. Sold tokens may deduct transfer tax from the sent amount;
/// rebases, dishonest balances and additional sender-side debits are not supported.
contract TokenDeals is EIP712, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice The permanent administrator; deployment never grants the factory ownership.
    address public constant owner = 0x6C4c78f2C3bDf4C4318Fe305FB1C8BC1694d19b5;
    /// @notice Permanent NIGHTSHIFT FeeSplitter on Ethereum.
    address public constant FEE_TO = 0x1119d5Df2f046bC2d3c0F6279EF2E9cE49422d44;
    /// @notice Maximum normal or holder fee, in basis points (2%).
    uint256 public constant MAX_FEE_BPS = 200;
    /// @notice Maximum remaining lifetime of a deal on open or update.
    uint256 public constant MAX_DEAL_LIFETIME = 365 days;
    /// @notice Maximum remaining lifetime of a holder pass at execution.
    uint256 public constant MAX_PASS_LIFETIME = 24 hours;
    /// @notice Gas forwarded by each ETH settlement push; failures become claimable credit.
    uint256 public constant ETH_PUSH_GAS = 50_000;
    /// @notice EIP-712 type hash for reusable, recipient-bound holder passes.
    bytes32 public constant HOLDER_PASS_TYPEHASH = keccak256("HolderPass(address recipient,uint64 expiry)");

    struct Deal {
        address seller;
        address token;
        address payCoin;
        uint256 held;
        uint256 left;
        uint256 price;
        uint256 minBuy;
        uint64 expiry;
        address buyer;
        bool open;
    }

    /// @notice Deal details; held is the actual deposit and never changes. Unknown ids return zeros.
    mapping(uint256 dealId => Deal) public deals;
    /// @notice Number of deals ever opened; ids start at one and are never reused.
    uint256 public dealCount;
    /// @notice Whether a coin may be used for NEW deals; zero denotes native ETH.
    mapping(address coin => bool) public payCoin;
    /// @notice Per-buy cap on cost plus fee, in payment base units; zero means unlimited.
    mapping(address coin => uint256) public maxPay;
    /// @notice Current normal fee in basis points, initially 100 (1%).
    uint256 public feeBps = 100;
    /// @notice Current holder fee in basis points, initially 50 (0.5%).
    uint256 public holderFeeBps = 50;
    /// @notice ECDSA pass signer. Zero disables passes until the owner configures a signer.
    address public passSigner;
    /// @notice ETH from failed settlement pushes, withdrawable only by the credited account.
    mapping(address account => uint256) public owed;

    error OnlyOwner();
    error UnknownDeal(uint256 dealId);
    error DealNotOpen(uint256 dealId);
    error DealExpired(uint256 dealId);
    error OnlySeller();
    error InvalidToken();
    error PaymentCoinNotAllowed();
    error InvalidAmount();
    error InvalidPrice();
    error InvalidExpiry();
    error InvalidMinBuy();
    error InvalidRecipient();
    error MaxTotalExceeded();
    error PaymentCapExceeded();
    error IncorrectETHValue();
    error InvalidPass();
    error PassSignerNotConfigured();
    error InvalidFees();
    error NothingOwed();
    error ETHClaimFailed();

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
    event FeesSet(uint256 feeBps, uint256 holderFeeBps);
    event PassSignerSet(address signer);
    event PayCoinSet(address indexed coin, bool allowed);
    event MaxPaySet(address indexed coin, uint256 max);
    /// @notice Records a failed ETH push in addition to the corresponding Bought event.
    event OwedCredited(address indexed account, uint256 amount);

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    /// @notice Deploys the fully configured Ethereum desk, without external calls or arguments.
    /// @dev Holder passes remain disabled until the fixed owner sets passSigner.
    constructor() EIP712("TokenDeals", "1") {
        _configureCoin(address(0), 1 ether);
        _configureCoin(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, 2500e6);
        _configureCoin(0xdAC17F958D2ee523a2206206994597C13D831ec7, 2500e6);
        _configureCoin(0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7, 500e18);
        _configureCoin(0xE5e58E53d0Bb204Aa62c995A6c8CC8a48e60C3AC, 40_000_000e18);
        emit FeesSet(feeBps, holderFeeBps);
        emit PassSignerSet(address(0));
    }

    /// @notice Deposits tokens and opens a public or recipient-restricted deal.
    /// @param token ERC-20 to sell; must have code and differ from the payment coin.
    /// @param amount Requested deposit in sold-token base units; held measures what actually arrives.
    /// @param payCoin_ Allowed payment coin; address(0) denotes ETH.
    /// @param price Payment base units per 1e18 sold-token base units, independent of token decimals.
    /// @param minBuy Smallest partial buy, in sold-token base units; the entire remainder is exempt.
    /// @param expiry Future expiry, at most 365 days from now.
    /// @param buyer Zero for a public deal, otherwise the only permitted token recipient.
    /// @return dealId New monotonically increasing id, starting at one.
    function open(
        address token,
        uint256 amount,
        address payCoin_,
        uint256 price,
        uint256 minBuy,
        uint64 expiry,
        address buyer
    ) external nonReentrant whenNotPaused returns (uint256 dealId) {
        if (token.code.length == 0 || token == payCoin_) revert InvalidToken();
        if (!payCoin[payCoin_]) revert PaymentCoinNotAllowed();
        if (amount == 0) revert InvalidAmount();
        _validateTerms(price, expiry);

        // Actual receipt cannot be known before transferFrom. The guard prevents any nested
        // state change during both balance reads and the transfer. A later revert is atomic.
        uint256 beforeBalance = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 held = IERC20(token).balanceOf(address(this)) - beforeBalance;
        if (held == 0) revert InvalidAmount();
        if (minBuy > held) revert InvalidMinBuy();

        dealId = ++dealCount;
        deals[dealId] = Deal(msg.sender, token, payCoin_, held, held, price, minBuy, expiry, buyer, true);
        emit DealOpened(dealId, msg.sender, token, payCoin_, held, price, minBuy, expiry, buyer);
    }

    /// @notice Buys tokens for recipient, charging msg.sender the price plus fee atomically.
    /// @param dealId Existing, open, unexpired deal.
    /// @param amount Sold-token base units to debit; transfer-tax tokens may deliver less.
    /// @param recipient Nonzero token recipient, matching the private buyer when one is set.
    /// @param maxTotal Maximum acceptable cost plus fee, in payment base units.
    /// @param passExpiry Signed expiry; ignored if pass is empty. Valid through this timestamp.
    /// @param pass Empty for normal fees, or a canonical 65-byte EIP-712 ECDSA holder signature.
    function buy(
        uint256 dealId,
        uint256 amount,
        address recipient,
        uint256 maxTotal,
        uint64 passExpiry,
        bytes calldata pass
    ) external payable nonReentrant whenNotPaused {
        Deal storage deal = _openDeal(dealId);
        if (block.timestamp >= deal.expiry) revert DealExpired(dealId);
        if (recipient == address(0) || (deal.buyer != address(0) && recipient != deal.buyer)) {
            revert InvalidRecipient();
        }
        if (amount == 0 || amount > deal.left) revert InvalidAmount();
        if (amount < deal.minBuy && amount != deal.left) revert InvalidMinBuy();

        bool holder = _validatePass(recipient, passExpiry, pass);
        (uint256 cost, uint256 fee, uint256 total) = _quote(deal.price, amount, holder);
        if (total > maxTotal) revert MaxTotalExceeded();
        uint256 cap = maxPay[deal.payCoin];
        if (cap != 0 && total > cap) revert PaymentCapExceeded();
        if (msg.value != (deal.payCoin == address(0) ? total : 0)) revert IncorrectETHValue();

        deal.left -= amount;
        if (deal.left == 0) deal.open = false;
        emit Bought(dealId, msg.sender, recipient, amount, cost, fee, holder);

        if (deal.payCoin != address(0)) {
            IERC20(deal.payCoin).safeTransferFrom(msg.sender, address(this), total);
        }
        IERC20(deal.token).safeTransfer(recipient, amount);
        if (deal.payCoin == address(0)) {
            _payETH(deal.seller, cost);
            _payETH(FEE_TO, fee);
        } else {
            IERC20(deal.payCoin).safeTransfer(deal.seller, cost);
            if (fee != 0) IERC20(deal.payCoin).safeTransfer(FEE_TO, fee);
        }
    }

    /// @notice Seller revises an open deal, including renewing an expired but uncancelled deal.
    /// @param dealId Seller's existing open deal.
    /// @param price New positive price, using the same base-unit convention as open.
    /// @param minBuy New minimum, no larger than the remaining inventory.
    /// @param expiry New future expiry, at most 365 days from now.
    function update(uint256 dealId, uint256 price, uint256 minBuy, uint64 expiry) external nonReentrant whenNotPaused {
        Deal storage deal = _openDeal(dealId);
        if (msg.sender != deal.seller) revert OnlySeller();
        _validateTerms(price, expiry);
        if (minBuy > deal.left) revert InvalidMinBuy();
        deal.price = price;
        deal.minBuy = minBuy;
        deal.expiry = expiry;
        emit DealUpdated(dealId, price, minBuy, expiry);
    }

    /// @notice Seller closes an open deal and receives its remaining tokens, even expired or paused.
    /// @dev returned is the amount sent, before any sold-token outbound transfer tax.
    function cancel(uint256 dealId) external nonReentrant {
        Deal storage deal = _openDeal(dealId);
        if (msg.sender != deal.seller) revert OnlySeller();
        uint256 returned = deal.left;
        deal.left = 0;
        deal.open = false;
        emit DealCancelled(dealId, returned);
        IERC20(deal.token).safeTransfer(deal.seller, returned);
    }

    /// @notice Withdraws all of the caller's credited ETH to that same caller, even while paused.
    /// @dev Forwards available gas; a failed claim reverts and preserves the entire credit.
    function claimOwed() external nonReentrant {
        uint256 amount = owed[msg.sender];
        if (amount == 0) revert NothingOwed();
        owed[msg.sender] = 0;
        emit OwedClaimed(msg.sender, amount);
        (bool success,) = payable(msg.sender).call{value: amount}("");
        if (!success) revert ETHClaimFailed();
    }

    /// @notice Returns current rounded cost, fee and total for an existing deal.
    /// @dev Arithmetic preview only: does not validate availability, amount, expiry, caps or a pass.
    /// The holder flag estimates the discounted fee but does not confer eligibility in buy.
    function quote(uint256 dealId, uint256 amount, bool holder)
        external
        view
        returns (uint256 cost, uint256 fee, uint256 total)
    {
        Deal storage deal = deals[dealId];
        if (deal.seller == address(0)) revert UnknownDeal(dealId);
        return _quote(deal.price, amount, holder);
    }

    /// @notice Owner sets fees satisfying holderFeeBps <= feeBps <= MAX_FEE_BPS.
    /// @dev Applies to future buys of existing deals too; buyers bound payment with maxTotal.
    function setFees(uint256 feeBps_, uint256 holderFeeBps_) external nonReentrant onlyOwner {
        if (holderFeeBps_ > feeBps_ || feeBps_ > MAX_FEE_BPS) revert InvalidFees();
        feeBps = feeBps_;
        holderFeeBps = holderFeeBps_;
        emit FeesSet(feeBps_, holderFeeBps_);
    }

    /// @notice Owner sets the ECDSA signer; zero disables all nonempty passes.
    /// @dev Rotation immediately invalidates signatures from the previous signer.
    function setPassSigner(address signer) external nonReentrant onlyOwner {
        passSigner = signer;
        emit PassSignerSet(signer);
    }

    /// @notice Owner allows or disallows a payment coin for new deals only; zero denotes ETH.
    /// @dev The owner must vet ERC-20 coins as plain, non-rebasing and without transfer fees.
    function setPayCoin(address coin, bool allowed) external nonReentrant onlyOwner {
        payCoin[coin] = allowed;
        emit PayCoinSet(coin, allowed);
    }

    /// @notice Owner sets the per-buy total cap in payment base units; zero removes the cap.
    /// @dev Applies to existing deals too, independently of the new-deal allowlist.
    function setMaxPay(address coin, uint256 max) external nonReentrant onlyOwner {
        maxPay[coin] = max;
        emit MaxPaySet(coin, max);
    }

    /// @notice Owner pauses open, update and buy. Cancellation and ETH claims remain available.
    function pause() external nonReentrant onlyOwner {
        _pause();
    }

    /// @notice Owner resumes open, update and buy.
    function unpause() external nonReentrant onlyOwner {
        _unpause();
    }

    function _configureCoin(address coin, uint256 cap) private {
        payCoin[coin] = true;
        maxPay[coin] = cap;
        emit PayCoinSet(coin, true);
        emit MaxPaySet(coin, cap);
    }

    function _validateTerms(uint256 price, uint64 expiry) private view {
        if (price == 0) revert InvalidPrice();
        if (expiry <= block.timestamp || uint256(expiry) > block.timestamp + MAX_DEAL_LIFETIME) {
            revert InvalidExpiry();
        }
    }

    function _openDeal(uint256 dealId) private view returns (Deal storage deal) {
        deal = deals[dealId];
        if (deal.seller == address(0)) revert UnknownDeal(dealId);
        if (!deal.open) revert DealNotOpen(dealId);
    }

    function _quote(uint256 price, uint256 amount, bool holder)
        private
        view
        returns (uint256 cost, uint256 fee, uint256 total)
    {
        cost = Math.mulDiv(amount, price, 1e18, Math.Rounding.Ceil);
        fee = Math.mulDiv(cost, holder ? holderFeeBps : feeBps, 10_000);
        total = cost + fee;
    }

    function _validatePass(address recipient, uint64 expiry, bytes calldata pass) private view returns (bool) {
        if (pass.length == 0) return false;
        address signer = passSigner;
        if (signer == address(0)) revert PassSignerNotConfigured();
        if (expiry < block.timestamp || uint256(expiry) > block.timestamp + MAX_PASS_LIFETIME) {
            revert InvalidPass();
        }
        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(HOLDER_PASS_TYPEHASH, recipient, expiry)));
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, pass);
        if (err != ECDSA.RecoverError.NoError || recovered != signer) revert InvalidPass();
        return true;
    }

    function _payETH(address account, uint256 amount) private {
        if (amount == 0) return;
        // Bounded gas and no returndata copying keep a hostile receiver from blocking the buy.
        (bool success,) = payable(account).call{value: amount, gas: ETH_PUSH_GAS}("");
        if (!success) {
            owed[account] += amount;
            emit OwedCredited(account, amount);
        }
    }
}
