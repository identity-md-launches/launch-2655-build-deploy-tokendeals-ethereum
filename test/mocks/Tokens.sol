// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Test-only token; taxes are deducted from amount, never charged on top to the sender.
contract TestToken is ERC20 {
    uint8 private immutable tokenDecimals;
    uint256 public immutable taxBps;
    bool public failTransfers;

    constructor(uint8 decimals_, uint256 taxBps_) ERC20("Test token", "TEST") {
        tokenDecimals = decimals_;
        taxBps = taxBps_;
    }

    function decimals() public view override returns (uint8) {
        return tokenDecimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFailTransfers(bool fail) external {
        failTransfers = fail;
    }

    function transfer(address to, uint256 amount) public virtual override returns (bool) {
        if (failTransfers) return false;
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public virtual override returns (bool) {
        if (failTransfers) return false;
        return super.transferFrom(from, to, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0) && taxBps != 0) {
            uint256 tax = amount * taxBps / 10_000;
            super._update(from, address(0), tax);
            amount -= tax;
        }
        super._update(from, to, amount);
    }
}

/// @dev USDT-style ERC-20 selectors with empty return data from approve/transfer/transferFrom.
contract NoBoolToken {
    uint8 public constant decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed account, address indexed spender, uint256 amount);

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
    }

    function transfer(address to, uint256 amount) external {
        _transfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external {
        allowance[from][msg.sender] -= amount;
        _transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) private {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

/// @dev Executes an arbitrary reentry attempt during incoming or outgoing token transfer.
contract CallbackToken is TestToken {
    address public target;
    bytes public payload;
    bool public onPull;
    bool public onPush;
    bool public attempted;
    bool public succeeded;
    bytes public result;

    constructor() TestToken(18, 0) {}

    function arm(address target_, bytes calldata payload_, bool pull, bool push) external {
        target = target_;
        payload = payload_;
        onPull = pull;
        onPush = push;
        attempted = false;
        succeeded = false;
        delete result;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (onPull) _callback();
        return super.transferFrom(from, to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (onPush) _callback();
        return super.transfer(to, amount);
    }

    function _callback() private {
        attempted = true;
        (succeeded, result) = target.call(payload);
    }
}

interface ITokenReceiver {
    function tokensReceived() external;
}

/// @dev Payment pull succeeds, but payout to one selected beneficiary returns false.
contract BlockedPayoutToken is TestToken {
    address public blocked;

    constructor() TestToken(6, 0) {}

    function blockRecipient(address account) external {
        blocked = account;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (to == blocked) return false;
        return super.transfer(to, amount);
    }
}

/// @dev ERC-20 with a recipient hook, to exercise a recipient reentering the escrow.
contract HookToken is TestToken {
    constructor() TestToken(18, 0) {}

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool ok = super.transfer(to, amount);
        if (to.code.length != 0) ITokenReceiver(to).tokensReceived();
        return ok;
    }
}
