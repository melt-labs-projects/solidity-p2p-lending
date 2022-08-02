// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.1;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract MainController is Ownable, Pausable, ReentrancyGuard, ERC721Holder{
    using SafeERC20 for IERC20;

    struct OfferInfo{
        address collection; //collection of the nft that you want to deposit
        uint idNft; //id of the nft that you want to deposit
        uint loanAmount; //amount that you want to ask for the nft, the amount is paid in the loanCurrency
        uint loanTimeStart; //this is set to 0 at the start, if the loan starts it is equal to block.timestamp
        uint loanTimeDuration; //the duration of the loan in days
        uint loanAPR; // the apr of the loan, the apr is annualized, so if you want a 30 day loan and a 12% apr, the actual apr of the loan will be 1%
        ControlFlags controlFlags; //flags to check requirements in the offer
        address loanCurrency; //currency used for the loan
        address borrower; // address of the borrower
        address lender; //address of the lender
    }

    struct ControlFlags{
        bool repayed; //flag used to check if the offer has been repayed
        bool withdrawn; //flag used to check if the offer has been withdrawn
        bool borrowed; //flag used to check if the borrower has already withdrawn his laon
        bool empty; //flag to check if the nft has already been withdrawn
    }

    mapping(address => uint) public offerPerAddress; //variable to check how many offer a particular address has
    mapping(address => mapping(uint => OfferInfo)) public offerInfo; //variable to check an offer by providing a collection and an id
    mapping(address => mapping(address => uint[])) public collectionInfoPerAddress; //variable to check the id of a particular collection deposited by a particular address
    mapping(address => bool) public allowedCollections; //whitelisted collections
    mapping(address => bool) public allowedCurrency; //whitelisted currencies
    uint public collectionLength; //number of whitelisted collections
    uint public currencyLength; //number of whitelisted currencies
    uint public totalOffers; //number of totalOffers
    event WhitelistCollection(address indexed collection);
    event WhitelistCurrency(address indexed currency);
    event CreateOffer(address indexed collection, uint indexed idNft, address indexed user, uint loanAmount, uint loanTimeDuration, uint loanAPR, address loanCurrency);
    event WhitdrawOffer(address indexed collection, uint indexed idNft, address indexed user, uint loanAmount, uint loanTimeDuration, uint loanAPR, address loanCurrency, address borrower);
    event AcceptOffer(address indexed collection, uint indexed idNft, address indexed user, uint loanAmount, uint loanTimeDuration, uint loanAPR, address loanCurrency, address borrower, address lender, uint loanTimeStart);
    event RepayOffer(address indexed collection, uint indexed idNft, address indexed user, uint loanAmount, uint loanTimeDuration, uint loanAPR, address loanCurrency, address borrower, address lender, uint loanTimeStart);
    event Borrow(address indexed collection, uint indexed idNft, address indexed user, uint loanAmount, uint loanTimeDuration, uint loanAPR, address loanCurrency, address borrower, address lender, uint loanTimeStart);
    event WithdrawNFT(address indexed collection, uint indexed idNft, address indexed user, uint loanAmount, uint loanTimeDuration, uint loanAPR, address loanCurrency, address borrower, address lender, uint loanTimeStart);
    event WithdrawDeposit(address indexed collection, uint indexed idNft, address indexed user, uint loanAmount, uint loanTimeDuration, uint loanAPR, address loanCurrency, address borrower, address lender, uint loanTimeStart);

    constructor(){}

    /**
     * @dev checking that the address call the method is the borrower for that offer
     */
    modifier onlyBorrower(address _collection, uint _idNft) {
        OfferInfo memory offer = offerInfo[_collection][_idNft];
        require(msg.sender == offer.borrower, "ERROR: you are not the borrower");
        _;
    }

    /**
     * @dev checking that the address call the method is the lender for that offer
     */
    modifier onlyLender(address _collection, uint _idNft) {
        OfferInfo memory offer = offerInfo[_collection][_idNft];
        require(msg.sender == offer.lender, "ERROR: you are not the lender");
        _;
    }

    /**
     * @dev checking that the offer has not been withdrawn
     */
    modifier notWithdrawn(address _collection, uint _idNft){
        OfferInfo memory offer = offerInfo[_collection][_idNft];
        require(!offer.controlFlags.withdrawn, "ERROR: the offer has been withdrawn");
        _;
    }

    /**
     * @dev checking that the offer has no lender yet
     */
    modifier notStarted(address _collection, uint _idNft){
        OfferInfo memory offer = offerInfo[_collection][_idNft];
        require(offer.lender == address(0) && offer.loanTimeStart == 0, "ERROR: the offer already started");
        _;
    }

    /**
     * @dev checking that the offer exists
     */
    modifier offerExist(address _collection, uint _idNft){
        OfferInfo memory offer = offerInfo[_collection][_idNft];
        require(offer.borrower != address(0), "ERROR: the offer doesn't exists");
        _;
    }

    //TODO add unwhitelist functions

    /**
     * @dev 
     * whitelisting a collection
     * @param
     * _collection: the address of the collection that is being whitelisted
     */
    function whitelistCollection(address _collection) external onlyOwner{
        allowedCollections[_collection] = true;
        collectionLength += 1;
        emit WhitelistCollection(_collection);
    }

    /**
     * @dev 
     * whitelisting a currencies
     * @param
     * _currency: the address of the currency that is being whitelisted
     */
    function whitelistCurrency(address _currency) external onlyOwner{
        allowedCurrency[_currency] = true;
        currencyLength += 1;
        emit WhitelistCollection(_currency);
    }

    /**
     * @dev 
     * creating an offer
     * for the offer to be created there are condition that needs to be met:
     * -the contract cannot be suspended
     * -the _collection and _currency needs to be whitelisted
     * -the loanAmount needs to be higher than 10000 (0.0000000000001) because we will need to modify this number for the yield function
     * -the loanTimeDuration is higher than 0
     * @param
     * _collection: address of the collection for the offer
     * _idNFT: id of the nft
     * _loanAmount: loan requested
     * _loanTimeDuration: duration of the loan in days
     * _loanAPR: apr for the loan
     * _loanCurrency: currency for the loan
     */
    function createOffer(address _collection, uint _idNft, uint _loanAmount, uint _loanTimeDuration, uint _loanAPR, address _loanCurrency) external whenNotPaused nonReentrant{ 
        require(allowedCollections[_collection], "ERROR: the collection used is not whitelisted");
        require(allowedCurrency[_loanCurrency], "ERROR: the currency used is not whitelisted");
        require(_loanAmount >= 100000, "ERROR: the loan is too small");
        require(_loanTimeDuration > 0, "ERROR: the loan time duration can't be 0");
        offerInfo[_collection][_idNft] = OfferInfo(_collection, _idNft, _loanAmount, 0, _loanTimeDuration, _loanAPR, ControlFlags(false, false, false, false), _loanCurrency, msg.sender, address(0));
        collectionInfoPerAddress[msg.sender][_collection].push(_idNft);
        IERC721(_collection).safeTransferFrom(msg.sender, address(this), _idNft);
        offerPerAddress[msg.sender] += 1;
        totalOffers += 1;
        emit CreateOffer(_collection, _idNft, msg.sender, _loanTimeDuration, _loanAPR, _loanAmount, _loanCurrency);
    }

    /**
     * @dev 
     * withdraw an offer
     * for the offer to be withdrawn there are condition that needs to be met:
     * -the offer could not have a lender and a timestart
     * -this function can only be called by the address that created the offer
     * @param
     * _collection: address of the collection for the offer
     * _idNFT: id of the nft
     */
    function withdrawOffer(address _collection, uint _idNft) external offerExist(_collection, _idNft) notStarted(_collection, _idNft) onlyBorrower(_collection, _idNft) nonReentrant{
        OfferInfo storage offer = offerInfo[_collection][_idNft];
        IERC721(_collection).safeTransferFrom(address(this), offer.borrower, _idNft);
        offer.controlFlags.withdrawn = true;
        totalOffers -= 1;
        emit WhitdrawOffer(_collection, _idNft, msg.sender, offer.loanTimeDuration, offer.loanAPR, offer.loanAmount, offer.loanCurrency, offer.borrower);
    }

    /**
     * @dev 
     * accept an offer
     * for the offer to be accepted there are condition that needs to be met:
     * -the offer could not have been withdrawn
     * -the offer could not have a lender and a timestart
     * -tthe contract cannot be paused
     * @param
     * _collection: address of the collection for the offer
     * _idNFT: id of the nft
     */
    function acceptOffer(address _collection, uint _idNft) external offerExist(_collection, _idNft) notStarted(_collection, _idNft) notWithdrawn(_collection, _idNft) whenNotPaused nonReentrant{
        OfferInfo storage offer = offerInfo[_collection][_idNft];
        offer.loanTimeStart = block.timestamp;
        offer.lender = msg.sender;
        IERC20(offer.loanCurrency).transferFrom(offer.lender, address(this), offer.loanAmount);
        emit AcceptOffer(_collection, _idNft, msg.sender, offer.loanTimeDuration, offer.loanAPR, offer.loanAmount, offer.loanCurrency, offer.borrower, offer.lender, offer.loanTimeStart);
    }

    /**
     * @dev 
     * rapaying an offer
     * for the offer to be repayed there are condition that needs to be met:
     * -the offer could not have been withdrawn
     * -this function can only be called by the address that created the offer
     * -the offer has not already been repayed
     * -the contract has the nft (the offer is not empty)
     * @param
     * _collection: address of the collection for the offer
     * _idNFT: id of the nft
     */
    function repayOffer(address _collection, uint _idNft) external offerExist(_collection, _idNft) onlyBorrower(_collection, _idNft) nonReentrant{
        OfferInfo storage offer = offerInfo[_collection][_idNft];
        require(!offer.controlFlags.repayed, "ERROR: the offer has already been repayed");
        require(!offer.controlFlags.empty, "ERROR: the offer has already expired and the NFT has been transfered to the lender");
        offer.controlFlags.repayed = true;
        IERC20(offer.loanCurrency).transferFrom(offer.borrower, address(this), yield(offer.collection, offer.idNft)); // stack too deep to use _collection and _idNft
        emit RepayOffer(_collection, _idNft, msg.sender, offer.loanTimeDuration, offer.loanAPR, offer.loanAmount, offer.loanCurrency, offer.borrower, offer.lender, offer.loanTimeStart);
    }

    /**
     * @dev 
     * borrowing from an offer
     * for the address to borrow from the offer there are conditions that needs to be met:
     * -this function can only be called by the address that created the offer
     * @param
     * _collection: address of the collection for the offer
     * _idNFT: id of the nft
     */
    function borrow(address _collection, uint _idNft) offerExist(_collection, _idNft) onlyBorrower(_collection, _idNft) external nonReentrant{
        OfferInfo storage offer = offerInfo[_collection][_idNft];
        require(offer.lender != address(0) && offer.loanTimeStart != 0, "ERROR: the offer has not started");
        require(!offer.controlFlags.borrowed, "ERROR: the amount has already been borrowed");
        offer.controlFlags.borrowed = true;
        IERC20(offer.loanCurrency).transfer(offer.borrower, offer.loanAmount);
        emit Borrow(_collection, _idNft, msg.sender, offer.loanTimeDuration, offer.loanAPR, offer.loanAmount, offer.loanCurrency, offer.borrower, offer.lender, offer.loanTimeStart);
    }

    /**
     * @dev 
     * withdraw an NFT
     * for the NFT to be withdrawn there are condition that needs to be met:
     * -time start of the offer plus offer duration is smaller than the actual block.timestamp 
     * -if the offer has been repayed only the borrower can withdraw the NFT otherwise only the lender can withdraw the NFT
     * @param
     * _collection: address of the collection for the offer
     * _idNFT: id of the nft
     */
    function withdrawNFT(address _collection, uint _idNft) external offerExist(_collection, _idNft) nonReentrant{
        OfferInfo storage offer = offerInfo[_collection][_idNft];
        if(offer.controlFlags.repayed){
            require(msg.sender == offer.borrower, "ERROR: you are not the borrower");
            IERC721(_collection).safeTransferFrom(address(this), offer.borrower, _idNft);
            offer.controlFlags.empty = true;
            emit WithdrawNFT(_collection, _idNft, msg.sender, offer.loanTimeDuration, offer.loanAPR, offer.loanAmount, offer.loanCurrency, offer.borrower, offer.lender, offer.loanTimeStart);
        }else{
            require(block.timestamp > offer.loanTimeStart + offer.loanTimeDuration * 1 days, "ERROR: the offer has not ended");
            require(msg.sender == offer.lender, "ERROR: you are not the lender");
            IERC721(_collection).safeTransferFrom(address(this), offer.lender, _idNft);
            offer.controlFlags.empty = true;
            emit WithdrawNFT(_collection, _idNft, msg.sender, offer.loanTimeDuration, offer.loanAPR, offer.loanAmount, offer.loanCurrency, offer.borrower, offer.lender, offer.loanTimeStart);
        }
    }

    /**
     * @dev 
     * withdraw the currency
     * to withdraw the currency there are condition that needs to be met:
     * -time start of the offer plus offer duration is smaller than the actual block.timestamp 
     * -the offer needs to have been repayed by the borrower
     * @param
     * _collection: address of the collection for the offer
     * _idNFT: id of the nft
     */
    function withdrawDeposit(address _collection, uint _idNft) external offerExist(_collection, _idNft) onlyLender(_collection, _idNft) nonReentrant{
        OfferInfo storage offer = offerInfo[_collection][_idNft];
        require(offer.controlFlags.repayed, "ERROR: the offer has not been repayed yet by the borrower");
        IERC20(offer.loanCurrency).transfer(offer.lender, yield(_collection, _idNft));
        emit WithdrawDeposit(_collection, _idNft, msg.sender, offer.loanTimeDuration, offer.loanAPR, offer.loanAmount, offer.loanCurrency, offer.borrower, offer.lender, offer.loanTimeStart);
    }

    /**
     * @dev 
     * calculating the yield based on the desired apr, the desired duration and the loan amount
     * @param
     * _collection: address of the collection for the offer
     * _idNFT: id of the nft
     * @return
     * uint: the yield based on the loan amount, loan duration and loan apr
     */
    function yield(address _collection, uint _idNft) public view returns(uint){
        OfferInfo memory offer = offerInfo[_collection][_idNft];
        return offer.loanAmount + (offer.loanAmount / 100000) * (((offer.loanAPR * 1000) / 365) * offer.loanTimeDuration); //(loanamount/100000) * (((loanapr * 1000)/365) * loantimeduration) 
    }

    function pause() external onlyOwner{
        _pause();
    }

    function unpause() external onlyOwner{
        _unpause();
    }

}