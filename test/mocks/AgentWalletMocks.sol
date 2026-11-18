// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

/// @notice An ERC-8004 identity registry reduced to what the tests need, with `setAgentWallet` checked the way ERC-8004's
///         reference registry checks it: the owner calls (the reference also accepts an operator the owner approved,
///         which these tests do not need), the deadline is at most 5 minutes ahead, and the new wallet signs
///         AgentWalletSet(agentId, newWallet, owner, deadline) under the domain ("ERC8004IdentityRegistry", "1",
///         chainId, this): ECDSA first, then ERC-1271. A transfer clears the wallet, as in the reference.
contract MockIdentityRegistry {
    bytes32 private constant AGENT_WALLET_SET_TYPEHASH =
        keccak256("AgentWalletSet(uint256 agentId,address newWallet,address owner,uint256 deadline)");
    uint256 private constant MAX_DEADLINE_DELAY = 300;

    mapping(uint256 => address) private _owners;
    mapping(uint256 => address) private _wallets;

    function mint(address to, uint256 id) external {
        _owners[id] = to;
        _wallets[id] = to;
    }

    function transfer(uint256 id, address to) external {
        require(ownerOf(id) == msg.sender, "not owner");
        delete _wallets[id];
        _owners[id] = to;
    }

    function ownerOf(uint256 id) public view returns (address o) {
        o = _owners[id];
        require(o != address(0), "no token");
    }

    function getAgentWallet(uint256 agentId) external view returns (address) {
        return _wallets[agentId];
    }

    function domainSeparator() public view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("ERC8004IdentityRegistry"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }

    function agentWalletDigest(uint256 agentId, address newWallet, address owner, uint256 deadline)
        public
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                domainSeparator(),
                keccak256(abi.encode(AGENT_WALLET_SET_TYPEHASH, agentId, newWallet, owner, deadline))
            )
        );
    }

    function setAgentWallet(uint256 agentId, address newWallet, uint256 deadline, bytes calldata signature) external {
        address owner = ownerOf(agentId);
        require(msg.sender == owner, "Not authorized");
        require(newWallet != address(0), "bad wallet");
        require(block.timestamp <= deadline, "expired");
        require(deadline <= block.timestamp + MAX_DEADLINE_DELAY, "deadline too far");
        bytes32 digest = agentWalletDigest(agentId, newWallet, owner, deadline);
        bool ok;
        if (signature.length == 65) {
            bytes32 r = bytes32(signature[0:32]);
            bytes32 s = bytes32(signature[32:64]);
            uint8 v = uint8(signature[64]);
            ok = ecrecover(digest, v, r, s) == newWallet;
        }
        if (!ok) {
            (bool success, bytes memory res) =
                newWallet.staticcall(abi.encodeWithSignature("isValidSignature(bytes32,bytes)", digest, signature));
            ok = success && res.length >= 32 && abi.decode(res, (bytes4)) == bytes4(0x1626ba7e);
        }
        require(ok, "invalid wallet sig");
        _wallets[agentId] = newWallet;
    }
}
