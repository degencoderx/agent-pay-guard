// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * AgentPayGuard
 *
 * A policy-enforced USDC vault for agents.
 *
 * Core model:
 * - Owners deposit USDC into the vault.
 * - Anyone can submit a signed EIP-712 PaymentIntent created by an owner.
 * - The contract enforces owner policy (allowlist + caps + timelock + expiry + nonce).
 * - Recipient claims the intent, then anyone can finalize after timelock.
 *
 * This is designed for testnet demos and hackathon MVPs.
 */
contract AgentPayGuard is EIP712, ReentrancyGuard {
  using SafeERC20 for IERC20;

  error InvalidAddress();
  error InvalidAmount();
  error PolicyNotSet();
  error RecipientNotAllowed();
  error ExceedsMaxPerIntent();
  error InsufficientAvailableBalance();
  error IntentAlreadyExists();
  error IntentNotFound();
  error IntentExpired();
  error NonceAlreadyUsed();
  error NotRecipient();
  error NotOwner();
  error AlreadyClaimed();
  error NotClaimed();
  error AlreadyFinalized();
  error AlreadyCanceled();
  error TimelockNotElapsed();
  error DisputeWindowClosed();
  error IntentIsDisputed();
  error NotDisputed();
  error BadSignature();

  struct Policy {
    // Maximum USDC amount allowed per intent (in token base units).
    uint256 maxPerIntent;
    // Minimum delay between intent creation and finalization.
    uint48 timelockSeconds;
    // Window during which the owner can dispute after intent creation.
    uint48 disputeWindowSeconds;
  }

  struct PaymentIntent {
    address owner;
    address recipient;
    uint256 amount;
    bytes32 jobId;
    uint256 nonce;
    uint48 expiry;
  }

  struct IntentState {
    address owner;
    address recipient;
    uint256 amount;
    bytes32 jobId;
    uint256 nonce;
    uint48 createdAt;
    uint48 expiry;
    uint48 timelockEndsAt;
    uint48 disputeEndsAt;
    bool claimed;
    bool finalized;
    bool canceled;
    bool disputed;
    bytes32 evidenceHash;
  }

  bytes32 public constant PAYMENT_INTENT_TYPEHASH =
    keccak256(
      "PaymentIntent(address owner,address recipient,uint256 amount,bytes32 jobId,uint256 nonce,uint48 expiry)"
    );

  IERC20 public immutable usdc;

  // Deposited USDC (total) per owner.
  mapping(address owner => uint256) public deposited;
  // Locked USDC per owner (sum of created-but-not-finalized/canceled intents).
  mapping(address owner => uint256) public locked;

  // Policy and allowlists are per owner.
  mapping(address owner => Policy) public policies;
  mapping(address owner => mapping(address recipient => bool)) public allowedRecipient;

  mapping(address owner => mapping(uint256 nonce => bool)) public usedNonce;

  mapping(bytes32 intentHash => IntentState) private _intents;

  event Deposited(address indexed owner, uint256 amount);
  event Withdrawn(address indexed owner, uint256 amount);

  event PolicyUpdated(address indexed owner, uint256 maxPerIntent, uint48 timelockSeconds, uint48 disputeWindowSeconds);
  event RecipientAllowed(address indexed owner, address indexed recipient, bool allowed);

  event IntentCreated(
    bytes32 indexed intentHash,
    address indexed owner,
    address indexed recipient,
    uint256 amount,
    bytes32 jobId,
    uint256 nonce,
    uint48 expiry,
    uint48 timelockEndsAt,
    uint48 disputeEndsAt
  );

  event IntentCanceled(bytes32 indexed intentHash, address indexed owner);
  event IntentClaimed(bytes32 indexed intentHash, address indexed recipient, bytes32 evidenceHash);
  event IntentDisputed(bytes32 indexed intentHash, address indexed owner);
  event IntentResolved(bytes32 indexed intentHash, address indexed owner, bool paidOut);
  event IntentFinalized(bytes32 indexed intentHash, address indexed owner, address indexed recipient, uint256 amount);

  constructor(address usdcToken) EIP712("AgentPayGuard", "1") {
    if (usdcToken == address(0)) revert InvalidAddress();
    usdc = IERC20(usdcToken);
  }

  function availableBalance(address owner) public view returns (uint256) {
    return deposited[owner] - locked[owner];
  }

  function getIntent(bytes32 intentHash) external view returns (IntentState memory) {
    IntentState memory st = _intents[intentHash];
    if (st.owner == address(0)) revert IntentNotFound();
    return st;
  }

  function setPolicy(uint256 maxPerIntent, uint48 timelockSeconds, uint48 disputeWindowSeconds) external {
    if (maxPerIntent == 0) revert InvalidAmount();
    policies[msg.sender] = Policy({
      maxPerIntent: maxPerIntent,
      timelockSeconds: timelockSeconds,
      disputeWindowSeconds: disputeWindowSeconds
    });
    emit PolicyUpdated(msg.sender, maxPerIntent, timelockSeconds, disputeWindowSeconds);
  }

  function setRecipientAllowed(address recipient, bool allowed) external {
    if (recipient == address(0)) revert InvalidAddress();
    allowedRecipient[msg.sender][recipient] = allowed;
    emit RecipientAllowed(msg.sender, recipient, allowed);
  }

  function deposit(uint256 amount) external nonReentrant {
    if (amount == 0) revert InvalidAmount();
    deposited[msg.sender] += amount;
    usdc.safeTransferFrom(msg.sender, address(this), amount);
    emit Deposited(msg.sender, amount);
  }

  function withdraw(uint256 amount) external nonReentrant {
    if (amount == 0) revert InvalidAmount();
    uint256 avail = availableBalance(msg.sender);
    if (amount > avail) revert InsufficientAvailableBalance();

    deposited[msg.sender] -= amount;
    usdc.safeTransfer(msg.sender, amount);
    emit Withdrawn(msg.sender, amount);
  }

  function hashIntent(PaymentIntent calldata intent) public view returns (bytes32) {
    return _hashTypedDataV4(
      keccak256(
        abi.encode(
          PAYMENT_INTENT_TYPEHASH,
          intent.owner,
          intent.recipient,
          intent.amount,
          intent.jobId,
          intent.nonce,
          intent.expiry
        )
      )
    );
  }

  function createIntent(PaymentIntent calldata intent, bytes calldata signature) external nonReentrant returns (bytes32) {
    _validateAndConsumeIntent(intent, signature);

    bytes32 intentHash = hashIntent(intent);
    if (_intents[intentHash].owner != address(0)) revert IntentAlreadyExists();

    Policy memory pol = policies[intent.owner];
    if (pol.maxPerIntent == 0) revert PolicyNotSet();

    if (!allowedRecipient[intent.owner][intent.recipient]) revert RecipientNotAllowed();
    if (intent.amount == 0) revert InvalidAmount();
    if (intent.amount > pol.maxPerIntent) revert ExceedsMaxPerIntent();

    uint256 avail = availableBalance(intent.owner);
    if (intent.amount > avail) revert InsufficientAvailableBalance();

    uint48 nowTs = uint48(block.timestamp);
    uint48 timelockEndsAt = nowTs + pol.timelockSeconds;
    uint48 disputeEndsAt = nowTs + pol.disputeWindowSeconds;

    locked[intent.owner] += intent.amount;

    _intents[intentHash] = IntentState({
      owner: intent.owner,
      recipient: intent.recipient,
      amount: intent.amount,
      jobId: intent.jobId,
      nonce: intent.nonce,
      createdAt: nowTs,
      expiry: intent.expiry,
      timelockEndsAt: timelockEndsAt,
      disputeEndsAt: disputeEndsAt,
      claimed: false,
      finalized: false,
      canceled: false,
      disputed: false,
      evidenceHash: bytes32(0)
    });

    emit IntentCreated(
      intentHash,
      intent.owner,
      intent.recipient,
      intent.amount,
      intent.jobId,
      intent.nonce,
      intent.expiry,
      timelockEndsAt,
      disputeEndsAt
    );

    return intentHash;
  }

  function cancelIntent(bytes32 intentHash) external nonReentrant {
    IntentState storage st = _intents[intentHash];
    if (st.owner == address(0)) revert IntentNotFound();
    if (msg.sender != st.owner) revert NotOwner();
    if (st.canceled) revert AlreadyCanceled();
    if (st.finalized) revert AlreadyFinalized();
    if (st.claimed) revert AlreadyClaimed();

    st.canceled = true;
    locked[st.owner] -= st.amount;

    emit IntentCanceled(intentHash, st.owner);
  }

  function claimIntent(bytes32 intentHash, bytes32 evidenceHash) external nonReentrant {
    IntentState storage st = _intents[intentHash];
    if (st.owner == address(0)) revert IntentNotFound();
    if (st.canceled) revert AlreadyCanceled();
    if (st.finalized) revert AlreadyFinalized();
    if (st.claimed) revert AlreadyClaimed();
    if (block.timestamp > st.expiry) revert IntentExpired();

    if (msg.sender != st.recipient) revert NotRecipient();

    st.claimed = true;
    st.evidenceHash = evidenceHash;

    emit IntentClaimed(intentHash, msg.sender, evidenceHash);
  }

  function disputeIntent(bytes32 intentHash) external nonReentrant {
    IntentState storage st = _intents[intentHash];
    if (st.owner == address(0)) revert IntentNotFound();
    if (msg.sender != st.owner) revert NotOwner();
    if (!st.claimed) revert NotClaimed();
    if (st.canceled) revert AlreadyCanceled();
    if (st.finalized) revert AlreadyFinalized();
    if (st.disputed) revert IntentIsDisputed();

    if (block.timestamp > st.disputeEndsAt) revert DisputeWindowClosed();

    st.disputed = true;
    emit IntentDisputed(intentHash, msg.sender);
  }

  function resolveDispute(bytes32 intentHash, bool payOut) external nonReentrant {
    IntentState storage st = _intents[intentHash];
    if (st.owner == address(0)) revert IntentNotFound();
    if (msg.sender != st.owner) revert NotOwner();
    if (!st.disputed) revert NotDisputed();
    if (st.canceled) revert AlreadyCanceled();
    if (st.finalized) revert AlreadyFinalized();

    if (payOut) {
      _payout(intentHash, st);
      emit IntentResolved(intentHash, msg.sender, true);
      return;
    }

    st.canceled = true;
    locked[st.owner] -= st.amount;
    emit IntentResolved(intentHash, msg.sender, false);
  }

  function finalizeIntent(bytes32 intentHash) external nonReentrant {
    IntentState storage st = _intents[intentHash];
    if (st.owner == address(0)) revert IntentNotFound();
    if (!st.claimed) revert NotClaimed();
    if (st.canceled) revert AlreadyCanceled();
    if (st.finalized) revert AlreadyFinalized();
    if (st.disputed) revert IntentIsDisputed();
    if (block.timestamp < st.timelockEndsAt) revert TimelockNotElapsed();

    _payout(intentHash, st);
  }

  function _payout(bytes32 intentHash, IntentState storage st) internal {
    // State updates first.
    st.finalized = true;
    locked[st.owner] -= st.amount;
    deposited[st.owner] -= st.amount;

    usdc.safeTransfer(st.recipient, st.amount);

    emit IntentFinalized(intentHash, st.owner, st.recipient, st.amount);
  }

  function _validateAndConsumeIntent(PaymentIntent calldata intent, bytes calldata signature) internal {
    if (intent.owner == address(0) || intent.recipient == address(0)) revert InvalidAddress();
    if (intent.expiry == 0) revert IntentExpired();
    if (block.timestamp > intent.expiry) revert IntentExpired();

    if (usedNonce[intent.owner][intent.nonce]) revert NonceAlreadyUsed();

    bytes32 digest = hashIntent(intent);
    address signer = ECDSA.recover(digest, signature);
    if (signer != intent.owner) revert BadSignature();

    usedNonce[intent.owner][intent.nonce] = true;
  }
}
