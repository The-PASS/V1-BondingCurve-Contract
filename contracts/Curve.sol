// SPDX-License-Identifier: MIT

pragma solidity 0.8.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "./math-utils/interfaces/IAnalyticMath.sol";

/**
 * @dev thePASS Bonding Curve - minting NFT through erc20 or eth
 * PASS is orgnization's erc1155 token on curve
 * erc20 or eth is collateral token on curve
 * Users can mint PASS via deposting erc20 collateral token into curve
 * thePASS Bonding Curve Formula: f(X) = m*(x^N)+v
 * f(x) = PASS Price when total supply of PASS is x
 * m, slope of bonding curve
 * x = total supply of PASS
 * N = n/d, represented by intPower when N is integer
 * v = virtual balance, Displacement of bonding curve
 */
contract Curve is ERC1155Burnable {
    using Counters for Counters.Counter;
    using SafeERC20 for IERC20;

    IAnalyticMath public constant ANALYTICMATH =
        IAnalyticMath(0x350b9F764f13D12bc7765890e5a94FA02B3d1Ac8); // Mathmatical method for calculating power function

    string public name; // Contract name
    string public symbol; // Contract symbol
    string public baseUri;

    // token id counter. For erc721 contract, PASS serial number = token id
    Counters.Counter private tokenIdTracker = Counters.Counter({_value: 1});

    uint256 public totalSupply; // total supply of erc1155 tokens

    IERC20 public erc20; // collateral token on bonding curve
    uint256 private m; // slope of bonding curve
    uint256 private n; // numerator of exponent in curve power function
    uint256 private d; // denominator of exponent in curve power function
    uint256 private intPower; // when n/d is integer
    uint256 private virtualBalance; // vitual balance for setting a reasonable initial price

    mapping(uint256 => uint256) public decPowerCache; // cache of power function calculation result when exponent is decimal，n => cost
    uint256 public reserve; // reserve of collateral tokens stored in bonding curve AMM pool

    address payable public platform; // thePass platform's commission account
    uint256 public platformRate; // thePass platform's commission rate in pph

    address payable public creator; // creator's commission account
    uint256 public creatorRate; // creator's commission rate in pph

    event Minted(
        uint256 indexed tokenId,
        uint256 indexed cost,
        uint256 indexed reserveAfterMint,
        uint256 balance,
        uint256 platformProfit,
        uint256 creatorProfit
    );
    event Burned(
        address indexed account,
        uint256 indexed tokenId,
        uint256 balance,
        uint256 returnAmount,
        uint256 reserveAfterBurn
    );
    event BatchBurned(
        address indexed account,
        uint256[] indexed tokenIds,
        uint256[] indexed balances,
        uint256 returnAmount,
        uint256 reserveAfterBurn
    );
    event Withdraw(address indexed to, uint256 amount);

    /**
     * @dev constrcutor of bonding curve with formular: f(x)=m*(x^N)+v
     * _erc20: collateral token(erc20) for miniting PASS on bonding curve, send 0x000...000 to appoint it as eth instead of erc20 token
     * _initMintPrice: f(1) = m + v, the first PASS minting price
     * _m: m, slope of curve
     * _virtualBalance: v = f(1) - _m, virtual balance, displacement of curve
     * _n,_d: _n/_d = N, exponent of the curve
     * reserve: reserve of collateral tokens stored in bonding curve AMM pool, start with 0
     */
    constructor(
        string memory _name,
        string memory _symbol,
        string memory _baseUri,
        address _erc20,
        uint256 _initMintPrice,
        uint256 _m,
        uint256 _n,
        uint256 _d
    ) ERC1155(_baseUri) {
        name = _name;
        symbol = _symbol;
        baseUri = _baseUri;

        erc20 = IERC20(_erc20);
        m = _m;
        n = _n;

        if ((_n / _d) * _d == _n) {
            intPower = _n / _d;
        } else {
            d = _d;
        }

        virtualBalance = _initMintPrice - _m;
        reserve = 0;
    }

    // @creator commission account and rate initilization
    function setFeeParameters(
        address payable _platform,
        uint256 _platformRate,
        address payable _creator,
        uint256 _createRate
    ) public {
        require(
            platform == address(0) && creator == address(0),
            "Curve: commission account and rate cannot be modified."
        );
        platform = _platform;
        platformRate = _platformRate;
        creator = _creator;
        creatorRate = _createRate;
    }

    // only contract admin can change beneficiary account
    function changeBeneficiary(address payable _newAddress) public {
        require(creator == _msgSender(), "caller is not the owner");
        creator = _newAddress;
    }

    /**
     * @dev each PASS minting transaction by depositing collateral erc20 tokens will create a new erc1155 token id sequentially
     * _balance: number of PASSes user want to mint
     * _amount: the maximum deposited amount set by the user
     * _maxPriceFistNFT: the maximum price for the first mintable PASS to prevent front-running with least gas consumption
     * return: token id
     */
    function mint(
        uint256 _balance,
        uint256 _amount,
        uint256 _maxPriceFirstPASS
    ) public returns (uint256) {
        require(address(erc20) != address(0), "Curve: erc20 address is null.");
        uint256 firstPrice = caculateCurrentCostToMint(1);
        require(
            _maxPriceFirstPASS >= firstPrice,
            "Curve: price exceeds slippage tolerance."
        );

        return _mint(_balance, _amount, false);
    }

    // for small amount of PASS minting, it will be unceessary to check the maximum price for the fist mintable PASS
    function mint(uint256 _balance, uint256 _amount) public returns (uint256) {
        require(address(erc20) != address(0), "Curve: erc20 address is null.");
        return _mint(_balance, _amount, false);
    }

    /**
     * @dev user burn PASS/PASSes to receive corresponding collateral tokens
     * _tokenId: the token id of PASS/PASSes to burn
     * _balance: the number of PASS/PASSes to burn
     */
    function burn(
        address _account,
        uint256 _tokenId,
        uint256 _balance
    ) public override {
        require(address(erc20) != address(0), "Curve: erc20 address is null.");

        // checks if allowed to burn
        super._burn(_account, _tokenId, _balance);

        uint256 burnReturn = getCurrentReturnToBurn(_balance);
        totalSupply -= _balance;
        reserve = reserve - burnReturn;

        erc20.safeTransfer(_account, burnReturn);

        emit Burned(_account, _tokenId, _balance, burnReturn, reserve);
    }

    // allow user to burn batches of PASSes with a set of token id
    function burnBatch(
        address _account,
        uint256[] memory _tokenIds,
        uint256[] memory _balances
    ) public override {
        require(address(erc20) != address(0), "Curve: erc20 address is null.");

        // checks if allowed to burn
        super._burnBatch(_account, _tokenIds, _balances);

        uint256 totalBalance;
        for (uint256 i = 0; i < _balances.length; i++) {
            totalBalance += _balances[i];
            totalSupply -= _balances[i];
        }

        uint256 burnReturn = getCurrentReturnToBurn(totalBalance);
        reserve = reserve - burnReturn;
        erc20.safeTransfer(_account, burnReturn);

        emit BatchBurned(_account, _tokenIds, _balances, burnReturn, reserve);
    }

    /**
     * @dev each PASS minting transaction by depositing ETHs will create a new erc1155 token id sequentially
     * _balance: number of PASSes user want to mint
     * _maxPriceFirstPASS: the maximum price for the first mintable PASS to prevent front-running with least gas consumption
     * return: token ID
     */
    function mintEth(uint256 _balance, uint256 _maxPriceFirstPASS)
        public
        payable
        returns (uint256)
    {
        require(
            address(erc20) == address(0),
            "Curve: erc20 address is NOT null."
        );
        uint256 firstPrice = caculateCurrentCostToMint(1);
        require(
            _maxPriceFirstPASS >= firstPrice,
            "Curve: price exceeds slippage tolerance."
        );

        return _mint(_balance, msg.value, true);
    }

    function mintEth(uint256 _balance) public payable returns (uint256) {
        require(
            address(erc20) == address(0),
            "Curve: erc20 address is NOT null."
        );

        return _mint(_balance, msg.value, true);
    }

    /**
     * @dev user burn PASS/PASSes to receive corresponding ETHs
     * _tokenId: the token id of PASS/PASSes to burn
     * _balance: the number of PASS/PASSes to burn
     */
    function burnEth(
        address _account,
        uint256 _tokenId,
        uint256 _balance
    ) public {
        require(
            address(erc20) == address(0),
            "Curve: erc20 address is NOT null."
        );
        super._burn(_account, _tokenId, _balance);

        uint256 burnReturn = getCurrentReturnToBurn(_balance);

        totalSupply -= _balance;

        reserve = reserve - burnReturn;
        payable(_account).transfer(burnReturn);

        emit Burned(_account, _tokenId, _balance, burnReturn, reserve);
    }

    // allow user to burn batches of PASSes with a set of token id
    function burnBatchETH(
        address _account,
        uint256[] memory _tokenIds,
        uint256[] memory _balances
    ) public {
        require(address(erc20) == address(0), "Curve: erc20 address is null.");
        super._burnBatch(_account, _tokenIds, _balances);

        uint256 totalBalance;
        for (uint256 i = 0; i < _balances.length; i++) {
            totalBalance += _balances[i];
            totalSupply -= _balances[i];
        }

        uint256 burnReturn = getCurrentReturnToBurn(totalBalance);

        reserve = reserve - burnReturn;
        payable(_account).transfer(burnReturn);

        emit BatchBurned(_account, _tokenIds, _balances, burnReturn, reserve);
    }

    function uri(uint256 _tokenId)
        public
        view
        override
        returns (string memory)
    {
        return string(abi.encodePacked(baseUri, toString(_tokenId)));
    }

    // get current supply of PASS
    function getCurrentSupply() public view returns (uint256) {
        return totalSupply;
    }

    // internal function to mint PASS
    function _mint(
        uint256 _balance,
        uint256 _amount,
        bool bETH
    ) private returns (uint256 tokenId) {
        uint256 mintCost = caculateCurrentCostToMint(_balance);
        require(_amount >= mintCost, "Curve: not enough token sent");

        address account = _msgSender();

        uint256 platformProfit = (mintCost * platformRate) / 100;
        uint256 creatorProfit = (mintCost * creatorRate) / 100;

        tokenId = tokenIdTracker.current(); // accumulate the token id
        tokenIdTracker.increment(); // automate token id increment

        totalSupply += _balance;
        _mint(account, tokenId, _balance, "");

        uint256 reserveCut = mintCost - platformProfit - creatorProfit;
        reserve = reserve + reserveCut;

        if (bETH) {
            // return overcharge eth
            if (_amount - (mintCost) > 0) {
                payable(account).transfer(_amount - (mintCost));
            }
            if (platformRate > 0) {
                platform.transfer(platformProfit);
            }
        } else {
            erc20.safeTransferFrom(account, address(this), mintCost);
            if (platformRate > 0) {
                erc20.safeTransfer(platform, platformProfit);
            }
        }

        emit Minted(
            tokenId,
            mintCost,
            reserve,
            _balance,
            platformProfit,
            creatorProfit
        );

        return tokenId; // returns tokenId in case its useful to check it
    }

    function _getEthBalance() internal view returns (uint256) {
        return address(this).balance;
    }

    function _getErc20Balance() internal view returns (uint256) {
        return IERC20(erc20).balanceOf(address(this));
    }

    /**
     * @dev internal function to calculate the cost of minting _balance PASSes in a transaction
     * _balance: number of PASS/PASSes to mint
     */
    function caculateCurrentCostToMint(uint256 _balance)
        internal
        returns (uint256)
    {
        uint256 curStartX = getCurrentSupply() + 1;
        uint256 totalCost;
        if (intPower > 0) {
            if (intPower <= 10) {
                uint256 intervalSum = caculateIntervalSum(
                    intPower,
                    curStartX,
                    curStartX + _balance - 1
                );
                totalCost = m * intervalSum + (virtualBalance * _balance);
            } else {
                for (uint256 i = curStartX; i < curStartX + _balance; i++) {
                    totalCost =
                        totalCost +
                        (m * (i**intPower) + (virtualBalance));
                }
            }
        } else {
            for (uint256 i = curStartX; i < curStartX + _balance; i++) {
                if (decPowerCache[i] == 0) {
                    (uint256 p, uint256 q) = ANALYTICMATH.pow(i, 1, n, d);
                    uint256 cost = virtualBalance + ((m * p) / q);
                    totalCost = totalCost + cost;
                    decPowerCache[i] = cost;
                } else {
                    totalCost = totalCost + decPowerCache[i];
                }
            }
        }
        return totalCost;
    }

    // external view function to query the current cost to mint a PASS/PASSes
    function getCurrentCostToMint(uint256 _balance)
        public
        view
        returns (uint256)
    {
        uint256 curStartX = getCurrentSupply() + 1;
        uint256 totalCost;
        if (intPower > 0) {
            if (intPower <= 10) {
                uint256 intervalSum = caculateIntervalSum(
                    intPower,
                    curStartX,
                    curStartX + _balance - 1
                );
                totalCost = m * (intervalSum) + (virtualBalance * _balance);
            } else {
                for (uint256 i = curStartX; i < curStartX + _balance; i++) {
                    totalCost =
                        totalCost +
                        (m * (i**intPower) + (virtualBalance));
                }
            }
        } else {
            for (uint256 i = curStartX; i < curStartX + _balance; i++) {
                (uint256 p, uint256 q) = ANALYTICMATH.pow(i, 1, n, d);
                uint256 cost = virtualBalance + ((m * p) / q);
                totalCost = totalCost + (cost);
            }
        }
        return totalCost;
    }

    /**
     * @dev calculate the return of burning _balance PASSes in a transaction
     * _balance: number of PASS/PASSes to be burned
     */
    function getCurrentReturnToBurn(uint256 _balance)
        public
        view
        returns (uint256)
    {
        uint256 curEndX = getCurrentSupply();
        _balance = _balance > curEndX ? curEndX : _balance;

        uint256 totalReturn;
        if (intPower > 0) {
            if (intPower <= 10) {
                uint256 intervalSum = caculateIntervalSum(
                    intPower,
                    curEndX - _balance + 1,
                    curEndX
                );
                totalReturn = m * intervalSum + (virtualBalance * (_balance));
            } else {
                for (uint256 i = curEndX; i > curEndX - _balance; i--) {
                    totalReturn =
                        totalReturn +
                        (m * (i**intPower) + (virtualBalance));
                }
            }
        } else {
            for (uint256 i = curEndX; i > curEndX - _balance; i--) {
                totalReturn = totalReturn + decPowerCache[i];
            }
        }
        totalReturn = (totalReturn * (100 - platformRate - creatorRate)) / 100;
        return totalReturn;
    }

    // Bernoulli's formula for calculating the sum of intervals between the two reserves
    function caculateIntervalSum(
        uint256 _power,
        uint256 _startX,
        uint256 _endX
    ) public pure returns (uint256) {
        return
            ANALYTICMATH.caculateIntPowerSum(_power, _endX) -
            ANALYTICMATH.caculateIntPowerSum(_power, _startX - 1);
    }

    // anyone can withdraw reserve of erc20 tokens/ETH to creator's beneficiary account
    function withdraw() public {
        if (address(erc20) == address(0)) {
            creator.transfer(_getEthBalance() - reserve); // withdraw eth to beneficiary account
            emit Withdraw(creator, _getEthBalance() - reserve);
        } else {
            erc20.safeTransfer(creator, _getErc20Balance() - reserve); // withdraw erc20 tokens to beneficiary account
            emit Withdraw(creator, _getErc20Balance() - reserve);
        }
    }

    /**
     * @dev Converts a `uint256` to its ASCII `string` decimal representation.
     */
    function toString(uint256 value) internal pure returns (string memory) {
        // Inspired by OraclizeAPI's implementation - MIT licence
        // https://github.com/oraclize/ethereum-api/blob/b42146b063c7d6ee1358846c198246239e9360e8/oraclizeAPI_0.4.25.sol

        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
