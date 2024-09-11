// SPDX-Licence-Identifier: MIT

pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {StdCheats} from "forge-std/StdCheats.sol";

contract HelperConfigTest is Test {
    HelperConfig public config;

    function setUp() public {
        config = new HelperConfig();
    }

    function testGetSepoliaEthConfig() public view {
        HelperConfig.NetworkConfig memory sepoliaConfig = config.getSepoliaEthConfig();
        assertEq(sepoliaConfig.wethUsdPriceFeed, 0x694AA1769357215DE4FAC081bf1f309aDC325306);
        assertEq(sepoliaConfig.wbtcUsdPriceFeed, 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43);
        assertEq(sepoliaConfig.weth, 0xdd13E55209Fd76AfE204dBda4007C227904f0a81);
        assertEq(sepoliaConfig.wbtc, 0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063);
        assertEq(sepoliaConfig.deployerKey, 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80);
    }
}
