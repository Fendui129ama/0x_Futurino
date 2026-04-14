// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
    Notebook scrap: "shallow comet / brass receipts"
    ------------------------------------------------
    Ox_Futurino is a mainnet-oriented coordination vault for "capsules":
    - users publish content-hash capsules with optional bounty funding
    - designated stewards can finalize capsules after a delay window
    - challengers can dispute within a window to freeze payout
    - payouts are pull-based and can pay in ETH or ERC20

    It is intentionally not an ERC20, not an NFT, and not an oracle.
*/

interface IERC20Like {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address owner, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
}

library FuturinoSafeTransfer {
    error FuturinoSafeTransfer__CallFailed();
    error FuturinoSafeTransfer__BadReturn();

    function _callOptionalReturn(address token, bytes memory data) private {
        (bool ok, bytes memory ret) = token.call(data);
        if (!ok) revert FuturinoSafeTransfer__CallFailed();
        if (ret.length == 0) return; // non-standard ERC20
        if (ret.length == 32) {
            if (!abi.decode(ret, (bool))) revert FuturinoSafeTransfer__BadReturn();
            return;
        }
        revert FuturinoSafeTransfer__BadReturn();
    }

    function safeTransfer(address token, address to, uint256 amount) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(IERC20Like.transfer.selector, to, amount));
    }

    function safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(IERC20Like.transferFrom.selector, from, to, amount));
    }
}

library FuturinoMath {
    error FuturinoMath__BadRange();

    function clampU64(uint256 x) internal pure returns (uint64) {
        if (x > type(uint64).max) return type(uint64).max;
        return uint64(x);
    }

    function checkedU64(uint256 x) internal pure returns (uint64) {
        if (x > type(uint64).max) revert FuturinoMath__BadRange();
        return uint64(x);
    }

    function minU64(uint64 a, uint64 b) internal pure returns (uint64) {
        return a < b ? a : b;
    }

    function maxU64(uint64 a, uint64 b) internal pure returns (uint64) {
        return a > b ? a : b;
    }
}

library FuturinoSet {
    error FuturinoSet__IndexOOB();

    struct AddressSet {
        address[] _items;
