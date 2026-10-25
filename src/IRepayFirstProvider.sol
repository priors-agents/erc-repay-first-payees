// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

/// @title Agent Repay-First Payees: acting as an ERC-8183 provider (optional part)
/// @notice ERC-8183 accepts a budget proposal and the submission of the work only from a job's provider, and pays the
///         provider on completion. A payee that is a job's provider makes those two calls itself, for the agent's owner
///         or an operator the owner named, so the job pays the payee and sweeps pay that out like any other revenue.
///         It makes no other call for them.
/// @dev The ERC-165 identifier is `type(IRepayFirstProvider).interfaceId`.
interface IRepayFirstProvider {
    event OperatorSet(address indexed operator);

    /// @notice The address the owner named to act for the agent in its jobs, while that owner still holds the agent;
    ///         the zero address otherwise, or when the registry cannot name an owner.
    function operator() external view returns (address);

    /// @notice Names the operator, for as long as the caller owns the agent. The agent's owner only. The zero address
    ///         names none.
    function setOperator(address operator) external;

    /// @notice Calls `setBudget(jobId, amount, optParams)` on the ERC-8183 contract `commerce`, as the job's provider.
    ///         The owner or the operator only; reverts when that call reverts.
    function setJobBudget(address commerce, uint256 jobId, uint256 amount, bytes calldata optParams) external;

    /// @notice Calls `submit(jobId, deliverable, optParams)` on the ERC-8183 contract `commerce`, as the job's provider.
    ///         The owner or the operator only; reverts when that call reverts.
    function submitJob(address commerce, uint256 jobId, bytes32 deliverable, bytes calldata optParams) external;
}
