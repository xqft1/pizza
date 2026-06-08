// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {Pizza} from "../src/Pizza.sol";
import {PizzaOven} from "../src/PizzaOven.sol";

contract CurvePreview is Script {
    uint256 constant WAD = 1e18;
    uint256 constant MAX_SUPPLY = 21_000_000 ether;

    function run() external {
        address dummyAdmin = address(0x9999);
        address dummySato = address(0x1234);
        address rewardReceiver = address(0x5678);

        Pizza pizza = new Pizza(dummyAdmin);

        uint256 curveScale = 1_000_000 ether;

        PizzaOven oven = new PizzaOven(
            dummySato,
            address(pizza),
            rewardReceiver,
            curveScale,
            dummyAdmin
        );

        console2.log("Curve scale:", curveScale / 1e18, "SATO");
        console2.log("================================");

        preview(oven);

        console2.log("================================");

        milestone(oven, 50);
        milestone(oven, 75);
        milestone(oven, 90);
        milestone(oven, 95);
        milestone(oven, 99);
        milestone(oven, 999);
    }

    function preview(PizzaOven oven) internal view {
        printAt(oven, 1 ether);
        printAt(oven, 10 ether);
        printAt(oven, 100 ether);
        printAt(oven, 1_000 ether);
        printAt(oven, 10_000 ether);
        printAt(oven, 100_000 ether);
        printAt(oven, 1_000_000 ether);
        printAt(oven, 2_000_000 ether);
        printAt(oven, 5_000_000 ether);
    }

    function printAt(PizzaOven oven, uint256 totalSato) internal view {
        uint256 minted = oven.totalMintableAt(totalSato);
        uint256 percentBps = (minted * 10_000) / MAX_SUPPLY;

        console2.log("Total SATO:", totalSato / 1e18);
        console2.log("PIZZA minted:", minted / 1e18);
        console2.log("Percent minted bps:", percentBps);
        console2.log("--------------------------------");
    }

    function milestone(PizzaOven oven, uint256 percent) internal view {
        uint256 target;

        if (percent == 999) {
            target = (MAX_SUPPLY * 9990) / 10000;
            console2.log("=== 99.9% MINTED ===");
        } else {
            target = (MAX_SUPPLY * percent) / 100;
            console2.log("===", percent, "% MINTED ===");
        }

        uint256 low = 0;
        uint256 high = 100_000_000 ether;

        for (uint256 i = 0; i < 100; i++) {
            uint256 mid = (low + high) / 2;

            uint256 minted = oven.totalMintableAt(mid);

            if (minted < target) {
                low = mid;
            } else {
                high = mid;
            }
        }

        console2.log("Approx SATO required:", high / 1e18);
        console2.log("--------------------------------");
    }
}