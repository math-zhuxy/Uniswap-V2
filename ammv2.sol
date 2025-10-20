// SPDX-License-Identifier: MIT
pragma solidity >= 0.8.0;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface FLASH_SWAP_CALLER {
    function callBack(uint256 amount, uint256 fee, string memory data) external returns (bool);
}

contract AMMV2 {
    address public poolOwner;
    mapping(address => uint256) public userLpToken;
    uint256 public lpTokenTotalSupply;

    // A、B两种代币地址
    address public tokenAAddress;
    address public tokenBAddress;
    
    // 手续费率 (千分之三)
    uint256 public constant FEE_RATE = 3;
    uint256 public constant FEE_DENOMINATOR = 1000;

    // Flash Swap 手续费率
    uint256 public constant FLASH_SWAP_FEE_PER_THOUSAND = 3;
    
    // 最小流动性锁定
    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    // 池名称
    string public POOL_NAME;
    
    // 相关事件
    event AddLiquidity(address indexed user, uint256 amountA, uint256 amountB, uint256 lpTokens);
    event RemoveLiquidity(address indexed user, uint256 amountA, uint256 amountB, uint256 lpTokens);
    event Swap(address indexed user, address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut);

    // TWAP 相关变量
    uint256 public lastPrice;
    uint256 public lastTimestamp;
    uint256 public cumulativePrice;
    uint256 public cumulativeTime;
    
    modifier onlyPoolOwner() {
        require(msg.sender == poolOwner, "Only pool owner can call this function");
        _;
    }
    
    constructor(address _tokenA, address _tokenB, string memory _pool_name) {
        poolOwner = msg.sender;
        tokenAAddress = _tokenA;
        tokenBAddress = _tokenB;
        lpTokenTotalSupply = 0;

        lastTimestamp = block.timestamp;
        cumulativePrice = 0;
        cumulativeTime = 0;
        lastPrice = 0;

        POOL_NAME = _pool_name;
    }

    // 智能合约类型
    function getContractName() external pure returns (string memory) {
        return "amm";
    }

    // Babylonian method
    function sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }

    // TWAP 价格更新函数
    function updatePrice() private {
        uint256 poolTokenANum = IERC20(tokenAAddress).balanceOf(address(this));
        uint256 poolTokenBNum = IERC20(tokenBAddress).balanceOf(address(this));

        uint256 newPrice = poolTokenANum * 1e18 / (poolTokenBNum + 1);
        require(newPrice > 0, "Price must be positive");

        uint256 currentTime = block.timestamp;
        uint256 timeElapsed = currentTime - lastTimestamp;

        // 累加 price * delta_t
        cumulativePrice += lastPrice * timeElapsed;
        cumulativeTime += timeElapsed;

        // 更新状态
        lastPrice = newPrice;
        lastTimestamp = currentTime;
    }

    function GetTwapPrice() external view returns (uint256) {
        if (cumulativeTime == 0) {
            return 0; 
        }

        return cumulativePrice / cumulativeTime;
    }
    
    // 添加流动性
    function addLiquidity(uint256 amountA, uint256 amountB) external returns (uint256 lpTokens) {
        uint256 poolTokenANum = IERC20(tokenAAddress).balanceOf(address(this));
        uint256 poolTokenBNum = IERC20(tokenBAddress).balanceOf(address(this));

        require(amountA > 0 && amountB > 0, "Invalid amounts");
        
        // 转入代币
        require(IERC20(tokenAAddress).transferFrom(msg.sender, address(this), amountA), "Transfer A failed");
        require(IERC20(tokenBAddress).transferFrom(msg.sender, address(this), amountB), "Transfer B failed");
        
        if (lpTokenTotalSupply == 0) {
            // 首次添加流动性
            lpTokens = sqrt(amountA * amountB);
            require(lpTokens > MINIMUM_LIQUIDITY, "Insufficient liquidity");
            
            // 锁定最小流动性
            lpTokenTotalSupply = lpTokens;
            userLpToken[msg.sender] = lpTokens - MINIMUM_LIQUIDITY;
            userLpToken[address(0)] = MINIMUM_LIQUIDITY;

        } else {
            // 后续添加流动性，按比例计算
            uint256 lpTokensA = (amountA * lpTokenTotalSupply) / poolTokenANum;
            uint256 lpTokensB = (amountB * lpTokenTotalSupply) / poolTokenBNum;
            lpTokens = lpTokensA < lpTokensB ? lpTokensA : lpTokensB;
        }
        
        require(lpTokens > 0, "Insufficient LP tokens");
        
        // 更新状态
        lpTokenTotalSupply += lpTokens;
        userLpToken[msg.sender] += lpTokens;
        updatePrice();
        
        emit AddLiquidity(msg.sender, amountA, amountB, lpTokens);
    }
    
    // 移除流动性
    function removeLiquidity(uint256 lpTokens) external returns (uint256 amountA, uint256 amountB) {
        uint256 poolTokenANum = IERC20(tokenAAddress).balanceOf(address(this));
        uint256 poolTokenBNum = IERC20(tokenBAddress).balanceOf(address(this));

        require(lpTokens > 0, "Invalid LP tokens");
        require(userLpToken[msg.sender] >= lpTokens, "Insufficient LP tokens");
        
        // 计算可提取的代币数量
        amountA = (lpTokens * poolTokenANum) / lpTokenTotalSupply;
        amountB = (lpTokens * poolTokenBNum) / lpTokenTotalSupply;
        
        require(amountA > 0 && amountB > 0, "Insufficient liquidity");
        
        // 更新状态
        userLpToken[msg.sender] -= lpTokens;
        lpTokenTotalSupply -= lpTokens;
        updatePrice();
        
        // 转出代币
        require(IERC20(tokenAAddress).transfer(msg.sender, amountA), "Transfer A failed");
        require(IERC20(tokenBAddress).transfer(msg.sender, amountB), "Transfer B failed");
        
        emit RemoveLiquidity(msg.sender, amountA, amountB, lpTokens);
    }
    
    // 代币兑换 - A换B
    function swapAForB(uint256 amountAIn) external returns (uint256 amountBOut) {
        uint256 poolTokenANum = IERC20(tokenAAddress).balanceOf(address(this));
        uint256 poolTokenBNum = IERC20(tokenBAddress).balanceOf(address(this));

        require(amountAIn > 0, "Invalid amount");
        require(poolTokenANum > 0 && poolTokenBNum > 0, "Pool not initialized");
        
        // 计算手续费后的输入金额
        uint256 amountAInWithFee = amountAIn * (FEE_DENOMINATOR - FEE_RATE) / FEE_DENOMINATOR;
        
        // 根据 x*y=k 模型计算输出金额
        amountBOut = (poolTokenBNum * amountAInWithFee) / (poolTokenANum + amountAInWithFee);
        
        require(amountBOut > 0, "Insufficient output amount");
        require(amountBOut < poolTokenBNum, "Insufficient liquidity");
        
        // 转入代币A
        require(IERC20(tokenAAddress).transferFrom(msg.sender, address(this), amountAIn), "Transfer A failed");
        
        // 转出代币B
        require(IERC20(tokenBAddress).transfer(msg.sender, amountBOut), "Transfer B failed");

        updatePrice();
        
        emit Swap(msg.sender, tokenAAddress, amountAIn, tokenBAddress, amountBOut);
    }
    
    // 代币兑换 - B换A
    function swapBForA(uint256 amountBIn) external returns (uint256 amountAOut) {
        uint256 poolTokenANum = IERC20(tokenAAddress).balanceOf(address(this));
        uint256 poolTokenBNum = IERC20(tokenBAddress).balanceOf(address(this));

        require(amountBIn > 0, "Invalid amount");
        require(poolTokenANum > 0 && poolTokenBNum > 0, "Pool not initialized");
        
        // 计算手续费后的输入金额
        uint256 amountBInWithFee = amountBIn * (FEE_DENOMINATOR - FEE_RATE) / FEE_DENOMINATOR;
        
        // 根据 x*y=k 模型计算输出金额
        amountAOut = (poolTokenANum * amountBInWithFee) / (poolTokenBNum + amountBInWithFee);
        
        require(amountAOut > 0, "Insufficient output amount");
        require(amountAOut < poolTokenANum, "Insufficient liquidity");
        
        // 转入代币B
        require(IERC20(tokenBAddress).transferFrom(msg.sender, address(this), amountBIn), "Transfer B failed");
        
        // 转出代币A
        require(IERC20(tokenAAddress).transfer(msg.sender, amountAOut), "Transfer A failed");

        updatePrice();
        
        emit Swap(msg.sender, tokenBAddress, amountBIn, tokenAAddress, amountAOut);
    }
    
    // 获取兑换报价 - A换B
    function getAmountBOut(uint256 amountAIn) external view returns (uint256 amountBOut) {
        uint256 poolTokenANum = IERC20(tokenAAddress).balanceOf(address(this));
        uint256 poolTokenBNum = IERC20(tokenBAddress).balanceOf(address(this));

        require(amountAIn > 0, "Invalid amount");
        require(poolTokenANum > 0 && poolTokenBNum > 0, "Pool not initialized");
        
        uint256 amountAInWithFee = amountAIn * (FEE_DENOMINATOR - FEE_RATE) / FEE_DENOMINATOR;
        amountBOut = (poolTokenBNum * amountAInWithFee) / (poolTokenANum + amountAInWithFee);
    }
    
    // 获取兑换报价 - B换A
    function getAmountAOut(uint256 amountBIn) external view returns (uint256 amountAOut) {
        uint256 poolTokenANum = IERC20(tokenAAddress).balanceOf(address(this));
        uint256 poolTokenBNum = IERC20(tokenBAddress).balanceOf(address(this));

        require(amountBIn > 0, "Invalid amount");
        require(poolTokenANum > 0 && poolTokenBNum > 0, "Pool not initialized");
        
        uint256 amountBInWithFee = amountBIn * (FEE_DENOMINATOR - FEE_RATE) / FEE_DENOMINATOR;
        amountAOut = (poolTokenANum * amountBInWithFee) / (poolTokenBNum + amountBInWithFee);
    }
    
    // 获取当前汇率
    function getExchangeRate() external view returns (uint256 rateAToB, uint256 rateBToA) {
        uint256 poolTokenANum = IERC20(tokenAAddress).balanceOf(address(this));
        uint256 poolTokenBNum = IERC20(tokenBAddress).balanceOf(address(this));

        if (poolTokenANum > 0 && poolTokenBNum > 0) {
            rateAToB = (poolTokenBNum * 1e18) / (poolTokenANum + 1);
            rateBToA = (poolTokenANum * 1e18) / (poolTokenBNum + 1);
        }
        else {
            rateAToB = 0;
            rateBToA = 0;
        }
    }
    
    // 获取用户LP代币余额
    function getUserLPBalance(address user) external view returns (uint256) {
        return userLpToken[user];
    }
    
    // 获取池子信息
    function getPoolInfo() external view returns (
        uint256 tokenABalance,
        uint256 tokenBBalance,
        uint256 totalLPSupply,
        uint256 k
    ) {

        tokenABalance = IERC20(tokenAAddress).balanceOf(address(this));
        tokenBBalance = IERC20(tokenBAddress).balanceOf(address(this));
        totalLPSupply = lpTokenTotalSupply;
        k = tokenABalance * tokenBBalance;
    }
    
    // 紧急提取函数
    function emergencyWithdraw() external onlyPoolOwner {
        uint256 balanceA = IERC20(tokenAAddress).balanceOf(address(this));
        uint256 balanceB = IERC20(tokenBAddress).balanceOf(address(this));
        
        if (balanceA > 0) {
            IERC20(tokenAAddress).transfer(poolOwner, balanceA);
        }
        if (balanceB > 0) {
            IERC20(tokenBAddress).transfer(poolOwner, balanceB);
        }

        updatePrice();
    }
    
    // 转移池子所有权
    function transferOwnership(address newOwner) external onlyPoolOwner {
        require(newOwner != address(0), "Invalid address");
        poolOwner = newOwner;
    }

    // 闪电贷 A币
    function flashSwapTokenA(uint256 amount, string memory data, address caller) external returns (bool) {

        uint256 usedAmount = IERC20(tokenAAddress).balanceOf(address(this));
        require(usedAmount >= amount, "Not enough money");
        require(IERC20(tokenAAddress).transfer(caller, amount), "Transfer error");
        uint256 Fee = amount * FLASH_SWAP_FEE_PER_THOUSAND / 1000;

        FLASH_SWAP_CALLER(caller).callBack(amount, Fee, data);
        
        uint256 curAmount = IERC20(tokenAAddress).balanceOf(address(this));
        require(curAmount >= usedAmount + Fee, "Do not give back enough money");

        updatePrice();
        return true;
    }

    // 闪电贷 B币
    function flashSwapTokenB(uint256 amount, string memory data, address caller) external returns (bool) {

        uint256 usedAmount = IERC20(tokenBAddress).balanceOf(address(this));
        require(usedAmount >= amount, "Not enough money");
        require(IERC20(tokenBAddress).transfer(caller, amount), "Transfer error");
        uint256 Fee = amount * FLASH_SWAP_FEE_PER_THOUSAND / 1000;

        FLASH_SWAP_CALLER(caller).callBack(amount, Fee, data);
        
        uint256 curAmount = IERC20(tokenBAddress).balanceOf(address(this));
        require(curAmount >= usedAmount + Fee, "Do not give back enough money");

        updatePrice();
        return true;
    }
}
