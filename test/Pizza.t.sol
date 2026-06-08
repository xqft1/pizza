// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {Pizza} from "../src/Pizza.sol";
import {PizzaOven} from "../src/PizzaOven.sol";
import {LpRewardDistributor} from "../src/LpRewardDistributor.sol";

contract MockSato {
    string public name = "SATO";
    string public symbol = "SATO";
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount)
        external
        returns (bool)
    {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount)
        external
        returns (bool)
    {
        require(balanceOf[msg.sender] >= amount, "no balance");

        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;

        return true;
    }

    function transferFrom(address from, address to, uint256 amount)
        external
        returns (bool)
    {
        require(balanceOf[from] >= amount, "no balance");
        require(allowance[from][msg.sender] >= amount, "no allowance");

        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;

        return true;
    }
}

contract MockLpToken {
    string public name = "LP";
    string public symbol = "LP";
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount)
        external
        returns (bool)
    {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount)
        external
        returns (bool)
    {
        require(balanceOf[msg.sender] >= amount, "no balance");

        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;

        return true;
    }

    function transferFrom(address from, address to, uint256 amount)
        external
        returns (bool)
    {
        require(balanceOf[from] >= amount, "no balance");
        require(allowance[from][msg.sender] >= amount, "no allowance");

        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;

        return true;
    }
}

contract PizzaTest is Test {
    Pizza pizza;
    PizzaOven oven;

    MockSato sato;
    MockLpToken lp;

    LpRewardDistributor distributor;

    address alice = address(1);

    function setUp() public {
        sato = new MockSato();
        lp = new MockLpToken();

        pizza = new Pizza(address(this));

        distributor = new LpRewardDistributor(
            address(sato),
            address(lp)
        );

        oven = new PizzaOven(
            address(sato),
            address(pizza),
            address(distributor),
            1_000_000 ether,
            address(this)
        );

        pizza.grantRole(pizza.MINTER_ROLE(), address(oven));

        sato.mint(alice, 10_000_000 ether);
        lp.mint(alice, 1000 ether);
    }

    function testBakePizza() public {
        vm.startPrank(alice);

        sato.approve(address(oven), 100 ether);

        oven.bake(100 ether);

        vm.stopPrank();

        assertGt(pizza.balanceOf(alice), 0);
    }

    function testCurveSlowsAsSupplyIncreases() public {
        vm.startPrank(alice);

        sato.approve(address(oven), 200 ether);

        uint256 quoteBefore = oven.quote(100 ether);

        oven.bake(100 ether);

        uint256 quoteAfter = oven.quote(100 ether);

        vm.stopPrank();

        assertGt(quoteBefore, quoteAfter);
    }

    function testOnlyOvenCanMint() public {
        vm.expectRevert();

        pizza.mint(alice, 1 ether);
    }

    function testTotalSatoContributedUpdates() public {
        vm.startPrank(alice);

        sato.approve(address(oven), 300 ether);

        oven.bake(100 ether);
        oven.bake(200 ether);

        vm.stopPrank();

        assertEq(oven.totalSatoContributed(), 300 ether);
    }

    function testCannotBakeZeroSato() public {
        vm.startPrank(alice);

        sato.approve(address(oven), 1 ether);

        vm.expectRevert("No SATO sent");
        oven.bake(0);

        vm.stopPrank();
    }

    function testCannotExceedMaxSupply() public {
        uint256 hugeAmount = 1_000_000_000 ether;

        sato.mint(alice, hugeAmount);

        vm.startPrank(alice);

        sato.approve(address(oven), hugeAmount);

        oven.bake(hugeAmount);

        vm.stopPrank();

        assertLe(pizza.totalSupply(), pizza.MAX_SUPPLY());
    }

    function testLpRewardsFlow() public {
        vm.startPrank(alice);

        lp.approve(address(distributor), 100 ether);
        distributor.stake(100 ether);

        sato.approve(address(oven), 100 ether);
        oven.bake(100 ether);

        distributor.claim();

        vm.stopPrank();

        assertGt(sato.balanceOf(alice), 0);
    }
}