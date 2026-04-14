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

    // =========
    // Accounting
    // =========
    mapping(address => mapping(address => uint256)) public withdrawable; // user => asset => amount

    // =========
    // Capsules
    // =========
    enum CapsuleState {
        None,
        Open,
        Challenged,
        Resolved,
        Paid
    }

    struct Capsule {
        CapsuleState state;
        address owner;
        address asset;
        uint256 bounty;
        bytes32 contentHash;

        uint64 openAt;
        uint64 finalEarliestAt;
        uint64 finalLatestAt;
        uint64 challengeLatestAt;
        uint32 stewardQuorum;

        // finalize voting compactness
        address proposedBeneficiary;
        uint256 proposedPayout;
        uint32 approvals;

        // challenge
        address challenger;
        bytes32 challengeHash;
        uint96 challengeBondWei;

        // resolution
        bool payoutAllowed;
        bytes32 resolutionHash;
    }

    mapping(bytes32 => Capsule) public capsules;

    struct FinalizeProposal {
        address beneficiary;
        uint256 payout;
        bytes32 proposalHash;
    }

    mapping(bytes32 => FinalizeProposal) public finalizeProposal;
    mapping(bytes32 => mapping(address => bytes32)) public stewardVotedProposal; // capsuleId => steward => proposalHash

    // replay protection for signatures
    mapping(address => uint256) public ownerNonces;
    mapping(bytes32 => bool) public usedDigests;

    // challenge bond parameters
    uint96 public minChallengeBondWei;
    uint96 public maxChallengeBondWei;
    uint16 public bondSlashBps; // if challenger loses, this % of bond is slashed to feeSink

    // =========
    // Modifiers
    // =========
    modifier onlyGovernor() {
        if (msg.sender != governor) revert Futurino__NotGovernor();
        _;
    }

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert Futurino__NotGuardian();
        _;
    }

    modifier onlySteward() {
        if (!_stewards.contains(msg.sender)) revert Futurino__NotSteward();
        _;
    }

    // =========
    // Constructor
    // =========
    constructor() {
        governor = msg.sender;
        guardian = GENESIS_GUARDIAN;
        feeSink = GENESIS_FEE_SINK;
        protocolFeeBps = 77;
        minChallengeBondWei = DEFAULT_MIN_BOND_WEI;
        maxChallengeBondWei = DEFAULT_MAX_BOND_WEI;
        bondSlashBps = 4_200; // 42%

        // ETH + 2 “random” assets toggled off by default.
        isAssetAllowed[address(0)] = true;
        isAssetAllowed[GENESIS_SIGNAL] = false;
        isAssetAllowed[address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48)] = false; // common stable (kept off)

        // seed a few stewards (governor can rotate)
        _stewards.add(0xCc12aB34Cd56Ef78aB90cD12eF34aB56cD78eF90);
        _stewards.add(0x12aBCd34Ef56aB78Cd90Ef12aB34cD56eF78aB90);
        _stewards.add(0xaB12cD34eF56aB78cD90eF12aB34cD56Ef78Ab90);

        DOMAIN_SALT = keccak256(
            abi.encodePacked(
                block.chainid,
                address(this),
                msg.sender,
                block.prevrandao,
                block.timestamp,
                GENESIS_FEE_SINK,
                GENESIS_GUARDIAN,
                bytes32(uint256(0x0f3B8aE1d4C2b9A6071E5f0A2d8C4e9B1a7F3c2D5e8A9b0C1d2E3f4A5b6C7d8))
            )
        );

        emit FuturinoGovernorSet(address(0), governor);
        emit FuturinoGuardianSet(address(0), guardian);
        emit FuturinoProtocolFeeSet(protocolFeeBps, feeSink);
        emit FuturinoChallengeBondSet(minChallengeBondWei, maxChallengeBondWei, bondSlashBps);
        emit FuturinoPauseSet(false);
    }

    receive() external payable {
        // only accept ETH from explicit funding calls (prevents accidental transfers)
        if (msg.sender != address(this)) revert Futurino__EtherRejected();
    }

    fallback() external payable {
        revert Futurino__EtherRejected();
    }

    // =========
    // Admin
    // =========
    function proposeGovernor(address newGov) external onlyGovernor {
        if (newGov == address(0)) revert Futurino__BadInput();
        pendingGovernor = newGov;
        emit FuturinoGovernorProposed(governor, newGov);
    }

    function acceptGovernor() external {
        if (msg.sender != pendingGovernor) revert Futurino__NotPendingGovernor();
        address old = governor;
        governor = msg.sender;
        pendingGovernor = address(0);
        emit FuturinoGovernorSet(old, msg.sender);
    }

    function setGuardian(address newGuardian) external onlyGovernor {
        if (newGuardian == address(0)) revert Futurino__BadInput();
        address old = guardian;
        guardian = newGuardian;
        emit FuturinoGuardianSet(old, newGuardian);
    }

    function setPaused(bool v) external onlyGuardian {
        _setPaused(v);
        emit FuturinoPauseSet(v);
    }

    function setProtocolFee(uint16 feeBps_, address sink_) external onlyGovernor {
        if (feeBps_ > MAX_FEE_BPS) revert Futurino__FeeTooHigh();
        if (sink_ == address(0)) revert Futurino__BadInput();
        protocolFeeBps = feeBps_;
        feeSink = sink_;
        emit FuturinoProtocolFeeSet(feeBps_, sink_);
    }

    function setChallengeBondParams(uint96 minBondWei_, uint96 maxBondWei_, uint16 slashBps_) external onlyGovernor {
        if (minBondWei_ == 0 || maxBondWei_ < minBondWei_) revert Futurino__BadInput();
        if (slashBps_ > MAX_BOND_SLASH_BPS) revert Futurino__BadInput();
        minChallengeBondWei = minBondWei_;
        maxChallengeBondWei = maxBondWei_;
        bondSlashBps = slashBps_;
        emit FuturinoChallengeBondSet(minBondWei_, maxBondWei_, slashBps_);
    }

    function setSteward(address steward, bool allowed) external onlyGovernor {
        if (steward == address(0)) revert Futurino__BadInput();
        if (allowed && _stewards.length() >= MAX_STEWARD_COUNT) revert Futurino__TooManyStewards();
        bool changed = allowed ? _stewards.add(steward) : _stewards.remove(steward);
        if (changed) emit FuturinoStewardSet(steward, allowed);
    }

    function stewardCount() external view returns (uint256) {
        return _stewards.length();
    }

    function stewardAt(uint256 idx) external view returns (address) {
        return _stewards.at(idx);
    }

    function toggleAsset(address asset, bool allowed) external onlyGovernor {
        // asset==0 means ETH
        isAssetAllowed[asset] = allowed;
        emit FuturinoAssetToggled(asset, allowed);
    }

    function setAssetConfig(address asset, uint16 feeBpsOverride, uint256 minBounty) external onlyGovernor {
        if (feeBpsOverride > MAX_ASSET_FEE_OVERRIDE_BPS) revert Futurino__AssetConfig();
        assetConfig[asset] = AssetConfig({feeBpsOverride: feeBpsOverride, minBounty: uint240(minBounty)});
        emit FuturinoAssetConfigSet(asset, feeBpsOverride, minBounty);
    }

    // =========
    // Capsule identifiers
    // =========
    function computeCapsuleId(
        address owner,
        address asset,
        uint256 bounty,
        bytes32 contentHash,
        uint64 openAt,
        uint64 finalEarliestAt,
        uint64 finalLatestAt,
        uint64 challengeLatestAt,
        uint32 stewardQuorum
    ) public pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(owner, asset, bounty, contentHash, openAt, finalEarliestAt, finalLatestAt, challengeLatestAt, stewardQuorum)
        );
    }

    // =========
    // Funding helpers
    // =========
    function _pullToken(address token, address from, uint256 amount) internal {
        if (amount == 0) return;
        FuturinoSafeTransfer.safeTransferFrom(token, from, address(this), amount);
    }

    function _pushToken(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        FuturinoSafeTransfer.safeTransfer(token, to, amount);
    }

    function _credit(address to, address asset, uint256 amount) internal {
        if (amount == 0) return;
        withdrawable[to][asset] += amount;
    }

    // =========
    // Open capsule (direct)
    // =========
    function openCapsuleETH(
        bytes32 contentHash,
        uint64 finalEarliestAt,
        uint64 finalLatestAt,
        uint64 challengeLatestAt,
        uint32 stewardQuorum
    ) external payable whenNotPaused nonReentrant returns (bytes32 capsuleId) {
        capsuleId = _openCapsule(msg.sender, address(0), msg.value, contentHash, finalEarliestAt, finalLatestAt, challengeLatestAt, stewardQuorum);
    }

    function openCapsuleToken(
        address token,
        uint256 bounty,
        bytes32 contentHash,
        uint64 finalEarliestAt,
        uint64 finalLatestAt,
        uint64 challengeLatestAt,
        uint32 stewardQuorum
    ) external whenNotPaused nonReentrant returns (bytes32 capsuleId) {
        if (token == address(0)) revert Futurino__BadInput();
        _pullToken(token, msg.sender, bounty);
        capsuleId = _openCapsule(msg.sender, token, bounty, contentHash, finalEarliestAt, finalLatestAt, challengeLatestAt, stewardQuorum);
    }

    function _openCapsule(
        address owner,
        address asset,
        uint256 bounty,
        bytes32 contentHash,
        uint64 finalEarliestAt,
        uint64 finalLatestAt,
        uint64 challengeLatestAt,
        uint32 stewardQuorum
    ) internal returns (bytes32 capsuleId) {
        if (!isAssetAllowed[asset]) revert Futurino__UnsupportedAsset();
        if (contentHash == bytes32(0)) revert Futurino__BadInput();
        if (bounty == 0) revert Futurino__BadInput();
        if (stewardQuorum < MIN_STEWARD_QUORUM || stewardQuorum > MAX_STEWARD_QUORUM) revert Futurino__BadInput();
        if (_stewards.length() == 0) revert Futurino__BadInput();

        uint256 minB = uint256(assetConfig[asset].minBounty);
        if (minB != 0 && bounty < minB) revert Futurino__BadInput();

        uint64 now64 = uint64(block.timestamp);
        if (!(finalEarliestAt > now64)) revert Futurino__BadInput();
        if (!(finalLatestAt > finalEarliestAt)) revert Futurino__BadInput();
        if (!(challengeLatestAt > finalEarliestAt && challengeLatestAt <= finalLatestAt)) revert Futurino__BadInput();

        capsuleId = computeCapsuleId(owner, asset, bounty, contentHash, now64, finalEarliestAt, finalLatestAt, challengeLatestAt, stewardQuorum);
        Capsule storage c = capsules[capsuleId];
        if (c.state != CapsuleState.None) revert Futurino__CapsuleState();

        c.state = CapsuleState.Open;
        c.owner = owner;
        c.asset = asset;
        c.bounty = bounty;
        c.contentHash = contentHash;
        c.openAt = now64;
        c.finalEarliestAt = finalEarliestAt;
        c.finalLatestAt = finalLatestAt;
        c.challengeLatestAt = challengeLatestAt;
        c.stewardQuorum = stewardQuorum;

        emit FuturinoCapsuleOpened(
            capsuleId,
            owner,
            asset,
            bounty,
            contentHash,
            now64,
            finalEarliestAt,
            finalLatestAt,
            challengeLatestAt,
            stewardQuorum
        );
    }

    // =========
    // Owner cancel (only before finalEarliestAt and only if never proposed)
    // =========
    function cancelCapsule(bytes32 capsuleId, bytes32 reasonHash) external whenNotPaused nonReentrant {
        Capsule storage c = capsules[capsuleId];
        if (c.state != CapsuleState.Open) revert Futurino__CapsuleState();
        if (msg.sender != c.owner) revert Futurino__NotCapsuleOwner();
        if (uint64(block.timestamp) >= c.finalEarliestAt) revert Futurino__CannotCancel();
        if (c.proposedBeneficiary != address(0) || c.approvals != 0) revert Futurino__CannotCancel();

        c.state = CapsuleState.Paid;
        _credit(c.owner, c.asset, c.bounty);
        emit FuturinoCapsuleCancelled(capsuleId, c.owner, reasonHash);
    }

    // =========
    // Open capsule (signature-based)
    // =========
    function capsuleOpenDigest(
        address owner,
        address asset,
        uint256 bounty,
        bytes32 contentHash,
        uint64 finalEarliestAt,
        uint64 finalLatestAt,
        uint64 challengeLatestAt,
        uint32 stewardQuorum,
        uint256 ownerNonce
    ) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                CAPSULE_OPEN_TYPEHASH,
                owner,
                asset,
                bounty,
                contentHash,
                finalEarliestAt,
                finalLatestAt,
                challengeLatestAt,
                stewardQuorum,
                ownerNonce,
                block.chainid,
                address(this)
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SALT, structHash));
    }

    function openCapsuleWithSigETH(
        address owner,
        bytes32 contentHash,
        uint64 finalEarliestAt,
        uint64 finalLatestAt,
        uint64 challengeLatestAt,
        uint32 stewardQuorum,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external payable whenNotPaused nonReentrant returns (bytes32 capsuleId) {
        uint256 nonce = ownerNonces[owner];
        bytes32 digest = capsuleOpenDigest(owner, address(0), msg.value, contentHash, finalEarliestAt, finalLatestAt, challengeLatestAt, stewardQuorum, nonce);
        if (usedDigests[digest]) revert Futurino__AlreadyUsed();
        address signer = FuturinoECDSA.recover(digest, v, r, s);
        if (signer != owner) revert Futurino__BadSig();
        usedDigests[digest] = true;
        ownerNonces[owner] = nonce + 1;
        capsuleId = _openCapsule(owner, address(0), msg.value, contentHash, finalEarliestAt, finalLatestAt, challengeLatestAt, stewardQuorum);
    }

    function openCapsuleWithSigToken(
        address owner,
        address token,
        uint256 bounty,
        bytes32 contentHash,
        uint64 finalEarliestAt,
        uint64 finalLatestAt,
        uint64 challengeLatestAt,
        uint32 stewardQuorum,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external whenNotPaused nonReentrant returns (bytes32 capsuleId) {
        if (token == address(0)) revert Futurino__BadInput();
        uint256 nonce = ownerNonces[owner];
        bytes32 digest = capsuleOpenDigest(owner, token, bounty, contentHash, finalEarliestAt, finalLatestAt, challengeLatestAt, stewardQuorum, nonce);
        if (usedDigests[digest]) revert Futurino__AlreadyUsed();
        address signer = FuturinoECDSA.recover(digest, v, r, s);
        if (signer != owner) revert Futurino__BadSig();
        usedDigests[digest] = true;
        ownerNonces[owner] = nonce + 1;
        _pullToken(token, msg.sender, bounty);
        capsuleId = _openCapsule(owner, token, bounty, contentHash, finalEarliestAt, finalLatestAt, challengeLatestAt, stewardQuorum);
    }

    // =========
    // Top up bounty
    // =========
    function topUpETH(bytes32 capsuleId) external payable whenNotPaused nonReentrant {
        Capsule storage c = capsules[capsuleId];
        if (c.state == CapsuleState.None) revert Futurino__CapsuleMissing();
        if (c.asset != address(0)) revert Futurino__BadInput();
        if (c.state != CapsuleState.Open) revert Futurino__CapsuleState();
        if (msg.value == 0) revert Futurino__BadInput();
        c.bounty += msg.value;
        emit FuturinoCapsuleTopped(capsuleId, msg.sender, msg.value);
    }

    function topUpToken(bytes32 capsuleId, uint256 amount) external whenNotPaused nonReentrant {
        Capsule storage c = capsules[capsuleId];
        if (c.state == CapsuleState.None) revert Futurino__CapsuleMissing();
        if (c.asset == address(0)) revert Futurino__BadInput();
        if (c.state != CapsuleState.Open) revert Futurino__CapsuleState();
        if (amount == 0) revert Futurino__BadInput();
        _pullToken(c.asset, msg.sender, amount);
        c.bounty += amount;
        emit FuturinoCapsuleTopped(capsuleId, msg.sender, amount);
    }

    // =========
    // Steward: propose/finalize (quorum)
    // =========
    function stewardApproveFinalize(
        bytes32 capsuleId,
        address beneficiary,
        uint256 payout,
        bytes32 stewardNoteHash
    ) external whenNotPaused onlySteward nonReentrant {
        Capsule storage c = capsules[capsuleId];
        if (c.state != CapsuleState.Open) revert Futurino__CapsuleState();

        uint64 now64 = uint64(block.timestamp);
        if (now64 < c.finalEarliestAt) revert Futurino__TooEarly();
        if (now64 > c.finalLatestAt) revert Futurino__TooLate();

        if (beneficiary == address(0)) revert Futurino__BadInput();
        if (payout == 0 || payout > c.bounty) revert Futurino__BadInput();

        bytes32 pHash = keccak256(abi.encodePacked("FIN", capsuleId, beneficiary, payout, stewardNoteHash, DOMAIN_SALT));

        FinalizeProposal storage fp = finalizeProposal[capsuleId];
        if (fp.proposalHash == bytes32(0) || fp.proposalHash != pHash) {
            // new proposal: reset vote counter
            fp.beneficiary = beneficiary;
            fp.payout = payout;
            fp.proposalHash = pHash;
            c.approvals = 0;
        }

        if (stewardVotedProposal[capsuleId][msg.sender] == pHash) revert Futurino__AlreadyVoted();
        stewardVotedProposal[capsuleId][msg.sender] = pHash;

        c.approvals += 1;
        c.proposedBeneficiary = beneficiary;
        c.proposedPayout = payout;

        emit FuturinoFinalizeVote(capsuleId, msg.sender, pHash, c.approvals);

        if (c.approvals >= c.stewardQuorum) {
            emit FuturinoCapsuleFinalized(capsuleId, msg.sender, beneficiary, payout);
        }
    }

    // =========
    // Challenge flow
    // =========
    function challenge(bytes32 capsuleId, bytes32 challengeHash) external whenNotPaused nonReentrant {
        Capsule storage c = capsules[capsuleId];
        if (c.state != CapsuleState.Open) revert Futurino__CapsuleState();
        if (c.proposedBeneficiary == address(0) || c.approvals < c.stewardQuorum) revert Futurino__CapsuleState();
        if (challengeHash == bytes32(0)) revert Futurino__BadInput();

        uint64 now64 = uint64(block.timestamp);
        if (now64 > c.challengeLatestAt) revert Futurino__TooLate();
        if (c.challenger != address(0)) revert Futurino__ChallengeExists();

        c.state = CapsuleState.Challenged;
        c.challenger = msg.sender;
        c.challengeHash = challengeHash;
        emit FuturinoCapsuleChallenged(capsuleId, msg.sender, challengeHash);
    }

    function challengeWithBond(bytes32 capsuleId, bytes32 challengeHash) external payable whenNotPaused nonReentrant {
        Capsule storage c = capsules[capsuleId];
        if (c.state != CapsuleState.Open) revert Futurino__CapsuleState();
        if (c.proposedBeneficiary == address(0) || c.approvals < c.stewardQuorum) revert Futurino__CapsuleState();
        if (challengeHash == bytes32(0)) revert Futurino__BadInput();
        if (msg.value < minChallengeBondWei || msg.value > maxChallengeBondWei) revert Futurino__BondRequired();

        uint64 now64 = uint64(block.timestamp);
        if (now64 > c.challengeLatestAt) revert Futurino__TooLate();
        if (c.challenger != address(0)) revert Futurino__ChallengeExists();

        c.state = CapsuleState.Challenged;
        c.challenger = msg.sender;
        c.challengeHash = challengeHash;
        c.challengeBondWei = uint96(msg.value);

        emit FuturinoChallengeBondPosted(capsuleId, msg.sender, msg.value);
        emit FuturinoCapsuleChallenged(capsuleId, msg.sender, challengeHash);
    }

    function resolveChallenge(bytes32 capsuleId, bool payoutAllowed, bytes32 resolutionHash) external onlyGuardian nonReentrant {
        Capsule storage c = capsules[capsuleId];
        if (c.state != CapsuleState.Challenged) revert Futurino__CapsuleState();
        if (resolutionHash == bytes32(0)) revert Futurino__BadInput();

        c.state = CapsuleState.Resolved;
        c.payoutAllowed = payoutAllowed;
        c.resolutionHash = resolutionHash;
        emit FuturinoCapsuleResolved(capsuleId, payoutAllowed, resolutionHash);

        // settle bond (ETH only)
        if (c.challengeBondWei != 0 && c.challenger != address(0)) {
            uint256 bond = uint256(c.challengeBondWei);
            c.challengeBondWei = 0;
            if (!payoutAllowed) {
                // challenger wins: return bond
                _credit(c.challenger, address(0), bond);
                emit FuturinoChallengeBondSettled(capsuleId, c.challenger, true, bond, 0);
            } else {
                // challenger loses: slash portion to feeSink, return remainder
                uint256 slashed = (bond * bondSlashBps) / 10_000;
                uint256 back = bond - slashed;
                if (slashed != 0) _credit(feeSink, address(0), slashed);
                if (back != 0) _credit(c.challenger, address(0), back);
                emit FuturinoChallengeBondSettled(capsuleId, c.challenger, false, back, slashed);
            }
        }
    }

    // =========
    // Execute payout (pull-based credits)
    // =========
    function executePayout(bytes32 capsuleId) external whenNotPaused nonReentrant {
        Capsule storage c = capsules[capsuleId];
        if (c.state == CapsuleState.None) revert Futurino__CapsuleMissing();
        if (c.state == CapsuleState.Paid) revert Futurino__CapsuleState();

        // if never challenged, allow after challenge window
        uint64 now64 = uint64(block.timestamp);
        if (c.state == CapsuleState.Open) {
            if (c.proposedBeneficiary == address(0) || c.approvals < c.stewardQuorum) revert Futurino__CapsuleState();
            if (now64 <= c.challengeLatestAt) revert Futurino__TooEarly();
            c.state = CapsuleState.Resolved;
            c.payoutAllowed = true;
            c.resolutionHash = keccak256(abi.encodePacked("AUTO_OK", capsuleId, now64, DOMAIN_SALT));
            emit FuturinoCapsuleResolved(capsuleId, true, c.resolutionHash);
        } else if (c.state == CapsuleState.Challenged) {
            revert Futurino__CapsuleState();
        } else if (c.state != CapsuleState.Resolved) {
            revert Futurino__CapsuleState();
        }

        if (!c.payoutAllowed) {
            // return entire bounty to owner
            _credit(c.owner, c.asset, c.bounty);
            c.state = CapsuleState.Paid;
            return;
        }

        uint16 feeBps = protocolFeeBps;
