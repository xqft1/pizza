// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

interface IPizza {
    function mint(address to, uint256 amount) external;
    function totalSupply() external view returns (uint256);
}

interface ILpRewardDistributor {
    function notifyRewardAmount(uint256 amount) external;
}

contract PizzaOven is Ownable {
    IERC20 public immutable sato;
    IPizza public immutable pizza;

    uint256 public constant WAD = 1e18;
    uint256 public constant MAX_SUPPLY = 21_000_000 * 1e18;

    // Bigger number = slower curve / cheaper for longer.
    uint256 public immutable curveScale;

    // This should be the LP reward distributor contract.
    address public rewardReceiver;

    uint256 public totalSatoContributed;

    event PizzaBaked(
        address indexed baker,
        uint256 satoAmount,
        uint256 pizzaMinted,
        uint256 totalSatoContributed,
        uint256 totalPizzaSupply
    );

    event RewardReceiverUpdated(
        address indexed oldReceiver,
        address indexed newReceiver
    );

    constructor(
        address _sato,
        address _pizza,
        address _rewardReceiver,
        uint256 _curveScale,
        address _owner
    ) Ownable(_owner) {
        require(_sato != address(0), "SATO zero address");
        require(_pizza != address(0), "PIZZA zero address");
        require(_rewardReceiver != address(0), "Receiver zero address");
        require(_curveScale > 0, "Bad curve scale");
        require(_owner != address(0), "Owner zero address");

        sato = IERC20(_sato);
        pizza = IPizza(_pizza);
        rewardReceiver = _rewardReceiver;
        curveScale = _curveScale;
    }

    function setRewardReceiver(address newReceiver) external onlyOwner {
        require(newReceiver != address(0), "Receiver zero address");

        address oldReceiver = rewardReceiver;
        rewardReceiver = newReceiver;

        emit RewardReceiverUpdated(oldReceiver, newReceiver);
    }

    function bake(uint256 satoAmount) external {
        require(satoAmount > 0, "No SATO sent");

        uint256 supply = pizza.totalSupply();
        require(supply < MAX_SUPPLY, "Max supply reached");

        uint256 pizzaOut = _quote(satoAmount);
        require(pizzaOut > 0, "Too little SATO");
        require(supply + pizzaOut <= MAX_SUPPLY, "Exceeds max supply");

        totalSatoContributed += satoAmount;

        require(
            sato.transferFrom(msg.sender, rewardReceiver, satoAmount),
            "SATO transfer failed"
        );

        ILpRewardDistributor(rewardReceiver).notifyRewardAmount(satoAmount);

        pizza.mint(msg.sender, pizzaOut);

        emit PizzaBaked(
            msg.sender,
            satoAmount,
            pizzaOut,
            totalSatoContributed,
            supply + pizzaOut
        );
    }

    function quote(uint256 satoAmount) external view returns (uint256 pizzaOut) {
        if (pizza.totalSupply() >= MAX_SUPPLY) return 0;
        pizzaOut = _quote(satoAmount);
    }

    function totalMintableAt(uint256 totalSatoAmount)
        public
        view
        returns (uint256)
    {
        // minted = MAX_SUPPLY * (1 - e^(-totalSato / curveScale))

        uint256 exponentWad = (totalSatoAmount * WAD) / curveScale;

        // casting is safe for realistic SATO totals in this protocol
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 negativeExponent = -int256(exponentWad);

        uint256 decay = uint256(FixedPointMathLib.expWad(negativeExponent));
        uint256 mintedRatio = WAD - decay;

        return (MAX_SUPPLY * mintedRatio) / WAD;
    }

    function _quote(uint256 satoAmount)
        internal
        view
        returns (uint256 pizzaOut)
    {
        uint256 beforeMintable = totalMintableAt(totalSatoContributed);
        uint256 afterMintable = totalMintableAt(
            totalSatoContributed + satoAmount
        );

        pizzaOut = afterMintable - beforeMintable;
    }
}