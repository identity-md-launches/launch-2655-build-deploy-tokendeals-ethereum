// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TokenDeals} from "../../src/TokenDeals.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev Seller, fee recipient or credit recipient used only in local tests.
contract ETHActor {
    enum Mode {
        Accept,
        Reject,
        ReenterCancel,
        ReenterClaim,
        ExhaustGas,
        LargeReturn
    }
    TokenDeals public immutable desk;
    Mode public mode;
    bool public attempted;
    bool public succeeded;
    bytes4 public errorSelector;
    uint256 public dealId;

    constructor(TokenDeals desk_) {
        desk = desk_;
    }

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function openDeal(address token, uint256 amount, address coin, uint256 price, uint64 expiry)
        external
        returns (uint256)
    {
        IERC20(token).approve(address(desk), amount);
        dealId = desk.open(token, amount, coin, price, 0, expiry, address(0));
        return dealId;
    }

    function claim() external {
        desk.claimOwed();
    }

    function cancel() external {
        desk.cancel(dealId);
    }

    receive() external payable {
        Mode current = mode;
        if (current == Mode.Reject) revert("ETH rejected by test actor");
        if (current == Mode.ExhaustGas) {
            assembly ("memory-safe") { for {} 1 {} {} }
        }
        if (current == Mode.LargeReturn) {
            assembly { return(0, 0x8000) }
        }
        if (current == Mode.ReenterCancel || current == Mode.ReenterClaim) {
            bytes memory payload = current == Mode.ReenterCancel
                ? abi.encodeCall(TokenDeals.cancel, (dealId))
                : abi.encodeCall(TokenDeals.claimOwed, ());
            (bool ok, bytes memory result) = address(desk).call(payload);
            attempted = true;
            succeeded = ok;
            errorSelector = bytes4(result);
        }
    }
}

contract ReentrantRecipient {
    TokenDeals public immutable desk;
    uint256 public dealId;
    bool public attempted;
    bool public succeeded;
    bytes4 public errorSelector;
    uint256 public seenLeft;

    constructor(TokenDeals desk_) {
        desk = desk_;
    }

    function setDeal(uint256 id) external {
        dealId = id;
    }

    function tokensReceived() external {
        (,,,, uint256 left,,,,,) = desk.deals(dealId);
        seenLeft = left;
        (bool ok, bytes memory result) = address(desk)
            .call(abi.encodeCall(TokenDeals.buy, (dealId, 1, address(this), type(uint256).max, uint64(0), bytes(""))));
        attempted = true;
        succeeded = ok;
        errorSelector = bytes4(result);
    }
}
