// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {Pizza} from "../src/Pizza.sol";
import {PizzaOven} from "../src/PizzaOven.sol";
import {LpRewardDistributor} from "../src/LpRewardDistributor.sol";

contract Deploy is Script {
    address constant SATO = address(0x00829f4b62eebe12af653b4dd4ffc480966f7d7f09);

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        address deployer = vm.addr(deployerPrivateKey);
        address pizzaAddress = vm.envAddress("PIZZA");
        address lpToken = vm.envAddress("LP_TOKEN");

        uint256 curveScale = 1_000_000 ether;

        vm.startBroadcast(deployerPrivateKey);

        Pizza pizza = Pizza(pizzaAddress);

        LpRewardDistributor distributor = new LpRewardDistributor(
            SATO,
            lpToken
        );

        PizzaOven oven = new PizzaOven(
            SATO,
            pizzaAddress,
            address(distributor),
            curveScale,
            deployer
        );

        pizza.grantRole(pizza.MINTER_ROLE(), address(oven));

        // removes your temporary manual mint permission
        pizza.revokeRole(pizza.MINTER_ROLE(), deployer);

        vm.stopBroadcast();

        console2.log("PIZZA:", pizzaAddress);
        console2.log("LP token:", lpToken);
        console2.log("Distributor:", address(distributor));
        console2.log("Oven:", address(oven));
        console2.log("Owner:", deployer);
        console2.log("Curve scale:", curveScale / 1e18, "SATO");
    }
}