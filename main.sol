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
}

abstract contract FuturinoPausable {
    error FuturinoPausable__Paused();
    error FuturinoPausable__NotPaused();

    bool public paused;

    modifier whenNotPaused() {
        if (paused) revert FuturinoPausable__Paused();
        _;
    }

    modifier whenPaused() {
        if (!paused) revert FuturinoPausable__NotPaused();
        _;
    }

    function _setPaused(bool v) internal {
        paused = v;
    }
}

contract Ox_Futurino is FuturinoReentrancyGuard, FuturinoPausable {
    using FuturinoSet for FuturinoSet.AddressSet;

    // =========
    // Errors
    // =========
    error Futurino__NotGovernor();
    error Futurino__NotGuardian();
    error Futurino__NotSteward();
    error Futurino__NotCapsuleOwner();
    error Futurino__BadInput();
    error Futurino__EtherRejected();
    error Futurino__UnsupportedAsset();
    error Futurino__CapsuleMissing();
    error Futurino__CapsuleState();
    error Futurino__TooEarly();
    error Futurino__TooLate();
    error Futurino__TransferFailed();
    error Futurino__BadSig();
    error Futurino__AlreadyUsed();
    error Futurino__ChallengeExists();
    error Futurino__NotChallenger();
    error Futurino__FeeTooHigh();
    error Futurino__GovPending();
    error Futurino__NotPendingGovernor();
    error Futurino__AssetConfig();
    error Futurino__FinalizeProposal();
    error Futurino__AlreadyVoted();
    error Futurino__NoProposal();
    error Futurino__BondRequired();
    error Futurino__BondAsset();
    error Futurino__CannotCancel();
    error Futurino__TooManyStewards();

    // =========
    // Events
    // =========
    event FuturinoGovernorSet(address indexed oldGov, address indexed newGov);
    event FuturinoGovernorProposed(address indexed currentGov, address indexed pendingGov);
    event FuturinoGuardianSet(address indexed oldGuardian, address indexed newGuardian);
    event FuturinoPauseSet(bool paused);

    event FuturinoStewardSet(address indexed steward, bool allowed);
    event FuturinoAssetToggled(address indexed asset, bool allowed);
    event FuturinoAssetConfigSet(address indexed asset, uint16 feeBpsOverride, uint256 minBounty);

    event FuturinoCapsuleOpened(
        bytes32 indexed capsuleId,
        address indexed owner,
        address indexed asset,
