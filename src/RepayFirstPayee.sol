// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {IRepayFirstPayee, IRepayFirstCreditor} from "./IRepayFirstPayee.sol";
import {IRepayFirstProvider} from "./IRepayFirstProvider.sol";

/// @dev The two ERC-8183 functions that accept only a job's provider, in the form of ERC-8183's reference.
interface IERC8183Provider {
    function setBudget(uint256 jobId, uint256 amount, bytes calldata optParams) external;
    function submit(uint256 jobId, bytes32 deliverable, bytes calldata optParams) external;
}

interface IERC20Approve {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IERC721OwnerOf {
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface IERC165 {
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

/// @title RepayFirstPayee
/// @notice Reference implementation of the Agent Repay-First Payees draft. One payee per agent, deployed at a CREATE2
///         address by `RepayFirstPayeeFactory`. Each creditor is called with a fixed gas budget, so one that fails or
///         burns gas is skipped and the rest of the sweep goes on. What a creditor is offered and does not take stays
///         here in its reserve, up to what it is owed, and is offered again at each sweep: a lender that takes only
///         full repayment is repaid once its reserve covers what is due. As an ERC-8183 job's provider it proposes
///         the budget and submits the work for the owner or its operator, and makes no other call for them.
/// @dev Not audited. A reference for the interface, not a contract to hold real revenue.
contract RepayFirstPayee is IRepayFirstPayee, IRepayFirstProvider, IERC165 {
    uint256 public constant MAX_CREDITORS = 8;
    uint16 public constant BPS = 10_000;
    /// @notice Gas given to a creditor's `amountOwed` and `hasClaim`, and to its `collect`.
    uint256 public constant VIEW_GAS = 50_000;
    uint256 public constant COLLECT_GAS = 300_000;

    IERC721OwnerOf private immutable _registry;
    uint256 private immutable _agentId;

    address private _beneficiary;
    address private _beneficiarySetBy; // the owner who chose `_beneficiary`; the choice holds only while it owns
    address[] private _creditors;
    mapping(address => uint16) private _share;
    /// @dev Reserves are kept under the place a creditor was given when added (never reused), so removing it ends all
    ///      its reserves at once, whatever the tokens, and a creditor added again starts with none.
    mapping(address => uint256) private _place;
    uint256 private _places;
    mapping(uint256 => mapping(address => uint256)) private _reserve; // place => token => amount
    address private _operator;
    address private _operatorSetBy; // as for the beneficiary: the operator acts only while this owner owns
    bool private _locked;

    error NotOwner();
    error NotOperator();
    error BadCreditor();
    error BadShare();
    error TooManyCreditors();
    error CreditorHasClaim();
    error Reentrant();
    error TransferFailed();

    modifier lock() {
        if (_locked) revert Reentrant();
        _locked = true;
        _;
        _locked = false;
    }

    modifier onlyOwner() {
        if (_registry.ownerOf(_agentId) != msg.sender) revert NotOwner();
        _;
    }

    constructor(address registry_, uint256 agentId_) {
        _registry = IERC721OwnerOf(registry_);
        _agentId = agentId_;
    }

    // ---------------------------------------------------------------- views

    function identityRegistry() external view returns (address) {
        return address(_registry);
    }

    function agentId() external view returns (uint256) {
        return _agentId;
    }

    /// @dev A beneficiary set by an owner counts only while that owner holds the identity, so a seller cannot keep the
    ///      revenue earned after a sale. When the registry cannot name an owner (a burned identity), the last choice
    ///      stands, and with none the result is the zero address: `sweep` then still pays the creditors and keeps the
    ///      rest.
    function beneficiary() public view returns (address) {
        try _registry.ownerOf(_agentId) returns (address owner) {
            if (_beneficiary != address(0) && owner == _beneficiarySetBy) return _beneficiary;
            return owner;
        } catch {
            return _beneficiary;
        }
    }

    function creditors() external view returns (address[] memory) {
        return _creditors;
    }

    function maxShareBps(address creditor) external view returns (uint16) {
        return _share[creditor];
    }

    function reserved(address creditor, address token) external view returns (uint256) {
        uint256 place = _place[creditor];
        return place == 0 ? 0 : _reserve[place][token];
    }

    /// @dev Like a beneficiary, an operator counts only while the owner that named it holds the identity; with no owner
    ///      to read, there is none.
    function operator() public view returns (address) {
        try _registry.ownerOf(_agentId) returns (address owner) {
            return owner == _operatorSetBy ? _operator : address(0);
        } catch {
            return address(0);
        }
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IRepayFirstPayee).interfaceId || interfaceId == type(IRepayFirstProvider).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    // ---------------------------------------------------------------- configuration

    function addCreditor(address creditor, uint16 maxShareBps_) external lock onlyOwner {
        if (creditor == address(0) || creditor == address(this) || _share[creditor] != 0) revert BadCreditor();
        if (maxShareBps_ == 0 || maxShareBps_ > BPS) revert BadShare();
        if (_creditors.length >= MAX_CREDITORS) revert TooManyCreditors();
        _creditors.push(creditor);
        _share[creditor] = maxShareBps_;
        _place[creditor] = ++_places;
        emit CreditorAdded(creditor, maxShareBps_);
    }

    function removeCreditor(address creditor) external lock {
        if (_share[creditor] == 0) revert BadCreditor();
        if (msg.sender != creditor) {
            if (_registry.ownerOf(_agentId) != msg.sender) revert NotOwner();
            if (_hasClaim(creditor)) revert CreditorHasClaim();
        }
        uint256 n = _creditors.length;
        for (uint256 i; i < n; ++i) {
            if (_creditors[i] == creditor) {
                for (uint256 j = i; j + 1 < n; ++j) {
                    _creditors[j] = _creditors[j + 1]; // keep seniority order
                }
                _creditors.pop();
                break;
            }
        }
        delete _share[creditor];
        delete _place[creditor]; // its reserves end: the next sweep counts them as balance outside any reserve
        emit CreditorRemoved(creditor);
    }

    function setBeneficiary(address beneficiary_) external lock onlyOwner {
        _beneficiary = beneficiary_;
        _beneficiarySetBy = msg.sender; // onlyOwner: the current owner
        emit BeneficiarySet(beneficiary_);
    }

    // ---------------------------------------------------------------- ERC-8183 provider

    function setOperator(address operator_) external lock onlyOwner {
        _operator = operator_;
        _operatorSetBy = msg.sender; // onlyOwner: the current owner
        emit OperatorSet(operator_);
    }

    /// @dev Only these two calls, to whatever `commerce` the caller names: they move nothing out of the payee (a token
    ///      has neither function, and outside a sweep the payee holds no approval). What the job pays on completion is a
    ///      plain transfer to the payee, swept like any other revenue.
    function setJobBudget(address commerce, uint256 jobId, uint256 amount, bytes calldata optParams) external lock {
        _onlyOwnerOrOperator();
        IERC8183Provider(commerce).setBudget(jobId, amount, optParams);
    }

    function submitJob(address commerce, uint256 jobId, bytes32 deliverable, bytes calldata optParams) external lock {
        _onlyOwnerOrOperator();
        IERC8183Provider(commerce).submit(jobId, deliverable, optParams);
    }

    function _onlyOwnerOrOperator() private view {
        try _registry.ownerOf(_agentId) returns (address owner) {
            if (msg.sender == owner || (msg.sender == _operator && owner == _operatorSetBy)) return;
        } catch {}
        revert NotOperator();
    }

    // ---------------------------------------------------------------- sweep

    function sweep(address token) external lock returns (uint256 toCreditors, uint256 forwarded) {
        IERC20Approve t = IERC20Approve(token);
        if (t.balanceOf(address(this)) == 0) return (0, 0);

        (uint256[] memory owed, uint256[] memory held, uint256 total) = _owedAndHeld(t);
        uint256 remaining = total;
        for (uint256 i; i < owed.length; ++i) {
            address c = _creditors[i];
            uint256 give = owed[i] - held[i];
            uint256 cap = total * _share[c] / BPS;
            if (give > cap) give = cap;
            if (give > remaining) give = remaining;
            remaining -= give;
            toCreditors += _settle(t, c, held[i] + give);
        }

        address to = beneficiary();
        if (to != address(0)) {
            forwarded = remaining;
            if (forwarded > 0 && !t.transfer(to, forwarded)) revert TransferFailed();
        }
        emit Swept(token, toCreditors, forwarded);
    }

    /// @dev What each creditor is owed now; its reserve lowered to that, so a reserve above what is owed is released; and
    ///      B, the balance outside the reserves: what arrived since the last sweep and what was released.
    function _owedAndHeld(IERC20Approve t)
        private
        view
        returns (uint256[] memory owed, uint256[] memory held, uint256 total)
    {
        uint256 n = _creditors.length;
        owed = new uint256[](n);
        held = new uint256[](n);
        uint256 inReserve;
        for (uint256 i; i < n; ++i) {
            address c = _creditors[i];
            owed[i] = _owed(c, address(t));
            uint256 r = _reserve[_place[c]][address(t)];
            held[i] = r < owed[i] ? r : owed[i];
            inReserve += held[i];
        }
        uint256 balance = t.balanceOf(address(this));
        total = balance > inReserve ? balance - inReserve : 0;
    }

    /// @dev Approves exactly `offer`, calls `collect`, resets the approval, and keeps in the creditor's reserve what it
    ///      did not take. What it took is the fall in balance, at most `offer` by the allowance; tokens sent in
    ///      meanwhile stay for the next sweep.
    function _settle(IERC20Approve t, address creditor, uint256 offer) private returns (uint256 taken) {
        if (offer != 0) {
            uint256 before = t.balanceOf(address(this));
            if (!t.approve(creditor, offer)) revert TransferFailed();
            try IRepayFirstCreditor(creditor).collect{gas: COLLECT_GAS}(_agentId, address(t), offer) {} catch {}
            if (!t.approve(creditor, 0)) revert TransferFailed();
            uint256 after_ = t.balanceOf(address(this));
            taken = after_ < before ? before - after_ : 0;
        }
        mapping(address => uint256) storage reserve = _reserve[_place[creditor]];
        if (reserve[address(t)] != offer - taken) {
            reserve[address(t)] = offer - taken;
            emit Reserved(creditor, address(t), offer - taken);
        }
    }

    function _owed(address creditor, address token) private view returns (uint256 owed) {
        try IRepayFirstCreditor(creditor).amountOwed{gas: VIEW_GAS}(_agentId, token) returns (uint256 o) {
            owed = o;
        } catch {}
    }

    /// @dev A creditor whose `hasClaim` fails is treated as having one: the owner cannot drop a lender by making its
    ///      check revert.
    function _hasClaim(address creditor) private view returns (bool) {
        try IRepayFirstCreditor(creditor).hasClaim{gas: VIEW_GAS}(_agentId) returns (bool h) {
            return h;
        } catch {
            return true;
        }
    }
}

/// @title RepayFirstPayeeFactory
/// @notice Deploys one payee per agent at an address known before deployment, so an agent can advertise it as its
///         revenue address first.
contract RepayFirstPayeeFactory {
    address public immutable registry;

    event PayeeDeployed(uint256 indexed agentId, address payee);

    error AlreadyDeployed(address payee);

    constructor(address registry_) {
        registry = registry_;
    }

    function payeeOf(uint256 agentId) public view returns (address) {
        bytes32 initHash =
            keccak256(abi.encodePacked(type(RepayFirstPayee).creationCode, abi.encode(registry, agentId)));
        return
            address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(agentId), initHash))))
            );
    }

    function deploy(uint256 agentId) external returns (address payee) {
        address existing = payeeOf(agentId);
        if (existing.code.length != 0) revert AlreadyDeployed(existing);
        payee = address(new RepayFirstPayee{salt: bytes32(agentId)}(registry, agentId));
        emit PayeeDeployed(agentId, payee);
    }
}
