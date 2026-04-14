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
        mapping(address => uint256) _posPlusOne;
    }

    function contains(AddressSet storage s, address a) internal view returns (bool) {
        return s._posPlusOne[a] != 0;
    }

    function length(AddressSet storage s) internal view returns (uint256) {
        return s._items.length;
    }

    function at(AddressSet storage s, uint256 idx) internal view returns (address) {
        if (idx >= s._items.length) revert FuturinoSet__IndexOOB();
        return s._items[idx];
    }

    function add(AddressSet storage s, address a) internal returns (bool) {
        if (a == address(0)) return false;
        if (s._posPlusOne[a] != 0) return false;
        s._items.push(a);
        s._posPlusOne[a] = s._items.length;
        return true;
    }

    function remove(AddressSet storage s, address a) internal returns (bool) {
        uint256 p = s._posPlusOne[a];
        if (p == 0) return false;
        uint256 idx = p - 1;
        uint256 last = s._items.length - 1;
        if (idx != last) {
            address swap = s._items[last];
            s._items[idx] = swap;
            s._posPlusOne[swap] = idx + 1;
        }
        s._items.pop();
        delete s._posPlusOne[a];
        return true;
    }
}

library FuturinoECDSA {
    error FuturinoECDSA__BadSig();
    error FuturinoECDSA__BadV();
    error FuturinoECDSA__BadS();

    // secp256k1n/2
    uint256 internal constant _HALF_ORDER =
        0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    function recover(bytes32 digest, uint8 v, bytes32 r, bytes32 s) internal pure returns (address) {
        if (v != 27 && v != 28) revert FuturinoECDSA__BadV();
        if (uint256(s) > _HALF_ORDER) revert FuturinoECDSA__BadS();
        address signer = ecrecover(digest, v, r, s);
        if (signer == address(0)) revert FuturinoECDSA__BadSig();
        return signer;
    }
}

abstract contract FuturinoReentrancyGuard {
    error FuturinoReentrancyGuard__Reentered();

    uint256 private _rg;

    modifier nonReentrant() {
        if (_rg == 2) revert FuturinoReentrancyGuard__Reentered();
        _rg = 2;
        _;
        _rg = 1;
    }

    constructor() {
        _rg = 1;
    }
