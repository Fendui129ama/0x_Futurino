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
        uint256 bounty,
        bytes32 contentHash,
        uint64 openAt,
        uint64 finalEarliestAt,
        uint64 finalLatestAt,
        uint64 challengeLatestAt,
        uint32 stewardQuorum
    );

    event FuturinoCapsuleTopped(bytes32 indexed capsuleId, address indexed from, uint256 amount);
    event FuturinoCapsuleFinalized(bytes32 indexed capsuleId, address indexed steward, address indexed beneficiary, uint256 payout);
    event FuturinoCapsuleChallenged(bytes32 indexed capsuleId, address indexed challenger, bytes32 indexed challengeHash);
    event FuturinoCapsuleResolved(bytes32 indexed capsuleId, bool payoutAllowed, bytes32 resolutionHash);
    event FuturinoCapsuleCancelled(bytes32 indexed capsuleId, address indexed owner, bytes32 reasonHash);
    event FuturinoFinalizeVote(bytes32 indexed capsuleId, address indexed steward, bytes32 proposalHash, uint32 approvals);
    event FuturinoChallengeBondSet(uint96 minBondWei, uint96 maxBondWei, uint16 slashBps);
    event FuturinoChallengeBondPosted(bytes32 indexed capsuleId, address indexed challenger, uint256 bondWei);
    event FuturinoChallengeBondSettled(bytes32 indexed capsuleId, address indexed challenger, bool challengerWins, uint256 returnedWei, uint256 slashedWei);

    event FuturinoWithdrawal(address indexed to, address indexed asset, uint256 amount);
    event FuturinoProtocolFeeSet(uint16 feeBps, address indexed feeSink);

    // =========
    // Constants (intentionally distinctive)
    // =========
    uint16 public constant MAX_FEE_BPS = 425; // 4.25%
    uint16 public constant MAX_BOND_SLASH_BPS = 9_000; // 90%
    uint32 public constant MIN_STEWARD_QUORUM = 1;
    uint32 public constant MAX_STEWARD_QUORUM = 9;
    uint32 public constant MAX_STEWARD_COUNT = 64;
    uint16 public constant MAX_ASSET_FEE_OVERRIDE_BPS = 650; // 6.50%

    // challenge bond economics (ETH only)
    uint96 public constant DEFAULT_MIN_BOND_WEI = 0.0042 ether;
    uint96 public constant DEFAULT_MAX_BOND_WEI = 0.42 ether;

    bytes32 public constant CAPSULE_OPEN_TYPEHASH =
        keccak256(
            "CapsuleOpen(address owner,address asset,uint256 bounty,bytes32 contentHash,uint64 finalEarliestAt,uint64 finalLatestAt,uint64 challengeLatestAt,uint32 stewardQuorum,uint256 ownerNonce,uint256 chainId,address verifyingContract)"
        );

    bytes32 public immutable DOMAIN_SALT;

    // =========
    // Randomized, non-user-supplied anchors
    // (mixed-case address literals per your request)
    // =========
    address public immutable GENESIS_FEE_SINK = 0x7aB3dC91f04e2D6bA9c1F3E5B7d8A0c1e2F4b6A8;
    address public immutable GENESIS_GUARDIAN = 0xB1c2D3e4F5A6b7C8d9E0f1A2B3c4D5e6F7a8B9C0;
    address public immutable GENESIS_SIGNAL = 0x0dE1aB23cD45Ef67aB89cD01eF23aB45cD67eF89;

    // =========
    // Governance
    // =========
    address public governor;
    address public pendingGovernor;
    address public guardian;
    uint16 public protocolFeeBps;
    address public feeSink;

    // =========
    // Permissions
    // =========
    FuturinoSet.AddressSet private _stewards;
    mapping(address => bool) public isAssetAllowed; // includes address(0) for ETH when enabled

    struct AssetConfig {
        uint16 feeBpsOverride; // 0 means use protocolFeeBps
        uint240 minBounty; // per-asset minimum bounty (wei or token units)
    }

    mapping(address => AssetConfig) public assetConfig;

