pragma solidity ^0.4.24;

import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/lifecycle/Pausable.sol";
import "openzeppelin-solidity/contracts/ReentrancyGuard.sol";
import "./ControlToken.sol";
import "./ShareToken.sol";
import "./KyberNetwork.sol";
import "./Utils.sol";

/**
 * @title The main smart contract of the Betoken hedge fund.
 * @author Zefram Lou (Zebang Liu)
 * @dev Need to remove Kairo minting before release
 */
contract BetokenFund is Pausable, Utils, ReentrancyGuard {
  using SafeMath for uint256;

  enum CyclePhase { DepositWithdraw, MakeDecisions, RedeemCommission }

  struct Investment {
    address tokenAddress;
    uint256 cycleNumber;
    uint256 stake;
    uint256 tokenAmount;
    uint256 buyPrice;
    uint256 sellPrice;
    bool isSold;
  }

  /**
   * @notice Executes function only during the given cycle phase.
   * @param phase the cycle phase during which the function may be called
   */
  modifier during(CyclePhase phase) {
    require(cyclePhase == phase);
    _;
  }

  /**
   * @notice Checks if `token` is a valid token.
   * @param token the token's address
   */
  modifier isValidToken(address token) {
    require(!isMaliciousCoin[token]);
    if (token != address(ETH_TOKEN_ADDRESS)) {
      DetailedERC20 _token = DetailedERC20(token);
      require(_token.totalSupply() > 0);
      require(_token.decimals() >= MIN_DECIMALS);
    }
    _;
  }

  // Address of the control token contract.
  address public controlTokenAddr;

  // Address of the share token contract.
  address public shareTokenAddr;

  // Address of the KyberNetwork contract
  address public kyberAddr;

  // Address to which the developer fees will be paid.
  address public developerFeeAccount;

  // Address of the DAI stable-coin contract.
  address public daiAddr;

  // Address of the previous version of BetokenFund.
  address public previousVersion;

  // The number of the current investment cycle.
  uint256 public cycleNumber;

  // The amount of funds held by the fund.
  uint256 public totalFundsInDAI;

  // The start time for the current investment cycle phase, in seconds since Unix epoch.
  uint256 public startTimeOfCyclePhase;

  // The proportion of the fund that gets distributed to Kairo holders every cycle. Fixed point decimal.
  uint256 public commissionRate;

  // The proportion of contract balance that gets distributed to Kairo holders every cycle. Fixed point decimal.
  uint256 public assetFeeRate;

  // The proportion of contract balance that goes the the devs every cycle. Fixed point decimal.
  uint256 public developerFeeRate;

  // The proportion of funds that goes the the devs during withdrawals. Fixed point decimal.
  uint256 public exitFeeRate;

  // Amount of Kairo rewarded to the user who calls a phase transition/investment handling function
  uint256 public functionCallReward;

  // Amount of commission to be paid out this cycle
  uint256 public totalCommission;

  // Flag for whether emergency withdrawing is allowed.
  bool public allowEmergencyWithdraw;

  // Stores the lengths of each cycle phase in seconds.
  uint256[3] phaseLengths;

  // The last cycle where a user redeemed commission.
  mapping(address => uint256) public lastCommissionRedemption;

  // List of investments in the current cycle.
  mapping(address => Investment[]) public userInvestments;

  // Records if a token's contract maliciously treats the BetokenFund differently when calling transfer(), transferFrom(), or approve().
  mapping(address => bool) public isMaliciousCoin;

  // The current cycle phase.
  CyclePhase public cyclePhase;

  // Contract instances
  ControlToken internal cToken;
  ShareToken internal sToken;
  KyberNetwork internal kyber;
  DetailedERC20 internal dai;

  event ChangedPhase(uint256 indexed _cycleNumber, uint256 indexed _newPhase, uint256 _timestamp);

  event Deposit(uint256 indexed _cycleNumber, address indexed _sender, address _tokenAddress, uint256 _tokenAmount, uint256 _daiAmount, uint256 _timestamp);
  event Withdraw(uint256 indexed _cycleNumber, address indexed _sender, address _tokenAddress, uint256 _tokenAmount, uint256 daiAmount, uint256 _timestamp);

  event CreatedInvestment(uint256 indexed _cycleNumber, address indexed _sender, uint256 _id, address _tokenAddress, uint256 _stakeInWeis, uint256 _buyPrice, uint256 _costDAIAmount);
  event SoldInvestment(uint256 indexed _cycleNumber, address indexed _sender, uint256 _investmentId, uint256 _receivedKairos, uint256 _sellPrice, uint256 _earnedDAIAmount);

  event ROI(uint256 indexed _cycleNumber, uint256 _beforeTotalFunds, uint256 _afterTotalFunds);
  event CommissionPaid(uint256 indexed _cycleNumber, address indexed _sender, uint256 _commission);
  event TotalCommissionPaid(uint256 indexed _cycleNumber, uint256 _totalCommissionInWeis);

  /**
   * Contract initialization functions
   */

  // Constructor
  constructor(
    address _cTokenAddr,
    address _sTokenAddr,
    address _kyberAddr,
    address _daiAddr,
    address _developerFeeAccount,
    uint256[3] _phaseLengths,
    uint256 _commissionRate,
    uint256 _assetFeeRate,
    uint256 _developerFeeRate,
    uint256 _exitFeeRate,
    uint256 _functionCallReward,
    address _previousVersion
  )
    public
  {
    require(_commissionRate.add(_developerFeeRate) < 10**18);

    controlTokenAddr = _cTokenAddr;
    shareTokenAddr = _sTokenAddr;
    kyberAddr = _kyberAddr;
    daiAddr = _daiAddr;
    cToken = ControlToken(_cTokenAddr);
    sToken = ShareToken(_sTokenAddr);
    kyber = KyberNetwork(_kyberAddr);
    dai = DetailedERC20(_daiAddr);

    developerFeeAccount = _developerFeeAccount;
    phaseLengths = _phaseLengths;
    commissionRate = _commissionRate;
    assetFeeRate = _assetFeeRate;
    developerFeeRate = _developerFeeRate;
    exitFeeRate = _exitFeeRate;
    startTimeOfCyclePhase = 0;
    cyclePhase = CyclePhase.RedeemCommission;
    functionCallReward = _functionCallReward;
    previousVersion = _previousVersion;
    allowEmergencyWithdraw = false;
  }

  /**
   * Getters
   */

  /**
   * @notice Returns the length of the user's investments array.
   * @return length of the user's investments array
   */
  function investmentsCount(address _userAddr) public view returns(uint256 _count) {
    return userInvestments[_userAddr].length;
  }

  /**
   * @notice Returns the phaseLengths array.
   * @return the phaseLengths array
   */
  function getPhaseLengths() public view returns(uint256[3] _phaseLengths) {
    return phaseLengths;
  }

  /**
   * Meta functions
   */

  /**
   * Emergency functions
   */

  /**
   * @notice Sells token in emergency situations. Only callable by owner.
   * @param _tokenAddr the address of the token to be sold
   */
  function emergencyDumpToken(address _tokenAddr)
    public
    onlyOwner
    whenPaused
  {
    DetailedERC20 token = DetailedERC20(_tokenAddr);
    __kyberTrade(token, getBalance(token, this), dai);
  }

  /**
   * @notice Return staked Kairos for a investment under emergency situations. Should be called by users.
   * @param _investmentId the ID of the investment
   */
  function emergencyRedeemStake(uint256 _investmentId) whenPaused public {
    require(allowEmergencyWithdraw);
    Investment storage investment = userInvestments[msg.sender][_investmentId];
    require(investment.cycleNumber == cycleNumber);
    uint256 stake = investment.stake;
    require(stake > 0);
    delete investment.stake;
    cToken.transfer(msg.sender, stake);
  }

  /**
   * @notice Updates the current fund balance. Only callable by owner.
   */
  function emergencyUpdateBalance() onlyOwner whenPaused public {
    totalFundsInDAI = getBalance(dai, this);
  }

  /**
   * @notice Changes whether emergency withdrawals are allowed. Only callable by owner.
   * @param _newVal the new value
   */
  function setAllowEmergencyWithdraw(bool _newVal) onlyOwner whenPaused public {
    allowEmergencyWithdraw = _newVal;
  }

  /**
   * @notice Function for withdrawing all funds in times of emergency. Only callable when fund is paused and allowEmergencyWithdraw is true.
   */
  function emergencyWithdraw()
    public
    whenPaused
  {
    require(allowEmergencyWithdraw);

    uint256 amountInDAI = getBalance(sToken, msg.sender).mul(totalFundsInDAI).div(sToken.totalSupply());
    sToken.ownerBurn(msg.sender, getBalance(sToken, msg.sender));
    totalFundsInDAI = totalFundsInDAI.sub(amountInDAI);

    // Transfer
    dai.transfer(msg.sender, amountInDAI);

    // Emit event
    emit Withdraw(cycleNumber, msg.sender, daiAddr, amountInDAI, amountInDAI, now);
  }

  /**
   * Parameter setters
   */

  /**
   * @notice Changes the address of the KyberNetwork contract used in the contract. Only callable by owner.
   * @param _newAddr the new address of KyberNetwork contract
   */
  function changeKyberNetworkAddress(address _newAddr) public onlyOwner whenPaused {
    require(_newAddr != address(0));
    kyberAddr = _newAddr;
    kyber = KyberNetwork(_newAddr);
  }

  /**
   * @notice Changes the address to which the developer fees will be sent. Only callable by owner.
   * @param _newAddr the new developer fee address
   */
  function changeDeveloperFeeAccount(address _newAddr) public onlyOwner {
    require(_newAddr != address(0));
    developerFeeAccount = _newAddr;
  }

  /**
  * @notice Changes the address of the DAI token smart contract. Only callable by owner.
  * @param _newAddr the new DAI smart contract address
  */
  function changeDAIAddress(address _newAddr) public onlyOwner whenPaused {
    require(_newAddr != address(0));
    daiAddr = _newAddr;
    dai = DetailedERC20(_newAddr);
  }

  /**
   * @notice Changes the proportion of profits given to Kairo holders each cycle. Only callable by owner.
   * @param _newProp the new proportion, fixed point decimal
   */
  function changeCommissionRate(uint256 _newProp) public onlyOwner {
    require(_newProp < PRECISION);
    commissionRate = _newProp;
  }

  /**
  * @notice Changes the proportion of fund balance given to Kairo holders each cycle. Only callable by owner.
  * @param _newProp the new proportion, fixed point decimal
  */
  function changeAssetFeeRate(uint256 _newProp) public onlyOwner {
    require(_newProp < PRECISION);
    assetFeeRate = _newProp;
  }

  /**
   * @notice Changes the proportion of fund balance sent to the developers each cycle. May only decrease. Only callable by owner.
   * @param _newProp the new proportion, fixed point decimal
   */
  function changeDeveloperFeeRate(uint256 _newProp) public onlyOwner {
    require(_newProp < PRECISION);
    require(_newProp < developerFeeRate);
    developerFeeRate = _newProp;
  }

  /**
   * @notice Changes exit fee rate. May only decrease. Only callable by owner.
   * @param _newProp the new proportion, fixed point decimal
   */
  function changeExitFeeRate(uint256 _newProp) public onlyOwner {
    require(_newProp < PRECISION);
    require(_newProp < exitFeeRate);
    exitFeeRate = _newProp;
  }

  /**
   * @notice Changes the amount of Kairo rewarded to whomever calls nextPhase() the first. Only callable by owner.
   * @param _newVal the new reward value in Kairo, 18 decimals
   */
  function changeCallReward(uint256 _newVal) public onlyOwner {
    functionCallReward = _newVal;
  }

  /**
   * @notice Changes the lengths of the phases in an investment cycle. Only callable by owner.
   * @param _newVal the new set of phase lengths, in the order of DepositWithdraw, MakeDecisions, RedeemCommission, in seconds
   */
  function changePhaseLengths(uint256[3] _newVal) public onlyOwner {
    phaseLengths = _newVal;
  }

  /**
   * @notice Changes the owner of the ControlToken contract. Only callable by owner.
   * @param  _newOwner the new owner address
   */
  function changeControlTokenOwner(address _newOwner) public onlyOwner whenPaused {
    require(_newOwner != address(0));
    cToken.transferOwnership(_newOwner);
  }

  /**
   * @notice Changes the maliciousness status of a token. Only callable by owner.
   * @param _coin the token's address
   * @param _status the new maliciousness status
   */
  function setMaliciousCoinStatus(address _coin, bool _status) public onlyOwner {
    require(_coin != address(0));
    isMaliciousCoin[_coin] = _status;
  }


  /**
   * @notice Moves the fund to the next phase in the investment cycle.
   */
  function nextPhase()
    public
    whenNotPaused
  {
    require(now >= startTimeOfCyclePhase.add(phaseLengths[uint(cyclePhase)]));

    if (cyclePhase == CyclePhase.RedeemCommission) {
      // Start new cycle
      if (cycleNumber == 0) {
        require(msg.sender == owner);
      }

      cycleNumber = cycleNumber.add(1);

      if (cToken.paused()) {
        cToken.unpause();
      }
    } else if (cyclePhase == CyclePhase.MakeDecisions) {
      // Burn any Kairo left in BetokenFund's account
      require(cToken.burnOwnerBalance());

      cToken.pause();
      __distributeFundsAfterCycleEnd();
    }

    cyclePhase = CyclePhase(addmod(uint(cyclePhase), 1, 3));
    startTimeOfCyclePhase = now;

    // Reward caller
    cToken.mint(msg.sender, functionCallReward);

    emit ChangedPhase(cycleNumber, uint(cyclePhase), now);
  }

  /**
   * DepositWithdraw phase functions
   */

  /**
   * @notice Deposit Ether into the fund. Ether will be converted into DAI.
   */
  function deposit()
    public
    payable
    during(CyclePhase.DepositWithdraw)
    whenNotPaused
    nonReentrant
  {
    // Buy DAI with ETH
    uint256 actualDAIDeposited;
    uint256 actualETHDeposited;
    uint256 beforeETHBalance = getBalance(ETH_TOKEN_ADDRESS, this);
    uint256 beforeDAIBalance = getBalance(dai, this);
    __kyberTrade(ETH_TOKEN_ADDRESS, msg.value, dai);
    actualETHDeposited = beforeETHBalance.sub(getBalance(ETH_TOKEN_ADDRESS, this));
    uint256 leftOverETH = msg.value.sub(actualETHDeposited);
    if (leftOverETH > 0) {
      msg.sender.transfer(leftOverETH);
    }
    actualDAIDeposited = getBalance(dai, this).sub(beforeDAIBalance);

    // Register investment
    if (sToken.totalSupply() == 0 || totalFundsInDAI == 0) {
      sToken.mint(msg.sender, actualDAIDeposited);
    } else {
      sToken.mint(msg.sender, actualDAIDeposited.mul(sToken.totalSupply()).div(totalFundsInDAI));
    }
    totalFundsInDAI = totalFundsInDAI.add(actualDAIDeposited);

    // Only for test version. Remove for release.
    cToken.mint(msg.sender, actualDAIDeposited);

    // Emit event
    emit Deposit(cycleNumber, msg.sender, ETH_TOKEN_ADDRESS, actualETHDeposited, actualDAIDeposited, now);
  }

  /**
   * @notice Deposit ERC20 tokens into the fund. Tokens will be converted into DAI.
   * @param _tokenAddr the address of the token to be deposited
   * @param _tokenAmount The amount of tokens to be deposited. May be different from actual deposited amount.
   */
  function depositToken(address _tokenAddr, uint256 _tokenAmount)
    public
    during(CyclePhase.DepositWithdraw)
    isValidToken(_tokenAddr)
    whenNotPaused
    nonReentrant
  {
    DetailedERC20 token = DetailedERC20(_tokenAddr);

    require(token.transferFrom(msg.sender, this, _tokenAmount));

    // Convert token into DAI
    uint256 actualDAIDeposited;
    uint256 actualTokenDeposited;
    if (_tokenAddr == daiAddr) {
      actualDAIDeposited = _tokenAmount;
      actualTokenDeposited = _tokenAmount;
    } else {
      // Buy DAI with tokens
      uint256 beforeTokenBalance = getBalance(token, this);
      uint256 beforeDAIBalance = getBalance(dai, this);
      __kyberTrade(token, _tokenAmount, dai);
      actualTokenDeposited = beforeTokenBalance.sub(getBalance(token, this));
      uint256 leftOverTokens = _tokenAmount.sub(actualTokenDeposited);
      if (leftOverTokens > 0) {
        require(token.transfer(msg.sender, leftOverTokens));
      }
      actualDAIDeposited = getBalance(dai, this).sub(beforeDAIBalance);
      require(actualDAIDeposited > 0);
    }

    // Register investment
    if (sToken.totalSupply() == 0 || totalFundsInDAI == 0) {
      sToken.mint(msg.sender, actualDAIDeposited);
    } else {
      sToken.mint(msg.sender, actualDAIDeposited.mul(sToken.totalSupply()).div(totalFundsInDAI));
    }
    totalFundsInDAI = totalFundsInDAI.add(actualDAIDeposited);

    // Only for test version. Remove for release.
    cToken.mint(msg.sender, actualDAIDeposited);

    // Emit event
    emit Deposit(cycleNumber, msg.sender, _tokenAddr, actualTokenDeposited, actualDAIDeposited, now);
  }

  /**
   * @notice Withdraws Ether by burning Shares.
   * @param _amountInDAI Amount of funds to be withdrawn expressed in DAI. Fixed-point decimal. May be different from actual amount.
   */
  function withdraw(uint256 _amountInDAI)
    public
    during(CyclePhase.DepositWithdraw)
    whenNotPaused
    nonReentrant
  {
    // Buy ETH
    uint256 actualETHWithdrawn;
    uint256 actualDAIWithdrawn;
    uint256 beforeETHBalance = getBalance(ETH_TOKEN_ADDRESS, this);
    uint256 beforeDaiBalance = getBalance(dai, this);
    __kyberTrade(dai, _amountInDAI, ETH_TOKEN_ADDRESS);
    actualETHWithdrawn = getBalance(ETH_TOKEN_ADDRESS, this).sub(beforeETHBalance);
    actualDAIWithdrawn = beforeDaiBalance.sub(getBalance(dai, this));
    require(actualDAIWithdrawn > 0);

    // Burn shares
    sToken.ownerBurn(msg.sender, actualDAIWithdrawn.mul(sToken.totalSupply()).div(totalFundsInDAI));
    totalFundsInDAI = totalFundsInDAI.sub(actualDAIWithdrawn);

    // Transfer Ether to user
    uint256 exitFee = actualETHWithdrawn.mul(exitFeeRate).div(PRECISION);
    developerFeeAccount.transfer(exitFee);
    actualETHWithdrawn = actualETHWithdrawn.sub(exitFee);
    msg.sender.transfer(actualETHWithdrawn);

    // Emit event
    emit Withdraw(cycleNumber, msg.sender, ETH_TOKEN_ADDRESS, actualETHWithdrawn, actualDAIWithdrawn, now);
  }

  /**
   * @notice Withdraws funds by burning Shares, and converts the funds into the specified token using Kyber Network.
   * @param _tokenAddr the address of the token to be withdrawn into the caller's account
   * @param _amountInDAI The amount of funds to be withdrawn expressed in DAI. Fixed-point decimal. May be different from actual amount.
   */
  function withdrawToken(address _tokenAddr, uint256 _amountInDAI)
    public
    during(CyclePhase.DepositWithdraw)
    isValidToken(_tokenAddr)
    whenNotPaused
    nonReentrant
  {
    DetailedERC20 token = DetailedERC20(_tokenAddr);

    // Convert DAI into desired tokens
    uint256 actualTokenWithdrawn;
    uint256 actualDAIWithdrawn;
    if (_tokenAddr == daiAddr) {
      actualDAIWithdrawn = _amountInDAI;
      actualTokenWithdrawn = _amountInDAI;
    } else {
      // Buy desired tokens
      uint256 beforeTokenBalance = getBalance(token, this);
      uint256 beforeDaiBalance = getBalance(dai, this);
      __kyberTrade(dai, _amountInDAI, token);
      actualTokenWithdrawn = getBalance(token, this).sub(beforeTokenBalance);
      actualDAIWithdrawn = beforeDaiBalance.sub(getBalance(dai, this));
      require(actualDAIWithdrawn > 0);
    }

    // Burn Shares
    sToken.ownerBurn(msg.sender, actualDAIWithdrawn.mul(sToken.totalSupply()).div(totalFundsInDAI));
    totalFundsInDAI = totalFundsInDAI.sub(actualDAIWithdrawn);

    // Transfer tokens to user
    uint256 exitFee = actualTokenWithdrawn.mul(exitFeeRate).div(PRECISION);
    token.transfer(developerFeeAccount, exitFee);
    actualTokenWithdrawn = actualTokenWithdrawn.sub(exitFee);
    token.transfer(msg.sender, actualTokenWithdrawn);

    // Emit event
    emit Withdraw(cycleNumber, msg.sender, _tokenAddr, actualTokenWithdrawn, actualDAIWithdrawn, now);
  }

  /**
   * MakeDecisions phase functions
   */

  /**
   * @notice Creates a new investment investment for an ERC20 token.
   * @param _tokenAddress address of the ERC20 token contract
   * @param _stake amount of Kairos to be staked in support of the investment
   */
  function createInvestment(
    address _tokenAddress,
    uint256 _stake
  )
    public
    during(CyclePhase.MakeDecisions)
    isValidToken(_tokenAddress)
    whenNotPaused
    nonReentrant
  {
    DetailedERC20 token = DetailedERC20(_tokenAddress);

    // Collect stake
    require(cToken.ownerCollectFrom(msg.sender, _stake));

    // Add investment to list
    userInvestments[msg.sender].push(Investment({
      tokenAddress: _tokenAddress,
      cycleNumber: cycleNumber,
      stake: _stake,
      tokenAmount: 0,
      buyPrice: 0,
      sellPrice: 0,
      isSold: false
    }));

    // Invest
    uint256 beforeTokenAmount = getBalance(token, this);
    uint256 beforeDAIBalance = getBalance(dai, this);
    uint256 investmentId = investmentsCount(msg.sender).sub(1);
    __handleInvestment(investmentId, true);
    userInvestments[msg.sender][investmentId].tokenAmount = getBalance(token, this).sub(beforeTokenAmount);

    // Emit event
    emit CreatedInvestment(cycleNumber, msg.sender, investmentsCount(msg.sender).sub(1), _tokenAddress, _stake, userInvestments[msg.sender][investmentId].buyPrice, beforeDAIBalance.sub(getBalance(dai, this)));
  }

  /**
   * @notice Called by user to sell the assets an investment invested in. Returns the staked Kairo plus rewards/penalties.
   * @param _investmentId the ID of the investment
   */
  function sellInvestmentAsset(uint256 _investmentId)
    public
    during(CyclePhase.MakeDecisions)
    whenNotPaused
    nonReentrant
  {
    Investment storage investment = userInvestments[msg.sender][_investmentId];
    require(investment.buyPrice > 0);
    require(investment.cycleNumber == cycleNumber);
    require(!investment.isSold);

    investment.isSold = true;

    // Sell asset
    uint256 beforeDAIBalance = getBalance(dai, this);
    __handleInvestment(_investmentId, false);

    // Return Kairo
    uint256 multiplier = investment.sellPrice.mul(PRECISION).div(investment.buyPrice);
    uint256 receiveKairoAmount = investment.stake.mul(multiplier).div(PRECISION);
    if (receiveKairoAmount > investment.stake) {
      cToken.transfer(msg.sender, investment.stake);
      cToken.mint(msg.sender, receiveKairoAmount.sub(investment.stake));
    } else {
      cToken.transfer(msg.sender, receiveKairoAmount);
      require(cToken.burnOwnerTokens(investment.stake.sub(receiveKairoAmount)));
    }

    // Emit event
    emit SoldInvestment(cycleNumber, msg.sender, _investmentId, receiveKairoAmount, investment.sellPrice, getBalance(dai, this).sub(beforeDAIBalance));
  }

  /**
   * RedeemCommission phase functions
   */

  /**
   * @notice Redeems commission.
   */
  function redeemCommission()
    public
    during(CyclePhase.RedeemCommission)
    whenNotPaused
    nonReentrant
  {
    require(lastCommissionRedemption[msg.sender] < cycleNumber);
    lastCommissionRedemption[msg.sender] = cycleNumber;
    uint256 commission = totalCommission.mul(getBalance(cToken, msg.sender)).div(cToken.totalSupply());
    dai.transfer(msg.sender, commission);

    delete userInvestments[msg.sender];

    emit CommissionPaid(cycleNumber, msg.sender, commission);
  }

  /**
   * @notice Redeems commission in shares.
   */
  function redeemCommissionInShares()
    public
    during(CyclePhase.RedeemCommission)
    whenNotPaused
    nonReentrant
  {
    require(lastCommissionRedemption[msg.sender] < cycleNumber);
    lastCommissionRedemption[msg.sender] = cycleNumber;
    uint256 commission = totalCommission.mul(getBalance(cToken, msg.sender)).div(cToken.totalSupply());
    sToken.mint(msg.sender, commission.mul(sToken.totalSupply()).div(totalFundsInDAI));
    totalFundsInDAI = totalFundsInDAI.add(commission);

    delete userInvestments[msg.sender];

    // Emit event
    emit Deposit(cycleNumber, msg.sender, daiAddr, commission, commission, now);
    emit CommissionPaid(cycleNumber, msg.sender, commission);
  }

  /**
   * @notice Sells tokens left over due to manager not selling or KyberNetwork not having enough demand. Callable by anyone.
   * @param _tokenAddr address of the token to be sold
   */
  function sellLeftoverToken(address _tokenAddr)
    public
    during(CyclePhase.RedeemCommission)
    isValidToken(_tokenAddr)
    whenNotPaused
    nonReentrant
  {
    uint256 beforeBalance = getBalance(dai, this);
    DetailedERC20 token = DetailedERC20(_tokenAddr);
    __kyberTrade(token, getBalance(token, this), dai);
    totalFundsInDAI = totalFundsInDAI.add(getBalance(dai, this).sub(beforeBalance));
  }

  /**
   * Internal use functions
   */

  /**
   * @notice Update fund statistics, and pay developer fees.
   */
  function __distributeFundsAfterCycleEnd() internal {
    uint256 profit = 0;
    if (getBalance(dai, this) > totalFundsInDAI) {
      profit = getBalance(dai, this).sub(totalFundsInDAI);
    }
    totalCommission = commissionRate.mul(profit).div(PRECISION);
    totalCommission = totalCommission.add(assetFeeRate.mul(getBalance(dai, this)).div(PRECISION));
    uint256 devFee = developerFeeRate.mul(getBalance(dai, this)).div(PRECISION);
    uint256 newTotalFunds = getBalance(dai, this).sub(totalCommission).sub(devFee);

    // Update values
    emit ROI(cycleNumber, totalFundsInDAI, newTotalFunds);
    totalFundsInDAI = newTotalFunds;

    // Transfer fees
    dai.transfer(developerFeeAccount, devFee);

    // Emit event
    emit TotalCommissionPaid(cycleNumber, totalCommission);
  }

  function __handleInvestment(uint256 _investmentId, bool _buy) internal {
    Investment storage investment = userInvestments[msg.sender][_investmentId];
    uint256 srcAmount;
    if (_buy) {
      srcAmount = totalFundsInDAI.mul(investment.stake).div(cToken.totalSupply());
    } else {
      srcAmount = investment.tokenAmount;
    }
    DetailedERC20 token = DetailedERC20(investment.tokenAddress);
    if (_buy) {
      investment.buyPrice = __kyberTrade(dai, srcAmount, token);
    } else {
      investment.sellPrice = invert(__kyberTrade(token, srcAmount, dai));
    }
  }

  /**
   * @notice Wrapper function for doing token conversion on Kyber Network
   * @param _srcToken the token to convert from
   * @param _srcAmount the amount of tokens to be converted
   * @param _destToken the destination token
   * @return _destPriceInSrc the price of the destination token, in terms of source tokens
   */
  function __kyberTrade(DetailedERC20 _srcToken, uint256 _srcAmount, DetailedERC20 _destToken) internal returns(uint256 _destPriceInSrc) {
    require(_srcToken != _destToken);
    uint256 actualDestAmount;
    uint256 beforeSrcBalance = getBalance(_srcToken, this);
    uint256 msgValue;

    if (_srcToken != ETH_TOKEN_ADDRESS) {
      msgValue = 0;
      _srcToken.approve(kyberAddr, 0);
      _srcToken.approve(kyberAddr, _srcAmount);
    } else {
      msgValue = _srcAmount;
    }
    actualDestAmount = kyber.trade.value(msgValue)(
      _srcToken,
      _srcAmount,
      _destToken,
      this,
      MAX_QTY,
      1,
      0
    );
    require(actualDestAmount > 0);
    if (_srcToken != ETH_TOKEN_ADDRESS) {
      _srcToken.approve(kyberAddr, 0);
    }

    _destPriceInSrc = beforeSrcBalance.sub(getBalance(_srcToken, this)).mul(PRECISION).mul(10**getDecimals(_destToken)).div(actualDestAmount.mul(10**getDecimals(_srcToken)));
  }

  function() public payable {
    if (msg.sender != kyberAddr) {
      revert();
    }
  }
}