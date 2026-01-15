// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/Reward.sol";
import "./mocks/MockERC20.sol";

contract RewardTest is Test {
    Reward reward;
    MockERC20 token;

    address owner;
    uint256 ownerPk;

    address user = address(0xBEEF);

    function setUp() public {
        // create owner keypair
        ownerPk = 0xA11CE;
        owner = vm.addr(ownerPk);

        vm.startPrank(owner);
        token = new MockERC20();
        reward = new Reward(address(token));
        vm.stopPrank();

        // fund reward contract
        token.mint(owner, 1_000_000 ether);
        vm.prank(owner);
        token.approve(address(reward), type(uint256).max);
        vm.prank(owner);
        reward.fundContract(500_000 ether);
    }

    /* ------------------------------------------------------------ */
    /*                          HELPERS                             */
    /* ------------------------------------------------------------ */

    function _signReward(
        address claimant,
        uint256 nonce,
        uint256 amount
    ) internal view returns (bytes memory) {
        bytes32 messageHash = keccak256(
            abi.encodePacked(
                claimant,
                nonce,
                amount,
                address(reward),
                block.chainid
            )
        );

        bytes32 ethHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash)
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, ethHash);
        return abi.encodePacked(r, s, v);
    }

    /* ------------------------------------------------------------ */
    /*                         TESTS                                */
    /* ------------------------------------------------------------ */

    function testClaimRewardSuccess() public {
        uint256 amount = 100 ether;
        uint256 nonce = 1;

        bytes memory sig = _signReward(user, nonce, amount);

        vm.prank(user);
        reward.claimReward(nonce, amount, sig);

        assertEq(token.balanceOf(user), amount);
        assertEq(reward.totalRewardClaimedByUser(user), amount);
        assertEq(reward.totalNumberOfRewardClaimedByUser(user), 1);
    }

    function testCannotReuseSignature() public {
        uint256 amount = 100 ether;
        uint256 nonce = 1;

        bytes memory sig = _signReward(user, nonce, amount);

        vm.prank(user);
        reward.claimReward(nonce, amount, sig);

        vm.prank(user);
        vm.expectRevert("Signature already used");
        reward.claimReward(nonce, amount, sig);
    }

    function testInvalidSignerReverts() public {
        uint256 fakePk = 0xB0B;
        address fakeSigner = vm.addr(fakePk);

        bytes32 messageHash = keccak256(
            abi.encodePacked(
                user,
                1,
                100 ether,
                address(reward),
                block.chainid
            )
        );

        bytes32 ethHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash)
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(fakePk, ethHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(user);
        vm.expectRevert("Invalid signature - not from contract owner");
        reward.claimReward(1, 100 ether, sig);
    }

    function testPausedContractCannotClaim() public {
        vm.prank(owner);
        reward.pause();

        bytes memory sig = _signReward(user, 1, 100 ether);

        vm.prank(user);
        vm.expectRevert("Pausable: paused");
        reward.claimReward(1, 100 ether, sig);
    }

    function testFundContractIncreasesBalance() public {
        uint256 beforeBalance = token.balanceOf(address(reward));

        vm.prank(owner);
        reward.fundContract(1000 ether);

        uint256 afterBalance = token.balanceOf(address(reward));
        assertEq(afterBalance, beforeBalance + 1000 ether);
    }

    function testEmergencyWithdrawByOwner() public {
        uint256 before = token.balanceOf(owner);

        vm.prank(owner);
        reward.emergencyWithdraw(1000 ether);

        uint256 afterBal = token.balanceOf(owner);
        assertEq(afterBal, before + 1000 ether);
    }
}
