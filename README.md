# DiskSpaceRental — Decentralised Storage Marketplace

A trustless disk space rental platform built on Ethereum.

## Features
- Provider listing with collateral locking
- Escrow-based rental payments
- Renter acknowledgement system
- Dispute resolution with slash mechanism
- Platform fee management
- Frontend with MetaMask integration

## Tech Stack
- Solidity ^0.8.29
- OpenZeppelin (ReentrancyGuard, Ownable, Pausable)
- HTML, CSS, JavaScript
- Ethers.js v6

## Smart Contract Highlights
- Split struct design to avoid EVM stack-too-deep errors
- Paginated array getters to avoid out-of-gas issues
- Collateral locked per rental, not per listing
