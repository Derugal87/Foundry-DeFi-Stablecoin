// SPDX-Licence-Identifier: MIT

pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";

contract DecentralizedStableCoinTest is Test {
    DecentralizedStableCoin public dsc;

    function setUp() public {
        dsc = new DecentralizedStableCoin();
    }

    function testCantMintWithZeroAddress() public {
        vm.expectRevert();
        dsc.mint(address(0), 100);
    }

    function testCantMintWithZero() public {
        vm.prank(dsc.owner());
        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__MustBeMoreThanZero.selector);
        dsc.mint(address(this), 0);
    }

    function testCantBurnZeroTokens() public {
        vm.prank(dsc.owner());
        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__MustBeMoreThanZero.selector);
        dsc.burn(0);
    }

    function testCantBurnMoreThanBalance() public {
        vm.deal(dsc.owner(), 50);
        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__BurnAmountExceedsBalance.selector);
        dsc.burn(100);
    }

    function testMustMintMoreThanZero() public {
        vm.deal(dsc.owner(), 50);
        dsc.mint(address(this), 10);
        assertEq(dsc.balanceOf(address(this)), 10);
    }

    function testMustBurnMoreThanZero() public {
        vm.deal(dsc.owner(), 50);
        dsc.mint(address(this), 10);
        dsc.burn(5);
        assertEq(dsc.balanceOf(address(this)), 5);
    }
}
