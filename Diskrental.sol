// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.0/contracts/utils/ReentrancyGuard.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.0/contracts/access/Ownable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.0/contracts/utils/Pausable.sol";

/**
 * @title  DiskSpaceRental
 * @notice Decentralised storage marketplace with provider collateral,
 *         escrow, renter confirmation, and slash-to-renter dispute resolution.

 * Stack-too-deep fix
 
 * The 14-field Rental struct caused EVM stack overflow during compilation.
 * It is now split into two mappings:
 *   • RentalCore      — parties, timing, capacity, status, flags
 *   • RentalFinancials — payment amounts (all uint256 money fields)
 * Functions load only the mapping they need, keeping stack usage low.
 
 * All other fixes carried forward:
 *   [C1] Collateral locked per rental
 *   [C2] receive() reverts
 *   [M1] Cancel deducts platform fee
 *   [M2] acknowledgeRental + ACK_TIMEOUT (now nonReentrant)
 *   [M3] Slash goes to renter
 *   [L1] pragma ^0.8.29
 *   [L2] listingExists modifier
 *   [L3] accessEndpoint stored as bytes32
 *   [L4] resolveDispute underflow guard
 *   [L5] Paginated array getters
 */
contract DiskSpaceRental is ReentrancyGuard, Ownable, Pausable {

    
    //  CONSTANTS
    

    uint256 public constant MIN_LISTING_GB            = 1;
    uint256 public constant MAX_LISTING_GB            = 100_000;
    uint256 public constant MIN_DURATION_DAYS         = 1;
    uint256 public constant MAX_DURATION_DAYS         = 365;
    uint256 public constant PLATFORM_FEE_BPS          = 250;       // 2.5%
    uint256 public constant BPS_DENOMINATOR           = 10_000;
    uint256 public constant PROVIDER_COLLATERAL_RATIO = 20;        // 20% of 30-day value
    uint256 public constant SLASH_PENALTY_BPS         = 5_000;     // 50% of locked collateral
    uint256 public constant CANCEL_GRACE_PERIOD       = 1 hours;
    uint256 public constant ACK_TIMEOUT               = 48 hours;
    uint256 public constant DISPUTE_WINDOW            = 24 hours;  // post-endTime dispute grace

    
    //  ENUMS
    

    enum ListingStatus  { Active, Paused, Removed }
    enum RentalStatus   { Active, Completed, Disputed, Resolved, Cancelled }
    enum DisputeOutcome { Pending, ProviderWins, RenterWins }

    // ─────────────────────────────────────────────────────────────
    //  STRUCTS  (kept small — no struct exceeds ~8 meaningful fields)
    // ─────────────────────────────────────────────────────────────

    struct StorageListing {
        address       provider;
        uint96        collateralDeposited; // packed with provider into one slot
        uint256       id;
        uint256       capacityGB;
        uint256       availableGB;
        uint256       pricePerGBPerDay;
        uint256       lockedCollateral;
        bytes32       metadataCID;         // IPFS CID hash — resolve off-chain
        string        region;
        ListingStatus status;
        uint256       createdAt;
    }

    // ── Rental split into two structs to avoid stack-too-deep ────

    /// Parties, timing, identifiers, flags
    struct RentalCore {
        address      provider;
        address      renter;
        uint256      listingId;
        uint256      capacityGB;
        uint256      durationDays;
        uint256      startTime;
        uint256      endTime;
        RentalStatus status;
        bool         renterAcknowledged;
        bytes32      accessEndpointHash;  // [L3] keccak256 of endpoint — store full string off-chain
    }

    /// All monetary fields
    struct RentalFinancials {
        uint256 pricePerGBPerDay;
        uint256 totalPayment;
        uint256 platformFee;
        uint256 providerCollateral;
    }

    struct Dispute {
        address        initiator;
        uint256        rentalId;
        uint256        raisedAt;
        uint256        resolvedAt;
        string         reason;
        DisputeOutcome outcome;
        address        resolver;
    }

    
    //  STATE
    

    uint256 private _listingCounter;
    uint256 private _rentalCounter;

    mapping(uint256 => StorageListing)  public listings;
    mapping(uint256 => RentalCore)      public rentalCores;
    mapping(uint256 => RentalFinancials) public rentalFinancials;
    mapping(uint256 => Dispute)         public disputes;

    mapping(address => uint256[]) private _providerListings;
    mapping(address => uint256[]) private _renterHistory;
    mapping(address => uint256[]) private _providerRentals;

    uint256 public platformTreasury;

    // ─────────────────────────────────────────────────────────────
    //  EVENTS
    // ─────────────────────────────────────────────────────────────

    event ListingCreated(uint256 indexed listingId, address indexed provider, uint256 capacityGB, uint256 pricePerGBPerDay);
    event ListingUpdated(uint256 indexed listingId, uint256 newPrice, ListingStatus status);
    event ListingRemoved(uint256 indexed listingId);

    event RentalCreated(uint256 indexed rentalId, uint256 indexed listingId, address indexed renter, uint256 capacityGB, uint256 durationDays, uint256 totalPayment);
    event RentalAcknowledged(uint256 indexed rentalId, address indexed renter);
    event RentalCompleted(uint256 indexed rentalId, uint256 providerPayout, uint256 platformFee);
    event RentalCancelled(uint256 indexed rentalId, uint256 refundAmount, uint256 platformFeeCharged);

    event DisputeRaised(uint256 indexed rentalId, address indexed initiator, string reason);
    event DisputeResolved(uint256 indexed rentalId, DisputeOutcome outcome, address resolver);

    event CollateralDeposited(uint256 indexed listingId, address indexed provider, uint256 amount);
    event CollateralWithdrawn(uint256 indexed listingId, address indexed provider, uint256 amount);
    event PlatformFeesWithdrawn(address indexed to, uint256 amount);

    // ─────────────────────────────────────────────────────────────
    //  CONSTRUCTOR
    // ─────────────────────────────────────────────────────────────

    constructor() Ownable(msg.sender) {}

    // ─────────────────────────────────────────────────────────────
    //  MODIFIERS
    // ─────────────────────────────────────────────────────────────

    modifier listingExists(uint256 listingId) {
        require(listings[listingId].createdAt != 0, "Listing not found");
        _;
    }
 
    modifier onlyListingProvider(uint256 listingId) {
        require(listings[listingId].provider == msg.sender, "Not listing provider");
        _;
    }

    modifier onlyRentalParty(uint256 rentalId) {
        RentalCore storage rc = rentalCores[rentalId];
        require(rc.renter == msg.sender || rc.provider == msg.sender, "Not rental party");
        _;
    }

    modifier rentalExists(uint256 rentalId) {
        require(rentalCores[rentalId].startTime != 0, "Rental not found");
        _;
    }

    
    //  PROVIDER: LISTING MANAGEMENT
    

    /**
     * @notice Create a listing. Provider deposits collateral = 20% of 30-day deal value.
     * @param metadataCID  bytes32 IPFS CID hash — resolve off-chain.
     */
    function createListing(
        uint256         capacityGB,
        uint256         pricePerGBPerDay,
        string calldata region,
        bytes32         metadataCID
    ) external payable whenNotPaused returns (uint256 listingId) {
        require(capacityGB >= MIN_LISTING_GB && capacityGB <= MAX_LISTING_GB, "Invalid capacity");
        require(pricePerGBPerDay > 0, "Price must be > 0");

        uint256 required = _requiredCollateral(capacityGB, pricePerGBPerDay);
        require(msg.value >= required,               "Insufficient collateral");
        require(msg.value <= type(uint96).max,       "Collateral overflow");

        listingId = ++_listingCounter;

        listings[listingId] = StorageListing({
            id:                  listingId,
            provider:            msg.sender,
            capacityGB:          capacityGB,
            availableGB:         capacityGB,
            pricePerGBPerDay:    pricePerGBPerDay,
            collateralDeposited: uint96(msg.value),
            lockedCollateral:    0,
            region:              region,
            metadataCID:         metadataCID,
            status:              ListingStatus.Active,
            createdAt:           block.timestamp
        });

        _providerListings[msg.sender].push(listingId);

        emit ListingCreated(listingId, msg.sender, capacityGB, pricePerGBPerDay);
        emit CollateralDeposited(listingId, msg.sender, msg.value);
    }

    /**
     * @notice Update listing price or status.
     */
    function updateListing(
        uint256       listingId,
        uint256       newPricePerGBPerDay,
        ListingStatus newStatus
    ) external listingExists(listingId) onlyListingProvider(listingId) {
        StorageListing storage l = listings[listingId];
        require(l.status != ListingStatus.Removed, "Listing removed");
        require(newStatus != ListingStatus.Removed, "Use removeListing()");

        if (newPricePerGBPerDay > 0) l.pricePerGBPerDay = newPricePerGBPerDay;
        l.status = newStatus;

        emit ListingUpdated(listingId, l.pricePerGBPerDay, newStatus);
    }

    /**
     * @notice Permanently remove listing and withdraw free collateral.
     */
    function removeListing(uint256 listingId)
        external
        listingExists(listingId)
        onlyListingProvider(listingId)
        nonReentrant
    {
        StorageListing storage l = listings[listingId];
        require(l.status != ListingStatus.Removed, "Already removed");
        require(l.availableGB == l.capacityGB,     "Active rentals exist");

        uint256 refund = l.collateralDeposited;
        l.collateralDeposited = 0;
        l.status = ListingStatus.Removed;

        (bool ok,) = payable(msg.sender).call{value: refund}("");
        require(ok, "Collateral refund failed");

        emit ListingRemoved(listingId);
        emit CollateralWithdrawn(listingId, msg.sender, refund);
    }

    /**
     * @notice Top-up listing collateral at any time.
     */
    function topUpCollateral(uint256 listingId)
        external
        payable
        listingExists(listingId)
        onlyListingProvider(listingId)
    {
        require(msg.value > 0, "No ETH sent");
        StorageListing storage l = listings[listingId];
        require(uint256(l.collateralDeposited) + msg.value <= type(uint96).max, "Overflow");
        l.collateralDeposited += uint96(msg.value);
        emit CollateralDeposited(listingId, msg.sender, msg.value);
    }

    
    //  RENTER: RENTAL MANAGEMENT
    

    /**
     * @notice Rent storage. Send exactly capacityGB * durationDays * pricePerGBPerDay wei.
     * @param accessEndpointHash  keccak256 hash of the off-chain endpoint string.
     */
    function rentStorage(
        uint256 listingId,
        uint256 capacityGB,
        uint256 durationDays,
        bytes32 accessEndpointHash
    ) external payable whenNotPaused nonReentrant returns (uint256 rentalId) {
        StorageListing storage l = listings[listingId];
        require(l.status == ListingStatus.Active,                                       "Listing not active");
        require(capacityGB >= 1 && capacityGB <= l.availableGB,                        "Invalid capacity");
        require(durationDays >= MIN_DURATION_DAYS && durationDays <= MAX_DURATION_DAYS,"Invalid duration");

        uint256 total      = capacityGB * durationDays * l.pricePerGBPerDay;
        uint256 fee        = (total * PLATFORM_FEE_BPS) / BPS_DENOMINATOR;
        uint256 collateral = _rentalCollateral(total);  
         

        require(msg.value == total, "Incorrect payment");

        uint256 freeCol = uint256(l.collateralDeposited) - l.lockedCollateral;
        require(freeCol >= collateral, "Provider collateral insufficient");

        l.availableGB      -= capacityGB;
        l.lockedCollateral += collateral;

        rentalId = ++_rentalCounter;

        // Write core fields
        RentalCore storage rc = rentalCores[rentalId];
        rc.provider            = l.provider;
        rc.renter              = msg.sender;
        rc.listingId           = listingId;
        rc.capacityGB          = capacityGB;
        rc.durationDays        = durationDays;
        rc.startTime           = block.timestamp;
        rc.endTime             = block.timestamp + (durationDays * 1 days);
        rc.status              = RentalStatus.Active;
        rc.renterAcknowledged  = false;
        rc.accessEndpointHash  = accessEndpointHash;

        // Write financial fields separately
        RentalFinancials storage rf = rentalFinancials[rentalId];
        rf.pricePerGBPerDay   = l.pricePerGBPerDay;
        rf.totalPayment       = total;
        rf.platformFee        = fee;
        rf.providerCollateral = collateral;

        _renterHistory[msg.sender].push(rentalId);
        _providerRentals[l.provider].push(rentalId);

        emit RentalCreated(rentalId, listingId, msg.sender, capacityGB, durationDays, total);
    }

    /**
     * @notice Renter confirms storage access was received.
     *         If endTime already passed, triggers immediate payout.
     */
    function acknowledgeRental(uint256 rentalId)
        external
        nonReentrant
        rentalExists(rentalId)
    {
        RentalCore storage rc = rentalCores[rentalId];
        require(rc.renter == msg.sender,          "Only renter");
        require(rc.status == RentalStatus.Active, "Not active");
        require(!rc.renterAcknowledged,           "Already acknowledged");

        rc.renterAcknowledged = true;
        emit RentalAcknowledged(rentalId, msg.sender);

        if (block.timestamp >= rc.endTime) {
            _completeRental(rentalId);
        }
    }

    /**
     * @notice Complete a rental after endTime.
     *         Requires renter ack OR ACK_TIMEOUT elapsed. Callable by anyone.
     */
    function completeRental(uint256 rentalId)
        external
        nonReentrant
        rentalExists(rentalId)
    {
        RentalCore storage rc = rentalCores[rentalId];
        require(rc.status == RentalStatus.Active,  "Not active");
        require(block.timestamp >= rc.endTime,     "Rental period not ended");
        require(
            rc.renterAcknowledged || block.timestamp >= rc.endTime + ACK_TIMEOUT,
            "Awaiting renter acknowledgement"
        );

        _completeRental(rentalId);
    }

    /**
     * @notice Cancel within grace period. Platform fee is still charged.
     */
    function cancelRental(uint256 rentalId)
        external
        nonReentrant
        rentalExists(rentalId)
    {
        RentalCore storage rc       = rentalCores[rentalId];
        RentalFinancials storage rf = rentalFinancials[rentalId];

        require(rc.renter == msg.sender,                                "Only renter can cancel");
        require(rc.status == RentalStatus.Active,                       "Not active");
        require(block.timestamp <= rc.startTime + CANCEL_GRACE_PERIOD,  "Grace period expired");

        rc.status = RentalStatus.Cancelled;

        StorageListing storage l = listings[rc.listingId];
        l.availableGB      += rc.capacityGB;

        // [L4] underflow guard
        require(l.lockedCollateral >= rf.providerCollateral, "Collateral accounting error");
        l.lockedCollateral -= rf.providerCollateral;

        uint256 refund = rf.totalPayment - rf.platformFee;
        platformTreasury += rf.platformFee;

        (bool ok,) = payable(rc.renter).call{value: refund}("");
        require(ok, "Refund failed");

        emit RentalCancelled(rentalId, refund, rf.platformFee);
    }

   
    //  DISPUTE RESOLUTION
    

    /**
     * @notice Either party raises a dispute.
     *         Allowed while Active OR within DISPUTE_WINDOW after endTime.
     */
    function raiseDispute(
        uint256         rentalId,
        string calldata reason
    ) external rentalExists(rentalId) onlyRentalParty(rentalId) {
        RentalCore storage rc = rentalCores[rentalId];

        // Allow dispute within window even if endTime just passed
        bool withinWindow = block.timestamp <= rc.endTime + DISPUTE_WINDOW;
        require(rc.status == RentalStatus.Active && withinWindow, "Not disputable");
        require(disputes[rentalId].raisedAt == 0, "Dispute already open");

        rc.status = RentalStatus.Disputed;

        disputes[rentalId] = Dispute({
            rentalId:   rentalId,
            initiator:  msg.sender,
            reason:     reason,
            raisedAt:   block.timestamp,
            outcome:    DisputeOutcome.Pending,
            resolver:   address(0),
            resolvedAt: 0
        });

        emit DisputeRaised(rentalId, msg.sender, reason);
    }

    /**
     * @notice Owner resolves a dispute.
     *
     *  ProviderWins → provider paid; collateral released back to listing pool.
     *  RenterWins   → renter refunded + receives slash bonus; collateral deducted.
     */
    function resolveDispute(
        uint256        rentalId,
        DisputeOutcome outcome
    ) external onlyOwner nonReentrant rentalExists(rentalId) {
        RentalCore storage rc       = rentalCores[rentalId];
        RentalFinancials storage rf = rentalFinancials[rentalId];
        Dispute storage d           = disputes[rentalId];

        require(rc.status == RentalStatus.Disputed, "Not in dispute");
        require(outcome != DisputeOutcome.Pending,  "Invalid outcome");

        d.outcome    = outcome;
        d.resolver   = msg.sender;
        d.resolvedAt = block.timestamp;
        rc.status    = RentalStatus.Resolved;

        StorageListing storage l = listings[rc.listingId];
        l.availableGB += rc.capacityGB;

        // [L4] underflow guard before releasing lock
        require(l.lockedCollateral >= rf.providerCollateral, "Collateral accounting error");
        l.lockedCollateral -= rf.providerCollateral;

        if (outcome == DisputeOutcome.ProviderWins) {
            uint256 providerPayout = rf.totalPayment - rf.platformFee;
            platformTreasury += rf.platformFee;

            (bool ok,) = payable(rc.provider).call{value: providerPayout}("");
            require(ok, "Provider payout failed");

        } else {
            // RenterWins: slash 50% of reserved collateral → renter gets bonus
            uint256 slash = (rf.providerCollateral * SLASH_PENALTY_BPS) / BPS_DENOMINATOR;
            if (slash > l.collateralDeposited) slash = uint256(l.collateralDeposited);

            l.collateralDeposited -= uint96(slash);

            uint256 slashFee    = (slash * PLATFORM_FEE_BPS) / BPS_DENOMINATOR;
            uint256 renterBonus = slash - slashFee;
            platformTreasury   += slashFee;

            uint256 renterTotal = rf.totalPayment + renterBonus;

            (bool ok,) = payable(rc.renter).call{value: renterTotal}("");
            require(ok, "Renter refund failed");
        }

        emit DisputeResolved(rentalId, outcome, msg.sender);
    }

    
    //  ADMIN
    

    function withdrawPlatformFees(address payable to) external onlyOwner nonReentrant {
        uint256 amount = platformTreasury;
        require(amount > 0, "Nothing to withdraw");
        platformTreasury = 0;

        (bool ok,) = to.call{value: amount}("");
        require(ok, "Withdrawal failed");

        emit PlatformFeesWithdrawn(to, amount);
    }

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

  
    //  VIEW HELPERS
    

    /**
     * @notice Quote a deal before committing.
     */
    function quoteDeal(
        uint256 listingId,
        uint256 capacityGB,
        uint256 durationDays
    ) external view listingExists(listingId) returns (
        uint256 total,
        uint256 platformFee,
        uint256 providerReceives,
        uint256 collateralRequired,
        bool    collateralAvailable
    ) {
        StorageListing storage l = listings[listingId];
        total               = capacityGB * durationDays * l.pricePerGBPerDay;
        platformFee         = (total * PLATFORM_FEE_BPS) / BPS_DENOMINATOR;
        providerReceives    = total - platformFee;
        collateralRequired  = _rentalCollateral(total);
        uint256 free        = uint256(l.collateralDeposited) - l.lockedCollateral;
        collateralAvailable = free >= collateralRequired;
    }

    function requiredCollateralForListing(
        uint256 capacityGB,
        uint256 pricePerGBPerDay
    ) external pure returns (uint256) {
        return _requiredCollateral(capacityGB, pricePerGBPerDay);
    }

    function freeCollateral(uint256 listingId)
        external
        view
        listingExists(listingId)
        returns (uint256)
    {
        StorageListing storage l = listings[listingId];
        return uint256(l.collateralDeposited) - l.lockedCollateral;
    }

    function isRentalActive(uint256 rentalId) external view returns (bool) {
        RentalCore storage rc = rentalCores[rentalId];
        return rc.status == RentalStatus.Active && block.timestamp < rc.endTime;
    }

    // [L5] Paginated getters — avoids out-of-gas on large arrays

    function getProviderListings(address provider, uint256 offset, uint256 limit)
        external view returns (uint256[] memory result)
    {
        return _paginate(_providerListings[provider], offset, limit);
    }

    function getRenterHistory(address renter, uint256 offset, uint256 limit)
        external view returns (uint256[] memory result)
    {
        return _paginate(_renterHistory[renter], offset, limit);
    }

    function getProviderRentals(address provider, uint256 offset, uint256 limit)
        external view returns (uint256[] memory result)
    {
        return _paginate(_providerRentals[provider], offset, limit);
    }

    function providerListingCount(address provider) external view returns (uint256) {
        return _providerListings[provider].length;
    }

    function renterHistoryCount(address renter) external view returns (uint256) {
        return _renterHistory[renter].length;
    }

    function providerRentalCount(address provider) external view returns (uint256) {
        return _providerRentals[provider].length;
    }

    // ─────────────────────────────────────────────────────────────
    //  INTERNALS
    // ─────────────────────────────────────────────────────────────

    function _completeRental(uint256 rentalId) internal {
        RentalCore storage rc       = rentalCores[rentalId];
        RentalFinancials storage rf = rentalFinancials[rentalId];

        rc.status = RentalStatus.Completed;

        StorageListing storage l = listings[rc.listingId];
        l.availableGB += rc.capacityGB;

        // [L4] underflow guard
        require(l.lockedCollateral >= rf.providerCollateral, "Collateral accounting error");
        l.lockedCollateral -= rf.providerCollateral;

        uint256 providerPayout = rf.totalPayment - rf.platformFee;
        platformTreasury      += rf.platformFee;

        (bool ok,) = payable(rc.provider).call{value: providerPayout}("");
        require(ok, "Provider payout failed");

        emit RentalCompleted(rentalId, providerPayout, rf.platformFee);
    }

    function _requiredCollateral(uint256 capacityGB, uint256 pricePerGBPerDay)
        internal pure returns (uint256)
    {
        return (capacityGB * 30 * pricePerGBPerDay * PROVIDER_COLLATERAL_RATIO) / 100;
    }

    function _rentalCollateral(uint256 totalPayment) internal pure returns (uint256) {
        return (totalPayment * PROVIDER_COLLATERAL_RATIO) / 100;
    }

    function _paginate(
        uint256[] storage arr,
        uint256 offset,
        uint256 limit
    ) internal view returns (uint256[] memory result) {
        uint256 total = arr.length;
        if (offset >= total) return new uint256[](0);
        uint256 end = offset + limit;
        if (end > total) end = total;
        result = new uint256[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            result[i - offset] = arr[i];
        }
    }

    // ─────────────────────────────────────────────────────────────
    //  FALLBACK
    // ─────────────────────────────────────────────────────────────

    receive() external payable {
        revert("Use createListing() or rentStorage()");
    }
}
