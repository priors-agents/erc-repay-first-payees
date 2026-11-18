// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IRepayFirstPayee} from "../src/IRepayFirstPayee.sol";
import {AgentWalletPayee, AgentWalletPayeeFactory} from "../src/AgentWalletPayee.sol";
import {MockToken, MockCreditor} from "./mocks/Mocks.sol";
import {MockIdentityRegistry} from "./mocks/AgentWalletMocks.sol";

contract AgentWalletPayeeTest is Test {
    bytes4 constant MAGIC = 0x1626ba7e;
    bytes4 constant INVALID = 0xffffffff;
    uint256 constant AGENT = 8835;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    MockIdentityRegistry registry;
    AgentWalletPayeeFactory factory;
    AgentWalletPayee payee;
    uint256 ownerKey = uint256(keccak256("owner"));
    address owner = vm.addr(ownerKey);
    address buyer = makeAddr("buyer");
    address stranger = makeAddr("stranger");
    uint256 deadline;

    function setUp() public {
        registry = new MockIdentityRegistry();
        factory = new AgentWalletPayeeFactory(address(registry));
        registry.mint(owner, AGENT);
        payee = AgentWalletPayee(factory.deploy(AGENT));
        deadline = block.timestamp + 240;
    }

    /// @dev What the registry asks the payee to approve when `owner_` sets it as the agent's wallet.
    function _digest(address owner_, uint256 deadline_) internal view returns (bytes32) {
        return registry.agentWalletDigest(AGENT, address(payee), owner_, deadline_);
    }

    /// @dev A Permit2 `PermitTransferFrom` digest: signed by the payee's ERC-1271, it would let `stranger` move `amount`
    ///      of `token` out of the payee.
    function _permit2Digest(address token, uint256 amount, uint256 deadline_) internal view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)"),
                keccak256("Permit2"),
                block.chainid,
                PERMIT2
            )
        );
        bytes32 permitted =
            keccak256(abi.encode(keccak256("TokenPermissions(address token,uint256 amount)"), token, amount));
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "PermitTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)"
                ),
                permitted,
                stranger,
                0,
                deadline_
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    // ------------------------------------------------------------- factory and the reference payee

    function test_factory_payeeOfIsTheDeployedAddress_andKnownBeforehand() public {
        address predicted = factory.payeeOf(42);
        assertEq(predicted.code.length, 0);
        registry.mint(owner, 42);
        assertEq(factory.deploy(42), predicted);
        assertEq(factory.payeeOf(AGENT), address(payee));
        vm.expectRevert(abi.encodeWithSelector(AgentWalletPayeeFactory.AlreadyDeployed.selector, predicted));
        factory.deploy(42);
    }

    function test_isTheReferencePayee_itsViewsAndSweepAreUnchanged() public {
        assertEq(payee.identityRegistry(), address(registry));
        assertEq(payee.agentId(), AGENT);
        assertEq(payee.beneficiary(), owner);
        assertEq(payee.MAX_CREDITORS(), 8);
        assertTrue(payee.supportsInterface(type(IRepayFirstPayee).interfaceId));

        MockToken usd = new MockToken();
        MockCreditor lender = new MockCreditor();
        lender.setOwed(AGENT, 30e6);
        vm.prank(owner);
        payee.addCreditor(address(lender), 10_000);
        usd.mint(address(payee), 100e6);
        (uint256 toCreditors, uint256 forwarded) = payee.sweep(address(usd));
        assertEq(toCreditors, 30e6);
        assertEq(forwarded, 70e6);
        assertEq(usd.balanceOf(owner), 70e6);
    }

    // ------------------------------------------------------------- isValidSignature

    function test_agentWalletDigest_isTheRegistrysDigest_forThisPayeeItsAgentAndItsOwner() public view {
        assertEq(payee.agentWalletDigest(deadline), _digest(owner, deadline));
    }

    function test_isValidSignature_acceptsTheAgentWalletDigest_withItsDeadlineAsTheSignature() public view {
        assertEq(payee.isValidSignature(_digest(owner, deadline), abi.encode(deadline)), MAGIC);
    }

    function test_isValidSignature_rejectsAPermit2TransferDigest() public {
        MockToken usd = new MockToken();
        bytes32 permit = _permit2Digest(address(usd), 100e6, deadline);
        assertEq(payee.isValidSignature(permit, abi.encode(deadline)), INVALID);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, permit);
        assertEq(payee.isValidSignature(permit, abi.encodePacked(r, s, v)), INVALID);
    }

    function testFuzz_isValidSignature_rejectsAnyOtherHash(bytes32 hash, uint256 deadline_) public view {
        vm.assume(hash != _digest(owner, deadline_));
        assertEq(payee.isValidSignature(hash, abi.encode(deadline_)), INVALID);
    }

    function test_isValidSignature_rejectsTheDigestForAnotherWalletAgentOwnerRegistryOrChain() public {
        bytes memory sig = abi.encode(deadline);
        assertEq(payee.isValidSignature(registry.agentWalletDigest(AGENT, stranger, owner, deadline), sig), INVALID);
        assertEq(payee.isValidSignature(registry.agentWalletDigest(42, address(payee), owner, deadline), sig), INVALID);
        assertEq(payee.isValidSignature(_digest(stranger, deadline), sig), INVALID);

        MockIdentityRegistry otherRegistry = new MockIdentityRegistry();
        otherRegistry.mint(owner, AGENT);
        bytes32 elsewhere = otherRegistry.agentWalletDigest(AGENT, address(payee), owner, deadline);
        assertEq(payee.isValidSignature(elsewhere, sig), INVALID);

        bytes32 here = _digest(owner, deadline);
        vm.chainId(block.chainid + 1);
        assertEq(payee.isValidSignature(here, sig), INVALID);
    }

    function test_isValidSignature_rejectsAWrongDeadline() public view {
        assertEq(payee.isValidSignature(_digest(owner, deadline), abi.encode(deadline + 1)), INVALID);
        assertEq(payee.isValidSignature(_digest(owner, deadline), abi.encode(deadline - 1)), INVALID);
        assertEq(payee.isValidSignature(_digest(owner, deadline + 1), abi.encode(deadline)), INVALID);
    }

    function testFuzz_isValidSignature_rejectsADigestForAnyDeadlineButTheSignedOne(uint256 signed, uint256 other)
        public
        view
    {
        vm.assume(signed != other);
        assertEq(payee.isValidSignature(_digest(owner, other), abi.encode(signed)), INVALID);
    }

    function test_isValidSignature_rejectsTheOwnersEcdsaSignature_andAnyOtherLength() public view {
        bytes32 digest = _digest(owner, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);
        assertEq(payee.isValidSignature(digest, abi.encodePacked(r, s, v)), INVALID);
        assertEq(payee.isValidSignature(digest, ""), INVALID);
        assertEq(payee.isValidSignature(digest, hex"01"), INVALID);
        assertEq(payee.isValidSignature(digest, abi.encode(deadline, uint256(0))), INVALID);
    }

    function test_isValidSignature_afterATransfer_rejectsTheFormerOwnersDigest_andAcceptsTheNewOwners() public {
        bytes32 former = _digest(owner, deadline);
        vm.prank(owner);
        registry.transfer(AGENT, buyer);
        assertEq(payee.isValidSignature(former, abi.encode(deadline)), INVALID);
        assertEq(payee.isValidSignature(_digest(buyer, deadline), abi.encode(deadline)), MAGIC);
    }

    function test_isValidSignature_withNoOwnerToName_rejectsEverything() public {
        AgentWalletPayee unowned = AgentWalletPayee(factory.deploy(777)); // ownerOf(777) reverts
        assertEq(unowned.isValidSignature(bytes32(0), abi.encode(uint256(1))), INVALID);
        assertEq(unowned.isValidSignature(bytes32(0), hex"01"), INVALID);
    }

    // ------------------------------------------------------------- setAgentWallet end to end

    function test_setAgentWallet_theOwnerSetsThePayee_withTheDeadlineAsTheSignature() public {
        vm.prank(owner);
        registry.setAgentWallet(AGENT, address(payee), deadline, abi.encode(deadline));
        assertEq(registry.getAgentWallet(AGENT), address(payee));
    }

    function test_setAgentWallet_aStrangerCannot() public {
        vm.prank(stranger);
        vm.expectRevert(bytes("Not authorized"));
        registry.setAgentWallet(AGENT, address(payee), deadline, abi.encode(deadline));
    }

    function test_setAgentWallet_theOwnersOwnSignatureDoesNotSetThePayee() public {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, _digest(owner, deadline));
        vm.prank(owner);
        vm.expectRevert(bytes("invalid wallet sig"));
        registry.setAgentWallet(AGENT, address(payee), deadline, abi.encodePacked(r, s, v));
    }

    function test_setAgentWallet_afterATransfer_onlyTheNewOwnerSetsThePayeeAgain() public {
        vm.prank(owner);
        registry.setAgentWallet(AGENT, address(payee), deadline, abi.encode(deadline));
        vm.prank(owner);
        registry.transfer(AGENT, buyer);
        assertEq(registry.getAgentWallet(AGENT), address(0));

        vm.prank(owner);
        vm.expectRevert(bytes("Not authorized"));
        registry.setAgentWallet(AGENT, address(payee), deadline, abi.encode(deadline));

        vm.prank(buyer);
        registry.setAgentWallet(AGENT, address(payee), deadline, abi.encode(deadline));
        assertEq(registry.getAgentWallet(AGENT), address(payee));
    }
}
