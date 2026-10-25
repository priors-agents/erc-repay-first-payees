// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

/// @title Agent Repay-First Payees (draft ERC)
/// @notice An address an agent uses to receive its revenue (an x402 `payTo`, an ERC-8183 provider) that pays what its
///         registered creditors are owed before forwarding the rest to the agent. It validates no signature, so it
///         cannot be set as an ERC-8004 `agentWallet`.
/// @dev The ERC-165 identifier is `type(IRepayFirstPayee).interfaceId`.
interface IRepayFirstPayee {
    event CreditorAdded(address indexed creditor, uint16 maxShareBps);
    event CreditorRemoved(address indexed creditor);
    event BeneficiarySet(address indexed beneficiary);
    event Swept(address indexed token, uint256 toCreditors, uint256 forwarded);
    /// @notice A sweep changed what the payee holds for `creditor` in `token`; `amount` is the new figure.
    event Reserved(address indexed creditor, address indexed token, uint256 amount);

    /// @notice The ERC-721 identity registry `agentId()` belongs to.
    function identityRegistry() external view returns (address);

    /// @notice The agent whose revenue this payee receives. Never changes.
    function agentId() external view returns (uint256);

    /// @notice Where what is left after the creditors goes: the address the owner set, while that owner still holds
    ///         the agent, else the agent's owner; the zero address when neither can be named (a burned identity with
    ///         no beneficiary set), in which case `sweep` keeps what is left.
    function beneficiary() external view returns (address);

    /// @notice The creditors, most senior first.
    function creditors() external view returns (address[] memory);

    /// @notice The most of one sweep's balance `creditor` may take, in basis points; 0 if it is not a creditor.
    function maxShareBps(address creditor) external view returns (uint16);

    /// @notice What this payee holds for `creditor` in `token`: offered to it by sweeps, within its share and what it was
    ///         owed, and not yet taken. As the last sweep of `token` left it; 0 if it is not a creditor.
    function reserved(address creditor, address token) external view returns (uint256);

    /// @notice Adds a creditor, junior to every existing one. The agent's owner only.
    function addCreditor(address creditor, uint16 maxShareBps) external;

    /// @notice Removes a creditor. The creditor itself at any time; the agent's owner only when the creditor has no
    ///         claim on the agent.
    function removeCreditor(address creditor) external;

    /// @notice Sets where what is left goes, for as long as the caller owns the agent. The agent's owner only. The
    ///         zero address means the agent's owner.
    function setBeneficiary(address beneficiary) external;

    /// @notice Pays the creditors from this payee's balance of `token`, most senior first, keeps for each what it is
    ///         offered and does not take (up to what it is owed), then forwards the rest to the beneficiary (or keeps it
    ///         while the beneficiary is the zero address). Anyone may call it.
    function sweep(address token) external returns (uint256 toCreditors, uint256 forwarded);
}

/// @notice What a payee asks of a creditor.
interface IRepayFirstCreditor {
    /// @notice What `agentId` owes this creditor in `token` and may be paid now.
    function amountOwed(uint256 agentId, address token) external view returns (uint256);

    /// @notice Whether this creditor has any claim on `agentId` (an open loan, whatever its due date).
    function hasClaim(uint256 agentId) external view returns (bool);

    /// @notice Takes at most `amount` of `token` from the calling payee (it has approved that much) and applies it to
    ///         what `agentId` owes. Returns the amount taken. What it leaves stays in the payee's reserve for it.
    function collect(uint256 agentId, address token, uint256 amount) external returns (uint256 applied);
}
