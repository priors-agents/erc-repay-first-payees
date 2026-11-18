// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {RepayFirstPayee, IERC721OwnerOf} from "./RepayFirstPayee.sol";

/// @title AgentWalletPayee
/// @notice The reference `RepayFirstPayee`, inherited unchanged, that can also be an agent's ERC-8004 `agentWallet`.
///         ERC-8004's `setAgentWallet` takes the new wallet's ERC-1271 approval; the draft's Rationale explains why a
///         payee must not approve its owner's signatures (Permit2 and some tokens accept ERC-1271 signatures for
///         transfers) and names this way out: "a payee that validates only an `agentWallet` digest it computes itself".
///         This payee approves exactly one kind of hash, the identity registry's `AgentWalletSet` digest for itself and
///         the agent's current owner, with the signature being the deadline, ABI-encoded. The registry lets only the
///         owner (or an operator it approved) send that call. ERC-8004 leaves that typed data to each registry: this
///         one computes it as ERC-8004's reference identity registry does (domain "ERC8004IdentityRegistry", "1").
/// @dev Not audited. A reference, not a contract to hold real revenue.
contract AgentWalletPayee is RepayFirstPayee {
    bytes32 public constant AGENT_WALLET_SET_TYPEHASH =
        keccak256("AgentWalletSet(uint256 agentId,address newWallet,address owner,uint256 deadline)");
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant NAME_HASH = keccak256("ERC8004IdentityRegistry");
    bytes32 private constant VERSION_HASH = keccak256("1");
    bytes4 private constant MAGIC = 0x1626ba7e;
    bytes4 private constant INVALID = 0xffffffff;

    address private immutable _reg;
    uint256 private immutable _id;

    constructor(address registry_, uint256 agentId_) RepayFirstPayee(registry_, agentId_) {
        _reg = registry_;
        _id = agentId_;
    }

    /// @notice The registry's EIP-712 digest of AgentWalletSet(agentId, this payee, the agent's owner now, deadline).
    function agentWalletDigest(uint256 deadline) public view returns (bytes32) {
        address owner = IERC721OwnerOf(_reg).ownerOf(_id);
        bytes32 domain = keccak256(abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, _reg));
        bytes32 structHash = keccak256(abi.encode(AGENT_WALLET_SET_TYPEHASH, _id, address(this), owner, deadline));
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    /// @notice ERC-1271: valid only for `hash == agentWalletDigest(deadline)` with `signature == abi.encode(deadline)`.
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        if (signature.length != 32) return INVALID;
        uint256 deadline = abi.decode(signature, (uint256));
        try this.agentWalletDigest(deadline) returns (bytes32 digest) {
            return digest == hash ? MAGIC : INVALID;
        } catch {
            return INVALID; // no owner to name
        }
    }
}

/// @title AgentWalletPayeeFactory
/// @notice The reference `RepayFirstPayeeFactory`'s rule for `AgentWalletPayee`: one payee per agent at a CREATE2
///         address (salt: the agent id) known before it is deployed, so it can be shown, paid or set as the agentWallet
///         first. Anyone deploys.
/// @dev Not audited. A reference, not a contract to hold real revenue.
contract AgentWalletPayeeFactory {
    address public immutable registry;

    event PayeeDeployed(uint256 indexed agentId, address payee);

    error AlreadyDeployed(address payee);

    constructor(address registry_) {
        registry = registry_;
    }

    function payeeOf(uint256 agentId) public view returns (address) {
        bytes32 initHash =
            keccak256(abi.encodePacked(type(AgentWalletPayee).creationCode, abi.encode(registry, agentId)));
        return
            address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(agentId), initHash))))
            );
    }

    function deploy(uint256 agentId) external returns (address payee) {
        address existing = payeeOf(agentId);
        if (existing.code.length != 0) revert AlreadyDeployed(existing);
        payee = address(new AgentWalletPayee{salt: bytes32(agentId)}(registry, agentId));
        emit PayeeDeployed(agentId, payee);
    }
}
